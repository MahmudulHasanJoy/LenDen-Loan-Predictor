"""Platform owner (super admin): lenders, model registry, feature flags, jobs."""
from fastapi import APIRouter, Depends, HTTPException

from lenden.jobs import JOBS, run_job
from lenden.security import require

from ..deps import current_user, platform, run
from ..schemas import ActiveIn, FlagIn, OrgIn, PromoteIn

router = APIRouter(prefix="/admin", tags=["super admin"])


@router.get("/stats")
def platform_stats(user: dict = Depends(current_user)):
    return run(platform.platform_stats, user)


@router.get("/orgs")
def list_orgs(user: dict = Depends(current_user)):
    return run(platform.list_orgs, user)


@router.post("/orgs")
def create_org(body: OrgIn, user: dict = Depends(current_user)):
    return run(platform.create_org, user, body.name, body.plan, body.admin_email, body.admin_name,
               body.admin_password, body.currency, body.locale)


@router.patch("/orgs/{org_id}")
def set_org_active(org_id: int, body: ActiveIn, user: dict = Depends(current_user)):
    return run(platform.set_org_active, user, org_id, body.active)


@router.get("/models")
def models(user: dict = Depends(current_user)):
    return run(platform.list_models, user)


@router.post("/models/{version_id}/promote")
def promote(version_id: int, body: PromoteIn, user: dict = Depends(current_user)):
    return run(platform.promote, user, version_id, body.to)


@router.get("/models/{version_id}/shadow-report")
def shadow_report(version_id: int, user: dict = Depends(current_user)):
    return run(platform.shadow_report, user, version_id)


@router.get("/flags")
def flags(user: dict = Depends(current_user)):
    return run(platform.list_flags, user)


@router.put("/flags/{key}")
def set_flag(key: str, body: FlagIn, user: dict = Depends(current_user)):
    return run(platform.set_flag, user, key, body.enabled)


@router.get("/jobs")
def jobs(user: dict = Depends(current_user)):
    require(user, "superadmin")
    rows = {r["name"]: r for r in run(platform._q, "SELECT * FROM job_runs")}
    return [{"name": n, "interval_seconds": i, "last_run_at": rows.get(n, {}).get("last_run_at"),
             "last_result": rows.get(n, {}).get("last_result")} for n, (i, _) in JOBS.items()]


@router.post("/jobs/{name}/run")
def run_now(name: str, user: dict = Depends(current_user)):
    require(user, "superadmin")
    if name not in JOBS:
        raise HTTPException(status_code=404, detail="Unknown job.")
    return {"name": name, "result": run_job(platform, name, force=True)}
