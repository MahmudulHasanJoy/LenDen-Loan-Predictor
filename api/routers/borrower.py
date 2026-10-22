"""Borrower: drafts, applications, documents, loans and the credit ladder."""
from fastapi import APIRouter, Depends, File, Form, Request, UploadFile

from lenden.settings import MAX_UPLOAD_BYTES

from ..deps import current_user, idempotent, platform, run
from ..schemas import ApplicationIn, PaymentIn

router = APIRouter(tags=["borrower"])


@router.get("/drafts", tags=["drafts"])
def my_drafts(user: dict = Depends(current_user)):
    return run(platform.list_drafts, user)


@router.post("/applications")
def apply(body: ApplicationIn, request: Request, user: dict = Depends(current_user)):
    """Apply with an `offer_id` (v3) or with `org_id` + `inputs` (v2). Send an Idempotency-Key header to make
    retries safe."""
    return idempotent(request, user, platform.apply, user, body.org_id, body.inputs, body.consent, body.offer_id,
                      body.demographics)


@router.get("/applications/mine")
def my_applications(user: dict = Depends(current_user)):
    return run(platform.my_applications, user)


@router.get("/applications/{app_id}")
def my_application(app_id: int, user: dict = Depends(current_user)):
    """Status timeline, document requests, decision reasons and the next best step."""
    return run(platform.borrower_application, user, app_id)


@router.post("/applications/{app_id}/withdraw")
def withdraw(app_id: int, user: dict = Depends(current_user)):
    return run(platform.withdraw, user, app_id)


@router.post("/applications/{app_id}/documents")
async def upload(app_id: int, kind: str = Form(...), file: UploadFile = File(...),
                 user: dict = Depends(current_user)):
    data = await file.read(MAX_UPLOAD_BYTES + 1)
    return run(platform.upload_document, user, app_id, kind, file.filename or "document", file.content_type or "", data)


@router.get("/documents/{doc_id}/link")
def document_link(doc_id: int, user: dict = Depends(current_user)):
    """A download link valid for 5 minutes (borrower: own documents; staff: their lender's)."""
    return run(platform.document_link, user, doc_id)


@router.get("/loans")
def my_loans(user: dict = Depends(current_user)):
    return run(platform.my_loans, user)


@router.get("/loans/{loan_id}")
def loan(loan_id: int, user: dict = Depends(current_user)):
    return run(platform.loan_detail, user, loan_id)


@router.post("/loans/{loan_id}/repayments")
def pay(loan_id: int, body: PaymentIn, request: Request, user: dict = Depends(current_user)):
    """Record a (mock) payment. Without an amount, pays the next instalment."""
    return idempotent(request, user, platform.pay, user, loan_id, body.amount)


@router.get("/me/levels")
def levels(user: dict = Depends(current_user)):
    return run(platform.my_levels, user)
