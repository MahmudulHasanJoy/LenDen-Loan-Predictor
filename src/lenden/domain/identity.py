"""Accounts and sessions: sign-up, login, refresh tokens, password reset, phone OTP, two-factor."""
from __future__ import annotations

import re
import secrets
import uuid

from .. import clock, db
from ..errors import AuthError, BadRequest, Conflict, NotFound
from ..ratelimit import limiter
from ..security import (create_token, hash_password, hash_token, needs_rehash, new_secret, new_totp_secret,
                        totp_uri, verify_password, verify_totp)
from ..settings import (ACCESS_MINUTES, DEMO_DOMAINS, DEV_EXPOSE_CODES, EXPOSE_CODES_FOR_ALL, LOCALES, PUBLIC_URL,
                        REFRESH_DAYS, REQUIRE_STAFF_2FA, ROLES)
from .base import Base, jdump, public_user

LOGIN_LIMIT, LOGIN_WINDOW = 5, 15 * 60          # failed attempts per account and per IP
OTP_LIMIT, OTP_WINDOW = 5, 60 * 60              # codes sent per phone per hour
STAFF = ("officer", "admin", "superadmin")


def may_show_code(email: str | None) -> bool:
    """Demo mode shows OTP codes and reset links on screen, but only for demo accounts."""
    if not DEV_EXPOSE_CODES:
        return False
    return EXPOSE_CODES_FOR_ALL or bool(email and email.endswith(DEMO_DOMAINS))


def normalise_phone(phone: str) -> str:
    """Bangladesh mobile numbers -> +8801XXXXXXXXX; other numbers must already be E.164."""
    p = re.sub(r"[\s\-()]", "", phone or "")
    if re.fullmatch(r"01[3-9]\d{8}", p):
        p = "+88" + p
    elif re.fullmatch(r"8801[3-9]\d{8}", p):
        p = "+" + p
    if not re.fullmatch(r"\+\d{8,15}", p):
        raise BadRequest("Enter a valid mobile number, e.g. 01712345678.", code="PHONE_INVALID",
                         fields={"phone": "invalid"})
    return p


