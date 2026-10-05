"""Password hashing (PBKDF2-SHA256, stdlib) and JWT access tokens."""
import base64
import hashlib
import hmac
import os
from datetime import datetime, timedelta, timezone

import jwt

from .settings import JWT_HOURS, JWT_SECRET, PASSWORD_ITERATIONS


class AuthError(Exception):
    """Bad credentials or token (HTTP 401)."""


class Forbidden(Exception):
    """Authenticated but not allowed (HTTP 403)."""


def hash_password(password: str, iterations: int | None = None) -> str:
    iterations = iterations or PASSWORD_ITERATIONS
    salt = os.urandom(16)
    dk = hashlib.pbkdf2_hmac("sha256", password.encode(), salt, iterations)
    return f"pbkdf2_sha256${iterations}${base64.b64encode(salt).decode()}${base64.b64encode(dk).decode()}"


def verify_password(password: str, stored: str) -> bool:
    try:
        algo, iters, salt_b64, hash_b64 = stored.split("$")
    except ValueError:
        return False
    if algo != "pbkdf2_sha256":
        return False
    dk = hashlib.pbkdf2_hmac("sha256", password.encode(), base64.b64decode(salt_b64), int(iters))
    return hmac.compare_digest(dk, base64.b64decode(hash_b64))


def create_token(user: dict, secret: str = JWT_SECRET, hours: int = JWT_HOURS) -> str:
    now = datetime.now(timezone.utc)
    payload = {"sub": str(user["id"]), "role": user["role"], "org": user.get("org_id"),
               "iat": now, "exp": now + timedelta(hours=hours)}
    return jwt.encode(payload, secret, algorithm="HS256")


def decode_token(token: str, secret: str = JWT_SECRET) -> dict:
    try:
        return jwt.decode(token, secret, algorithms=["HS256"])
    except jwt.ExpiredSignatureError as e:
        raise AuthError("Session expired. Please log in again.") from e
    except jwt.PyJWTError as e:
        raise AuthError("Invalid token.") from e


def require(user: dict, *roles: str) -> None:
    if user["role"] not in roles:
        raise Forbidden(f"This action needs one of these roles: {', '.join(roles)}.")
