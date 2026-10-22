"""Shared plumbing for the domain services: queries, audit, events, notifications, settings."""
from __future__ import annotations

import json
from datetime import timedelta

import numpy as np

from credit_risk.config import COST_FN, COST_FP
from credit_risk.offers import RulesError, clean_rules

from .. import clock, db
from ..errors import BadRequest, NotFound


def jdump(v) -> str:
    return json.dumps(v, default=_np_default)


def _np_default(o):
    if hasattr(o, "item"):
        return o.item()
    raise TypeError(f"not JSON serialisable: {type(o).__name__}")


def py(v):
    """numpy scalars -> plain Python (for JSON responses)."""
    if isinstance(v, dict):
        return {k: py(x) for k, x in v.items()}
    if isinstance(v, (list, tuple)):
        return [py(x) for x in v]
    return v.item() if hasattr(v, "item") else v


def public_user(u: dict) -> dict:
    out = {k: u.get(k) for k in ("id", "email", "name", "role", "org_id", "active", "created_at",
                                 "phone", "locale")}
    out["phone_verified"] = bool(u.get("phone_verified_at"))
    out["totp_enabled"] = bool(u.get("totp_enabled"))
    out["notification_prefs"] = u.get("notification_prefs") or {"email": True}
    return out


class Base:
    """Every domain mixin inherits this. `self.db` is the Database, `self.risk` the active model."""

    db: db.Database

    # ---------------------------------------------------------------- queries
    def _q(self, sql: str, args=()) -> list[dict]:
        return db.rows(self.db.execute(sql, args).fetchall())

    def _one(self, sql: str, args=()) -> dict | None:
        return db.row(self.db.execute(sql, args).fetchone())

    def _scalar(self, sql: str, args=()):
        r = self.db.execute(sql, args).fetchone()
        return r[0] if r else None

    # ---------------------------------------------------------------- history
    def _audit(self, user: dict | None, action: str, target: str = "", detail: dict | None = None,
               org_id: int | None = None) -> None:
        self.db.execute(
            "INSERT INTO audit_log (org_id, user_id, action, target, detail, created_at) VALUES (?,?,?,?,?,?)",
            (org_id if org_id is not None else (user or {}).get("org_id"),
             (user or {}).get("id"), action, target, jdump(detail or {}), db.now()))

    def _event(self, app_id: int, from_status: str | None, to_status: str, actor: dict | None,
               note: str | None = None) -> None:
        self.db.execute("""INSERT INTO application_events (application_id, from_status, to_status, actor_id,
                           note, created_at) VALUES (?,?,?,?,?,?)""",
                        (app_id, from_status, to_status, (actor or {}).get("id"), note, db.now()))

    def _emit(self, event: str, payload: dict) -> None:
        """Domain event -> outbox, in the same transaction as the change that caused it."""
        self.db.execute("INSERT INTO outbox (event, payload, created_at) VALUES (?,?,?)",
                        (event, jdump(payload), db.now()))

    def _notify(self, user_id: int, event: str, payload: dict | None = None, email: bool = True) -> None:
        """In-app notification now; email/SMS later via the outbox dispatcher."""
        payload = payload or {}
        self.db.execute("INSERT INTO notifications (user_id, event, payload, created_at) VALUES (?,?,?,?)",
                        (user_id, event, jdump(payload), db.now()))
        if email:
            self._emit("notify.email", {"user_id": user_id, "event": event, "data": payload})

    # ---------------------------------------------------------------- orgs and settings
    def _org(self, org_id: int) -> dict:
        o = self._one("SELECT * FROM orgs WHERE id=?", (org_id,))
        if not o:
            raise NotFound("Lender not found.", code="LENDER_NOT_FOUND")
        return o

    def _settings(self, org_id: int) -> dict:
        s = self._one("SELECT cost_ratio, review_capacity, offer_rules, sla_hours, updated_at "
                      "FROM org_settings WHERE org_id=?", (org_id,))
        s = s or {"cost_ratio": COST_FN // COST_FP, "review_capacity": None, "offer_rules": None,
                  "sla_hours": 48, "updated_at": None}
        try:
            s["offer_rules"] = clean_rules(s.get("offer_rules"), self.risk.schema)
        except RulesError:
            s["offer_rules"] = clean_rules(None, self.risk.schema)
        return s

    def recommendation_threshold(self, settings: dict) -> float:
        thr = self.risk.threshold_for(settings["cost_ratio"])
        cap = settings.get("review_capacity")
        if cap and self._ref_scores is not None:
            thr = max(thr, float(np.quantile(self._ref_scores, 1 - cap)))
        return round(thr, 4)

    def _flag(self, key: str, default: bool = True) -> bool:
        v = self._scalar("SELECT enabled FROM feature_flags WHERE key=?", (key,))
        return default if v is None else bool(v)

    @staticmethod
    def _later(**kw) -> str:
        return clock.iso(clock.utcnow() + timedelta(**kw))

    @staticmethod
    def _require_text(value: str | None, field: str, message: str) -> str:
        v = (value or "").strip()
        if not v:
            raise BadRequest(message, code="FIELD_REQUIRED", fields={field: "required"})
        return v
