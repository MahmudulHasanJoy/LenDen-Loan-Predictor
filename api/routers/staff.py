"""Loan officers and lender admins."""
from typing import Literal, Optional

from fastapi import APIRouter, Depends, Query

from ..deps import current_user, platform, run
from ..schemas import ActiveIn, DecisionIn, DocRequestIn, MemberIn, OfferRulesIn, SettingsIn

router = APIRouter(prefix="/org")


# ----------------------------------------------------------------------------- officer
@router.get("/applications", tags=["officer"])
def org_applications(status: Optional[Literal["pending", "submitted", "in_review", "needs_docs", "approved", "rejected",
                                              "withdrawn"]] = None,
                     light: Optional[Literal["green", "yellow", "red"]] = None,
                     odds: Optional[Literal["excellent", "good", "fair", "low"]] = None,
                     assigned: Optional[Literal["me", "unassigned"]] = None,
                     sort: Literal["risk", "newest", "oldest", "amount", "sla"] = "risk",
                     limit: int = Query(50, ge=1, le=500), offset: int = Query(0, ge=0),
                     cursor: Optional[str] = None, user: dict = Depends(current_user)):
    return run(platform.list_applications, user, status, light, sort, limit, offset, assigned, odds, cursor)


@router.get("/applications/{app_id}", tags=["officer"])
def org_application(app_id: int, user: dict = Depends(current_user)):
    return run(platform.get_application, user, app_id)


@router.post("/applications/{app_id}/claim", tags=["officer"])
def claim(app_id: int, user: dict = Depends(current_user)):
    return run(platform.claim, user, app_id)


@router.post("/applications/{app_id}/release", tags=["officer"])
def release(app_id: int, user: dict = Depends(current_user)):
    return run(platform.release, user, app_id)


@router.post("/applications/{app_id}/decision", tags=["officer"])
def decide(app_id: int, body: DecisionIn, user: dict = Depends(current_user)):
    """Approve (optionally with terms), reject (reason codes required) or ask for documents."""
    terms = body.terms.model_dump(exclude_none=True) if body.terms else None
    return run(platform.decide, user, app_id, body.decision, body.note, body.reason_codes, terms, body.documents)


@router.post("/applications/{app_id}/document-requests", tags=["officer"])
def request_documents(app_id: int, body: DocRequestIn, user: dict = Depends(current_user)):
    return run(platform.request_documents, user, app_id, body.documents, body.note)


@router.get("/dashboard", tags=["officer"])
def dashboard(user: dict = Depends(current_user)):
    return run(platform.dashboard, user)


@router.get("/loans", tags=["officer"])
def org_loans(status: Optional[Literal["active", "closed", "defaulted"]] = None, user: dict = Depends(current_user)):
    return run(platform.org_loans, user, status)


@router.get("/loans/{loan_id}", tags=["officer"])
def org_loan(loan_id: int, user: dict = Depends(current_user)):
    return run(platform.loan_detail, user, loan_id)


# ----------------------------------------------------------------------------- lender admin
@router.get("/settings", tags=["admin"])
def get_settings(user: dict = Depends(current_user)):
    return run(platform.get_settings, user)


@router.put("/settings", tags=["admin"])
def update_settings(body: SettingsIn, user: dict = Depends(current_user)):
    return run(platform.update_settings, user, body.cost_ratio, body.review_capacity, body.clear_capacity,
               body.sla_hours)


@router.get("/offer-rules", tags=["admin"])
def get_rules(user: dict = Depends(current_user)):
    return run(platform.get_offer_rules, user)


@router.put("/offer-rules", tags=["admin"])
def update_rules(body: OfferRulesIn, user: dict = Depends(current_user)):
    return run(platform.update_offer_rules, user, body.model_dump(exclude_none=True))


@router.get("/team", tags=["admin"])
def team(user: dict = Depends(current_user)):
    return run(platform.list_team, user)


@router.post("/team", tags=["admin"])
def add_member(body: MemberIn, user: dict = Depends(current_user)):
    return run(platform.add_team_member, user, body.email, body.name, body.password, body.role)


@router.patch("/team/{member_id}", tags=["admin"])
def set_member_active(member_id: int, body: ActiveIn, user: dict = Depends(current_user)):
    return run(platform.set_member_active, user, member_id, body.active)


@router.get("/portfolio", tags=["admin"])
def portfolio(user: dict = Depends(current_user)):
    return run(platform.portfolio, user)


@router.get("/fairness", tags=["admin"])
def fairness(user: dict = Depends(current_user)):
    return run(platform.fairness_report, user)


@router.get("/drift", tags=["admin"])
def drift(user: dict = Depends(current_user)):
    return run(platform.drift_report, user)


@router.get("/audit", tags=["admin"])
def audit(limit: int = Query(50, ge=1, le=500), cursor: Optional[str] = None, user: dict = Depends(current_user)):
    return run(platform.audit_log, user, limit, cursor)
