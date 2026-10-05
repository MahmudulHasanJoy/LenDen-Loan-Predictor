"""LenDen API: one backend for borrowers, loan officers, lender admins and the platform owner.

Run locally:
    uvicorn api.main:app --reload --host 0.0.0.0 --port 8000      # docs at /docs
On first start an empty database is filled with demo data (set LENDEN_SEED_DEMO=0 to skip).
"""
import os
import sys
import threading
from pathlib import Path
from typing import Any, Literal, Optional

from fastapi import Body, Depends, FastAPI, HTTPException, Query, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from pydantic import BaseModel, Field

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
from credit_risk.readiness import affordability  # noqa: E402
from credit_risk.service import CreditRiskService, ValidationError  # noqa: E402
from lenden import __version__, db  # noqa: E402
from lenden.security import AuthError, Forbidden, decode_token  # noqa: E402
from lenden.services import BadRequest, Conflict, NotFound, Platform  # noqa: E402
from lenden.settings import MODEL_PATH, ROOT, database_target  # noqa: E402

# ----------------------------------------------------------------------------- startup
risk = CreditRiskService(os.getenv("LENDEN_MODEL", MODEL_PATH))
platform = Platform(db.connect(database_target()), risk)
_lock = threading.RLock()      # one database connection shared by worker threads

def _seed_demo_if_empty():
    """Fill an empty database with demo data. Runs in the background so the server
    answers /health immediately; other requests wait on the lock until it finishes."""
    with _lock:
        try:
            if platform.db.execute("SELECT 1 FROM orgs").fetchone():
                platform.db.rollback()
                return
            from lenden.seed import build
            build(platform)
            platform.db.commit()
            print("LenDen: demo data created.", flush=True)
        except Exception as e:  # never take the server down because of demo data
            platform.db.rollback()
            print(f"LenDen: demo seeding failed: {e}", flush=True)


if os.getenv("LENDEN_SEED_DEMO", "1") == "1":
    if os.getenv("LENDEN_SEED_SYNC") == "1":
        _seed_demo_if_empty()
    else:
        threading.Thread(target=_seed_demo_if_empty, name="seed-demo", daemon=True).start()

app = FastAPI(
    title="LenDen API",
    version=__version__,
    description="Multi-tenant loan-readiness platform. Borrowers check readiness and apply; "
                "loan officers review a risk-sorted queue; lender admins tune costs and monitor "
                "fairness and drift. Educational project on synthetic data.",
)
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])


def run(fn, *args, **kwargs):
    """Run one unit of work: commit on success, roll back on any error."""
    with _lock:
        try:
            result = fn(*args, **kwargs)
            platform.db.commit()
            return result
        except Exception:
            platform.db.rollback()
            raise


# ----------------------------------------------------------------------------- errors
def _handler(status: int):
    async def handle(_: Request, exc: Exception):
        detail = getattr(exc, "errors", None) or str(exc)
        return JSONResponse(status_code=status, content={"detail": detail})
    return handle


for exc_type, status in [(AuthError, 401), (Forbidden, 403), (NotFound, 404), (Conflict, 409),
                         (BadRequest, 422), (ValidationError, 422)]:
    app.add_exception_handler(exc_type, _handler(status))


# ----------------------------------------------------------------------------- auth
bearer = HTTPBearer(auto_error=False)


def current_user(creds: Optional[HTTPAuthorizationCredentials] = Depends(bearer)) -> dict:
    if creds is None:
        raise HTTPException(status_code=401, detail="Please log in.")
    return run(platform.user_from_claims, decode_token(creds.credentials))


# ----------------------------------------------------------------------------- schemas
class Register(BaseModel):
    email: str = Field(..., examples=["you@example.com"])
    name: str = Field(..., min_length=2, max_length=80)
    password: str = Field(..., min_length=8)


class Login(BaseModel):
    email: str = Field(..., examples=["mahmud@greenfield.demo"])
    password: str = Field(..., examples=["demo1234"])


class EmiRequest(BaseModel):
    principal: float = Field(..., gt=0)
    annual_rate: float = Field(..., ge=0, le=100)
    months: int = Field(..., gt=0, le=480)
    annual_income: float = Field(..., gt=0)


class ApplicationIn(BaseModel):
    org_id: int
    inputs: dict[str, Any]
    consent: bool


class DecisionIn(BaseModel):
    decision: Literal["approved", "rejected", "needs_docs"]
    note: str = ""


class SettingsIn(BaseModel):
    cost_ratio: Optional[int] = Field(None, ge=1, le=50)
    review_capacity: Optional[float] = Field(None, ge=0.01, le=1)
    clear_capacity: bool = False


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


# ----------------------------------------------------------------------------- public
@app.get("/health", tags=["public"])
def health():
    return {"status": "ok", "version": __version__, "model": risk.model_name,
            "database": platform.db.dialect}


@app.get("/metadata", tags=["public"])
def metadata():
    """Form fields (ranges, options, defaults) for the loan inputs."""
    return risk.metadata()


@app.get("/lenders", tags=["public"])
def lenders():
    return run(platform.list_lenders)


