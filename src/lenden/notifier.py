"""Email and SMS delivery, plus the Bangla/English message templates.

The outbox dispatcher (jobs.py) calls `deliver()` for each pending event. Without configuration
messages are written to the log (handy in development and on the free tier).
"""
from __future__ import annotations

import json
import logging
import smtplib
import urllib.request
from email.message import EmailMessage

from .settings import MAIL_FROM, RESEND_API_KEY, SMTP_HOST, SMTP_PASSWORD, SMTP_PORT, SMTP_USER

log = logging.getLogger("lenden.notify")

TEMPLATES = {
    "account.welcome": {
        "en": ("Welcome to LenDen", "Hi {name}, your account is ready. Check your loan chances any time."),
        "bn": ("লেনদেন-এ স্বাগতম", "{name}, আপনার অ্যাকাউন্ট তৈরি হয়েছে। যেকোনো সময় আপনার ঋণের সম্ভাবনা দেখুন।"),
    },
    "account.password_reset": {
        "en": ("Reset your LenDen password", "Open this link within one hour to choose a new password: {link}"),
        "bn": ("পাসওয়ার্ড রিসেট করুন", "এক ঘণ্টার মধ্যে এই লিংকে গিয়ে নতুন পাসওয়ার্ড দিন: {link}"),
    },
    "application.submitted": {
        "en": ("Application sent to {lender}", "Your application #{application_id} was sent to {lender}. We'll tell you when it moves."),
        "bn": ("{lender}-এ আবেদন পাঠানো হয়েছে", "আপনার আবেদন #{application_id} {lender}-এ পাঠানো হয়েছে। অগ্রগতি হলে জানাব।"),
    },
    "application.approved": {
        "en": ("Your loan was approved", "{lender} approved application #{application_id}. Open LenDen to see your repayment schedule."),
        "bn": ("আপনার ঋণ অনুমোদিত হয়েছে", "{lender} আবেদন #{application_id} অনুমোদন করেছে। কিস্তির সময়সূচি দেখতে লেনদেন খুলুন।"),
    },
    "application.rejected": {
        "en": ("Update on your application", "{lender} could not approve application #{application_id} this time. Open LenDen to see why and what would help."),
        "bn": ("আপনার আবেদনের আপডেট", "{lender} এবার আবেদন #{application_id} অনুমোদন করতে পারেনি। কারণ ও করণীয় দেখতে লেনদেন খুলুন।"),
    },
    "documents.requested": {
        "en": ("Documents needed", "Please upload the requested documents for application #{application_id} within {due_days} days."),
        "bn": ("কাগজপত্র প্রয়োজন", "আবেদন #{application_id}-এর জন্য {due_days} দিনের মধ্যে কাগজপত্র আপলোড করুন।"),
    },
    "documents.reminder": {
        "en": ("Reminder: documents needed", "Application #{application_id} is waiting for your documents."),
        "bn": ("মনে করিয়ে দিচ্ছি: কাগজপত্র", "আবেদন #{application_id} আপনার কাগজপত্রের অপেক্ষায় আছে।"),
    },
    "documents.expired": {
        "en": ("Document request expired", "The document request for application #{application_id} has expired."),
        "bn": ("কাগজপত্রের সময় শেষ", "আবেদন #{application_id}-এর কাগজপত্র জমার সময় শেষ হয়েছে।"),
    },
    "draft.reminder": {
        "en": ("Finish your loan check", "You're a few steps away from seeing your offers. Pick up where you left off."),
        "bn": ("ঋণ যাচাই শেষ করুন", "অফার দেখতে আর কয়েক ধাপ বাকি। যেখানে থেমেছিলেন সেখান থেকে শুরু করুন।"),
    },
    "repayment.due_soon": {
        "en": ("Instalment due soon", "Instalment {seq} of {amount} is due on {due_date}."),
        "bn": ("কিস্তির সময় ঘনিয়ে এসেছে", "{due_date} তারিখে {seq} নম্বর কিস্তি {amount} পরিশোধ করতে হবে।"),
    },
    "repayment.late": {
        "en": ("Instalment overdue", "Instalment {seq} ({amount}) is {days} days late."),
        "bn": ("কিস্তি বকেয়া", "{seq} নম্বর কিস্তি ({amount}) {days} দিন দেরি হয়েছে।"),
    },
    "repayment.missed": {
        "en": ("Missed instalment", "Instalment {seq} was missed. Your credit level is now {level}."),
        "bn": ("কিস্তি পরিশোধ হয়নি", "{seq} নম্বর কিস্তি পরিশোধ হয়নি। আপনার ক্রেডিট লেভেল এখন {level}।"),
    },
    "loan.closed": {
        "en": ("Loan repaid", "Well done! Your loan with {lender} is fully repaid. Credit level: {level_after}."),
        "bn": ("ঋণ পরিশোধ সম্পন্ন", "অভিনন্দন! {lender}-এর ঋণ পুরোপুরি পরিশোধ হয়েছে। ক্রেডিট লেভেল: {level_after}।"),
    },
    "otp.code": {
        "en": ("", "Your LenDen code is {code}. It expires in 5 minutes."),
        "bn": ("", "আপনার লেনদেন কোড {code}। ৫ মিনিটে মেয়াদ শেষ হবে।"),
    },
}


class _Safe(dict):
    def __missing__(self, key):
        return "{" + key + "}"


def render(event: str, locale: str, data: dict) -> tuple[str, str]:
    t = TEMPLATES.get(event, {})
    subject, body = t.get(locale) or t.get("en") or (event, json.dumps(data))
    return subject.format_map(_Safe(data)), body.format_map(_Safe(data))


def send_email(to: str, subject: str, body: str) -> str:
    if RESEND_API_KEY:
        req = urllib.request.Request("https://api.resend.com/emails", method="POST",
                                     data=json.dumps({"from": MAIL_FROM, "to": [to], "subject": subject,
                                                      "text": body}).encode())
        req.add_header("Authorization", f"Bearer {RESEND_API_KEY}")
        req.add_header("Content-Type", "application/json")
        with urllib.request.urlopen(req, timeout=15):
            return "resend"
    if SMTP_HOST:
        msg = EmailMessage()
        msg["From"], msg["To"], msg["Subject"] = MAIL_FROM, to, subject
        msg.set_content(body)
        with smtplib.SMTP(SMTP_HOST, SMTP_PORT, timeout=15) as s:
            s.starttls()
            if SMTP_USER:
                s.login(SMTP_USER, SMTP_PASSWORD)
            s.send_message(msg)
        return "smtp"
    log.info("email (not sent, no provider configured) to=%s subject=%r", _mask(to), subject)
    return "log"


def send_sms(phone: str, body: str) -> str:
    """SMS is an interface only: plug a provider in here. The code itself is never logged."""
    log.info("sms (mocked) to=%s chars=%d", _mask(phone), len(body))
    return "mock"


def _mask(v: str) -> str:
    return (v[:3] + "***" + v[-2:]) if v and len(v) > 6 else "***"
