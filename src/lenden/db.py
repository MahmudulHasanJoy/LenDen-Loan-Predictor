"""Database layer: SQLite for local development, PostgreSQL (e.g. Supabase) in production.

    DATABASE_URL=postgresql://...   -> PostgreSQL via psycopg 3, small connection pool
    (unset)                         -> SQLite file at LENDEN_DB (default var/lenden.db)

Services write SQL once with `?` placeholders; this module adapts it per dialect.

Units of work: the API wraps each request in `with db.session():`, which takes a connection
from the pool, commits on success and rolls back on any error. Code running outside a session
(scripts, tests, the seeder) uses one shared "default" connection and commits explicitly.
"""
from __future__ import annotations

import contextvars
import json
import queue
import sqlite3
import threading
from contextlib import contextmanager, nullcontext
from pathlib import Path

from . import clock

try:                                    # PostgreSQL driver is optional for local SQLite use
    import psycopg
except ImportError:                     # pragma: no cover
    psycopg = None

# Every LenDen table, in a safe drop order (children first).
TABLES = (
    "shadow_scores", "drift_snapshots", "idempotency_keys", "job_runs", "feature_flags",
    "password_resets", "otp_codes", "refresh_tokens", "outbox", "notifications", "consents",
    "borrower_levels", "repayments", "loans", "documents", "document_requests",
    "application_events", "applications", "offers", "drafts", "model_versions", "audit_log",
    "org_settings", "users", "orgs", "schema_migrations",
)
JSON_COLS = ("inputs", "reasons", "reason_codes", "payload", "items", "metrics", "features",
             "report", "detail", "offer_rules", "terms", "demographics", "prefs", "response",
             "counterfactual", "notification_prefs")


def now() -> str:
    return clock.iso()


def to_postgres(sql: str) -> str:
    """Translate `?` placeholders to psycopg's `%s` (escaping literal %)."""
    return sql.replace("%", "%%").replace("?", "%s")


def is_postgres_url(url: str | None) -> bool:
    return bool(url) and str(url).startswith(("postgres://", "postgresql://"))


class Row:
    """Row usable by index (row[0]) and by name (row['email']), and convertible with dict()."""
    __slots__ = ("_keys", "_values")

    def __init__(self, keys, values):
        self._keys, self._values = keys, values

    def keys(self):
        return self._keys

    def __getitem__(self, k):
        if isinstance(k, int):
            return self._values[k]
        return self._values[self._keys.index(k)]

    def __len__(self):
        return len(self._values)


class _PgCursor:
    def __init__(self, cur):
        self._cur = cur
        self._keys = [d.name for d in cur.description] if cur.description else []
        self.rowcount = cur.rowcount

    def fetchone(self):
        r = self._cur.fetchone()
        return None if r is None else Row(self._keys, r)

    def fetchall(self):
        return [Row(self._keys, r) for r in self._cur.fetchall()]


class _Conn:
    """A raw connection plus the number of statements run since the last commit."""
    __slots__ = ("raw", "pending")

    def __init__(self, raw):
        self.raw, self.pending = raw, 0


