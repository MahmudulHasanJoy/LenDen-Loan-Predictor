"""Runtime settings, read from environment variables."""
import os
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

DB_PATH = Path(os.getenv("LENDEN_DB", ROOT / "var" / "lenden.db"))
# Production: a PostgreSQL URL, e.g. Supabase's *session pooler* connection string.
DATABASE_URL = os.getenv("DATABASE_URL", "").strip()


def database_target() -> str:
    """PostgreSQL if DATABASE_URL is set, otherwise the local SQLite file."""
    return os.getenv("DATABASE_URL", "").strip() or os.getenv("LENDEN_DB", "") or str(DB_PATH)
# The platform ships the fairness-aware model (trained without Age, see notebook 02).
MODEL_PATH = Path(os.getenv("LENDEN_MODEL", ROOT / "artifacts" / "model_fair.joblib"))
# Set LENDEN_JWT_SECRET to a long random string in production (e.g. `openssl rand -hex 32`).
JWT_SECRET = os.getenv("LENDEN_JWT_SECRET", "dev-only-insecure-secret-change-me-in-production")
JWT_HOURS = int(os.getenv("LENDEN_JWT_HOURS", "12"))
PASSWORD_ITERATIONS = int(os.getenv("LENDEN_PBKDF2_ITERS", "200000"))

ROLES = ("borrower", "officer", "admin", "superadmin")
STATUSES = ("submitted", "needs_docs", "approved", "rejected")
DECISIONS = ("approved", "rejected", "needs_docs")
PLANS = ("free", "pro", "enterprise")
