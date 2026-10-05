"""Business logic for every role. Framework-free: the API layer only maps HTTP to these calls.

Tenant isolation rule: officer/admin calls always filter by the caller's org_id.
"""
from __future__ import annotations

import json
import re
from collections import Counter
from datetime import datetime, timedelta, timezone

import numpy as np
import pandas as pd

from credit_risk.config import CAT_COLS, COST_FN, COST_FP, NUM_COLS
from credit_risk.monitoring import psi_report
from credit_risk.readiness import light_for, readiness
from credit_risk.service import CreditRiskService

from . import db
from .security import AuthError, Forbidden, create_token, hash_password, require, verify_password
from .settings import DECISIONS, PLANS, ROLES

FAIRNESS_ATTRS = ("MaritalStatus", "HasDependents")
MIN_GROUP = 5          # fewer decided applications than this -> "not enough data"
MIN_DRIFT_APPS = 100   # below this, stable data still shows PSI ~0.15 from sampling noise


class NotFound(Exception):
    pass


class Conflict(Exception):
    pass


class BadRequest(ValueError):
    pass


def _slug(name: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-") or "org"


def _public_user(u: dict) -> dict:
    return {k: u[k] for k in ("id", "email", "name", "role", "org_id", "active", "created_at")}


class Platform:
    def __init__(self, conn: db.Database, risk: CreditRiskService):
        self.db = conn
        self.risk = risk
        self.hash_iterations: int | None = None    # None = secure default; seed uses fewer for demo users
        ref = risk.reference_sample
        self._ref_inputs = ref[risk.features] if ref is not None else None
        self._ref_scores = (risk.pipeline.predict_proba(self._ref_inputs)[:, 1]
                            if ref is not None else None)

    # ================================================================ helpers
    def _q(self, sql: str, args=()) -> list[dict]:
        return db.rows(self.db.execute(sql, args).fetchall())

    def _one(self, sql: str, args=()) -> dict | None:
        return db.row(self.db.execute(sql, args).fetchone())

    def _audit(self, user: dict | None, action: str, target: str = "", detail: dict | None = None,
               org_id: int | None = None) -> None:
        self.db.execute(
            "INSERT INTO audit_log (org_id, user_id, action, target, detail, created_at) VALUES (?,?,?,?,?,?)",
            (org_id if org_id is not None else (user or {}).get("org_id"),
             (user or {}).get("id"), action, target, json.dumps(detail or {}), db.now()))

    def _settings(self, org_id: int) -> dict:
        s = self._one("SELECT cost_ratio, review_capacity, updated_at FROM org_settings WHERE org_id=?",
                      (org_id,))
        return s or {"cost_ratio": COST_FN // COST_FP, "review_capacity": None, "updated_at": None}

    def _org(self, org_id: int) -> dict:
        o = self._one("SELECT * FROM orgs WHERE id=?", (org_id,))
        if not o:
            raise NotFound("Lender not found.")
        return o

    # ================================================================ accounts
    def _create_user(self, email: str, name: str, password: str, role: str,
                     org_id: int | None = None) -> dict:
        if role not in ROLES:
            raise BadRequest(f"Unknown role {role!r}.")
        if len(password) < 8:
            raise BadRequest("Password must be at least 8 characters.")
        if "@" not in email:
            raise BadRequest("Enter a valid email address.")
        email = email.strip().lower()
        # Check first so PostgreSQL never enters an aborted transaction on the common case.
        if self._one("SELECT id FROM users WHERE email=?", (email,)):
            raise Conflict("An account with this email already exists.")
        try:
            user_id = self.db.insert(
                "INSERT INTO users (email, name, password_hash, role, org_id, created_at) VALUES (?,?,?,?,?,?)",
                (email, name.strip(), hash_password(password, self.hash_iterations), role, org_id, db.now()))
        except self.db.IntegrityError as e:          # race with a concurrent sign-up
            raise Conflict("An account with this email already exists.") from e
        return self.get_user(user_id)

    def get_user(self, user_id: int) -> dict:
        u = self._one("SELECT * FROM users WHERE id=?", (user_id,))
        if not u:
            raise NotFound("User not found.")
        return _public_user(u)

    def register_borrower(self, email: str, name: str, password: str) -> dict:
        user = self._create_user(email, name, password, "borrower")
        self.db.commit()
        return {"token": create_token(user), "user": user}

    def login(self, email: str, password: str) -> dict:
        u = self._one("SELECT * FROM users WHERE email=?", (email.strip().lower(),))
        if not u or not verify_password(password, u["password_hash"]):
            raise AuthError("Wrong email or password.")
        if not u["active"]:
            raise AuthError("This account is deactivated.")
        if u["org_id"] and not self._org(u["org_id"])["active"]:
            raise AuthError("Your organisation's account is suspended.")
        user = _public_user(u)
        out = {"token": create_token(user), "user": user}
        if user["org_id"]:
            out["org"] = self._org(user["org_id"])
        return out

    def user_from_claims(self, claims: dict) -> dict:
        try:
            user = self.get_user(int(claims["sub"]))
        except (NotFound, KeyError, ValueError) as e:
            raise AuthError("Account no longer exists.") from e
        if not user["active"]:
            raise AuthError("This account is deactivated.")
        return user

    def me(self, user: dict) -> dict:
        out = {"user": user}
        if user["org_id"]:
            out["org"] = self._org(user["org_id"])
        return out

    # ================================================================ public
    def list_lenders(self) -> list[dict]:
        return self._q("SELECT id, name, slug, plan FROM orgs WHERE active=1 ORDER BY name")

    def check_readiness(self, inputs: dict) -> dict:
        return readiness(self.risk, inputs)

    # ================================================================ borrower
    def apply(self, borrower: dict, org_id: int, inputs: dict, consent: bool) -> dict:
        require(borrower, "borrower")
        if not consent:
            raise BadRequest("You must agree to share your details with the lender.")
        org = self._org(org_id)
        if not org["active"]:
            raise BadRequest("This lender is not accepting applications.")
        pending = self._one(
            "SELECT id FROM applications WHERE borrower_id=? AND org_id=? AND status IN ('submitted','needs_docs')",
            (borrower["id"], org_id))
        if pending:
            raise Conflict("You already have an open application with this lender.")

        settings = self._settings(org_id)
        pred = self.risk.predict(inputs, cost_ratio=settings["cost_ratio"])
        threshold = self.recommendation_threshold(settings)
        clean = self.risk.validate(inputs).iloc[0].to_dict()
        clean = {k: (v.item() if hasattr(v, "item") else v) for k, v in clean.items()}
        ts = db.now()
        app_id = self.db.insert(
            """INSERT INTO applications (org_id, borrower_id, inputs, loan_amount, loan_purpose, risk_score,
               default_probability, light, recommendation, threshold, reasons, model_version,
               consent_at, created_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
            (org_id, borrower["id"], json.dumps(clean), clean["LoanAmount"], clean["LoanPurpose"],
             pred["risk_score"], pred["default_probability"], light_for(pred["default_probability"]),
             "REVIEW" if pred["risk_score"] >= threshold else "APPROVE", threshold,
             json.dumps(pred["reasons"]), f"{pred['model']} v{self.risk.version}", ts, ts))
        self._audit(borrower, "application.submitted", f"application:{app_id}", org_id=org_id)
        self.db.commit()
        return self._borrower_view(self._get_app(app_id))

    def my_applications(self, borrower: dict) -> list[dict]:
        require(borrower, "borrower")
        apps = self._q("""SELECT a.*, o.name AS lender FROM applications a JOIN orgs o ON o.id=a.org_id
                          WHERE a.borrower_id=? ORDER BY a.created_at DESC, a.id DESC""", (borrower["id"],))
        return [self._borrower_view(a) for a in apps]

    def _borrower_view(self, a: dict) -> dict:
        lender = a.get("lender") or self._org(a["org_id"])["name"]
        return {"id": a["id"], "lender": lender, "org_id": a["org_id"], "loan_amount": a["loan_amount"],
                "loan_purpose": a["loan_purpose"], "light": a["light"], "status": a["status"],
                "decision_note": a["decision_note"], "created_at": a["created_at"],
                "decided_at": a["decided_at"]}

    # ================================================================ officer
    def recommendation_threshold(self, settings: dict) -> float:
        thr = self.risk.threshold_for(settings["cost_ratio"])
        cap = settings.get("review_capacity")
        if cap and self._ref_scores is not None:
            thr = max(thr, float(np.quantile(self._ref_scores, 1 - cap)))
        return round(thr, 4)

    def _get_app(self, app_id: int) -> dict:
        a = self._one("SELECT * FROM applications WHERE id=?", (app_id,))
        if not a:
            raise NotFound("Application not found.")
        return a

    def list_applications(self, user: dict, status: str | None = None, light: str | None = None,
                          sort: str = "risk", limit: int = 100, offset: int = 0) -> dict:
        require(user, "officer", "admin")
        where, args = ["a.org_id=?"], [user["org_id"]]
        if status == "pending":
            where.append("a.status IN ('submitted','needs_docs')")
        elif status:
            where.append("a.status=?"); args.append(status)
        if light:
            where.append("a.light=?"); args.append(light)
        order = {"risk": "a.risk_score DESC", "newest": "a.created_at DESC, a.id DESC",
                 "oldest": "a.created_at ASC, a.id ASC", "amount": "a.loan_amount DESC"}.get(sort)
        if order is None:
            raise BadRequest("sort must be one of risk, newest, oldest, amount.")
        total = self.db.execute(f"SELECT COUNT(*) FROM applications a WHERE {' AND '.join(where)}",
                                args).fetchone()[0]
        items = self._q(f"""SELECT a.id, a.loan_amount, a.loan_purpose, a.risk_score, a.default_probability,
                                   a.light, a.recommendation, a.status, a.created_at, u.name AS borrower_name
                            FROM applications a JOIN users u ON u.id=a.borrower_id
                            WHERE {' AND '.join(where)} ORDER BY {order} LIMIT ? OFFSET ?""",
                        args + [min(limit, 500), offset])
        return {"total": total, "items": items}

    def get_application(self, user: dict, app_id: int) -> dict:
        require(user, "officer", "admin")
        a = self._get_app(app_id)
        if a["org_id"] != user["org_id"]:
            raise NotFound("Application not found.")      # never reveal other tenants' data
        b = self.get_user(a["borrower_id"])
        decider = self.get_user(a["decided_by"])["name"] if a["decided_by"] else None
        a.update({"borrower": {"id": b["id"], "name": b["name"], "email": b["email"]},
                  "decided_by_name": decider})
        return a

    def decide(self, user: dict, app_id: int, decision: str, note: str = "") -> dict:
        require(user, "officer", "admin")
        if decision not in DECISIONS:
            raise BadRequest(f"decision must be one of {', '.join(DECISIONS)}.")
        a = self.get_application(user, app_id)
        if a["status"] in ("approved", "rejected"):
            raise Conflict("This application has already been decided.")
        if decision == "rejected" and not note.strip():
            raise BadRequest("Please give the borrower a reason when rejecting.")
        self.db.execute("""UPDATE applications SET status=?, decision_note=?, decided_at=?, decided_by=?
                           WHERE id=?""", (decision, note.strip() or None, db.now(), user["id"], app_id))
        self._audit(user, f"application.{decision}", f"application:{app_id}",
                    {"recommendation": a["recommendation"], "note": note.strip()})
        self.db.commit()
        return self.get_application(user, app_id)

    # ================================================================ admin
    def get_settings(self, user: dict) -> dict:
        require(user, "admin", "officer")
        s = self._settings(user["org_id"])
        return {**s, "recommendation_threshold": self.recommendation_threshold(s),
                "max_cost_ratio": max(self.risk.threshold_by_ratio)}

    def update_settings(self, user: dict, cost_ratio: int | None = None,
                        review_capacity: float | None = None, clear_capacity: bool = False) -> dict:
        require(user, "admin")
        s = self._settings(user["org_id"])
        if cost_ratio is not None:
            if not 1 <= int(cost_ratio) <= max(self.risk.threshold_by_ratio):
                raise BadRequest("cost_ratio must be between 1 and 50.")
            s["cost_ratio"] = int(cost_ratio)
        if clear_capacity:
            s["review_capacity"] = None
        elif review_capacity is not None:
            if not 0.01 <= review_capacity <= 1:
                raise BadRequest("review_capacity must be between 0.01 and 1.")
            s["review_capacity"] = float(review_capacity)
        self.db.execute("""INSERT INTO org_settings (org_id, cost_ratio, review_capacity, updated_at)
                           VALUES (?,?,?,?) ON CONFLICT(org_id) DO UPDATE SET
                           cost_ratio=excluded.cost_ratio, review_capacity=excluded.review_capacity,
                           updated_at=excluded.updated_at""",
                        (user["org_id"], s["cost_ratio"], s["review_capacity"], db.now()))
        self._audit(user, "settings.updated", "org_settings",
                    {"cost_ratio": s["cost_ratio"], "review_capacity": s["review_capacity"]})
        self.db.commit()
        return self.get_settings(user)

    def list_team(self, user: dict) -> list[dict]:
        require(user, "admin")
        return self._q("""SELECT id, email, name, role, org_id, active, created_at FROM users
                          WHERE org_id=? ORDER BY role, name""", (user["org_id"],))

    def add_team_member(self, user: dict, email: str, name: str, password: str,
                        role: str = "officer") -> dict:
        require(user, "admin")
        if role not in ("officer", "admin"):
            raise BadRequest("role must be officer or admin.")
        member = self._create_user(email, name, password, role, user["org_id"])
        self._audit(user, "team.added", f"user:{member['id']}", {"role": role})
        self.db.commit()
        return member

    def set_member_active(self, user: dict, member_id: int, active: bool) -> dict:
        require(user, "admin")
        m = self.get_user(member_id)
        if m["org_id"] != user["org_id"]:
            raise NotFound("User not found.")
        if m["id"] == user["id"] and not active:
            raise BadRequest("You cannot deactivate yourself.")
        self.db.execute("UPDATE users SET active=? WHERE id=?", (int(active), member_id))
        self._audit(user, "team.activated" if active else "team.deactivated", f"user:{member_id}")
        self.db.commit()
        return self.get_user(member_id)

    def dashboard(self, user: dict) -> dict:
        require(user, "admin", "officer")
        apps = self._q("SELECT * FROM applications WHERE org_id=?", (user["org_id"],))
        status = Counter(a["status"] for a in apps)
        lights = Counter(a["light"] for a in apps)
        decided = [a for a in apps if a["status"] in ("approved", "rejected")]
        n_dec = len(decided)
        overrides = sum((a["recommendation"] == "APPROVE") != (a["status"] == "approved") for a in decided)
        hours = [(datetime.fromisoformat(a["decided_at"]) - datetime.fromisoformat(a["created_at"]))
                 .total_seconds() / 3600 for a in decided if a["decided_at"]]
        today = datetime.now(timezone.utc).date()
        days = [(today - timedelta(days=i)).isoformat() for i in range(13, -1, -1)]
        per_day = Counter(a["created_at"][:10] for a in apps)
        return {
            "totals": {"applications": len(apps),
                       "pending": status["submitted"] + status["needs_docs"],
                       **{s: status[s] for s in ("submitted", "needs_docs", "approved", "rejected")}},
            "lights": {k: lights[k] for k in ("green", "yellow", "red")},
            "approval_rate": round(status["approved"] / n_dec, 4) if n_dec else None,
            "review_recommended_rate": (round(sum(a["recommendation"] == "REVIEW" for a in apps) / len(apps), 4)
                                        if apps else None),
            "override_rate": round(overrides / n_dec, 4) if n_dec else None,
            "avg_default_probability": (round(float(np.mean([a["default_probability"] for a in apps])), 4)
                                        if apps else None),
            "avg_hours_to_decision": round(float(np.mean(hours)), 1) if hours else None,
            "trend": [{"date": d, "applications": per_day.get(d, 0)} for d in days],
            "fairness": self._fairness(decided),
            "drift": self._drift(apps),
            "settings": self.get_settings(user),
        }

    def _fairness(self, decided: list[dict]) -> list[dict]:
        out = []
        for attr in FAIRNESS_ATTRS:
            groups: dict[str, list[int]] = {}
            for a in decided:
                groups.setdefault(str(a["inputs"].get(attr)), []).append(int(a["status"] == "approved"))
            rates = {g: (sum(v) / len(v), len(v)) for g, v in groups.items() if len(v) >= MIN_GROUP}
            if len(rates) < 2:
                out.append({"attribute": attr, "status": "not enough data", "groups": []})
                continue
            best = max(r for r, _ in rates.values()) or 1.0
            gs = [{"group": g, "n": n, "approval_rate": round(r, 4),
                   "disparate_impact": round(r / best, 4) if best else None}
                  for g, (r, n) in sorted(rates.items())]
            worst = min(g["disparate_impact"] for g in gs)
            out.append({"attribute": attr, "worst_disparate_impact": worst,
                        "status": "ok" if worst >= 0.8 else "check", "groups": gs})
        return out

    def _drift(self, apps: list[dict]) -> dict:
        if self._ref_inputs is None or len(apps) < MIN_DRIFT_APPS:
            return {"status": "not enough data", "min_applications": MIN_DRIFT_APPS, "features": []}
        cur = pd.DataFrame([a["inputs"] for a in apps])[self.risk.features]
        num = [c for c in NUM_COLS if c in self.risk.features]
        cat = [c for c in CAT_COLS if c in self.risk.features]
        rep = psi_report(self._ref_inputs, cur, num, cat, bins=5 if len(cur) < 500 else 10)
        worst = rep.iloc[0]
        return {"status": worst["status"], "max_psi": round(float(worst["psi"]), 4),
                "features": [{"feature": r.feature, "psi": round(float(r.psi), 4), "status": r.status}
                             for r in rep.head(6).itertuples()]}

    def audit_log(self, user: dict, limit: int = 50) -> list[dict]:
        require(user, "admin")
        return self._q("""SELECT l.*, u.name AS user_name FROM audit_log l LEFT JOIN users u ON u.id=l.user_id
                          WHERE l.org_id=? ORDER BY l.id DESC LIMIT ?""", (user["org_id"], limit))

    # ================================================================ super admin
    def list_orgs(self, user: dict) -> list[dict]:
        require(user, "superadmin")
        return self._q("""SELECT o.*,
                (SELECT COUNT(*) FROM users u WHERE u.org_id=o.id) AS staff,
                (SELECT COUNT(*) FROM applications a WHERE a.org_id=o.id) AS applications
                FROM orgs o ORDER BY o.created_at, o.id""")

    def create_org(self, user: dict | None, name: str, plan: str, admin_email: str,
                   admin_name: str, admin_password: str) -> dict:
        if user is not None:
            require(user, "superadmin")
        if plan not in PLANS:
            raise BadRequest(f"plan must be one of {', '.join(PLANS)}.")
        if not name.strip():
            raise BadRequest("Organisation name is required.")
        slug, n = _slug(name), 1
        while self._one("SELECT id FROM orgs WHERE slug=?", (slug,)):
            n += 1
            slug = f"{_slug(name)}-{n}"
        org_id = self.db.insert("INSERT INTO orgs (name, slug, plan, created_at) VALUES (?,?,?,?)",
                                (name.strip(), slug, plan, db.now()))
        self.db.execute("INSERT INTO org_settings (org_id, cost_ratio, review_capacity, updated_at) VALUES (?,?,?,?)",
                        (org_id, COST_FN // COST_FP, None, db.now()))
        try:
            admin = self._create_user(admin_email, admin_name, admin_password, "admin", org_id)
        except Exception:
            self.db.rollback()
            raise
        self._audit(user, "org.created", f"org:{org_id}", {"plan": plan}, org_id=org_id)
        self.db.commit()
        return {"org": self._org(org_id), "admin": admin}

    def set_org_active(self, user: dict, org_id: int, active: bool) -> dict:
        require(user, "superadmin")
        self._org(org_id)
        self.db.execute("UPDATE orgs SET active=? WHERE id=?", (int(active), org_id))
        self._audit(user, "org.activated" if active else "org.suspended", f"org:{org_id}", org_id=org_id)
        self.db.commit()
        return self._org(org_id)

    def platform_stats(self, user: dict) -> dict:
        require(user, "superadmin")
        one = lambda sql: self.db.execute(sql).fetchone()[0]  # noqa: E731
        return {"orgs": one("SELECT COUNT(*) FROM orgs"),
                "active_orgs": one("SELECT COUNT(*) FROM orgs WHERE active=1"),
                "borrowers": one("SELECT COUNT(*) FROM users WHERE role='borrower'"),
                "staff": one("SELECT COUNT(*) FROM users WHERE role IN ('officer','admin')"),
                "applications": one("SELECT COUNT(*) FROM applications"),
                "plans": dict(Counter(r["plan"] for r in self._q("SELECT plan FROM orgs")))}
