"""Request bodies (Pydantic). Responses are plain dicts from the services."""
from __future__ import annotations

from typing import Any, Literal, Optional

from pydantic import BaseModel, Field


class Register(BaseModel):
    email: str = Field(..., examples=["you@example.com"])
    name: str = Field(..., min_length=2, max_length=80)
    password: str = Field(..., min_length=8)
    phone: Optional[str] = Field(None, examples=["01712345678"])
    locale: Literal["en", "bn"] = "en"
    anon_token: Optional[str] = Field(None, description="Claims the anonymous draft started before sign-up")


class Login(BaseModel):
    email: str = Field(..., examples=["mahmud@greenfield.demo"])
    password: str = Field(..., examples=["demo1234"])
    totp: Optional[str] = None
    anon_token: Optional[str] = None


class RefreshIn(BaseModel):
    refresh_token: str


class ForgotIn(BaseModel):
    email: str


class ResetIn(BaseModel):
    token: str
    password: str = Field(..., min_length=8)


class ChangePasswordIn(BaseModel):
    old_password: str
    new_password: str = Field(..., min_length=8)


class OtpRequest(BaseModel):
    phone: str
    purpose: Literal["login", "verify"] = "login"


class OtpVerify(BaseModel):
    phone: str
    code: str = Field(..., min_length=4, max_length=8)
    purpose: Literal["login", "verify"] = "login"
    anon_token: Optional[str] = None


class TotpCode(BaseModel):
    code: str


class ProfileIn(BaseModel):
    name: Optional[str] = None
    locale: Optional[Literal["en", "bn"]] = None
    notification_prefs: Optional[dict[str, bool]] = None


class DeleteAccountIn(BaseModel):
    password: str


class EmiRequest(BaseModel):
    principal: float = Field(..., gt=0)
    annual_rate: float = Field(..., ge=0, le=100)
    months: int = Field(..., gt=0, le=480)
    annual_income: float = Field(..., gt=0)


class DraftIn(BaseModel):
    inputs: dict[str, Any] = {}
    step: int = Field(1, ge=1, le=4)
    locale: Literal["en", "bn"] = "en"
    demographics: dict[str, str] = {}


class DraftUpdate(BaseModel):
    inputs: dict[str, Any] = {}
    step: Optional[int] = Field(None, ge=1, le=4)
    locale: Optional[Literal["en", "bn"]] = None
    demographics: dict[str, str] = {}


class SimulateIn(BaseModel):
    inputs: dict[str, Any] = {}
    overrides: dict[str, Any] = {}
    org_id: Optional[int] = None
    draft_id: Optional[int] = None


class ApplicationIn(BaseModel):
    offer_id: Optional[int] = None
    org_id: Optional[int] = None
    inputs: Optional[dict[str, Any]] = None
    consent: bool
    demographics: dict[str, str] = {}


class TermsIn(BaseModel):
    amount: Optional[float] = Field(None, gt=0)
    term: Optional[int] = Field(None, gt=0, le=120)
    rate: Optional[float] = Field(None, ge=0, le=60)


class DecisionIn(BaseModel):
    decision: Literal["approved", "rejected", "needs_docs"]
    note: str = ""
    reason_codes: list[str] = []
    terms: Optional[TermsIn] = None
    documents: list[str] = []


class DocRequestIn(BaseModel):
    documents: list[str] = Field(..., min_length=1)
    note: str = ""


class PaymentIn(BaseModel):
    amount: Optional[float] = Field(None, gt=0)


class SettingsIn(BaseModel):
    cost_ratio: Optional[int] = Field(None, ge=1, le=50)
    review_capacity: Optional[float] = Field(None, ge=0.01, le=1)
    clear_capacity: bool = False
    sla_hours: Optional[int] = Field(None, ge=4, le=336)


class OfferRulesIn(BaseModel):
    base_rate: Optional[float] = None
    rate_step: Optional[float] = None
    min_amount: Optional[float] = None
    max_amount: Optional[float] = None
    terms: Optional[list[int]] = None
    min_income: Optional[float] = None
    max_dti: Optional[float] = None
    max_income_share: Optional[float] = None
    ladder_caps: Optional[list[float]] = None


class MemberIn(BaseModel):
    email: str
    name: str = Field(..., min_length=2)
    password: str = Field(..., min_length=8)
    role: Literal["officer", "admin"] = "officer"


class ActiveIn(BaseModel):
    active: bool


class OrgIn(BaseModel):
    name: str = Field(..., min_length=2)
    plan: Literal["free", "pro", "enterprise"] = "free"
    admin_email: str
    admin_name: str = Field(..., min_length=2)
    admin_password: str = Field(..., min_length=8)
    currency: str = "BDT"
    locale: Literal["en", "bn"] = "en"


class PromoteIn(BaseModel):
    to: Literal["candidate", "shadow", "active", "retired"]


class FlagIn(BaseModel):
    enabled: bool
