"""Smallest actionable change that improves a borrower's approval odds by one level.

Search is greedy over the same actionable features the readiness tips use (amount, term,
co-signer, existing debt, interest rate); it never suggests changing who someone is.
Each candidate has a "cost" so that, among changes that work, the gentlest one wins.
"""
from __future__ import annotations

from itertools import combinations

from .odds import ODDS, RANK, odds_for
from .scoring import score_frame, variants


def _candidates(app: dict, schema: dict) -> list[dict]:
    out = []
    amt_lo = schema["LoanAmount"]["min"]
    for frac in (0.9, 0.8, 0.7, 0.6, 0.5, 0.4, 0.25):
        amt = max(amt_lo, round(app["LoanAmount"] * frac, -3))
        if amt < app["LoanAmount"]:
            out.append({"feature": "LoanAmount", "code": "LOWER_AMOUNT", "from": app["LoanAmount"],
                        "to": amt, "cost": (1 - frac) * 10})
    for term in schema["LoanTerm"].get("options", []):
        if term != app["LoanTerm"]:
            out.append({"feature": "LoanTerm", "code": "SHORTER_TERM" if term < app["LoanTerm"] else "LONGER_TERM",
                        "from": app["LoanTerm"], "to": term, "cost": abs(term - app["LoanTerm"]) / 12})
    if app.get("HasCoSigner") == "No":
        out.append({"feature": "HasCoSigner", "code": "ADD_COSIGNER", "from": "No", "to": "Yes", "cost": 2.5})
    dti_lo = schema["DTIRatio"]["min"]
    for cut in (0.05, 0.1, 0.15, 0.2, 0.3):
        dti = round(max(dti_lo, app["DTIRatio"] - cut), 2)
        if dti < app["DTIRatio"]:
            out.append({"feature": "DTIRatio", "code": "LOWER_DTI", "from": app["DTIRatio"], "to": dti,
                        "cost": cut * 20})
    rate_lo = schema["InterestRate"]["min"]
    for cut in (1, 2, 3, 4):
        rate = round(max(rate_lo, app["InterestRate"] - cut), 1)
        if rate < app["InterestRate"]:
            out.append({"feature": "InterestRate", "code": "LOWER_RATE", "from": app["InterestRate"],
                        "to": rate, "cost": cut * 0.75})
    return out


def _public(c: dict) -> dict:
    return {k: c[k] for k in ("feature", "code", "from", "to")}


def next_step(service, app: dict, threshold: float, max_changes: int = 3) -> dict | None:
    """The cheapest change set (1 to 3 changes) that lifts odds by at least one level.

    Returns None when odds are already excellent or nothing within reach helps.
    """
    X0 = service.validate(app)
    clean = {k: (v.item() if hasattr(v, "item") else v) for k, v in X0.iloc[0].to_dict().items()}
    raw0, p0 = score_frame(service, X0)
    current = odds_for(float(raw0[0]), threshold)
    if current == "excellent":
        return None
    target = RANK[current] - 1
    singles = _candidates(clean, service.schema)
    if not singles:
        return None
    raw, prob = score_frame(service, variants(service, clean, [{c["feature"]: c["to"]} for c in singles]))
    scored = [(c, float(r), float(p)) for c, r, p in zip(singles, raw, prob)]
    hits = [(c["cost"], [c], r, p) for c, r, p in scored if RANK[odds_for(r, threshold)] <= target]
    if not hits and max_changes >= 2:
        top = sorted(scored, key=lambda t: t[1])[:8]
        pairs = [(a, b) for (a, _, _), (b, _, _) in combinations(top, 2) if a["feature"] != b["feature"]]
        if pairs:
            raw2, prob2 = score_frame(service, variants(
                service, clean, [{a["feature"]: a["to"], b["feature"]: b["to"]} for a, b in pairs]))
            hits = [(a["cost"] + b["cost"], [a, b], float(r), float(p))
                    for (a, b), r, p in zip(pairs, raw2, prob2) if RANK[odds_for(float(r), threshold)] <= target]
    if not hits and max_changes >= 3:
        top = sorted(scored, key=lambda t: t[1])
        best_per_feature: dict = {}
        for c, r, p in top:                      # strongest variant of each feature
            best_per_feature.setdefault(c["feature"], c)
        trio = list(combinations(list(best_per_feature.values())[:5], 3))
        if trio:
            raw3, prob3 = score_frame(service, variants(
                service, clean, [{c["feature"]: c["to"] for c in t} for t in trio]))
            hits = [(sum(c["cost"] for c in t), list(t), float(r), float(p))
                    for t, r, p in zip(trio, raw3, prob3) if RANK[odds_for(float(r), threshold)] <= target]
    if not hits:
        return None
    cost, changes, r, p = min(hits, key=lambda h: (h[0], h[2]))
    return {"changes": [_public(c) for c in changes], "odds": odds_for(r, threshold), "from_odds": current,
            "probability": round(p, 4), "points_lower": round((float(p0[0]) - p) * 100, 1)}


def odds_ladder() -> tuple[str, ...]:
    return ODDS
