"""Offer estimates: for one borrower and one lender, which amounts and terms are realistic?

Each lender defines offer rules (base rate, rate step per odds level, limits, terms, policy
limits and credit-ladder caps). For a draft the engine searches a small grid of amounts and
terms within those limits, prices each point, and keeps the ones with good-or-better odds
whose instalment is at most 40% of monthly income. The model scores the whole grid in one
batch, so this is fast enough to run for every lender on every check.
"""
from __future__ import annotations

from .odds import RANK, odds_for
from .readiness import emi
from .scoring import score_frame, variants

DEFAULT_RULES = {
    "base_rate": 12.0,        # % a year for "excellent" odds
    "rate_step": 2.5,         # extra % per odds level below excellent
    "min_amount": 5000,
    "max_amount": 249999,
    "terms": [12, 24, 36, 48, 60],
    "min_income": 15000,      # policy: below this the lender does not lend
    "max_dti": 0.8,           # policy: debt-to-income above this is declined
    "max_income_share": 0.40, # instalment share of income an offer may take
    "ladder_caps": [0.10, 0.25, 0.50, 1.0],   # share of max_amount per credit level L1..L4
}
OFFERABLE = ("excellent", "good")


class RulesError(ValueError):
    def __init__(self, fields: dict):
        super().__init__("; ".join(f"{k}: {v}" for k, v in fields.items()))
        self.fields = fields


def clean_rules(rules: dict | None, schema: dict) -> dict:
    """Merge with defaults and validate against what the model understands."""
    r = {**DEFAULT_RULES, **(rules or {})}
    errs = {}
    amt, rate = schema["LoanAmount"], schema["InterestRate"]
    try:
        r["base_rate"] = float(r["base_rate"]); r["rate_step"] = float(r["rate_step"])
        r["min_amount"] = float(r["min_amount"]); r["max_amount"] = float(r["max_amount"])
        r["min_income"] = float(r["min_income"]); r["max_dti"] = float(r["max_dti"])
        r["max_income_share"] = float(r["max_income_share"])
        r["terms"] = sorted({int(t) for t in r["terms"]})
        r["ladder_caps"] = [float(c) for c in r["ladder_caps"]]
    except (TypeError, ValueError):
        raise RulesError({"rules": "numbers expected"}) from None
    if not rate["min"] <= r["base_rate"] <= rate["max"]:
        errs["base_rate"] = f"must be between {rate['min']:g} and {rate['max']:g}"
    if not 0 <= r["rate_step"] <= 10:
        errs["rate_step"] = "must be between 0 and 10"
    if not amt["min"] <= r["min_amount"] < r["max_amount"] <= amt["max"]:
        errs["amounts"] = f"need {amt['min']:g} <= min_amount < max_amount <= {amt['max']:g}"
    allowed = set(schema["LoanTerm"].get("options", []))
    if not r["terms"] or not set(r["terms"]) <= allowed:
        errs["terms"] = f"choose from {sorted(allowed)}"
    if not 0 < r["max_dti"] <= 1:
        errs["max_dti"] = "must be between 0 and 1"
    if not 0.1 <= r["max_income_share"] <= 0.6:
        errs["max_income_share"] = "must be between 0.1 and 0.6"
    caps = r["ladder_caps"]
    if len(caps) != 4 or any(not 0 < c <= 1 for c in caps) or caps != sorted(caps) or caps[-1] != 1.0:
        errs["ladder_caps"] = "four increasing shares ending at 1.0"
    if errs:
        raise RulesError(errs)
    return r


def rate_for(odds: str, rules: dict, schema: dict) -> float:
    lo, hi = schema["InterestRate"]["min"], schema["InterestRate"]["max"]
    return round(min(hi, max(lo, rules["base_rate"] + rules["rate_step"] * RANK[odds])), 2)


def ladder_cap(rules: dict, level: int) -> float:
    return max(rules["min_amount"], rules["max_amount"] * rules["ladder_caps"][max(1, min(level, 4)) - 1])


def offer_for(service, inputs: dict, rules: dict, threshold: float, ladder_level: int = 1) -> dict:
    X0 = service.validate(inputs)
    app = {k: (v.item() if hasattr(v, "item") else v) for k, v in X0.iloc[0].to_dict().items()}
    schema = service.schema
    policy = []
    if app["Income"] < rules["min_income"]:
        policy.append("POLICY_MIN_INCOME")
    if app["DTIRatio"] > rules["max_dti"]:
        policy.append("POLICY_MAX_DTI")

    cap = ladder_cap(rules, ladder_level)
    top = min(app["LoanAmount"], cap)
    amounts = sorted({max(rules["min_amount"], round(top * f, -3)) for f in (1.0, 0.85, 0.7, 0.55, 0.4, 0.25)},
                     reverse=True)
    amounts = [a for a in amounts if a <= cap]
    terms = [t for t in rules["terms"] if t in schema["LoanTerm"].get("options", rules["terms"])]
    grid = [(a, t) for a in amounts for t in terms]

    # Pass 1: price at the "good" rate to estimate odds; pass 2: re-score at the priced rate.
    first = rate_for("good", rules, schema)
    raw1, _ = score_frame(service, variants(service, app, [{"LoanAmount": a, "LoanTerm": t, "InterestRate": first}
                                                           for a, t in grid]))
    priced = [rate_for(odds_for(float(r), threshold), rules, schema) for r in raw1]
    raw2, prob2 = score_frame(service, variants(service, app, [{"LoanAmount": a, "LoanTerm": t, "InterestRate": rt}
                                                               for (a, t), rt in zip(grid, priced)]))
    points = []
    for (a, t), rt, r, p in zip(grid, priced, raw2, prob2):
        odds = odds_for(float(r), threshold)
        rate = max(rt, rate_for(odds, rules, schema))          # never price below the final odds
        m = emi(a, rate, t)
        points.append({"amount": float(a), "term": int(t), "rate": rate, "emi": round(m, 2),
                       "income_share": round(m * 12 / app["Income"], 4), "odds": odds,
                       "probability": round(float(p), 4)})
    ok = [p for p in points if p["odds"] in OFFERABLE and p["income_share"] <= rules["max_income_share"]]
    eligible = bool(ok) and not policy
    pool = ok if ok else points
    best = sorted(pool, key=lambda p: (RANK[p["odds"]] if not ok else 0, -p["amount"], p["income_share"]))[0]
    out = {
        "eligible": eligible,
        "requested_amount": float(app["LoanAmount"]),
        "ladder_level": ladder_level,
        "ladder_cap": round(cap, 2),
        "capped_by_ladder": app["LoanAmount"] > cap,
        "policy": policy,
        "best": best,
        "amount_min": min(p["amount"] for p in ok) if ok else None,
        "amount_max": max(p["amount"] for p in ok) if ok else None,
        "rate_min": min(p["rate"] for p in ok) if ok else None,
        "rate_max": max(p["rate"] for p in ok) if ok else None,
    }
    return out