class Database:
    def __init__(self, target: str | Path = ":memory:", pool_size: int = 5, migrate: bool = True):
        self.url = str(target)
        self.dialect = "postgres" if is_postgres_url(self.url) else "sqlite"
        self._lock = threading.RLock()        # guards the default connection (and all of SQLite)
        self._bound: contextvars.ContextVar = contextvars.ContextVar(f"lenden_db_{id(self)}", default=None)
        self._pool: queue.LifoQueue = queue.LifoQueue()
        self._max = max(1, pool_size)
        self._opened = 0
        self._pool_lock = threading.Lock()
        self._default = _Conn(self._open())
        if migrate:
            from .migrate import migrate as run_migrations
            run_migrations(self)

    # ---------------------------------------------------------- connections
    def _open(self):
        if self.dialect == "postgres":
            if psycopg is None:
                raise RuntimeError("DATABASE_URL points to PostgreSQL but psycopg is not installed. "
                                   "Run: pip install 'psycopg[binary]'")
            # prepare_threshold=None: Supabase's pooler does not support prepared statements.
            return psycopg.connect(self.url, autocommit=False, prepare_threshold=None, connect_timeout=15)
        if self.url != ":memory:":
            Path(self.url).parent.mkdir(parents=True, exist_ok=True)
        conn = sqlite3.connect(self.url, check_same_thread=False)
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA foreign_keys = ON")
        return conn

    def _checkout(self) -> _Conn:
        try:
            c = self._pool.get_nowait()
        except queue.Empty:
            with self._pool_lock:
                can_open = self._opened < self._max
                if can_open:
                    self._opened += 1
            if can_open:
                try:
                    return _Conn(self._open())
                except Exception:
                    with self._pool_lock:
                        self._opened -= 1
                    raise
            c = self._pool.get(timeout=30)
        if c.raw.closed:
            try:
                c.raw = self._open()
            except Exception:
                with self._pool_lock:
                    self._opened -= 1
                raise
        return c

    def _checkin(self, c: _Conn) -> None:
        if c.raw.closed:
            with self._pool_lock:
                self._opened -= 1
            return
        self._pool.put(c)

    @contextmanager
    def session(self):
        """One unit of work: commit on success, roll back on error. Nested calls join the outer one."""
        if self._bound.get() is not None:
            yield self
            return
        if self.dialect == "sqlite":
            with self._lock:
                token = self._bound.set(self._default)
                try:
                    yield self
                    self.commit()
                except BaseException:
                    self.rollback()
                    raise
                finally:
                    self._bound.reset(token)
            return
        c = self._checkout()
        token = self._bound.set(c)
        try:
            yield self
            self.commit()
        except BaseException:
            self.rollback()
            raise
        finally:
            self._bound.reset(token)
            self._checkin(c)

    def _current(self) -> _Conn:
        return self._bound.get() or self._default

    @property
    def IntegrityError(self):            # noqa: N802 - mirrors the DB-API name
        errs = (sqlite3.IntegrityError,)
        return errs + (psycopg.IntegrityError,) if psycopg else errs

    def _reconnect_if_safe(self, c: _Conn, exc) -> bool:
        """Re-open a dropped PostgreSQL connection (poolers close idle ones), if no work would be lost."""
        if self.dialect != "postgres" or c.pending:
            return False
        if not isinstance(exc, psycopg.OperationalError) and not c.raw.closed:
            return False
        try:
            c.raw.close()
        except Exception:
            pass
        c.raw = self._open()
        return True

    # ---------------------------------------------------------- statements
    def execute(self, sql: str, args=()):
        c = self._current()
        with (self._lock if c is self._default else nullcontext()):
            if self.dialect == "sqlite":
                cur = c.raw.execute(sql, tuple(args))
                c.pending += 1
                return cur
            try:
                cur = c.raw.execute(to_postgres(sql), tuple(args))
            except Exception as e:
                if psycopg and isinstance(e, (psycopg.OperationalError, psycopg.InterfaceError)) \
                        and self._reconnect_if_safe(c, e):
                    cur = c.raw.execute(to_postgres(sql), tuple(args))
                else:
                    raise
            c.pending += 1
            return _PgCursor(cur)

    def insert(self, sql: str, args=()) -> int:
        """Run an INSERT and return the new row's id."""
        if self.dialect == "sqlite":
            return self.execute(sql, args).lastrowid
        return self.execute(sql.rstrip().rstrip(";") + " RETURNING id", args).fetchone()[0]

    def script(self, sql: str) -> None:
        """Run several statements (migrations). Commits."""
        c = self._current()
        with self._lock:
            if self.dialect == "sqlite":
                c.raw.executescript(sql)
            else:
                c.raw.execute(sql)
                c.raw.commit()
            c.pending = 0

    def commit(self):
        c = self._current()
        with (self._lock if c is self._default else nullcontext()):
            c.raw.commit()
            c.pending = 0

    def rollback(self):
        c = self._current()
        with (self._lock if c is self._default else nullcontext()):
            try:
                c.raw.rollback()
            finally:
                c.pending = 0

    def try_lock(self, key: int) -> bool:
        """Cluster-wide lock for background jobs (PostgreSQL advisory lock; always true on SQLite)."""
        if self.dialect == "sqlite":
            return True
        return bool(self.execute("SELECT pg_try_advisory_xact_lock(?)", (key,)).fetchone()[0])

    # ---------------------------------------------------------- schema
    def init_schema(self):
        from .migrate import migrate as run_migrations
        run_migrations(self)

    def drop_all(self):
        """Delete every LenDen table (tests and `seed --reset` only)."""
        with self._lock:
            c = self._default
            for t in TABLES:
                c.raw.execute(f"DROP TABLE IF EXISTS {t}" + (" CASCADE" if self.dialect == "postgres" else ""))
            c.raw.commit()
            c.pending = 0

    def close(self):
        self._default.raw.close()
        while True:
            try:
                self._pool.get_nowait().raw.close()
            except queue.Empty:
                break


def connect(target: str | Path = ":memory:", pool_size: int = 5, migrate: bool = True) -> Database:
    return Database(target, pool_size=pool_size, migrate=migrate)


def row(r) -> dict | None:
    if r is None:
        return None
    d = dict(zip(r.keys(), [r[k] for k in r.keys()]))
    for c in JSON_COLS:
        if c in d and isinstance(d[c], str):
            try:
                d[c] = json.loads(d[c])
            except ValueError:
                pass
    return d


def rows(rs) -> list[dict]:
    return [row(r) for r in rs]
