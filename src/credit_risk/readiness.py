"""Borrower-facing view of the model: traffic light, improvement tips, EMI.

The officer sees the full risk score and reasons. The borrower sees a simple
readiness light and concrete, *actionable* changes that would lower their risk.
Tips only touch things a borrower can change before applying (loan size, term,
co-signer, existing debt, shopping for a lower rate), never who they are.
"""
from __future__ import annotations

import pandas as pd

GREEN_MAX = 0.08    # calibrated default probability cut-offs (see notebook 02)
YELLOW_MAX = 0.16

LIGHTS = {
    "green":  {"title": "Ready to apply",
               "message": "Your profile looks like borrowers who usually repay on time."},
    "yellow": {"title": "Borderline: improve first",
               "message": "You may be approved, but a few changes could make it much more likely."},
    "red":    {"title": "High risk: wait or change the loan",
               "message": "Lenders are likely to hesitate. Try the changes below before applying."},
}


def light_for(probability: float) -> str:
    if probability < GREEN_MAX:
        return "green"
    if probability < YELLOW_MAX:
        return "yellow"
    return "red"


# ---------------------------------------------------------------- EMI / affordability
def emi(principal: float, annual_rate_pct: float, months: int) -> float:
    """Equal monthly instalment for an amortising loan."""
    if months <= 0:
        raise ValueError("months must be positive")
    r = annual_rate_pct / 100 / 12
    if r == 0:
        return principal / months
    return principal * r * (1 + r) ** months / ((1 + r) ** months - 1)


def affordability(principal: float, annual_rate_pct: float, months: int,
                  annual_income: float) -> dict:
    m = emi(principal, annual_rate_pct, months)
    share = (m * 12) / annual_income if annual_income > 0 else float("inf")
    if share <= 0.30:
        level, note = "comfortable", "The instalment is a manageable share of your income."
    elif share <= 0.40:
        level, note = "stretched", "Affordable, but leaves little room for surprises."
    else:
        level, note = "risky", "The instalment takes more than 40% of your income."
    total = m * months
    return {"monthly_payment": round(m, 2), "total_repayment": round(total, 2),
            "total_interest": round(total - principal, 2),
            "income_share": round(share, 4), "level": level, "note": note}


# ---------------------------------------------------------------- what-if tips
def _candidates(app: dict, schema: dict) -> list[tuple[str, dict, str]]:
    """(feature, changes, human description) for each actionable what-if."""
    out = []
    lo_amt = schema["LoanAmount"]["min"]
    for frac in (0.75, 0.5):
        amt = max(lo_amt, round(app["LoanAmount"] * frac, -3))
        if amt < app["LoanAmount"]:
            out.append(("LoanAmount", {"LoanAmount": amt},
                        f"Borrow {amt:,.0f} instead of {app['LoanAmount']:,.0f}"))
    for term in schema["LoanTerm"].get("options", []):
        if term != app["LoanTerm"]:
            out.append(("LoanTerm", {"LoanTerm": term},
                        f"Choose a {term}-month term instead of {app['LoanTerm']}"))
    if app.get("HasCoSigner") == "No":
        out.append(("HasCoSigner", {"HasCoSigner": "Yes"}, "Apply with a co-signer"))
    lo_dti = schema["DTIRatio"]["min"]
    for cut in (0.1, 0.2):
        dti = round(max(lo_dti, app["DTIRatio"] - cut), 2)
        if dti < app["DTIRatio"]:
            out.append(("DTIRatio", {"DTIRatio": dti},
                        f"Pay down existing debts (debt-to-income {app['DTIRatio']:.2f} -> {dti:.2f})"))
    lo_rate = schema["InterestRate"]["min"]
    for cut in (2, 4):
        rate = round(max(lo_rate, app["InterestRate"] - cut), 1)
        if rate < app["InterestRate"]:
            out.append(("InterestRate", {"InterestRate": rate},
                        f"Find a lower rate ({app['InterestRate']:.1f}% -> {rate:.1f}%), e.g. a secured loan"))
    return out


def improvement_tips(service, app: dict, max_tips: int = 4) -> dict:
    """Best actionable change per feature, plus a combined plan."""
    base = service.validate(app)
    p0 = _prob(service, base)
    cands = _candidates(app, service.schema)
    if not cands:
        return {"tips": [], "plan": None}
    rows = [base.assign(**changes) for _, changes, _ in cands]
    probs = _prob_batch(service, pd.concat(rows, ignore_index=True))

    best: dict[str, dict] = {}
    for (feat, changes, text), p in zip(cands, probs):
        gain = p0 - p
        if gain < 0.005:          # ignore changes worth less than half a point
            continue
        if feat not in best or gain > best[feat]["gain"]:
            best[feat] = {"feature": feat, "change": changes, "text": text,
                          "new_probability": round(float(p), 4), "gain": float(gain),
                          "new_light": light_for(float(p))}
    tips = sorted(best.values(), key=lambda t: t["gain"], reverse=True)[:max_tips]
    for t in tips:
        t["points_lower"] = round(t.pop("gain") * 100, 1)

    plan = None
    if len(tips) >= 2:
        combined = dict(app)
        for t in tips[:3]:
            combined.update(t["change"])
        p_plan = _prob(service, service.validate(combined))
        plan = {"steps": [t["text"] for t in tips[:3]],
                "new_probability": round(p_plan, 4), "new_light": light_for(p_plan),
                "points_lower": round((p0 - p_plan) * 100, 1)}
    return {"tips": tips, "plan": plan}


def _prob(service, X: pd.DataFrame) -> float:
    return float(_prob_batch(service, X)[0])


def _prob_batch(service, X: pd.DataFrame):
    scores = service.pipeline.predict_proba(X)[:, 1]
    return service.calibrator.predict(scores)


def readiness(service, app: dict) -> dict:
    """Everything the borrower screen needs, in one call."""
    X = service.validate(app)
    prob = _prob(service, X)
    light = light_for(prob)
    out = {"light": light, **LIGHTS[light], "default_probability": round(prob, 4)}
    out.update(improvement_tips(service, app))
    out["affordability"] = affordability(app["LoanAmount"], app["InterestRate"],
                                         int(app["LoanTerm"]), app["Income"])
    return out