@app.post("/readiness", tags=["public"])
def check_readiness(inputs: dict[str, Any] = Body(..., examples=[{
        "Income": 45000, "LoanAmount": 120000, "CreditScore": 610, "MonthsEmployed": 24,
        "NumCreditLines": 2, "InterestRate": 18.5, "LoanTerm": 60, "DTIRatio": 0.65,
        "Education": "Bachelor's", "EmploymentType": "Part-time", "MaritalStatus": "Single",
        "HasMortgage": "No", "HasDependents": "No", "LoanPurpose": "Home", "HasCoSigner": "No"}])):
    """Anonymous readiness check: traffic light, improvement tips and EMI. Nothing is stored."""
    return run(platform.check_readiness, inputs)


@app.post("/emi", tags=["public"])
def emi(req: EmiRequest):
    return affordability(req.principal, req.annual_rate, req.months, req.annual_income)


# ----------------------------------------------------------------------------- auth routes
@app.post("/auth/register", tags=["auth"])
def register(body: Register):
    return run(platform.register_borrower, body.email, body.name, body.password)


@app.post("/auth/login", tags=["auth"])
def login(body: Login):
    return run(platform.login, body.email, body.password)


@app.get("/me", tags=["auth"])
def me(user: dict = Depends(current_user)):
    return run(platform.me, user)


# ----------------------------------------------------------------------------- borrower
@app.post("/applications", tags=["borrower"])
def apply(body: ApplicationIn, user: dict = Depends(current_user)):
    return run(platform.apply, user, body.org_id, body.inputs, body.consent)


@app.get("/applications/mine", tags=["borrower"])
def my_applications(user: dict = Depends(current_user)):
    return run(platform.my_applications, user)


# ----------------------------------------------------------------------------- officer
@app.get("/org/applications", tags=["officer"])
def org_applications(status: Optional[Literal["pending", "submitted", "needs_docs", "approved", "rejected"]] = None,
                     light: Optional[Literal["green", "yellow", "red"]] = None,
                     sort: Literal["risk", "newest", "oldest", "amount"] = "risk",
                     limit: int = Query(50, ge=1, le=500), offset: int = Query(0, ge=0),
                     user: dict = Depends(current_user)):
    return run(platform.list_applications, user, status, light, sort, limit, offset)


@app.get("/org/applications/{app_id}", tags=["officer"])
def org_application(app_id: int, user: dict = Depends(current_user)):
    return run(platform.get_application, user, app_id)


@app.post("/org/applications/{app_id}/decision", tags=["officer"])
def decide(app_id: int, body: DecisionIn, user: dict = Depends(current_user)):
    return run(platform.decide, user, app_id, body.decision, body.note)


@app.get("/org/dashboard", tags=["officer"])
def dashboard(user: dict = Depends(current_user)):
    return run(platform.dashboard, user)


# ----------------------------------------------------------------------------- lender admin
@app.get("/org/settings", tags=["admin"])
def get_settings(user: dict = Depends(current_user)):
    return run(platform.get_settings, user)


@app.put("/org/settings", tags=["admin"])
def update_settings(body: SettingsIn, user: dict = Depends(current_user)):
    return run(platform.update_settings, user, body.cost_ratio, body.review_capacity, body.clear_capacity)


@app.get("/org/team", tags=["admin"])
def team(user: dict = Depends(current_user)):
    return run(platform.list_team, user)


@app.post("/org/team", tags=["admin"])
def add_member(body: MemberIn, user: dict = Depends(current_user)):
    return run(platform.add_team_member, user, body.email, body.name, body.password, body.role)


@app.patch("/org/team/{member_id}", tags=["admin"])
def set_member_active(member_id: int, body: ActiveIn, user: dict = Depends(current_user)):
    return run(platform.set_member_active, user, member_id, body.active)


@app.get("/org/audit", tags=["admin"])
def audit(limit: int = Query(50, ge=1, le=500), user: dict = Depends(current_user)):
    return run(platform.audit_log, user, limit)


# ----------------------------------------------------------------------------- platform owner
@app.get("/admin/stats", tags=["super admin"])
def platform_stats(user: dict = Depends(current_user)):
    return run(platform.platform_stats, user)


@app.get("/admin/orgs", tags=["super admin"])
def list_orgs(user: dict = Depends(current_user)):
    return run(platform.list_orgs, user)


@app.post("/admin/orgs", tags=["super admin"])
def create_org(body: OrgIn, user: dict = Depends(current_user)):
    return run(platform.create_org, user, body.name, body.plan, body.admin_email,
               body.admin_name, body.admin_password)


@app.patch("/admin/orgs/{org_id}", tags=["super admin"])
def set_org_active(org_id: int, body: ActiveIn, user: dict = Depends(current_user)):
    return run(platform.set_org_active, user, org_id, body.active)


# ----------------------------------------------------------------------------- web app
# In the Docker image the Flutter web build is copied to /app/web and served at "/",
# so one URL hosts both the app and the API. API routes above take priority.
WEB_DIR = Path(os.getenv("LENDEN_WEB_DIR", ROOT / "web"))
if (WEB_DIR / "index.html").exists():
    from fastapi.staticfiles import StaticFiles
    app.mount("/", StaticFiles(directory=WEB_DIR, html=True), name="web")
