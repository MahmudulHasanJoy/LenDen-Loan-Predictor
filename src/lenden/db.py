"""Database layer: SQLite for local development, PostgreSQL (e.g. Supabase) in production.

    DATABASE_URL=postgresql://...   -> PostgreSQL via psycopg 3
    (unset)                         -> SQLite file at LENDEN_DB (default var/lenden.db)

Services write SQL once with `?` placeholders; this module adapts it per dialect.
Every tenant-owned row carries org_id; queries in services.py always filter on it.
"""
from __future__ import annotations

import sqlite3
import threading
from datetime import datetime, timezone
from pathlib import Path

try:                                    # PostgreSQL driver is optional for local SQLite use
    import psycopg
except ImportError:                     # pragma: no cover
    psycopg = None

# ------------------------------------------------------------------ schemas
SCHEMA_SQLITE = """
PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS orgs (
    id          INTEGER PRIMARY KEY,
    name        TEXT NOT NULL,
    slug        TEXT NOT NULL UNIQUE,
    plan        TEXT NOT NULL DEFAULT 'free',
    active      INTEGER NOT NULL DEFAULT 1,
    created_at  TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS users (
    id            INTEGER PRIMARY KEY,
    email         TEXT NOT NULL UNIQUE,
    name          TEXT NOT NULL,
    password_hash TEXT NOT NULL,
    role          TEXT NOT NULL CHECK (role IN ('borrower','officer','admin','superadmin')),
    org_id        INTEGER REFERENCES orgs(id),
    active        INTEGER NOT NULL DEFAULT 1,
    created_at    TEXT NOT NULL,
    CHECK ((role IN ('officer','admin')) = (org_id IS NOT NULL))
);

CREATE TABLE IF NOT EXISTS org_settings (
    org_id          INTEGER PRIMARY KEY REFERENCES orgs(id),
    cost_ratio      INTEGER NOT NULL DEFAULT 20,
    review_capacity REAL,
    updated_at      TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS applications (
    id                  INTEGER PRIMARY KEY,
    org_id              INTEGER NOT NULL REFERENCES orgs(id),
    borrower_id         INTEGER NOT NULL REFERENCES users(id),
    inputs              TEXT NOT NULL,
    loan_amount         REAL NOT NULL,
    loan_purpose        TEXT NOT NULL,
    risk_score          REAL NOT NULL,
    default_probability REAL NOT NULL,
    light               TEXT NOT NULL,
    recommendation      TEXT NOT NULL CHECK (recommendation IN ('APPROVE','REVIEW')),
    threshold           REAL NOT NULL,
    reasons             TEXT NOT NULL,
    model_version       TEXT NOT NULL,
    status              TEXT NOT NULL DEFAULT 'submitted'
                        CHECK (status IN ('submitted','needs_docs','approved','rejected')),
    consent_at          TEXT NOT NULL,
    created_at          TEXT NOT NULL,
    decided_at          TEXT,
    decided_by          INTEGER REFERENCES users(id),
    decision_note       TEXT
);
CREATE INDEX IF NOT EXISTS ix_app_org_status ON applications(org_id, status);
CREATE INDEX IF NOT EXISTS ix_app_borrower ON applications(borrower_id);
CREATE INDEX IF NOT EXISTS ix_app_decided_by ON applications(decided_by);
CREATE INDEX IF NOT EXISTS ix_users_org ON users(org_id);

CREATE TABLE IF NOT EXISTS audit_log (
    id         INTEGER PRIMARY KEY,
    org_id     INTEGER,
    user_id    INTEGER,
    action     TEXT NOT NULL,
    target     TEXT,
    detail     TEXT,
    created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS ix_audit_org ON audit_log(org_id, id);
"""

