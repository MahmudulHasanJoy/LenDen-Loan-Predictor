"""Borrower rights: view and revoke consents, export my data, delete my account."""
from __future__ import annotations

from .. import db
from ..errors import BadRequest, NotFound
from ..security import hash_password, new_secret, require
from .base import Base, py

OPEN_SQL = "('submitted','in_review','needs_docs')"


class Privacy(Base):
    def list_consents(self, user: dict) -> list[dict]:
        return self._q("""SELECT c.id, c.org_id, o.name AS lender, c.purpose, c.text_version, c.granted_at, c.revoked_at
                          FROM consents c LEFT JOIN orgs o ON o.id=c.org_id WHERE c.user_id=? ORDER BY c.id DESC""",
                       (user["id"],))

    def revoke_consent(self, user: dict, consent_id: int) -> list[dict]:
        c = self._one("SELECT * FROM consents WHERE id=? AND user_id=?", (consent_id, user["id"]))
        if not c:
            raise NotFound("Consent not found.", code="CONSENT_NOT_FOUND")
        if c["revoked_at"]:
            return self.list_consents(user)
        self.db.execute("UPDATE consents SET revoked_at=? WHERE id=?", (db.now(), consent_id))
        # Without consent the lender may no longer process an open application.
        for a in self._q(f"SELECT * FROM applications WHERE borrower_id=? AND org_id=? AND status IN {OPEN_SQL}",
                         (user["id"], c["org_id"])):
            self._set_status(a, "withdrawn", user, "Consent revoked")
        self._audit(user, "consent.revoked", f"consent:{consent_id}", org_id=c["org_id"])
        return self.list_consents(user)

    def export_my_data(self, user: dict) -> dict:
        uid = user["id"]
        apps = self._q("SELECT * FROM applications WHERE borrower_id=? ORDER BY id", (uid,))
        for a in apps:
            for k in ("risk_score", "threshold", "recommendation", "model_version", "model_version_id", "assigned_to"):
                a.pop(k, None)
        loans = self._q("SELECT * FROM loans WHERE borrower_id=? ORDER BY id", (uid,))
        for loan in loans:
            loan["repayments"] = self._q("SELECT seq, due_date, amount_due, amount_paid, paid_at, status FROM repayments "
                                         "WHERE loan_id=? ORDER BY seq", (loan["id"],))
        return py({
            "user": self.get_user(uid),
            "drafts": self._q("SELECT id, step, inputs, demographics, status, created_at, updated_at FROM drafts "
                              "WHERE user_id=? ORDER BY id", (uid,)),
            "applications": apps,
            "application_events": self._q("""SELECT e.* FROM application_events e JOIN applications a
                                             ON a.id=e.application_id WHERE a.borrower_id=? ORDER BY e.id""", (uid,)),
            "documents": self._q("""SELECT d.id, d.application_id, d.kind, d.filename, d.size, d.uploaded_at FROM documents d
                                    JOIN applications a ON a.id=d.application_id WHERE a.borrower_id=?""", (uid,)),
            "loans": loans,
            "credit_levels": self._q("SELECT org_id, level, loans_repaid, updated_at FROM borrower_levels "
                                     "WHERE borrower_id=?", (uid,)),
            "consents": self.list_consents(user),
            "notifications": self._q("SELECT event, payload, created_at, read_at FROM notifications WHERE user_id=? "
                                     "ORDER BY id", (uid,)),
            "exported_at": db.now(),
        })

    def delete_account(self, user: dict, password_ok: bool) -> dict:
        require(user, "borrower")
        if not password_ok:
            raise BadRequest("Confirm with your password.", code="CREDENTIALS_INVALID")
        uid = user["id"]
        if self._scalar("SELECT COUNT(*) FROM loans WHERE borrower_id=? AND status='active'", (uid,)):
            raise BadRequest("Repay your active loans before deleting your account.", code="ACTIVE_LOANS")
        for a in self._q(f"SELECT * FROM applications WHERE borrower_id=? AND status IN {OPEN_SQL}", (uid,)):
            self._set_status(a, "withdrawn", user, "Account deleted")
        now = db.now()
        self.db.execute("UPDATE consents SET revoked_at=? WHERE user_id=? AND revoked_at IS NULL", (now, uid))
        self.db.execute("UPDATE drafts SET status='expired', inputs='{}', demographics='{}' WHERE user_id=?", (uid,))
        self.db.execute("DELETE FROM notifications WHERE user_id=?", (uid,))
        self.db.execute("UPDATE applications SET demographics='{}' WHERE borrower_id=?", (uid,))
        self._revoke_all(uid)
        # Decisions, loans and audit rows stay (the lender may be required to keep them), but nothing
        # in them identifies the person any more.
        self.db.execute("""UPDATE users SET email=?, name='Deleted user', phone=NULL, phone_verified_at=NULL,
                           password_hash=?, active=0, deleted_at=?, totp_secret=NULL WHERE id=?""",
                        (f"deleted-{uid}@deleted.lenden.invalid", hash_password(new_secret(), 1000), now, uid))
        for d in self._q("""SELECT d.id, d.storage_path FROM documents d JOIN applications a ON a.id=d.application_id
                            WHERE a.borrower_id=? AND a.status IN ('rejected','withdrawn') AND d.deleted_at IS NULL""",
                         (uid,)):
            self.storage.delete(d["storage_path"])
            self.db.execute("UPDATE documents SET deleted_at=? WHERE id=?", (now, d["id"]))
        self._audit({"id": uid}, "account.deleted", f"user:{uid}")
        return {"ok": True}
