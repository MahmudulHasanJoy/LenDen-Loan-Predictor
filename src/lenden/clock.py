"""One place for "now", so tests and the demo seeder can move time forward."""
from __future__ import annotations

from datetime import date, datetime, timedelta, timezone

_offset = timedelta(0)
_frozen: datetime | None = None


def utcnow() -> datetime:
    return (_frozen or datetime.now(timezone.utc)) + _offset


def today() -> date:
    return utcnow().date()


def iso(dt: datetime | None = None) -> str:
    return (dt or utcnow()).astimezone(timezone.utc).isoformat(timespec="seconds")


def parse(ts: str) -> datetime:
    dt = datetime.fromisoformat(ts)
    return dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)


def advance(**kwargs) -> None:
    """Move the clock forward, e.g. advance(days=3). Tests only."""
    global _offset
    _offset += timedelta(**kwargs)


def freeze(dt: datetime | None) -> None:
    global _frozen
    _frozen = dt


def reset() -> None:
    global _offset, _frozen
    _offset, _frozen = timedelta(0), None