# Same tables for PostgreSQL. Timestamps stay ISO-8601 text so both dialects behave identically.
SCHEMA_POSTGRES = """
CREATE TABLE IF NOT EXISTS orgs (
    id          SERIAL PRIMARY KEY,
    name        TEXT NOT NULL,
    slug        TEXT NOT NULL UNIQUE,
    plan        TEXT NOT NULL DEFAULT 'free',
    active      INTEGER NOT NULL DEFAULT 1,
    created_at  TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS users (
    id            SERIAL PRIMARY KEY,
    email         TEXT NOT NULL UNIQUE,
    name          TEXT NOT NULL,
    password_hash TEXT NOT NULL,
    role          TEXT NOT NULL CHECK (role IN ('borrower','officer','admin','superadmin')),
    org_id        INTEGER REFERENCES orgs(id),
    active        INTEGER NOT NULL DEFAULT 1,
    created_at    TEXT NOT NULL,
    CHECK ((role IN ('officer','admin')) = (org_id IS NOT NULL))
);

CREATE TABLE IF NOT EXISTS org_settings (
    org_id          INTEGER PRIMARY KEY REFERENCES orgs(id),
    cost_ratio      INTEGER NOT NULL DEFAULT 20,
    review_capacity DOUBLE PRECISION,
    updated_at      TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS applications (
    id                  SERIAL PRIMARY KEY,
    org_id              INTEGER NOT NULL REFERENCES orgs(id),
    borrower_id         INTEGER NOT NULL REFERENCES users(id),
    inputs              TEXT NOT NULL,
    loan_amount         DOUBLE PRECISION NOT NULL,
    loan_purpose        TEXT NOT NULL,
    risk_score          DOUBLE PRECISION NOT NULL,
    default_probability DOUBLE PRECISION NOT NULL,
    light               TEXT NOT NULL,
    recommendation      TEXT NOT NULL CHECK (recommendation IN ('APPROVE','REVIEW')),
    threshold           DOUBLE PRECISION NOT NULL,
    reasons             TEXT NOT NULL,
    model_version       TEXT NOT NULL,
    status              TEXT NOT NULL DEFAULT 'submitted'
                        CHECK (status IN ('submitted','needs_docs','approved','rejected')),
    consent_at          TEXT NOT NULL,
    created_at          TEXT NOT NULL,
    decided_at          TEXT,
    decided_by          INTEGER REFERENCES users(id),
    decision_note       TEXT
);
CREATE INDEX IF NOT EXISTS ix_app_org_status ON applications(org_id, status);
CREATE INDEX IF NOT EXISTS ix_app_borrower ON applications(borrower_id);
CREATE INDEX IF NOT EXISTS ix_app_decided_by ON applications(decided_by);
CREATE INDEX IF NOT EXISTS ix_users_org ON users(org_id);

CREATE TABLE IF NOT EXISTS audit_log (
    id         SERIAL PRIMARY KEY,
    org_id     INTEGER,
    user_id    INTEGER,
    action     TEXT NOT NULL,
    target     TEXT,
    detail     TEXT,
    created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS ix_audit_org ON audit_log(org_id, id);

-- Supabase exposes the public schema through its REST API. LenDen does not use that API,
-- so row-level security with no policies blocks it entirely. The backend connects as the
-- table owner, which bypasses RLS, so the app is unaffected.
ALTER TABLE orgs ENABLE ROW LEVEL SECURITY;
ALTER TABLE users ENABLE ROW LEVEL SECURITY;
ALTER TABLE org_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE applications ENABLE ROW LEVEL SECURITY;
ALTER TABLE audit_log ENABLE ROW LEVEL SECURITY;
"""

TABLES = ("audit_log", "applications", "org_settings", "users", "orgs")   # drop order
JSON_COLS = ("inputs", "reasons")


def now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


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

    def fetchone(self):
        r = self._cur.fetchone()
        return None if r is None else Row(self._keys, r)

    def fetchall(self):
        return [Row(self._keys, r) for r in self._cur.fetchall()]


class Database:
    """One connection shared by the app (the API serialises access with a lock)."""

    def __init__(self, target: str | Path = ":memory:"):
        self.url = str(target)
        self.dialect = "postgres" if is_postgres_url(self.url) else "sqlite"
        self._lock = threading.RLock()
        self._pending = 0          # statements since last commit/rollback
        self._conn = self._open()
        self.init_schema()

    # ---------------------------------------------------------- connection
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

    @property
    def IntegrityError(self):            # noqa: N802 - mirrors the DB-API name
        errs = (sqlite3.IntegrityError,)
        return errs + (psycopg.IntegrityError,) if psycopg else errs

    def _reconnect_if_safe(self, exc) -> bool:
        """Re-open a dropped PostgreSQL connection (poolers close idle ones), if no work would be lost."""
        if self.dialect != "postgres" or self._pending:
            return False
        if not isinstance(exc, psycopg.OperationalError) and not self._conn.closed:
            return False
        try:
            self._conn.close()
        except Exception:
            pass
        self._conn = self._open()
        return True

    # ---------------------------------------------------------- statements
    def execute(self, sql: str, args=()):
        with self._lock:
            if self.dialect == "sqlite":
                cur = self._conn.execute(sql, args)
                self._pending += 1
                return cur
            try:
                cur = self._conn.execute(to_postgres(sql), tuple(args))
            except Exception as e:
                if psycopg and isinstance(e, (psycopg.OperationalError, psycopg.InterfaceError)) \
                        and self._reconnect_if_safe(e):
                    cur = self._conn.execute(to_postgres(sql), tuple(args))
                else:
                    raise
            self._pending += 1
            return _PgCursor(cur)

    def insert(self, sql: str, args=()) -> int:
        """Run an INSERT and return the new row's id."""
        if self.dialect == "sqlite":
            return self.execute(sql, args).lastrowid
        return self.execute(sql.rstrip().rstrip(";") + " RETURNING id", args).fetchone()[0]

    def commit(self):
        with self._lock:
            self._conn.commit()
            self._pending = 0

    def rollback(self):
        with self._lock:
            try:
                self._conn.rollback()
            finally:
                self._pending = 0

    # ---------------------------------------------------------- schema
    def init_schema(self):
        with self._lock:
            if self.dialect == "sqlite":
                self._conn.executescript(SCHEMA_SQLITE)
            else:
                self._conn.execute(SCHEMA_POSTGRES)
                self._conn.commit()
            self._pending = 0

    def drop_all(self):
        """Delete every LenDen table (tests and `seed --reset` only)."""
        with self._lock:
            for t in TABLES:
                self._conn.execute(f"DROP TABLE IF EXISTS {t}" + (" CASCADE" if self.dialect == "postgres" else ""))
            self._conn.commit()
            self._pending = 0

    def close(self):
        self._conn.close()


def connect(target: str | Path = ":memory:") -> Database:
    return Database(target)


def row(r) -> dict | None:
    import json
    if r is None:
        return None
    d = dict(zip(r.keys(), [r[k] for k in r.keys()]))
    for c in JSON_COLS:
        if c in d and isinstance(d[c], str):
            d[c] = json.loads(d[c])
    return d


def rows(rs) -> list[dict]:
    return [row(r) for r in rs]
