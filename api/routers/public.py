"""Public endpoints: no login needed. Anonymous drafts use the X-Draft-Token header."""
from typing import Any, Optional

from fastapi import APIRouter, Body, Depends, Query, Request

from credit_risk.readiness import affordability
from lenden import __version__
from lenden.ratelimit import limiter

from ..deps import client_ip, draft_token, optional_user, platform, run
from ..schemas import DraftIn, DraftUpdate, EmiRequest, SimulateIn

router = APIRouter(tags=["public"])
EXAMPLE = {"Income": 45000, "LoanAmount": 120000, "CreditScore": 610, "MonthsEmployed": 24,
           "NumCreditLines": 2, "InterestRate": 18.5, "LoanTerm": 60, "DTIRatio": 0.65,
           "Education": "Bachelor's", "EmploymentType": "Part-time", "HasMortgage": "No",
           "LoanPurpose": "Home", "HasCoSigner": "No"}


@router.get("/health")
def health():
    return {"status": "ok", "version": __version__, "model": platform.risk.model_name,
            "model_version": platform.model_version_label, "database": platform.db.dialect}


@router.get("/metadata")
def metadata(locale: str = Query("en", pattern="^(en|bn)$")):
    """Form fields (ranges, options, defaults) and the wizard steps. Labels are translated by the apps."""
    from lenden.domain.drafts import DEMOGRAPHICS, STEPS
    m = platform.risk.metadata()
    m.update({"locale": locale, "model_version": platform.model_version_label,
              "steps": {str(k): v for k, v in STEPS.items()},
              "demographics": {k: list(v) for k, v in DEMOGRAPHICS.items()}})
    return m


@router.get("/lenders")
def lenders():
    return run(platform.list_lenders)


@router.post("/readiness")
def check_readiness(inputs: dict[str, Any] = Body(..., examples=[EXAMPLE])):
    """One-shot check: traffic light, odds, tips, next step and EMI. Nothing is stored."""
    return run(platform.check_readiness, inputs)


@router.post("/simulate")
def simulate(body: SimulateIn, request: Request, user: Optional[dict] = Depends(optional_user),
             token: Optional[str] = Depends(draft_token)):
    """Live what-if: odds, probability and EMI for base inputs plus slider overrides."""
    limiter.take(f"simulate:{client_ip(request)}", 120, 60)

    def go():
        inputs = dict(body.inputs)
        if body.draft_id:
            inputs = {**platform.get_draft(body.draft_id, user, token)["draft"]["inputs"], **inputs}
        return platform.simulate(inputs, body.overrides, body.org_id)
    return run(go)


@router.post("/emi")
def emi(req: EmiRequest):
    return affordability(req.principal, req.annual_rate, req.months, req.annual_income)


@router.post("/drafts", tags=["drafts"])
def create_draft(body: DraftIn, request: Request, user: Optional[dict] = Depends(optional_user)):
    """Start the wizard. Without a login the response carries an `anon_token` to send as X-Draft-Token."""
    limiter.take(f"drafts:{client_ip(request)}", 30, 3600)
    return run(platform.create_draft, user, body.inputs, body.step, body.locale, body.demographics)


@router.get("/drafts/{draft_id}", tags=["drafts"])
def get_draft(draft_id: int, user: Optional[dict] = Depends(optional_user), token: Optional[str] = Depends(draft_token)):
    return run(platform.get_draft, draft_id, user, token)


@router.put("/drafts/{draft_id}", tags=["drafts"])
def update_draft(draft_id: int, body: DraftUpdate, user: Optional[dict] = Depends(optional_user),
                 token: Optional[str] = Depends(draft_token)):
    """Autosave one wizard step (fields are merged into the draft)."""
    return run(platform.update_draft, draft_id, user, token, body.inputs, body.step, body.demographics, body.locale)


@router.delete("/drafts/{draft_id}", tags=["drafts"])
def delete_draft(draft_id: int, user: Optional[dict] = Depends(optional_user), token: Optional[str] = Depends(draft_token)):
    return run(platform.delete_draft, draft_id, user, token)


@router.get("/drafts/{draft_id}/offers", tags=["drafts"])
def draft_offers(draft_id: int, user: Optional[dict] = Depends(optional_user), token: Optional[str] = Depends(draft_token)):
    """Estimated offers from every active lender (amount and rate range, odds, best combination)."""
    return run(platform.draft_offers, draft_id, user, token)
