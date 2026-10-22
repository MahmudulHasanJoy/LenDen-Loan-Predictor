"""Lenders: public list, settings and offer rules, team, and the platform owner's org admin."""
from __future__ import annotations

import re

from credit_risk.config import COST_FN, COST_FP
from credit_risk.offers import RulesError, clean_rules

from .. import db
from ..errors import BadRequest, Conflict, NotFound
from ..security import require
from ..settings import LOCALES, PLANS
from .base import Base, jdump


def _slug(name: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-") or "org"


FLAGS = {  # feature flags the platform owner can switch, with their defaults
    "offers_marketplace": True,      # borrowers see every lender's offer side by side
    "credit_ladder": True,           # ladder caps limit offer amounts
    "phone_login": True,             # phone + OTP sign-in
    "shadow_scoring": True,          # score applications with the shadow model too
    "email_notifications": True,
}


class Orgs(Base):
    # ================================================================ public
    def list_lenders(self) -> list[dict]:
        orgs = self._q("SELECT id, name, slug, plan, currency FROM orgs WHERE active=1 ORDER BY name")
        hours = {r["org_id"]: r for r in self._decision_hours()}
        for o in orgs:
            h = hours.get(o["id"])
            o["typical_decision_hours"] = h["hours"] if h else None
            rules = self._settings(o["id"])["offer_rules"]
            o["rate_from"] = rules["base_rate"]
            o["max_amount"] = rules["max_amount"]
        return orgs

    def _decision_hours(self) -> list[dict]:
        """Median hours from submission to decision per lender, over the last 200 decisions."""
        out = []
        rows = self._q("SELECT org_id, created_at, decided_at FROM applications WHERE decided_at IS NOT NULL "
                       "ORDER BY id DESC LIMIT 2000")
        by_org: dict[int, list[float]] = {}
        from .. import clock
        for r in rows:
            h = (clock.parse(r["decided_at"]) - clock.parse(r["created_at"])).total_seconds() / 3600
            by_org.setdefault(r["org_id"], []).append(h)
        for org_id, hs in by_org.items():
            hs = sorted(hs[:200])
            out.append({"org_id": org_id, "hours": round(hs[len(hs) // 2], 1)})
        return out

    # ================================================================ lender admin
    def get_settings(self, user: dict) -> dict:
        require(user, "admin", "officer")
        s = self._settings(user["org_id"])
        return {**s, "recommendation_threshold": self.recommendation_threshold(s),
                "max_cost_ratio": max(self.risk.threshold_by_ratio)}

    def update_settings(self, user: dict, cost_ratio: int | None = None, review_capacity: float | None = None,
                        clear_capacity: bool = False, sla_hours: int | None = None) -> dict:
        require(user, "admin")
        s = self._settings(user["org_id"])
        if cost_ratio is not None:
            if not 1 <= int(cost_ratio) <= max(self.risk.threshold_by_ratio):
                raise BadRequest("cost_ratio must be between 1 and 50.", code="COST_RATIO_RANGE")
            s["cost_ratio"] = int(cost_ratio)
        if clear_capacity:
            s["review_capacity"] = None
        elif review_capacity is not None:
            if not 0.01 <= review_capacity <= 1:
                raise BadRequest("review_capacity must be between 0.01 and 1.", code="CAPACITY_RANGE")
            s["review_capacity"] = float(review_capacity)
        if sla_hours is not None:
            if not 4 <= int(sla_hours) <= 24 * 14:
                raise BadRequest("sla_hours must be between 4 and 336.", code="SLA_RANGE")
            s["sla_hours"] = int(sla_hours)
        self._save_settings(user["org_id"], s)
        self._audit(user, "settings.updated", "org_settings",
                    {"cost_ratio": s["cost_ratio"], "review_capacity": s["review_capacity"],
                     "sla_hours": s["sla_hours"]})
        return self.get_settings(user)

    def _save_settings(self, org_id: int, s: dict) -> None:
        self.db.execute("""INSERT INTO org_settings (org_id, cost_ratio, review_capacity, offer_rules, sla_hours,
                           updated_at) VALUES (?,?,?,?,?,?) ON CONFLICT(org_id) DO UPDATE SET
                           cost_ratio=excluded.cost_ratio, review_capacity=excluded.review_capacity,
                           offer_rules=excluded.offer_rules, sla_hours=excluded.sla_hours,
                           updated_at=excluded.updated_at""",
                        (org_id, s["cost_ratio"], s["review_capacity"], jdump(s["offer_rules"]),
                         s.get("sla_hours") or 48, db.now()))

    def get_offer_rules(self, user: dict) -> dict:
        require(user, "admin", "officer")
        s = self._settings(user["org_id"])
        return {"rules": s["offer_rules"], "limits": {
            "amount_min": self.risk.schema["LoanAmount"]["min"], "amount_max": self.risk.schema["LoanAmount"]["max"],
            "rate_min": self.risk.schema["InterestRate"]["min"], "rate_max": self.risk.schema["InterestRate"]["max"],
            "terms": self.risk.schema["LoanTerm"].get("options", [])}}

    def update_offer_rules(self, user: dict, rules: dict) -> dict:
        require(user, "admin")
        s = self._settings(user["org_id"])
        try:
            s["offer_rules"] = clean_rules({**s["offer_rules"], **rules}, self.risk.schema)
        except RulesError as e:
            raise BadRequest("Some offer rules are not valid.", code="RULES_INVALID", fields=e.fields) from e
        self._save_settings(user["org_id"], s)
        self._audit(user, "offer_rules.updated", "org_settings", s["offer_rules"])
        return self.get_offer_rules(user)

    # ================================================================ team
    def list_team(self, user: dict) -> list[dict]:
        require(user, "admin")
        return self._q("""SELECT id, email, name, role, org_id, active, created_at, totp_enabled FROM users
                          WHERE org_id=? ORDER BY role, name""", (user["org_id"],))

    def add_team_member(self, user: dict, email: str, name: str, password: str, role: str = "officer") -> dict:
        require(user, "admin")
        if role not in ("officer", "admin"):
            raise BadRequest("role must be officer or admin.", code="ROLE_INVALID")
        member = self._create_user(email, name, password, role, user["org_id"])
        self._audit(user, "team.added", f"user:{member['id']}", {"role": role})
        return member

    def set_member_active(self, user: dict, member_id: int, active: bool) -> dict:
        require(user, "admin")
        m = self.get_user(member_id)
        if m["org_id"] != user["org_id"]:
            raise NotFound("User not found.", code="USER_NOT_FOUND")
        if m["id"] == user["id"] and not active:
            raise BadRequest("You cannot deactivate yourself.", code="SELF_DEACTIVATE")
        self.db.execute("UPDATE users SET active=? WHERE id=?", (int(active), member_id))
        if not active:
            self._revoke_all(member_id)
            self.db.execute("UPDATE applications SET assigned_to=NULL WHERE assigned_to=? AND status IN "
                            "('submitted','in_review','needs_docs')", (member_id,))
        self._audit(user, "team.activated" if active else "team.deactivated", f"user:{member_id}")
        return self.get_user(member_id)

    # ================================================================ platform owner
    def list_orgs(self, user: dict) -> list[dict]:
        require(user, "superadmin")
        return self._q("""SELECT o.*,
                (SELECT COUNT(*) FROM users u WHERE u.org_id=o.id) AS staff,
                (SELECT COUNT(*) FROM applications a WHERE a.org_id=o.id) AS applications,
                (SELECT COUNT(*) FROM loans l WHERE l.org_id=o.id AND l.status='active') AS active_loans
                FROM orgs o ORDER BY o.created_at, o.id""")

    def create_org(self, user: dict | None, name: str, plan: str, admin_email: str, admin_name: str,
                   admin_password: str, currency: str = "BDT", locale: str = "en") -> dict:
        if user is not None:
            require(user, "superadmin")
        if plan not in PLANS:
            raise BadRequest(f"plan must be one of {', '.join(PLANS)}.", code="PLAN_INVALID")
        if not (name or "").strip():
            raise BadRequest("Organisation name is required.", code="NAME_REQUIRED")
        if self._one("SELECT id FROM users WHERE email=?", ((admin_email or "").strip().lower(),)):
            raise Conflict("An account with this email already exists.", code="EMAIL_TAKEN")
        if locale not in LOCALES:
            locale = "en"
        slug, n = _slug(name), 1
        while self._one("SELECT id FROM orgs WHERE slug=?", (slug,)):
            n += 1
            slug = f"{_slug(name)}-{n}"
        org_id = self.db.insert("INSERT INTO orgs (name, slug, plan, currency, locale, created_at) VALUES (?,?,?,?,?,?)",
                                (name.strip(), slug, plan, (currency or "BDT").upper()[:3], locale, db.now()))
        self._save_settings(org_id, {"cost_ratio": COST_FN // COST_FP, "review_capacity": None,
                                     "offer_rules": clean_rules(None, self.risk.schema), "sla_hours": 48})
        admin = self._create_user(admin_email, admin_name, admin_password, "admin", org_id)
        self._audit(user, "org.created", f"org:{org_id}", {"plan": plan}, org_id=org_id)
        return {"org": self._org(org_id), "admin": admin}

    def set_org_active(self, user: dict, org_id: int, active: bool) -> dict:
        require(user, "superadmin")
        self._org(org_id)
        self.db.execute("UPDATE orgs SET active=? WHERE id=?", (int(active), org_id))
        self._audit(user, "org.activated" if active else "org.suspended", f"org:{org_id}", org_id=org_id)
        return self._org(org_id)

    def list_flags(self, user: dict) -> list[dict]:
        require(user, "superadmin")
        stored = {r["key"]: r for r in self._q("SELECT * FROM feature_flags")}
        return [{"key": k, "enabled": bool(stored[k]["enabled"]) if k in stored else d,
                 "default": d, "updated_at": stored.get(k, {}).get("updated_at")} for k, d in FLAGS.items()]

    def set_flag(self, user: dict, key: str, enabled: bool) -> list[dict]:
        require(user, "superadmin")
        if key not in FLAGS:
            raise NotFound("Unknown feature flag.", code="FLAG_NOT_FOUND")
        self.db.execute("""INSERT INTO feature_flags (key, enabled, updated_at) VALUES (?,?,?)
                           ON CONFLICT(key) DO UPDATE SET enabled=excluded.enabled, updated_at=excluded.updated_at""",
                        (key, int(enabled), db.now()))
        self._audit(user, "flag.updated", f"flag:{key}", {"enabled": enabled})
        return self.list_flags(user)

    def flag(self, key: str) -> bool:
        return self._flag(key, FLAGS.get(key, True))
