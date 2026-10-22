"""Borrower drafts (wizard with autosave), the live simulator and offer estimates."""
from __future__ import annotations

from credit_risk.counterfactual import next_step
from credit_risk.odds import odds_for
from credit_risk.offers import offer_for
from credit_risk.readiness import affordability, readiness
from credit_risk.reasons import reason_codes
from credit_risk.service import ValidationError

from .. import clock, db
from ..errors import BadRequest, NotFound
from ..security import hash_token, new_secret
from ..settings import LOCALES
from .base import Base, jdump, py

# The wizard: steps 1-2 are the quick check, 3 the full profile, 4 consent and documents.
STEPS = {
    1: ["Income", "LoanAmount", "LoanPurpose"],
    2: ["LoanTerm", "EmploymentType", "MonthsEmployed"],
    3: ["CreditScore", "NumCreditLines", "DTIRatio", "InterestRate", "Education", "HasMortgage", "HasCoSigner"],
}
QUICK = STEPS[1] + STEPS[2]
DEMOGRAPHICS = {"gender": ("female", "male", "other", "undisclosed"),
                "age_band": ("18-25", "26-35", "36-45", "46-55", "56+", "undisclosed")}
ANON_DAYS, USER_DAYS = 7, 30


class Drafts(Base):
    # ================================================================ helpers
    def _check_partial(self, inputs: dict) -> dict:
        """Validate only the fields that are present (a draft may be incomplete)."""
        errors, clean = {}, {}
        for k, v in (inputs or {}).items():
            if k not in self.risk.schema or k not in self.risk.features:
                errors[k] = "unknown field"
                continue
            if v is None or v == "":
                continue
            spec = self.risk.schema[k]
            if spec["type"] == "category":
                if str(v) not in spec["options"]:
                    errors[k] = f"must be one of {spec['options']}"
                clean[k] = str(v)
                continue
            try:
                x = float(v)
            except (TypeError, ValueError):
                errors[k] = "must be a number"
                continue
            if not spec["min"] <= x <= spec["max"]:
                errors[k] = f"must be between {spec['min']:g} and {spec['max']:g}"
            if "options" in spec and int(x) not in spec["options"]:
                errors[k] = f"must be one of {spec['options']}"
            clean[k] = int(x) if spec["type"] == "integer" else x
        if errors:
            raise ValidationError(errors)
        return clean

    def complete_inputs(self, inputs: dict) -> tuple[dict, list[str]]:
        """Fill missing fields with the population default (median / most common)."""
        full, defaulted = {}, []
        for f in self.risk.features:
            spec = self.risk.schema[f]
            if inputs.get(f) not in (None, ""):
                full[f] = inputs[f]
            else:
                d = spec.get("median", spec.get("mode"))
                if spec["type"] == "integer":
                    d = int(round(d)) if "options" not in spec else min(spec["options"], key=lambda o: abs(o - d))
                full[f] = py(d)
                defaulted.append(f)
        return full, defaulted

    def _check_demographics(self, demo: dict | None) -> dict:
        out = {}
        for k, v in (demo or {}).items():
            if k not in DEMOGRAPHICS or v not in DEMOGRAPHICS[k]:
                raise BadRequest("Optional profile values are not valid.", code="DEMOGRAPHICS_INVALID",
                                 fields={k: f"one of {DEMOGRAPHICS.get(k, ())}"})
            out[k] = v
        return out

    def _draft_view(self, d: dict) -> dict:
        missing = [f for f in self.risk.features if f not in d["inputs"]]
        return {"id": d["id"], "step": d["step"], "inputs": d["inputs"], "demographics": d["demographics"],
                "locale": d["locale"], "status": d["status"], "missing": missing,
                "quick_check_done": all(f in d["inputs"] for f in QUICK), "complete": not missing,
                "created_at": d["created_at"], "updated_at": d["updated_at"], "expires_at": d["expires_at"]}

    def _get_draft(self, draft_id: int, user: dict | None, anon_token: str | None) -> dict:
        d = self._one("SELECT * FROM drafts WHERE id=?", (draft_id,))
        ok = d and d["status"] != "expired" and (
            (d["user_id"] is not None and user is not None and d["user_id"] == user["id"])
            or (d["user_id"] is None and anon_token and d["anon_token_hash"] == hash_token(anon_token)))
        if not ok:
            raise NotFound("Draft not found.", code="DRAFT_NOT_FOUND")
        if clock.parse(d["expires_at"]) < clock.utcnow():
            raise NotFound("This draft has expired. Please start again.", code="DRAFT_EXPIRED")
        return d

    # ================================================================ drafts
    def create_draft(self, user: dict | None, inputs: dict | None = None, step: int = 1, locale: str = "en",
                     demographics: dict | None = None) -> dict:
        if user and user["role"] != "borrower":
            raise BadRequest("Only borrowers create loan drafts.", code="ROLE_REQUIRED")
        clean = self._check_partial(inputs or {})
        demo = self._check_demographics(demographics)
        token = None if user else new_secret()
        ts = db.now()
        draft_id = self.db.insert(
            """INSERT INTO drafts (user_id, anon_token_hash, step, inputs, demographics, locale, created_at,
               updated_at, expires_at) VALUES (?,?,?,?,?,?,?,?,?)""",
            (user["id"] if user else None, hash_token(token) if token else None, max(1, min(int(step), 4)),
             jdump(clean), jdump(demo), locale if locale in LOCALES else "en", ts, ts,
             self._later(days=USER_DAYS if user else ANON_DAYS)))
        out = {"draft": self._draft_view(self._one("SELECT * FROM drafts WHERE id=?", (draft_id,)))}
        if token:
            out["anon_token"] = token
        return out

    def update_draft(self, draft_id: int, user: dict | None, anon_token: str | None, inputs: dict | None = None,
                     step: int | None = None, demographics: dict | None = None, locale: str | None = None) -> dict:
        d = self._get_draft(draft_id, user, anon_token)
        if d["status"] != "active":
            raise BadRequest("This draft was already submitted.", code="DRAFT_SUBMITTED")
        merged = {**d["inputs"], **self._check_partial(inputs or {})}
        demo = {**d["demographics"], **self._check_demographics(demographics)}
        new_step = max(1, min(int(step), 4)) if step is not None else d["step"]
        self.db.execute("""UPDATE drafts SET inputs=?, demographics=?, step=?, locale=?, updated_at=?, expires_at=?,
                           reminders_sent=0 WHERE id=?""",
                        (jdump(merged), jdump(demo), new_step,
                         locale if locale in LOCALES else d["locale"], db.now(),
                         self._later(days=USER_DAYS if d["user_id"] else ANON_DAYS), draft_id))
        return {"draft": self._draft_view(self._one("SELECT * FROM drafts WHERE id=?", (draft_id,)))}

    def get_draft(self, draft_id: int, user: dict | None, anon_token: str | None) -> dict:
        return {"draft": self._draft_view(self._get_draft(draft_id, user, anon_token))}

    def list_drafts(self, user: dict) -> list[dict]:
        rows = self._q("SELECT * FROM drafts WHERE user_id=? AND status='active' ORDER BY updated_at DESC", (user["id"],))
        return [self._draft_view(d) for d in rows if clock.parse(d["expires_at"]) >= clock.utcnow()]

    def delete_draft(self, draft_id: int, user: dict | None, anon_token: str | None) -> dict:
        d = self._get_draft(draft_id, user, anon_token)
        self.db.execute("UPDATE drafts SET status='expired' WHERE id=?", (d["id"],))
        return {"ok": True}

    # ================================================================ readiness and simulator
    def check_readiness(self, inputs: dict) -> dict:
        """v2 one-shot check, now also with odds, reason codes and the next best step."""
        out = readiness(self.risk, inputs)
        pred = self.risk.predict(inputs)
        out["odds"] = odds_for(pred["risk_score"], self.risk.threshold)
        out["reasons"] = reason_codes(pred["reasons"])
        out["next_step"] = next_step(self.risk, inputs, self.risk.threshold)
        return py(out)

    def simulate(self, inputs: dict, overrides: dict | None = None, org_id: int | None = None) -> dict:
        """Odds, probability and instalment for base inputs + slider overrides. Nothing is stored."""
        base = self._check_partial(inputs or {})
        base.update(self._check_partial(overrides or {}))
        full, defaulted = self.complete_inputs(base)
        threshold = self.risk.threshold
        if org_id:
            self._org(org_id)
            threshold = self.recommendation_threshold(self._settings(org_id))
        pred = self.risk.predict(full)
        aff = affordability(full["LoanAmount"], full["InterestRate"], int(full["LoanTerm"]), full["Income"])
        return py({
            "odds": odds_for(pred["risk_score"], threshold),
            "probability": pred["default_probability"],
            "threshold": threshold,
            "emi": aff["monthly_payment"],
            "affordability": aff["level"],
            "income_share": aff["income_share"],
            "reasons": reason_codes(pred["reasons"]),
            "next_step": next_step(self.risk, full, threshold),
            "estimated_fields": defaulted,
            "inputs": full,
            "model_version": self.model_version_label,
        })

    # ================================================================ offers
    def draft_offers(self, draft_id: int, user: dict | None, anon_token: str | None) -> dict:
        d = self._get_draft(draft_id, user, anon_token)
        if not all(f in d["inputs"] for f in QUICK):
            raise BadRequest("Finish the quick check first.", code="QUICK_CHECK_INCOMPLETE",
                             fields={f: "required" for f in QUICK if f not in d["inputs"]})
        full, defaulted = self.complete_inputs(d["inputs"])
        ladder_on = self.flag("credit_ladder")
        self.db.execute("UPDATE offers SET status='expired' WHERE draft_id=? AND status='estimate'", (draft_id,))
        out = []
        hours = {h["org_id"]: h["hours"] for h in self._decision_hours()}
        for org in self._q("SELECT id, name, slug, currency FROM orgs WHERE active=1 ORDER BY name"):
            s = self._settings(org["id"])
            threshold = self.recommendation_threshold(s)
            level = self._level(d["user_id"], org["id"]) if (d["user_id"] and ladder_on) else (1 if ladder_on else 4)
            o = offer_for(self.risk, full, s["offer_rules"], threshold, level)
            b = o["best"]
            offer_id = self.db.insert(
                """INSERT INTO offers (draft_id, org_id, eligible, amount_min, amount_max, rate_min, rate_max,
                   best_amount, best_term, best_rate, best_emi, odds, probability, ladder_level, model_version_id,
                   created_at, expires_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
                (draft_id, org["id"], int(o["eligible"]), o["amount_min"], o["amount_max"], o["rate_min"],
                 o["rate_max"], b["amount"], b["term"], b["rate"], b["emi"], b["odds"], b["probability"],
                 level, self.model_version_id, db.now(), self._later(days=14)))
            open_app = self._one("SELECT id FROM applications WHERE borrower_id=? AND org_id=? AND status IN "
                                 "('submitted','in_review','needs_docs')", (d["user_id"], org["id"])) \
                if d["user_id"] else None
            out.append({"offer_id": offer_id, "org_id": org["id"], "lender": org["name"], "currency": org["currency"],
                        "typical_decision_hours": hours.get(org["id"]), "has_open_application": bool(open_app),
                        **o, "next_step": None if (o["eligible"] or self.lean) else next_step(self.risk, full, threshold)})
        out.sort(key=lambda x: (not x["eligible"], x["best"]["rate"], -x["best"]["amount"]))
        return py({"draft_id": draft_id, "estimated_fields": defaulted, "offers": out,
                   "marketplace": self.flag("offers_marketplace")})
