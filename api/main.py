"""LenDen API: one backend for borrowers, loan officers, lender admins and the platform owner.

Run locally:
    uvicorn api.main:app --reload --host 0.0.0.0 --port 8000      # docs at /docs

Routes live under /v1. The same routes are also served without the prefix for one release,
so v2 apps that are already installed keep working.
"""
from __future__ import annotations

import json
import logging
import os
import sys
import threading
import time
import uuid
from pathlib import Path

from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from starlette.exceptions import HTTPException

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
from credit_risk.service import ValidationError  # noqa: E402
from lenden import __version__  # noqa: E402
from lenden.errors import AppError  # noqa: E402
from lenden.settings import CORS_ORIGINS, ROOT, SENTRY_DSN  # noqa: E402

from .deps import platform  # noqa: E402
from .routers import auth, borrower, files, owner, public, staff  # noqa: E402

log = logging.getLogger("lenden.api")
if not logging.getLogger().handlers:
    logging.basicConfig(level=logging.INFO, format="%(message)s")

if SENTRY_DSN:                                     # optional error tracking
    try:
        import sentry_sdk
        sentry_sdk.init(dsn=SENTRY_DSN, traces_sample_rate=0.0, send_default_pii=False)
    except ImportError:                            # pragma: no cover
        log.warning("SENTRY_DSN is set but sentry-sdk is not installed")


# ----------------------------------------------------------------------------- startup work
def _seed_demo_if_empty():
    """Fill an empty database with demo data, in the background so /health answers at once."""
    try:
        with platform.db.session():
            if platform.db.execute("SELECT 1 FROM orgs").fetchone():
                return
        from lenden.seed import build
        with platform.db.session():          # its own connection (SQLite: holds the lock until done)
            build(platform)
        log.info(json.dumps({"event": "demo_seeded"}))
    except Exception as e:                       # never take the server down because of demo data
        platform.db.rollback()
        log.error(json.dumps({"event": "demo_seed_failed", "error": str(e)}))


if os.getenv("LENDEN_SEED_DEMO", "1") == "1":
    if os.getenv("LENDEN_SEED_SYNC") == "1":
        _seed_demo_if_empty()
    else:
        threading.Thread(target=_seed_demo_if_empty, name="seed-demo", daemon=True).start()

if os.getenv("LENDEN_RUN_JOBS", "1") == "1" and os.getenv("LENDEN_TESTING") != "1":
    from lenden.jobs import Scheduler
    Scheduler(platform).start()

app = FastAPI(
    title="LenDen API",
    version=__version__,
    description="Multi-tenant loan-readiness platform. Borrowers check their chances, compare offers, apply, "
                "track and repay; officers review a risk-sorted queue with explanations; lender admins tune "
                "offers and costs and watch fairness and drift; the platform owner runs lenders and models. "
                "Educational project on synthetic data.",
)
app.add_middleware(CORSMiddleware, allow_origins=CORS_ORIGINS, allow_methods=["*"], allow_headers=["*"],
                   expose_headers=["X-Request-ID"])

CSP = ("default-src 'self'; script-src 'self' 'unsafe-inline' 'wasm-unsafe-eval' https://www.gstatic.com; "
       "style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; font-src 'self' data: https://fonts.gstatic.com; "
       "img-src 'self' data: blob:; connect-src 'self' https://www.gstatic.com https://fonts.gstatic.com "
       "https://fonts.googleapis.com; worker-src 'self' blob:; frame-ancestors 'none'; base-uri 'self'")


@app.middleware("http")
async def request_context(request: Request, call_next):
    rid = request.headers.get("x-request-id") or uuid.uuid4().hex[:16]
    start = time.perf_counter()
    response = await call_next(request)
    ms = round((time.perf_counter() - start) * 1000, 1)
    response.headers["X-Request-ID"] = rid
    response.headers["X-Content-Type-Options"] = "nosniff"
    response.headers["Referrer-Policy"] = "strict-origin-when-cross-origin"
    response.headers["X-Frame-Options"] = "DENY"
    if request.headers.get("x-forwarded-proto") == "https":
        response.headers["Strict-Transport-Security"] = "max-age=31536000; includeSubDomains"
    if response.headers.get("content-type", "").startswith("text/html") and os.getenv("LENDEN_CSP", "1") == "1":
        response.headers["Content-Security-Policy"] = CSP
    if request.url.path != "/health":
        log.info(json.dumps({"rid": rid, "method": request.method, "path": request.url.path,
                             "status": response.status_code, "ms": ms}))
    return response


# ----------------------------------------------------------------------------- errors
@app.exception_handler(AppError)
async def app_error(request: Request, exc: AppError):
    return JSONResponse(status_code=exc.status, content={"code": exc.code, "detail": exc.detail, "fields": exc.fields})


@app.exception_handler(ValidationError)
async def model_validation_error(request: Request, exc: ValidationError):
    return JSONResponse(status_code=422, content={"code": "INPUT_INVALID", "detail": str(exc), "fields": exc.errors})


@app.exception_handler(RequestValidationError)
async def request_validation_error(request: Request, exc: RequestValidationError):
    fields = {".".join(str(p) for p in e["loc"][1:]) or "body": e["msg"] for e in exc.errors()}
    return JSONResponse(status_code=422, content={"code": "VALIDATION_ERROR",
                                                  "detail": "Some fields are missing or invalid.", "fields": fields})


@app.exception_handler(HTTPException)
async def http_error(request: Request, exc: HTTPException):
    code = {401: "AUTH_REQUIRED", 403: "FORBIDDEN", 404: "NOT_FOUND", 422: "BAD_REQUEST"}.get(exc.status_code, "ERROR")
    return JSONResponse(status_code=exc.status_code, content={"code": code, "detail": exc.detail, "fields": {}},
                        headers=getattr(exc, "headers", None))


# ----------------------------------------------------------------------------- routes
for r in (public.router, auth.router, auth.me_router, borrower.router, staff.router, owner.router, files.router):
    app.include_router(r, prefix="/v1")
for r in (public.router, auth.router, auth.me_router, borrower.router, staff.router, owner.router):
    app.include_router(r, include_in_schema=False)          # v2 paths, kept for installed apps


# ----------------------------------------------------------------------------- web app
# In the Docker image the Flutter web build is copied to /app/web and served at "/",
# so one URL hosts both the app and the API. API routes above take priority.
WEB_DIR = Path(os.getenv("LENDEN_WEB_DIR", ROOT / "web"))
if (WEB_DIR / "index.html").exists():
    from fastapi.staticfiles import StaticFiles
    app.mount("/", StaticFiles(directory=WEB_DIR, html=True), name="web")