class Identity(Base):
    hash_iterations: int | None = None

    # ================================================================ users
    def _create_user(self, email: str, name: str, password: str, role: str,
                     org_id: int | None = None, phone: str | None = None, locale: str = "en") -> dict:
        if role not in ROLES:
            raise BadRequest(f"Unknown role {role!r}.", code="ROLE_INVALID")
        if len(password) < 8:
            raise BadRequest("Password must be at least 8 characters.", code="PASSWORD_SHORT",
                             fields={"password": "min 8"})
        email = (email or "").strip().lower()
        if not re.fullmatch(r"[^@\s]+@[^@\s]+\.[^@\s]+", email):
            raise BadRequest("Enter a valid email address.", code="EMAIL_INVALID", fields={"email": "invalid"})
        if len((name or "").strip()) < 2:
            raise BadRequest("Please enter your name.", code="NAME_REQUIRED", fields={"name": "required"})
        phone = normalise_phone(phone) if phone else None
        if locale not in LOCALES:
            locale = "en"
        # Check first so PostgreSQL never enters an aborted transaction on the common case.
        if self._one("SELECT id FROM users WHERE email=?", (email,)):
            raise Conflict("An account with this email already exists.", code="EMAIL_TAKEN")
        if phone and self._one("SELECT id FROM users WHERE phone=?", (phone,)):
            raise Conflict("This mobile number is already registered.", code="PHONE_TAKEN")
        try:
            user_id = self.db.insert(
                """INSERT INTO users (email, name, password_hash, role, org_id, phone, locale, created_at)
                   VALUES (?,?,?,?,?,?,?,?)""",
                (email, name.strip(), hash_password(password, self.hash_iterations), role, org_id, phone,
                 locale, db.now()))
        except self.db.IntegrityError as e:          # race with a concurrent sign-up
            raise Conflict("An account with this email already exists.", code="EMAIL_TAKEN") from e
        return self.get_user(user_id)

    def _user_row(self, user_id: int) -> dict:
        u = self._one("SELECT * FROM users WHERE id=?", (user_id,))
        if not u or u.get("deleted_at"):
            raise NotFound("User not found.", code="USER_NOT_FOUND")
        return u

    def get_user(self, user_id: int) -> dict:
        return public_user(self._user_row(user_id))

    # ================================================================ sessions
    def _issue(self, user: dict, family: str | None = None) -> dict:
        refresh = new_secret()
        self.db.execute("""INSERT INTO refresh_tokens (user_id, token_hash, family, created_at, expires_at)
                           VALUES (?,?,?,?,?)""",
                        (user["id"], hash_token(refresh), family or uuid.uuid4().hex, db.now(),
                         self._later(days=REFRESH_DAYS)))
        access = create_token(user)
        out = {"token": access, "access_token": access, "token_type": "bearer",
               "expires_in": ACCESS_MINUTES * 60, "refresh_token": refresh, "user": user}
        if user.get("org_id"):
            out["org"] = self._org(user["org_id"])
        if REQUIRE_STAFF_2FA and user["role"] in ("admin", "superadmin") and not user.get("totp_enabled"):
            out["two_factor_setup_required"] = True
        return out

    def _claim_draft(self, user: dict, anon_token: str | None) -> None:
        if anon_token and user["role"] == "borrower":
            self.db.execute("UPDATE drafts SET user_id=?, anon_token_hash=NULL WHERE anon_token_hash=? "
                            "AND user_id IS NULL AND status='active'", (user["id"], hash_token(anon_token)))

    def register_borrower(self, email: str, name: str, password: str, phone: str | None = None,
                          locale: str = "en", anon_token: str | None = None) -> dict:
        user = self._create_user(email, name, password, "borrower", phone=phone, locale=locale)
        self._claim_draft(user, anon_token)
        self._audit(user, "account.registered", f"user:{user['id']}")
        self._notify(user["id"], "account.welcome", {"name": user["name"]}, email=True)
        return self._issue(user)

    def login(self, email: str, password: str, totp: str | None = None, ip: str | None = None,
              anon_token: str | None = None) -> dict:
        email = (email or "").strip().lower()
        keys = [f"login:{email}"] + ([f"login-ip:{ip}"] if ip else [])
        for k in keys:
            limiter.check(k, LOGIN_LIMIT, LOGIN_WINDOW, "Too many failed logins. Try again in 15 minutes.",
                          code="LOGIN_LOCKED")
        u = self._one("SELECT * FROM users WHERE email=? AND deleted_at IS NULL", (email,))
        if not u or not verify_password(password, u["password_hash"]):
            for k in keys:
                limiter.hit(k)
            raise AuthError("Wrong email or password.", code="CREDENTIALS_INVALID")
        if not u["active"]:
            raise AuthError("This account is deactivated.", code="ACCOUNT_DEACTIVATED")
        if u["org_id"] and not self._org(u["org_id"])["active"]:
            raise AuthError("Your organisation's account is suspended.", code="ORG_SUSPENDED")
        if u["totp_enabled"]:
            if not totp:
                raise AuthError("Enter the 6-digit code from your authenticator app.", code="TOTP_REQUIRED")
            if not verify_totp(u["totp_secret"], totp, at=clock.utcnow().timestamp()):
                for k in keys:
                    limiter.hit(k)
                raise AuthError("That code is not correct.", code="TOTP_INVALID")
        limiter.reset(keys[0])
        if needs_rehash(u["password_hash"]) and self.hash_iterations is None:
            self.db.execute("UPDATE users SET password_hash=? WHERE id=?", (hash_password(password), u["id"]))
        user = public_user(u)
        self._claim_draft(user, anon_token)
        return self._issue(user)

    def refresh(self, refresh_token: str) -> dict:
        row = self._one("SELECT * FROM refresh_tokens WHERE token_hash=?", (hash_token(refresh_token or ""),))
        if not row:
            raise AuthError("Please log in again.", code="REFRESH_INVALID")
        if row["revoked_at"]:
            # A rotated token was used again: assume it was stolen and end the whole session family.
            self.db.execute("UPDATE refresh_tokens SET revoked_at=? WHERE family=? AND revoked_at IS NULL",
                            (db.now(), row["family"]))
            self.db.commit()
            raise AuthError("Please log in again.", code="REFRESH_REUSED")
        if clock.parse(row["expires_at"]) < clock.utcnow():
            raise AuthError("Please log in again.", code="REFRESH_EXPIRED")
        u = self._user_row(row["user_id"])
        if not u["active"] or (u["org_id"] and not self._org(u["org_id"])["active"]):
            raise AuthError("This account is not active.", code="ACCOUNT_DEACTIVATED")
        self.db.execute("UPDATE refresh_tokens SET revoked_at=? WHERE id=?", (db.now(), row["id"]))
        return self._issue(public_user(u), family=row["family"])

    def logout(self, refresh_token: str) -> dict:
        row = self._one("SELECT family FROM refresh_tokens WHERE token_hash=?", (hash_token(refresh_token or ""),))
        if row:
            self.db.execute("UPDATE refresh_tokens SET revoked_at=? WHERE family=? AND revoked_at IS NULL",
                            (db.now(), row["family"]))
        return {"ok": True}

    def _revoke_all(self, user_id: int) -> None:
        self.db.execute("UPDATE refresh_tokens SET revoked_at=? WHERE user_id=? AND revoked_at IS NULL",
                        (db.now(), user_id))

    def user_from_claims(self, claims: dict) -> dict:
        try:
            u = self._user_row(int(claims["sub"]))
        except (NotFound, KeyError, ValueError) as e:
            raise AuthError("Account no longer exists.", code="ACCOUNT_GONE") from e
        if not u["active"]:
            raise AuthError("This account is deactivated.", code="ACCOUNT_DEACTIVATED")
        if u["org_id"] and not self._org(u["org_id"])["active"]:
            raise AuthError("Your organisation's account is suspended.", code="ORG_SUSPENDED")
        return public_user(u)

    def me(self, user: dict) -> dict:
        out = {"user": user}
        if user["org_id"]:
            out["org"] = self._org(user["org_id"])
        if user["role"] == "borrower":
            out["levels"] = self.my_levels(user)
            out["unread_notifications"] = self._scalar(
                "SELECT COUNT(*) FROM notifications WHERE user_id=? AND read_at IS NULL", (user["id"],))
        return out

    def update_profile(self, user: dict, name: str | None = None, locale: str | None = None,
                       notification_prefs: dict | None = None) -> dict:
        if name is not None:
            if len(name.strip()) < 2:
                raise BadRequest("Please enter your name.", code="NAME_REQUIRED", fields={"name": "required"})
            self.db.execute("UPDATE users SET name=? WHERE id=?", (name.strip(), user["id"]))
        if locale is not None:
            if locale not in LOCALES:
                raise BadRequest("Language must be en or bn.", code="LOCALE_INVALID", fields={"locale": "en|bn"})
            self.db.execute("UPDATE users SET locale=? WHERE id=?", (locale, user["id"]))
        if notification_prefs is not None:
            prefs = {"email": bool(notification_prefs.get("email", True)),
                     "sms": bool(notification_prefs.get("sms", False))}
            self.db.execute("UPDATE users SET notification_prefs=? WHERE id=?", (jdump(prefs), user["id"]))
        return self.get_user(user["id"])

    def change_password(self, user: dict, old: str, new: str) -> dict:
        u = self._user_row(user["id"])
        if not verify_password(old, u["password_hash"]):
            raise AuthError("Your current password is not correct.", code="CREDENTIALS_INVALID")
        if len(new) < 8:
            raise BadRequest("Password must be at least 8 characters.", code="PASSWORD_SHORT")
        self.db.execute("UPDATE users SET password_hash=? WHERE id=?", (hash_password(new), user["id"]))
        self._revoke_all(user["id"])
        self._audit(user, "account.password_changed", f"user:{user['id']}")
        return self._issue(self.get_user(user["id"]))

    # ================================================================ password reset
    def forgot_password(self, email: str) -> dict:
        """Always answers the same way, so it cannot be used to discover accounts."""
        email = (email or "").strip().lower()
        limiter.take(f"forgot:{email}", 3, 3600, "Too many reset requests. Try again later.")
        out = {"ok": True}
        u = self._one("SELECT id, name, email FROM users WHERE email=? AND deleted_at IS NULL AND active=1",
                      (email,))
        if u:
            token = new_secret()
            self.db.execute("INSERT INTO password_resets (user_id, token_hash, created_at, expires_at) "
                            "VALUES (?,?,?,?)", (u["id"], hash_token(token), db.now(), self._later(hours=1)))
            link = f"{PUBLIC_URL}/#/reset?token={token}"
            self._emit("notify.email", {"user_id": u["id"], "event": "account.password_reset",
                                        "data": {"link": link}, "transactional": True})
            if may_show_code(u["email"]):
                out["dev_token"] = token
        return out

    def reset_password(self, token: str, password: str) -> dict:
        r = self._one("SELECT * FROM password_resets WHERE token_hash=?", (hash_token(token or ""),))
        if not r or r["used_at"] or clock.parse(r["expires_at"]) < clock.utcnow():
            raise BadRequest("This reset link is invalid or has expired.", code="RESET_INVALID")
        if len(password) < 8:
            raise BadRequest("Password must be at least 8 characters.", code="PASSWORD_SHORT")
        self.db.execute("UPDATE users SET password_hash=? WHERE id=?", (hash_password(password), r["user_id"]))
        self.db.execute("UPDATE password_resets SET used_at=? WHERE id=?", (db.now(), r["id"]))
        self._revoke_all(r["user_id"])
        self._audit({"id": r["user_id"]}, "account.password_reset", f"user:{r['user_id']}")
        return {"ok": True}

    # ================================================================ phone OTP (SMS is mocked)
    def request_otp(self, phone: str, purpose: str = "login", user: dict | None = None) -> dict:
        phone = normalise_phone(phone)
        if purpose not in ("login", "verify"):
            raise BadRequest("purpose must be login or verify.", code="OTP_PURPOSE")
        limiter.take(f"otp:{phone}", OTP_LIMIT, OTP_WINDOW, "Too many codes requested. Try again in an hour.")
        out = {"ok": True, "expires_in": 300}
        if purpose == "login":
            owner = self._one("SELECT id, email FROM users WHERE phone=? AND phone_verified_at IS NOT NULL "
                              "AND active=1 AND deleted_at IS NULL", (phone,))
            if not owner:
                return out            # same answer as success, so numbers cannot be probed
            show = may_show_code(owner["email"])
        else:
            if not user:
                raise AuthError("Please log in.", code="AUTH_REQUIRED")
            other = self._one("SELECT id FROM users WHERE phone=? AND id<>?", (phone, user["id"]))
            if other:
                raise Conflict("This mobile number is already registered.", code="PHONE_TAKEN")
            show = DEV_EXPOSE_CODES            # verifying your own number: the code only proves that number
        code = f"{secrets.randbelow(10**6):06d}"
        self.db.execute("INSERT INTO otp_codes (phone, code_hash, purpose, created_at, expires_at) VALUES (?,?,?,?,?)",
                        (phone, hash_token(f"{phone}:{code}"), purpose, db.now(), self._later(minutes=5)))
        self._emit("notify.sms", {"phone": phone, "event": "otp.code", "data": {"code": code}})
        if show:
            out["dev_code"] = code
        return out

    def _consume_otp(self, phone: str, code: str, purpose: str) -> None:
        r = self._one("""SELECT * FROM otp_codes WHERE phone=? AND purpose=? AND used_at IS NULL
                         ORDER BY id DESC LIMIT 1""", (phone, purpose))
        if not r or clock.parse(r["expires_at"]) < clock.utcnow() or r["attempts"] >= 5:
            raise AuthError("This code has expired. Request a new one.", code="OTP_EXPIRED")
        if hash_token(f"{phone}:{(code or '').strip()}") != r["code_hash"]:
            self.db.execute("UPDATE otp_codes SET attempts=attempts+1 WHERE id=?", (r["id"],))
            self.db.commit()
            raise AuthError("That code is not correct.", code="OTP_INVALID")
        self.db.execute("UPDATE otp_codes SET used_at=? WHERE id=?", (db.now(), r["id"]))

    def verify_otp(self, phone: str, code: str, purpose: str = "login", user: dict | None = None,
                   anon_token: str | None = None) -> dict:
        phone = normalise_phone(phone)
        self._consume_otp(phone, code, purpose)
        if purpose == "verify":
            if not user:
                raise AuthError("Please log in.", code="AUTH_REQUIRED")
            self.db.execute("UPDATE users SET phone=?, phone_verified_at=? WHERE id=?", (phone, db.now(), user["id"]))
            self._audit(user, "account.phone_verified", f"user:{user['id']}")
            return {"user": self.get_user(user["id"])}
        u = self._one("SELECT * FROM users WHERE phone=? AND phone_verified_at IS NOT NULL AND deleted_at IS NULL",
                      (phone,))
        if not u or not u["active"]:
            raise AuthError("No active account uses this number.", code="CREDENTIALS_INVALID")
        if u["role"] in STAFF:
            raise AuthError("Staff accounts sign in with email and password.", code="STAFF_EMAIL_ONLY")
        user = public_user(u)
        self._claim_draft(user, anon_token)
        return self._issue(user)

    # ================================================================ two-factor (TOTP)
    def totp_setup(self, user: dict) -> dict:
        if user["role"] not in STAFF:
            raise BadRequest("Two-factor login is for staff accounts.", code="TOTP_STAFF_ONLY")
        secret = new_totp_secret()
        self.db.execute("UPDATE users SET totp_secret=?, totp_enabled=0 WHERE id=?", (secret, user["id"]))
        return {"secret": secret, "otpauth_uri": totp_uri(secret, user["email"])}

    def totp_enable(self, user: dict, code: str) -> dict:
        u = self._user_row(user["id"])
        if not u["totp_secret"] or not verify_totp(u["totp_secret"], code, at=clock.utcnow().timestamp()):
            raise BadRequest("That code is not correct.", code="TOTP_INVALID")
        self.db.execute("UPDATE users SET totp_enabled=1 WHERE id=?", (user["id"],))
        self._audit(user, "account.2fa_enabled", f"user:{user['id']}")
        return self.get_user(user["id"])

    def totp_disable(self, user: dict, code: str) -> dict:
        u = self._user_row(user["id"])
        if not u["totp_enabled"] or not verify_totp(u["totp_secret"], code, at=clock.utcnow().timestamp()):
            raise BadRequest("That code is not correct.", code="TOTP_INVALID")
        self.db.execute("UPDATE users SET totp_enabled=0, totp_secret=NULL WHERE id=?", (user["id"],))
        self._audit(user, "account.2fa_disabled", f"user:{user['id']}")
        return self.get_user(user["id"])
