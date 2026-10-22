"""Dashboards: officer/admin dashboard, fairness, drift, portfolio, audit log and platform stats."""
from __future__ import annotations

from collections import Counter
from datetime import date, timedelta

import numpy as np
import pandas as pd

from credit_risk.config import CAT_COLS, NUM_COLS
from credit_risk.ladder import LEVELS
from credit_risk.monitoring import psi_report

from .. import clock, db
from ..security import require
from .base import Base, jdump, py

FAIRNESS_ATTRS = ("gender", "age_band")      # optional, self-reported, never used by the model
MIN_GROUP = 5           # fewer decided applications than this -> "not enough data"
MIN_DRIFT_APPS = 100    # below this, stable data still shows PSI ~0.15 from sampling noise
OPEN = ("submitted", "in_review", "needs_docs")


class Insights(Base):
    # ================================================================ dashboard
    def dashboard(self, user: dict) -> dict:
        require(user, "admin", "officer")
        apps = self._q("SELECT * FROM applications WHERE org_id=?", (user["org_id"],))
        status = Counter(a["status"] for a in apps)
        lights = Counter(a["light"] for a in apps)
        odds = Counter(a.get("odds") or "unknown" for a in apps)
        decided = [a for a in apps if a["status"] in ("approved", "rejected")]
        n_dec = len(decided)
        overrides = sum((a["recommendation"] == "APPROVE") != (a["status"] == "approved") for a in decided)
        hours = [(clock.parse(a["decided_at"]) - clock.parse(a["created_at"])).total_seconds() / 3600
                 for a in decided if a["decided_at"]]
        now = clock.utcnow()
        breaches = sum(1 for a in apps if a["status"] in OPEN and a.get("sla_due_at")
                       and clock.parse(a["sla_due_at"]) < now)
        today = clock.today()
        days = [(today - timedelta(days=i)).isoformat() for i in range(13, -1, -1)]
        per_day = Counter(a["created_at"][:10] for a in apps)
        return py({
            "totals": {"applications": len(apps), "pending": sum(status[s] for s in OPEN),
                       **{s: status[s] for s in ("submitted", "in_review", "needs_docs", "approved", "rejected",
                                                  "withdrawn")}},
            "lights": {k: lights[k] for k in ("green", "yellow", "red")},
            "odds": {k: odds[k] for k in ("excellent", "good", "fair", "low")},
            "sla_breaches": breaches,
            "my_queue": sum(1 for a in apps if a["status"] in OPEN and a.get("assigned_to") == user["id"]),
            "unassigned": sum(1 for a in apps if a["status"] in OPEN and not a.get("assigned_to")),
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
        })

    # ================================================================ fairness
    def _fairness(self, decided: list[dict]) -> list[dict]:
        out = []
        for attr in FAIRNESS_ATTRS:
            groups: dict[str, list[int]] = {}
            for a in decided:
                g = (a.get("demographics") or {}).get(attr)
                if g and g != "undisclosed":
                    groups.setdefault(g, []).append(int(a["status"] == "approved"))
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

    def fairness_report(self, user: dict) -> dict:
        require(user, "admin")
        decided = self._q("SELECT * FROM applications WHERE org_id=? AND status IN ('approved','rejected')",
                          (user["org_id"],))
        overrides = {"approved_low_odds": 0, "rejected_good_odds": 0, "followed": 0}
        for a in decided:
            if a["status"] == "approved" and a.get("odds") in ("fair", "low") and a["recommendation"] == "REVIEW":
                overrides["approved_low_odds"] += 1
            elif a["status"] == "rejected" and a.get("odds") in ("excellent", "good"):
                overrides["rejected_good_odds"] += 1
            else:
                overrides["followed"] += 1
        by_officer: dict[str, dict] = {}
        names = {u["id"]: u["name"] for u in self._q("SELECT id, name FROM users WHERE org_id=?", (user["org_id"],))}
        for a in decided:
            o = by_officer.setdefault(names.get(a["decided_by"], "unknown"), {"decided": 0, "approved": 0, "overrides": 0})
            o["decided"] += 1
            o["approved"] += a["status"] == "approved"
            o["overrides"] += (a["recommendation"] == "APPROVE") != (a["status"] == "approved")
        disclosed = sum(1 for a in decided if any(v and v != "undisclosed" for v in (a.get("demographics") or {}).values()))
        return {"groups": self._fairness(decided), "overrides": overrides,
                "officers": [{"officer": k, **v} for k, v in sorted(by_officer.items())],
                "decided": len(decided), "disclosed_share": round(disclosed / len(decided), 4) if decided else None,
                "threshold": 0.8}

    # ================================================================ drift
    def _drift(self, apps: list[dict]) -> dict:
        if self._ref_inputs is None or len(apps) < MIN_DRIFT_APPS:
            return {"status": "not enough data", "min_applications": MIN_DRIFT_APPS, "features": []}
        rows = [a["inputs"] for a in apps if all(f in a["inputs"] for f in self.risk.features)]
        if len(rows) < MIN_DRIFT_APPS:
            return {"status": "not enough data", "min_applications": MIN_DRIFT_APPS, "features": []}
        cur = pd.DataFrame(rows)[self.risk.features]
        num = [c for c in NUM_COLS if c in self.risk.features]
        cat = [c for c in CAT_COLS if c in self.risk.features]
        rep = psi_report(self._ref_inputs, cur, num, cat, bins=5 if len(cur) < 500 else 10)
        worst = rep.iloc[0]
        top5 = rep.head(5)
        return {"status": worst["status"], "max_psi": round(float(worst["psi"]), 4),
                "retrain_suggested": bool((top5["psi"] > 0.25).any()), "n": len(cur),
                "features": [{"feature": r.feature, "psi": round(float(r.psi), 4), "status": r.status}
                             for r in rep.head(6).itertuples()]}

    def drift_report(self, user: dict) -> dict:
        require(user, "admin")
        snap = self._one("SELECT report, created_at FROM drift_snapshots WHERE org_id=? ORDER BY id DESC LIMIT 1",
                         (user["org_id"],))
        if snap:
            return {**snap["report"], "snapshot_at": snap["created_at"]}
        apps = self._q("SELECT inputs FROM applications WHERE org_id=? ORDER BY id DESC LIMIT 2000", (user["org_id"],))
        return {**self._drift(apps), "snapshot_at": None}

    def snapshot_drift(self) -> int:
        n = 0
        for org in self._q("SELECT id FROM orgs WHERE active=1"):
            apps = self._q("SELECT inputs FROM applications WHERE org_id=? ORDER BY id DESC LIMIT 2000", (org["id"],))
            rep = self._drift(apps)
            self.db.execute("INSERT INTO drift_snapshots (org_id, model_version_id, report, created_at) VALUES (?,?,?,?)",
                            (org["id"], self.model_version_id, jdump(rep), db.now()))
            n += 1
        return n

    # ================================================================ portfolio
    def portfolio(self, user: dict) -> dict:
        require(user, "admin", "officer")
        org_id = user["org_id"]
        loans = self._q("SELECT * FROM loans WHERE org_id=?", (org_id,))
        reps = self._q("""SELECT r.* FROM repayments r JOIN loans l ON l.id=r.loan_id WHERE l.org_id=?""", (org_id,))
        today = clock.today().isoformat()
        due_so_far = [r for r in reps if r["due_date"] <= today]
        paid_on_time = sum(1 for r in due_so_far if r["status"] == "paid" and r["paid_at"]
                           and (clock.parse(r["paid_at"]).date() - date.fromisoformat(r["due_date"])).days <= 3)
        arrears = sum(r["amount_due"] - r["amount_paid"] for r in reps if r["status"] in ("late", "missed"))
        outstanding = sum(r["amount_due"] - r["amount_paid"] for r in reps if r["status"] != "paid")
        levels = Counter(r["level"] for r in self._q("SELECT level FROM borrower_levels WHERE org_id=?", (org_id,)))
        status = Counter(loan["status"] for loan in loans)
        return py({
            "loans": {"total": len(loans), "active": status["active"], "closed": status["closed"],
                      "defaulted": status["defaulted"]},
            "disbursed": round(sum(loan["principal"] for loan in loans), 2),
            "outstanding": round(outstanding, 2),
            "arrears": round(arrears, 2),
            "installments_due": len(due_so_far),
            "on_time_rate": round(paid_on_time / len(due_so_far), 4) if due_so_far else None,
            "late": sum(1 for r in reps if r["status"] == "late"),
            "missed": sum(1 for r in reps if r["status"] == "missed"),
            "ladder_mix": [{"level": lv["level"], "name": lv["name"], "borrowers": levels.get(lv["level"], 0)}
                           for lv in LEVELS],
            "currency": self._org(org_id)["currency"],
        })

    # ================================================================ audit and platform
    def audit_log(self, user: dict, limit: int = 50, cursor: str | None = None) -> list[dict]:
        require(user, "admin")
        before = int(cursor) if cursor and cursor.isdigit() else None
        sql = "SELECT l.*, u.name AS user_name FROM audit_log l LEFT JOIN users u ON u.id=l.user_id WHERE l.org_id=?"
        args: list = [user["org_id"]]
        if before:
            sql += " AND l.id<?"
            args.append(before)
        return self._q(sql + " ORDER BY l.id DESC LIMIT ?", args + [min(limit, 500)])

    def platform_stats(self, user: dict) -> dict:
        require(user, "superadmin")
        one = self._scalar
        week_ago = clock.iso(clock.utcnow() - timedelta(days=7))
        drafts = self._q("SELECT id, step, status, created_at FROM drafts WHERE created_at>=?", (week_ago,))
        submitted = self._q("""SELECT d.created_at AS started, a.created_at AS submitted FROM applications a
                               JOIN drafts d ON d.id=a.draft_id WHERE a.created_at>=?""", (week_ago,))
        minutes = sorted((clock.parse(s["submitted"]) - clock.parse(s["started"])).total_seconds() / 60 for s in submitted)
        n = len(drafts)
        funnel = {"started": n,
                  "quick_check": sum(1 for d in drafts if d["step"] >= 2 or d["status"] == "submitted"),
                  "full_profile": sum(1 for d in drafts if d["step"] >= 3 or d["status"] == "submitted"),
                  "submitted": sum(1 for d in drafts if d["status"] == "submitted")}
        return {"orgs": one("SELECT COUNT(*) FROM orgs"),
                "active_orgs": one("SELECT COUNT(*) FROM orgs WHERE active=1"),
                "borrowers": one("SELECT COUNT(*) FROM users WHERE role='borrower' AND deleted_at IS NULL"),
                "staff": one("SELECT COUNT(*) FROM users WHERE role IN ('officer','admin')"),
                "applications": one("SELECT COUNT(*) FROM applications"),
                "loans_active": one("SELECT COUNT(*) FROM loans WHERE status='active'"),
                "plans": dict(Counter(r["plan"] for r in self._q("SELECT plan FROM orgs"))),
                "funnel_7d": funnel,
                "drop_off_7d": round(1 - funnel["submitted"] / n, 4) if n else None,
                "median_minutes_to_submit_7d": round(minutes[len(minutes) // 2], 1) if minutes else None,
                "outbox_pending": one("SELECT COUNT(*) FROM outbox WHERE processed_at IS NULL"),
                "model": {"active": self.model_version_label,
                          "shadow": self.shadow_label}}
