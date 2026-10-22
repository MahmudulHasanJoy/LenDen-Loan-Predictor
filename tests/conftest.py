import os
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT / "src"), str(ROOT), str(ROOT / "tests")]

# Test settings, set before any lenden module reads the environment.
os.environ.setdefault("LENDEN_PBKDF2_ITERS", "1000")          # fast password hashing in tests only
os.environ["LENDEN_SEED_DEMO"] = "0"
os.environ["LENDEN_TESTING"] = "1"                             # no background scheduler
os.environ["LENDEN_DEV_EXPOSE_CODES"] = "1"                    # OTP codes / reset tokens in responses
os.environ["LENDEN_EXPOSE_CODES_FOR_ALL"] = "1"
os.environ.setdefault("LENDEN_UPLOAD_DIR", tempfile.mkdtemp(prefix="lenden-uploads-"))

import pytest  # noqa: E402


@pytest.fixture(autouse=True)
def _fresh_clock_and_limits():
    from lenden import clock
    from lenden.ratelimit import limiter
    clock.reset()
    limiter.reset()
    yield
    clock.reset()
    limiter.reset()


def make_db():
    """Fresh database: in-memory SQLite, or PostgreSQL when TEST_DATABASE_URL is set (CI matrix)."""
    from lenden import db
    url = os.getenv("TEST_DATABASE_URL")
    if url:
        fresh = db.connect(url, migrate=False)
        fresh.drop_all()
        fresh.close()
        return db.connect(url)
    return db.connect(":memory:")
