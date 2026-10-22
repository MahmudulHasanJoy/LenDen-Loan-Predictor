"""Stable reason codes for explanations and adverse-action notices.

The API never sends user-facing sentences for reasons, only codes such as DTI_HIGH; the apps
translate them (Bangla/English). Protected attributes are never reported as reasons.
"""
from __future__ import annotations

PROTECTED = {"Age", "MaritalStatus", "HasDependents"}
ACTIONABLE = {"LoanAmount", "LoanTerm", "HasCoSigner", "DTIRatio", "InterestRate"}

# Codes an officer can pick when rejecting (model codes + policy and process codes).
CATALOG = {
    "INCOME_LOW": "Income is low for the amount requested",
    "AMOUNT_HIGH": "Loan amount is high",
    "CREDIT_SCORE_LOW": "Credit score is low",
    "EMPLOYMENT_SHORT": "Time in current job is short",
    "EMPLOYMENT_TYPE": "Employment type",
    "CREDIT_LINES_MANY": "Many open credit lines",
    "CREDIT_LINES_FEW": "Short credit history",
    "RATE_HIGH": "Interest rate is high",
    "TERM_LONG": "Loan term is long",
    "TERM_SHORT": "Loan term is short for the amount",
    "DTI_HIGH": "Existing debt is high compared with income",
    "NO_COSIGNER": "No co-signer",
    "LOAN_PURPOSE": "Loan purpose",
    "MORTGAGE": "Existing mortgage",
    "EDUCATION_LEVEL": "Education level",
    "POLICY_MIN_INCOME": "Below the lender's minimum income",
    "POLICY_MAX_DTI": "Above the lender's maximum debt-to-income",
    "LADDER_LIMIT": "Above the limit for your credit level",
    "DOCUMENTS_MISSING": "Requested documents were not provided",
    "VERIFICATION_FAILED": "Information could not be verified",
    "OTHER": "Other (see note)",
}


def code_for(reason: dict) -> str | None:
    f, v, typ = reason["feature"], reason.get("value"), reason.get("typical")
    if f in PROTECTED:
        return None
    simple = {"Income": "INCOME_LOW", "LoanAmount": "AMOUNT_HIGH", "CreditScore": "CREDIT_SCORE_LOW",
              "MonthsEmployed": "EMPLOYMENT_SHORT", "InterestRate": "RATE_HIGH", "DTIRatio": "DTI_HIGH",
              "EmploymentType": "EMPLOYMENT_TYPE", "Education": "EDUCATION_LEVEL",
              "HasMortgage": "MORTGAGE", "LoanPurpose": "LOAN_PURPOSE", "HasCoSigner": "NO_COSIGNER"}
    if f in simple:
        return simple[f]
    try:
        higher = float(v) > float(typ)
    except (TypeError, ValueError):
        higher = True
    if f == "NumCreditLines":
        return "CREDIT_LINES_MANY" if higher else "CREDIT_LINES_FEW"
    if f == "LoanTerm":
        return "TERM_LONG" if higher else "TERM_SHORT"
    return None


def reason_codes(reasons: list[dict], top: int = 3) -> list[str]:
    """Codes for the features that push risk UP, strongest first."""
    out: list[str] = []
    for r in sorted(reasons, key=lambda r: r["impact"], reverse=True):
        if r["impact"] <= 0:
            continue
        c = code_for(r)
        if c and c not in out:
            out.append(c)
        if len(out) == top:
            break
    return out


def public_reasons(reasons: list[dict]) -> list[dict]:
    """Officer-facing reasons without protected attributes, each with its code."""
    return [{**r, "code": code_for(r)} for r in reasons if r["feature"] not in PROTECTED]
