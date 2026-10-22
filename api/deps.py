"""Shared API plumbing: the platform singleton, units of work, auth dependencies, idempotency."""
from __future__ import annotations

import json
from typing import Optional

from fastapi import Depends, Header, HTTPException, Request
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

from lenden import db as ldb
from lenden.security import decode_token
from lenden.services import build_platform

platform = build_platform()
bearer = HTTPBearer(auto_error=False)


def run(fn, *args, **kwargs):
    """Run one unit of work: commit on success, roll back on any error."""
    with platform.db.session():
        return fn(*args, **kwargs)


def client_ip(request: Request) -> str:
    fwd = request.headers.get("x-forwarded-for", "")
    return fwd.split(",")[0].strip() if fwd else (request.client.host if request.client else "unknown")


def current_user(creds: Optional[HTTPAuthorizationCredentials] = Depends(bearer)) -> dict:
    if creds is None:
        raise HTTPException(status_code=401, detail="Please log in.")
    claims = decode_token(creds.credentials)
    return run(platform.user_from_claims, claims)


def optional_user(creds: Optional[HTTPAuthorizationCredentials] = Depends(bearer)) -> Optional[dict]:
    if creds is None:
        return None
    return run(platform.user_from_claims, decode_token(creds.credentials))


def draft_token(x_draft_token: Optional[str] = Header(default=None)) -> Optional[str]:
    return x_draft_token


def idempotent(request: Request, user: dict, fn, *args, **kwargs):
    """Replay the stored response when the same Idempotency-Key is sent twice (e.g. a retry after a timeout)."""
    key = (request.headers.get("idempotency-key") or "").strip()[:100]
    if not key:
        return run(fn, *args, **kwargs)
    route = f"{request.method} {request.url.path}"
    with platform.db.session():
        seen = platform._one("SELECT route, response FROM idempotency_keys WHERE key=? AND user_id=?", (key, user["id"]))
        if seen:
            if seen["route"] != route:
                raise HTTPException(status_code=422, detail="Idempotency-Key reused for a different request.")
            return seen["response"]
        result = fn(*args, **kwargs)
        platform.db.execute("""INSERT INTO idempotency_keys (key, user_id, route, status_code, response, created_at)
                               VALUES (?,?,?,?,?,?)""",
                            (key, user["id"], route, 200, json.dumps(result, default=str), ldb.now()))
        return result
