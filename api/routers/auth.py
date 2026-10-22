"""Accounts and sessions."""
from fastapi import APIRouter, Depends, Request

from ..deps import client_ip, current_user, platform, run
from ..schemas import (ChangePasswordIn, DeleteAccountIn, ForgotIn, Login, OtpRequest, OtpVerify, ProfileIn,
                       RefreshIn, Register, ResetIn, TotpCode)

router = APIRouter(prefix="/auth", tags=["auth"])
me_router = APIRouter(tags=["auth"])


@router.post("/register")
def register(body: Register):
    return run(platform.register_borrower, body.email, body.name, body.password, body.phone, body.locale,
               body.anon_token)


@router.post("/login")
def login(body: Login, request: Request):
    """Returns a short-lived access token and a refresh token. `token` is kept for v2 apps."""
    return run(platform.login, body.email, body.password, body.totp, client_ip(request), body.anon_token)


@router.post("/refresh")
def refresh(body: RefreshIn):
    return run(platform.refresh, body.refresh_token)


@router.post("/logout")
def logout(body: RefreshIn):
    return run(platform.logout, body.refresh_token)


@router.post("/password/forgot")
def forgot(body: ForgotIn):
    return run(platform.forgot_password, body.email)


@router.post("/password/reset")
def reset(body: ResetIn):
    return run(platform.reset_password, body.token, body.password)


@router.post("/otp/request")
def otp_request(body: OtpRequest):
    """Send a sign-in code to a verified mobile number (SMS is mocked). To verify a number use /me/phone."""
    return run(platform.request_otp, body.phone, "login")


@router.post("/otp/verify")
def otp_verify(body: OtpVerify):
    return run(platform.verify_otp, body.phone, body.code, "login", None, body.anon_token)


@me_router.get("/me")
def me(user: dict = Depends(current_user)):
    return run(platform.me, user)


@me_router.put("/me")
def update_me(body: ProfileIn, user: dict = Depends(current_user)):
    return run(platform.update_profile, user, body.name, body.locale, body.notification_prefs)


@me_router.post("/me/password")
def change_password(body: ChangePasswordIn, user: dict = Depends(current_user)):
    return run(platform.change_password, user, body.old_password, body.new_password)


@me_router.post("/me/phone/request")
def phone_request(body: OtpRequest, user: dict = Depends(current_user)):
    """Send a code to verify (or change) the mobile number on this account."""
    return run(platform.request_otp, body.phone, "verify", user)


@me_router.post("/me/phone/verify")
def phone_verify(body: OtpVerify, user: dict = Depends(current_user)):
    return run(platform.verify_otp, body.phone, body.code, "verify", user)


@me_router.post("/me/2fa/setup")
def totp_setup(user: dict = Depends(current_user)):
    return run(platform.totp_setup, user)


@me_router.post("/me/2fa/enable")
def totp_enable(body: TotpCode, user: dict = Depends(current_user)):
    return run(platform.totp_enable, user, body.code)


@me_router.post("/me/2fa/disable")
def totp_disable(body: TotpCode, user: dict = Depends(current_user)):
    return run(platform.totp_disable, user, body.code)


@me_router.get("/me/consents", tags=["privacy"])
def consents(user: dict = Depends(current_user)):
    return run(platform.list_consents, user)


@me_router.post("/me/consents/{consent_id}/revoke", tags=["privacy"])
def revoke_consent(consent_id: int, user: dict = Depends(current_user)):
    return run(platform.revoke_consent, user, consent_id)


@me_router.get("/me/export", tags=["privacy"])
def export(user: dict = Depends(current_user)):
    """Everything LenDen stores about you, as JSON."""
    return run(platform.export_my_data, user)


@me_router.post("/me/delete", tags=["privacy"])
def delete_account(body: DeleteAccountIn, user: dict = Depends(current_user)):
    from lenden.security import verify_password

    def go():
        u = platform._user_row(user["id"])
        return platform.delete_account(user, verify_password(body.password, u["password_hash"]))
    return run(go)


@me_router.get("/notifications", tags=["notifications"])
def notifications(limit: int = 30, cursor: str | None = None, unread_only: bool = False,
                  user: dict = Depends(current_user)):
    return run(platform.list_notifications, user, limit, cursor, unread_only)


@me_router.post("/notifications/read-all", tags=["notifications"])
def read_all(user: dict = Depends(current_user)):
    return run(platform.mark_all_read, user)


@me_router.post("/notifications/{notification_id}/read", tags=["notifications"])
def read_one(notification_id: int, user: dict = Depends(current_user)):
    return run(platform.mark_read, user, notification_id)
