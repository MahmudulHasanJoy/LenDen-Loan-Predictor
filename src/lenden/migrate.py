"""Versioned schema migrations.

    python -m lenden.migrate            # apply pending migrations to DATABASE_URL / LENDEN_DB
    python -m lenden.migrate --status   # list applied and pending migrations

Migrations are plain SQL files in migrations/<dialect>/NNNN_name.sql, applied in order and
recorded in schema_migrations. Render runs this as the pre-deploy command, so a failing
migration stops the deploy and the previous version keeps serving.
"""
from __future__ import annotations

import argparse
import re
from pathlib import Path

from . import clock

MIGRATIONS = Path(__file__).resolve().parent / "migrations"
_NAME = re.compile(r"^(\d{4})_[a-z0-9_]+\.sql$")


def available(dialect: str) -> list[tuple[str, Path]]:
    files = sorted(p for p in (MIGRATIONS / dialect).iterdir() if _NAME.match(p.name))
    return [(p.name[:4], p) for p in files]


def applied(db) -> set[str]:
    db.script("CREATE TABLE IF NOT EXISTS schema_migrations (version TEXT PRIMARY KEY, name TEXT NOT NULL, "
              "applied_at TEXT NOT NULL)")
    return {r[0] for r in db.execute("SELECT version FROM schema_migrations").fetchall()}


def migrate(db) -> list[str]:
    """Apply every pending migration. Returns the names applied."""
    done = applied(db)
    db.commit()
    ran = []
    for version, path in available(db.dialect):
        if version in done:
            continue
        db.script(path.read_text(encoding="utf-8"))
        db.execute("INSERT INTO schema_migrations (version, name, applied_at) VALUES (?,?,?)",
                   (version, path.name, clock.iso()))
        db.commit()
        ran.append(path.name)
    return ran


def main(argv=None):
    from . import db as database
    from .settings import database_target
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--status", action="store_true")
    args = ap.parse_args(argv)
    conn = database.connect(database_target(), migrate=False)
    if args.status:
        done = applied(conn)
        for version, path in available(conn.dialect):
            print(("applied " if version in done else "pending ") + path.name)
        return
    ran = migrate(conn)
    print("\n".join(f"applied {n}" for n in ran) or "database is up to date")
    conn.close()


if __name__ == "__main__":
    main()
