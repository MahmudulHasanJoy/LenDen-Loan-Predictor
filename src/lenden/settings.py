"""Runtime settings, read from environment variables. Secrets are never given defaults in production."""
import os
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def _env(name: str, default: str = "") -> str:
    return os.getenv(name, default).strip()


def _flag(name: str, default: str = "0") -> bool:
    return _env(name, default).lower() in ("1", "true", "yes", "on")


DB_PATH = Path(_env("LENDEN_DB") or ROOT / "var" / "lenden.db")


def database_target() -> str:
    """PostgreSQL if DATABASE_URL is set, otherwise the local SQLite file."""
    return _env("DATABASE_URL") or _env("LENDEN_DB") or str(DB_PATH)


DB_POOL_SIZE = int(_env("LENDEN_DB_POOL", "5"))

# Models. The active model is chosen in the model registry; these are the files shipped in the image.
MODEL_PATH = Path(_env("LENDEN_MODEL") or ROOT / "artifacts" / "model_v3.joblib")
MODEL_DIR = Path(_env("LENDEN_MODEL_DIR") or ROOT / "artifacts")

# Auth. Set LENDEN_JWT_SECRET to a long random string in production (e.g. `openssl rand -hex 32`).
JWT_SECRET = _env("LENDEN_JWT_SECRET", "dev-only-insecure-secret-change-me-in-production")
ACCESS_MINUTES = int(_env("LENDEN_ACCESS_MINUTES", "15"))
REFRESH_DAYS = int(_env("LENDEN_REFRESH_DAYS", "30"))
JWT_HOURS = int(_env("LENDEN_JWT_HOURS", "12"))          # legacy v2 token lifetime (old APKs)
PASSWORD_ITERATIONS = int(_env("LENDEN_PBKDF2_ITERS", "600000"))
REQUIRE_STAFF_2FA = _flag("LENDEN_REQUIRE_STAFF_2FA")
# Development only: return reset links and OTP codes in API responses instead of only sending them.
# Only for the demo accounts (emails ending in .demo or @demo.app), so the public demo stays safe:
# a code shown on screen must never unlock a real person's account.
DEV_EXPOSE_CODES = _flag("LENDEN_DEV_EXPOSE_CODES")
EXPOSE_CODES_FOR_ALL = _flag("LENDEN_EXPOSE_CODES_FOR_ALL")      # tests only
DEMO_DOMAINS = ("@demo.app", ".demo")

# Web
CORS_ORIGINS = [o.strip() for o in _env("LENDEN_CORS_ORIGINS", "*").split(",") if o.strip()]
PUBLIC_URL = _env("LENDEN_PUBLIC_URL", "http://localhost:8000").rstrip("/")

# Files: local disk by default, Supabase Storage when both values are set.
UPLOAD_DIR = Path(_env("LENDEN_UPLOAD_DIR") or ROOT / "var" / "uploads")
SUPABASE_URL = _env("SUPABASE_URL").rstrip("/")
SUPABASE_SERVICE_KEY = _env("SUPABASE_SERVICE_KEY")
STORAGE_BUCKET = _env("LENDEN_STORAGE_BUCKET", "lenden-docs")
MAX_UPLOAD_BYTES = 5 * 1024 * 1024
UPLOAD_TYPES = {"application/pdf": ".pdf", "image/jpeg": ".jpg", "image/png": ".png"}

# Notifications: console by default; Resend or SMTP when configured.
RESEND_API_KEY = _env("RESEND_API_KEY")
SMTP_HOST = _env("SMTP_HOST")
SMTP_PORT = int(_env("SMTP_PORT", "587"))
SMTP_USER = _env("SMTP_USER")
SMTP_PASSWORD = _env("SMTP_PASSWORD")
MAIL_FROM = _env("LENDEN_MAIL_FROM", "LenDen <no-reply@lenden.app>")

# Background jobs run inside the web process unless disabled (e.g. when a separate worker runs them).
RUN_JOBS = _flag("LENDEN_RUN_JOBS", "1")
SEED_DEMO = _flag("LENDEN_SEED_DEMO", "1")
SENTRY_DSN = _env("SENTRY_DSN")

ROLES = ("borrower", "officer", "admin", "superadmin")
OPEN_STATUSES = ("submitted", "in_review", "needs_docs")
STATUSES = OPEN_STATUSES + ("approved", "rejected", "withdrawn")
DECISIONS = ("approved", "rejected", "needs_docs")
PLANS = ("free", "pro", "enterprise")
LOCALES = ("en", "bn")
