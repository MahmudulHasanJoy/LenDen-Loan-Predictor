"""The LenDen platform: one object that exposes every domain service.

Each domain lives in its own module under lenden/domain; `Platform` combines them so the API,
the seeder, the jobs and the tests all talk to one place. Framework-free: the API layer only
maps HTTP to these calls.

Tenant isolation rule: officer/admin calls always filter by the caller's org_id, and a record
from another tenant is reported as "not found".
"""
from __future__ import annotations

from pathlib import Path

from credit_risk.service import CreditRiskService

from . import db
from .domain.applications import Applications
from .domain.drafts import Drafts
from .domain.identity import Identity
from .domain.insights import Insights
from .domain.loans import Loans
from .domain.models import Models
from .domain.notifications import Notifications
from .domain.orgs import Orgs
from .domain.privacy import Privacy
from .errors import AppError, AuthError, BadRequest, Conflict, Forbidden, NotFound, RateLimited
from .settings import DB_POOL_SIZE, MODEL_PATH, database_target
from .storage import default_storage


__all__ = ["Platform", "build_platform", "AppError", "AuthError", "BadRequest", "Conflict", "Forbidden",
           "NotFound", "RateLimited"]


class Platform(Identity, Orgs, Drafts, Applications, Loans, Notifications, Privacy, Insights, Models):
    def __init__(self, conn: db.Database, risk: CreditRiskService, storage=None,
                 model_path: Path | None = None):
        self.db = conn
        self.storage = storage or default_storage()
        self.hash_iterations = None          # None = secure default; the seeder uses fewer for demo users
        self._set_risk(risk, Path(model_path).name if model_path else MODEL_PATH.name)
        self.ensure_registry(Path(model_path) if model_path else MODEL_PATH)
        self.load_models()


def build_platform(target: str | None = None) -> Platform:
    """Production wiring: database from the environment, model from the registry."""
    database = db.connect(target or database_target(), pool_size=DB_POOL_SIZE)
    return Platform(database, CreditRiskService(MODEL_PATH), model_path=MODEL_PATH)
