"""Application errors. Each carries a stable `code` the clients switch on, and an HTTP status.

The API turns any of these into  {"code": "...", "detail": "...", "fields": {...}}.
Clients translate `code`; `detail` is an English fallback for logs and API users.
"""
from __future__ import annotations


class AppError(Exception):
    status = 400
    default_code = "BAD_REQUEST"

    def __init__(self, detail: str = "", code: str | None = None, fields: dict | None = None):
        super().__init__(detail)
        self.detail = detail
        self.code = code or self.default_code
        self.fields = fields or {}


class BadRequest(AppError, ValueError):
    status, default_code = 422, "BAD_REQUEST"


class AuthError(AppError):
    status, default_code = 401, "AUTH_REQUIRED"


class Forbidden(AppError):
    status, default_code = 403, "FORBIDDEN"


class NotFound(AppError):
    status, default_code = 404, "NOT_FOUND"


class Conflict(AppError):
    status, default_code = 409, "CONFLICT"


class RateLimited(AppError):
    status, default_code = 429, "RATE_LIMITED"
