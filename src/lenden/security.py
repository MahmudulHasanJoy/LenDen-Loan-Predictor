"""Passwords (PBKDF2-SHA256), JWT access tokens, opaque refresh tokens, TOTP and signed file links.

Everything here is standard library + PyJWT, so it runs anywhere the API runs.
"""
from __future__ import annotations

import base64
import hashlib
import hmac
import os
import secrets
import struct
import time
from datetime import timedelta

import jwt

from . import clock
from .errors import AuthError, Forbidden
from .settings import ACCESS_MINUTES, JWT_SECRET, PASSWORD_ITERATIONS

__all__ = ["AuthError", "Forbidden", "hash_password", "verify_password", "needs_rehash", "create_token",
           "decode_token", "require", "new_secret", "hash_token", "totp_now", "verify_totp",
           "new_totp_secret", "sign_path", "verify_signed_path"]


# ------------------------------------------------------------------ passwords
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


def needs_rehash(stored: str, iterations: int | None = None) -> bool:
    """True when a stored hash uses fewer rounds than today's setting (re-hashed on next login)."""
    try:
        return int(stored.split("$")[1]) < (iterations or PASSWORD_ITERATIONS)
    except (IndexError, ValueError):
        return True


# ------------------------------------------------------------------ access tokens (JWT)
def create_token(user: dict, secret: str = JWT_SECRET, minutes: int | None = None) -> str:
    now = clock.utcnow()
    payload = {"sub": str(user["id"]), "role": user["role"], "org": user.get("org_id"),
               "iat": now, "exp": now + timedelta(minutes=minutes or ACCESS_MINUTES)}
    return jwt.encode(payload, secret, algorithm="HS256")


def decode_token(token: str, secret: str = JWT_SECRET) -> dict:
    try:
        # Tokens are issued with the (possibly test-shifted) clock, so validate against it too.
        claims = jwt.decode(token, secret, algorithms=["HS256"], options={"verify_exp": False})
    except jwt.PyJWTError as e:
        raise AuthError("Invalid token.", code="TOKEN_INVALID") from e
    if claims.get("exp", 0) < clock.utcnow().timestamp():
        raise AuthError("Session expired. Please log in again.", code="TOKEN_EXPIRED")
    return claims


def require(user: dict, *roles: str) -> None:
    if user["role"] not in roles:
        raise Forbidden(f"This action needs one of these roles: {', '.join(roles)}.", code="ROLE_REQUIRED")


# ------------------------------------------------------------------ opaque secrets
def new_secret(nbytes: int = 32) -> str:
    """URL-safe random token (refresh tokens, draft tokens, reset links)."""
    return secrets.token_urlsafe(nbytes)


def hash_token(token: str) -> str:
    """Tokens are stored hashed, so a database leak does not leak live sessions."""
    return hashlib.sha256(token.encode()).hexdigest()


# ------------------------------------------------------------------ TOTP (RFC 6238)
def new_totp_secret() -> str:
    return base64.b32encode(os.urandom(20)).decode().rstrip("=")


def _hotp(secret_b32: str, counter: int, digits: int = 6) -> str:
    key = base64.b32decode(secret_b32 + "=" * (-len(secret_b32) % 8), casefold=True)
    mac = hmac.new(key, struct.pack(">Q", counter), hashlib.sha1).digest()
    o = mac[-1] & 0x0F
    code = (struct.unpack(">I", mac[o:o + 4])[0] & 0x7FFFFFFF) % 10 ** digits
    return str(code).zfill(digits)


def totp_now(secret_b32: str, at: float | None = None, step: int = 30) -> str:
    return _hotp(secret_b32, int((at if at is not None else time.time()) // step))


def verify_totp(secret_b32: str, code: str, at: float | None = None, step: int = 30, window: int = 1) -> bool:
    t = int((at if at is not None else time.time()) // step)
    code = (code or "").strip().replace(" ", "")
    return any(hmac.compare_digest(_hotp(secret_b32, t + d), code) for d in range(-window, window + 1))


def totp_uri(secret_b32: str, email: str) -> str:
    return f"otpauth://totp/LenDen:{email}?secret={secret_b32}&issuer=LenDen"


# ------------------------------------------------------------------ signed file links
def sign_path(path: str, minutes: int = 5, secret: str = JWT_SECRET) -> str:
    """Short-lived token for downloading one stored file (like a signed URL)."""
    exp = int(clock.utcnow().timestamp()) + minutes * 60
    msg = f"{path}|{exp}".encode()
    sig = base64.urlsafe_b64encode(hmac.new(secret.encode(), msg, hashlib.sha256).digest()).decode().rstrip("=")
    raw = base64.urlsafe_b64encode(msg).decode().rstrip("=")
    return f"{raw}.{sig}"


def verify_signed_path(token: str, secret: str = JWT_SECRET) -> str:
    try:
        raw, sig = token.split(".")
        msg = base64.urlsafe_b64decode(raw + "=" * (-len(raw) % 4))
        good = base64.urlsafe_b64encode(hmac.new(secret.encode(), msg, hashlib.sha256).digest()).decode().rstrip("=")
        if not hmac.compare_digest(sig, good):
            raise ValueError
        path, exp = msg.decode().rsplit("|", 1)
    except (ValueError, UnicodeDecodeError) as e:
        raise Forbidden("This link is not valid.", code="LINK_INVALID") from e
    if int(exp) < clock.utcnow().timestamp():
        raise Forbidden("This link has expired.", code="LINK_EXPIRED")
    return path
