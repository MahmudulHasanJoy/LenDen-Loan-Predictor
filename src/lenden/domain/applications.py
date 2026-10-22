"""Applications: apply (from an offer), status timeline, officer queue, claim, decisions, documents."""
from __future__ import annotations

from credit_risk.counterfactual import next_step
from credit_risk.odds import odds_for
from credit_risk.offers import ladder_cap
from credit_risk.readiness import emi, light_for
from credit_risk.reasons import CATALOG, public_reasons

from .. import clock, db
from ..errors import BadRequest, Conflict, Forbidden, NotFound
from ..security import require, sign_path, verify_signed_path
from ..settings import DECISIONS, MAX_UPLOAD_BYTES, OPEN_STATUSES, UPLOAD_TYPES
from ..storage import new_key
from .base import Base, jdump, py

CONSENT_VERSION = "share-v1"
DOC_KINDS = {"bank_statements_3m": "Bank statements (last 3 months)", "salary_slip": "Salary slip",
             "national_id": "National ID card", "trade_license": "Trade licence", "utility_bill": "Utility bill",
             "other": "Other document"}
DOC_DUE_DAYS = 7
OPEN_SQL = "('submitted','in_review','needs_docs')"


class Applications(Base):
    lean = False        # True while seeding: skip explanations nobody will read
    # ================================================================ borrower: apply
    def apply(self, borrower: dict, org_id: int | None = None, inputs: dict | None = None, consent: bool = False,
              offer_id: int | None = None, demographics: dict | None = None) -> dict:
        require(borrower, "borrower")
        if not consent:
            raise BadRequest("You must agree to share your details with the lender.", code="CONSENT_REQUIRED")
        draft_id, demo, offer = None, self._check_demographics(demographics), None
        if offer_id is not None:
            offer = self._one("SELECT * FROM offers WHERE id=?", (offer_id,))
            draft = self._one("SELECT * FROM drafts WHERE id=?", (offer["draft_id"],)) if offer else None
            if not offer or not draft or draft["user_id"] != borrower["id"]:
                raise NotFound("Offer not found.", code="OFFER_NOT_FOUND")
            if offer["status"] != "estimate" or clock.parse(offer["expires_at"]) < clock.utcnow():
                raise Conflict("This offer has expired. Check your offers again.", code="OFFER_EXPIRED")
            org_id, draft_id = offer["org_id"], draft["id"]
            full, _ = self.complete_inputs(draft["inputs"])
            inputs = {**full, "LoanAmount": offer["best_amount"], "LoanTerm": offer["best_term"],
                      "InterestRate": offer["best_rate"]}
            demo = {**draft["demographics"], **demo}
        if org_id is None or inputs is None:
            raise BadRequest("Choose an offer (or a lender and your details).", code="OFFER_REQUIRED")
        org = self._org(org_id)
        if not org["active"]:
            raise BadRequest("This lender is not accepting applications.", code="LENDER_INACTIVE")
        if self._one(f"SELECT id FROM applications WHERE borrower_id=? AND org_id=? AND status IN {OPEN_SQL}",
                     (borrower["id"], org_id)):
            raise Conflict("You already have an open application with this lender.", code="APPLICATION_OPEN")

        settings = self._settings(org_id)
        clean = {k: py(v) for k, v in self.risk.validate(inputs).iloc[0].to_dict().items()}
        level = self._level(borrower["id"], org_id)
        if self.flag("credit_ladder"):
            cap = ladder_cap(settings["offer_rules"], level)
            if clean["LoanAmount"] > cap + 0.5:
                raise BadRequest(f"Your credit level allows up to {cap:,.0f} with this lender.", code="LADDER_LIMIT",
                                 fields={"ladder_cap": round(cap, 2), "ladder_level": level})
        threshold = self.recommendation_threshold(settings)
        pred = self.risk.predict(clean, cost_ratio=settings["cost_ratio"])
        odds = odds_for(pred["risk_score"], threshold)
        reasons = public_reasons(pred["reasons"])
        ts = db.now()
        app_id = self.db.insert(
            """INSERT INTO applications (org_id, borrower_id, inputs, loan_amount, loan_purpose, risk_score,
               default_probability, light, recommendation, threshold, reasons, model_version, consent_at,
               created_at, updated_at, draft_id, offer_id, model_version_id, odds, demographics, sla_due_at, terms)
               VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
            (org_id, borrower["id"], jdump(clean), clean["LoanAmount"], clean["LoanPurpose"], pred["risk_score"],
             pred["default_probability"], light_for(pred["default_probability"]),
             "REVIEW" if pred["risk_score"] >= threshold else "APPROVE", threshold, jdump(reasons),
             self.model_version_label, ts, ts, ts, draft_id, offer_id, self.model_version_id, odds, jdump(demo),
             self._later(hours=settings["sla_hours"]),
             jdump({"amount": clean["LoanAmount"], "term": clean["LoanTerm"], "rate": clean["InterestRate"]})))
        self.db.execute("INSERT INTO consents (user_id, org_id, purpose, text_version, granted_at) VALUES (?,?,?,?,?)",
                        (borrower["id"], org_id, "share_application", CONSENT_VERSION, ts))
        if draft_id:
            self.db.execute("UPDATE drafts SET status='submitted', updated_at=? WHERE id=?", (ts, draft_id))
            self.db.execute("UPDATE offers SET status='used' WHERE id=?", (offer_id,))
        self._event(app_id, None, "submitted", borrower)
        self._shadow_score(app_id, clean, threshold)
        self._audit(borrower, "application.submitted", f"application:{app_id}", org_id=org_id)
        self._notify(borrower["id"], "application.submitted", {"application_id": app_id, "lender": org["name"]})
        return self.borrower_application(borrower, app_id)

    # ================================================================ borrower: track
    def my_applications(self, borrower: dict) -> list[dict]:
        require(borrower, "borrower")
        apps = self._q("""SELECT a.*, o.name AS lender FROM applications a JOIN orgs o ON o.id=a.org_id
                          WHERE a.borrower_id=? ORDER BY a.created_at DESC, a.id DESC""", (borrower["id"],))
        return [self._borrower_view(a) for a in apps]

    def _borrower_view(self, a: dict) -> dict:
        lender = a.get("lender") or self._org(a["org_id"])["name"]
        return {"id": a["id"], "lender": lender, "org_id": a["org_id"], "loan_amount": a["loan_amount"],
                "loan_purpose": a["loan_purpose"], "light": a["light"], "odds": a.get("odds"), "status": a["status"],
                "decision_note": a["decision_note"], "reason_codes": a.get("reason_codes") or [],
                "terms": a.get("terms"), "created_at": a["created_at"], "decided_at": a["decided_at"]}

    def _timeline(self, app_id: int) -> list[dict]:
        return self._q("""SELECT e.from_status, e.to_status, e.note, e.created_at, u.name AS actor_name, u.role AS actor_role
                          FROM application_events e LEFT JOIN users u ON u.id=e.actor_id
                          WHERE e.application_id=? ORDER BY e.id""", (app_id,))

    def _doc_requests(self, app_id: int) -> list[dict]:
        reqs = self._q("SELECT * FROM document_requests WHERE application_id=? ORDER BY id DESC", (app_id,))
        docs = self._q("SELECT id, request_id, kind, filename, content_type, size, uploaded_at FROM documents "
                       "WHERE application_id=? AND deleted_at IS NULL ORDER BY id", (app_id,))
        for r in reqs:
            have = {d["kind"] for d in docs if d["request_id"] == r["id"]}
            r["items"] = [{"kind": k, "label": DOC_KINDS.get(k, k), "uploaded": k in have} for k in r["items"]]
        return reqs

    def _documents(self, app_id: int) -> list[dict]:
        return self._q("SELECT id, request_id, kind, filename, content_type, size, uploaded_at FROM documents "
                       "WHERE application_id=? AND deleted_at IS NULL ORDER BY id", (app_id,))

    def borrower_application(self, borrower: dict, app_id: int) -> dict:
        require(borrower, "borrower")
        a = self._get_app(app_id)
        if a["borrower_id"] != borrower["id"]:
            raise NotFound("Application not found.", code="APPLICATION_NOT_FOUND")
        out = self._borrower_view(a)
        out["timeline"] = self._timeline(app_id)
        out["document_requests"] = self._doc_requests(app_id)
        out["documents"] = self._documents(app_id)
        loan = self._one("SELECT id FROM loans WHERE application_id=?", (app_id,))
        out["loan_id"] = loan["id"] if loan else None
        if self.lean:
            out["next_step"] = None
        elif a["status"] == "rejected" or (a["status"] in OPEN_STATUSES and a.get("odds") in ("fair", "low")):
            try:
                out["next_step"] = next_step(self.risk, a["inputs"], a["threshold"])
            except Exception:                    # older applications may use fields a newer model lacks
                out["next_step"] = None
        else:
            out["next_step"] = None
        return py(out)

    def withdraw(self, borrower: dict, app_id: int) -> dict:
        require(borrower, "borrower")
        a = self._get_app(app_id)
        if a["borrower_id"] != borrower["id"]:
            raise NotFound("Application not found.", code="APPLICATION_NOT_FOUND")
        if a["status"] not in OPEN_STATUSES:
            raise Conflict("Only open applications can be withdrawn.", code="APPLICATION_CLOSED")
        self._set_status(a, "withdrawn", borrower, "Withdrawn by borrower")
        self.db.execute("UPDATE document_requests SET status='cancelled' WHERE application_id=? AND status='open'",
                        (app_id,))
        self._audit(borrower, "application.withdrawn", f"application:{app_id}", org_id=a["org_id"])
        return self.borrower_application(borrower, app_id)

    # ================================================================ officer: queue and detail
    def _get_app(self, app_id: int) -> dict:
        a = self._one("SELECT * FROM applications WHERE id=?", (app_id,))
        if not a:
            raise NotFound("Application not found.", code="APPLICATION_NOT_FOUND")
        return a

    def _set_status(self, a: dict, status: str, actor: dict | None, note: str | None = None, **cols) -> None:
        sets = ["status=?", "updated_at=?"] + [f"{k}=?" for k in cols]
        self.db.execute(f"UPDATE applications SET {', '.join(sets)} WHERE id=?",
                        [status, db.now(), *cols.values(), a["id"]])
        self._event(a["id"], a["status"], status, actor, note)

    def list_applications(self, user: dict, status: str | None = None, light: str | None = None,
                          sort: str = "risk", limit: int = 100, offset: int = 0, assigned: str | None = None,
                          odds: str | None = None, cursor: str | None = None) -> dict:
        require(user, "officer", "admin")
        if cursor:
            try:
                offset = max(0, int(cursor))
            except ValueError:
                raise BadRequest("Invalid cursor.", code="CURSOR_INVALID") from None
        where, args = ["a.org_id=?"], [user["org_id"]]
        if status == "pending":
            where.append(f"a.status IN {OPEN_SQL}")
        elif status:
            where.append("a.status=?"); args.append(status)
        if light:
            where.append("a.light=?"); args.append(light)
        if odds:
            where.append("a.odds=?"); args.append(odds)
        if assigned == "me":
            where.append("a.assigned_to=?"); args.append(user["id"])
        elif assigned == "unassigned":
            where.append("a.assigned_to IS NULL")
        order = {"risk": "a.risk_score DESC, a.id", "newest": "a.created_at DESC, a.id DESC",
                 "oldest": "a.created_at ASC, a.id ASC", "amount": "a.loan_amount DESC, a.id",
                 "sla": "a.sla_due_at ASC, a.id"}.get(sort)
        if order is None:
            raise BadRequest("sort must be one of risk, newest, oldest, amount, sla.", code="SORT_INVALID")
        w = " AND ".join(where)
        total = self._scalar(f"SELECT COUNT(*) FROM applications a WHERE {w}", args)
        limit = min(limit, 500)
        items = self._q(f"""SELECT a.id, a.loan_amount, a.loan_purpose, a.risk_score, a.default_probability, a.light,
                                   a.odds, a.recommendation, a.status, a.created_at, a.sla_due_at, a.assigned_to,
                                   u.name AS borrower_name, s.name AS assigned_name
                            FROM applications a JOIN users u ON u.id=a.borrower_id
                            LEFT JOIN users s ON s.id=a.assigned_to
                            WHERE {w} ORDER BY {order} LIMIT ? OFFSET ?""", args + [limit, offset])
        now = clock.utcnow()
        for it in items:
            it["sla_breached"] = bool(it["status"] in OPEN_STATUSES and it["sla_due_at"]
                                      and clock.parse(it["sla_due_at"]) < now)
        nxt = offset + len(items)
        return {"total": total, "items": items, "next_cursor": str(nxt) if nxt < total else None}

    def get_application(self, user: dict, app_id: int) -> dict:
        require(user, "officer", "admin")
        a = self._get_app(app_id)
        if a["org_id"] != user["org_id"]:
            raise NotFound("Application not found.", code="APPLICATION_NOT_FOUND")   # never reveal other tenants
        b = self.get_user(a["borrower_id"])
        names = {r["id"]: r["name"] for r in self._q(
            "SELECT id, name FROM users WHERE id IN (?, ?)", (a["decided_by"] or 0, a["assigned_to"] or 0))}
        a.update({"borrower": {"id": b["id"], "name": b["name"], "email": b["email"],
                               "phone_verified": b["phone_verified"]},
                  "decided_by_name": names.get(a["decided_by"]), "assigned_name": names.get(a["assigned_to"]),
                  "timeline": self._timeline(app_id), "document_requests": self._doc_requests(app_id),
                  "documents": self._documents(app_id), "ladder_level": self._level(a["borrower_id"], a["org_id"]),
                  "reason_catalog": CATALOG})
        a["reasons"] = public_reasons(a["reasons"]) if a["reasons"] and "code" not in a["reasons"][0] else a["reasons"]
        try:
            a["next_step"] = None if self.lean else next_step(self.risk, a["inputs"], a["threshold"])
        except Exception:
            a["next_step"] = None
        a["similar"] = self._q("""SELECT id, risk_score, status, loan_amount FROM applications
                                  WHERE org_id=? AND id<>? AND status IN ('approved','rejected')
                                  ORDER BY ABS(risk_score - ?) LIMIT 5""", (a["org_id"], app_id, a["risk_score"]))
        a["shadow"] = self._one("""SELECT s.probability, s.odds, m.version FROM shadow_scores s
                                   JOIN model_versions m ON m.id=s.model_version_id
                                   WHERE s.application_id=? ORDER BY s.id DESC LIMIT 1""", (app_id,))
        loan = self._one("SELECT id, status FROM loans WHERE application_id=?", (app_id,))
        a["loan"] = loan
        a["demographics"] = None          # collected for fairness monitoring only; never shown to officers
        return py(a)

    def claim(self, user: dict, app_id: int) -> dict:
        require(user, "officer", "admin")
        a = self.get_application(user, app_id)
        if a["status"] not in OPEN_STATUSES:
            raise Conflict("This application has already been decided.", code="APPLICATION_CLOSED")
        if a["assigned_to"] and a["assigned_to"] != user["id"]:
            raise Conflict(f"{a['assigned_name']} is already reviewing this application.", code="ALREADY_CLAIMED")
        if a["status"] == "submitted":
            self._set_status(a, "in_review", user, assigned_to=user["id"])
        else:
            self.db.execute("UPDATE applications SET assigned_to=?, updated_at=? WHERE id=?", (user["id"], db.now(), app_id))
        self._audit(user, "application.claimed", f"application:{app_id}")
        return self.get_application(user, app_id)

    def release(self, user: dict, app_id: int) -> dict:
        require(user, "officer", "admin")
        a = self.get_application(user, app_id)
        if a["assigned_to"] not in (None, user["id"]) and user["role"] != "admin":
            raise Forbidden("Only the assigned officer or an admin can release this.", code="NOT_ASSIGNEE")
        self.db.execute("UPDATE applications SET assigned_to=NULL, updated_at=? WHERE id=?", (db.now(), app_id))
        return self.get_application(user, app_id)

    # ================================================================ officer: decide
    def decide(self, user: dict, app_id: int, decision: str, note: str = "", reason_codes: list[str] | None = None,
               terms: dict | None = None, documents: list[str] | None = None) -> dict:
        require(user, "officer", "admin")
        if decision not in DECISIONS:
            raise BadRequest(f"decision must be one of {', '.join(DECISIONS)}.", code="DECISION_INVALID")
        a = self.get_application(user, app_id)
        if a["status"] not in OPEN_STATUSES:
            raise Conflict("This application has already been decided.", code="APPLICATION_CLOSED")
        if a["assigned_to"] and a["assigned_to"] != user["id"] and user["role"] != "admin":
            raise Conflict(f"{a['assigned_name']} is reviewing this application.", code="ALREADY_CLAIMED")
        note = (note or "").strip()
        borrower_id, org = a["borrower_id"], self._org(a["org_id"])

        if decision == "needs_docs":
            items = documents or ["bank_statements_3m"]
            self._create_doc_request(a, user, items, note)
            self._set_status(a, "needs_docs", user, note or None, assigned_to=a["assigned_to"] or user["id"])
            self._audit(user, "application.needs_docs", f"application:{app_id}", {"items": items})
            return self.get_application(user, app_id)

        codes = [c for c in (reason_codes or []) if c]
        if decision == "rejected":
            if not codes and not note:
                raise BadRequest("Choose at least one reason for the borrower.", code="REASONS_REQUIRED",
                                 fields={"reason_codes": "required"})
            unknown = [c for c in codes if c not in CATALOG]
            if unknown:
                raise BadRequest("Unknown reason code.", code="REASON_UNKNOWN", fields={"reason_codes": unknown})
            codes = codes or ["OTHER"]
            self._set_status(a, "rejected", user, note or None, decision_note=note or None, decided_at=db.now(),
                             decided_by=user["id"], reason_codes=jdump(codes))
            self._notify(borrower_id, "application.rejected", {"application_id": app_id, "lender": org["name"],
                                                               "reasons": codes})
        else:
            t = self._clean_terms(a, terms)
            self._set_status(a, "approved", user, note or None, decision_note=note or None, decided_at=db.now(),
                             decided_by=user["id"], terms=jdump(t))
            loan_id = self._create_loan(self._get_app(app_id), t)
            self._notify(borrower_id, "application.approved", {"application_id": app_id, "lender": org["name"],
                                                               "loan_id": loan_id, **t})
        self.db.execute("UPDATE document_requests SET status='cancelled' WHERE application_id=? AND status='open'",
                        (app_id,))
        override = (a["recommendation"] == "APPROVE") != (decision == "approved")
        self._audit(user, f"application.{decision}", f"application:{app_id}",
                    {"recommendation": a["recommendation"], "odds": a["odds"], "override": override,
                     "note": note, "reason_codes": codes})
        return self.get_application(user, app_id)

    def _clean_terms(self, a: dict, terms: dict | None) -> dict:
        t = a.get("terms") or {}
        t = {"amount": float(t.get("amount") or a["loan_amount"]),
             "term": int(t.get("term") or a["inputs"]["LoanTerm"]),
             "rate": float(t.get("rate") or a["inputs"]["InterestRate"])}
        for k, v in (terms or {}).items():
            if k in t and v is not None:
                t[k] = type(t[k])(v)
        if not 0 < t["amount"] <= a["loan_amount"] * 1.0001:
            raise BadRequest("The approved amount can't exceed what was requested.", code="TERMS_INVALID",
                             fields={"amount": f"max {a['loan_amount']:g}"})
        if not 1 <= t["term"] <= 120:
            raise BadRequest("Term must be between 1 and 120 months.", code="TERMS_INVALID", fields={"term": "1-120"})
        if not 0 <= t["rate"] <= 60:
            raise BadRequest("Rate must be between 0 and 60%.", code="TERMS_INVALID", fields={"rate": "0-60"})
        t["emi"] = round(emi(t["amount"], t["rate"], t["term"]), 2)
        return t

    # ================================================================ documents
    def _create_doc_request(self, a: dict, user: dict, items: list[str], note: str) -> int:
        bad = [k for k in items if k not in DOC_KINDS]
        if bad or not items:
            raise BadRequest("Unknown document type.", code="DOC_KIND_UNKNOWN", fields={"documents": bad})
        self.db.execute("UPDATE document_requests SET status='cancelled' WHERE application_id=? AND status='open'",
                        (a["id"],))
        req_id = self.db.insert("""INSERT INTO document_requests (application_id, items, note, created_by, created_at,
                                   due_at) VALUES (?,?,?,?,?,?)""",
                                (a["id"], jdump(list(dict.fromkeys(items))), note or None, user["id"], db.now(),
                                 self._later(days=DOC_DUE_DAYS)))
        self._notify(a["borrower_id"], "documents.requested",
                     {"application_id": a["id"], "items": items, "due_days": DOC_DUE_DAYS, "note": note})
        return req_id

    def request_documents(self, user: dict, app_id: int, items: list[str], note: str = "") -> dict:
        return self.decide(user, app_id, "needs_docs", note, documents=items)

    def upload_document(self, borrower: dict, app_id: int, kind: str, filename: str, content_type: str,
                        data: bytes) -> dict:
        require(borrower, "borrower")
        a = self._get_app(app_id)
        if a["borrower_id"] != borrower["id"]:
            raise NotFound("Application not found.", code="APPLICATION_NOT_FOUND")
        if a["status"] not in OPEN_STATUSES:
            raise Conflict("This application is closed.", code="APPLICATION_CLOSED")
        if kind not in DOC_KINDS:
            raise BadRequest("Unknown document type.", code="DOC_KIND_UNKNOWN", fields={"kind": list(DOC_KINDS)})
        ext = UPLOAD_TYPES.get((content_type or "").split(";")[0].strip().lower())
        if not ext:
            raise BadRequest("Upload a PDF, JPG or PNG file.", code="FILE_TYPE", fields={"file": "pdf|jpg|png"})
        if not data:
            raise BadRequest("The file is empty.", code="FILE_EMPTY")
        if len(data) > MAX_UPLOAD_BYTES:
            raise BadRequest("Files can be at most 5 MB.", code="FILE_TOO_LARGE", fields={"file": "max 5 MB"})
        if not self._sniff_ok(data, ext):
            raise BadRequest("The file does not look like a PDF, JPG or PNG.", code="FILE_TYPE")
        req = self._one("SELECT * FROM document_requests WHERE application_id=? AND status='open' ORDER BY id DESC "
                        "LIMIT 1", (app_id,))
        key = self.storage.save(new_key(app_id, ext), data, content_type)
        doc_id = self.db.insert("""INSERT INTO documents (application_id, request_id, kind, filename, content_type, size,
                                   storage_path, uploaded_by, uploaded_at) VALUES (?,?,?,?,?,?,?,?,?)""",
                                (app_id, req["id"] if req else None, kind, (filename or "document")[:120],
                                 content_type, len(data), key, borrower["id"], db.now()))
        self._audit(borrower, "document.uploaded", f"document:{doc_id}", {"kind": kind}, org_id=a["org_id"])
        if req:
            have = {r["kind"] for r in self._q("SELECT kind FROM documents WHERE request_id=? AND deleted_at IS NULL",
                                               (req["id"],))}
            if set(req["items"]) <= have:
                self.db.execute("UPDATE document_requests SET status='fulfilled' WHERE id=?", (req["id"],))
                if a["status"] == "needs_docs":
                    self._set_status(a, "in_review", borrower, "Documents uploaded")
                if a["assigned_to"]:
                    self._notify(a["assigned_to"], "documents.received", {"application_id": app_id}, email=False)
        return self.borrower_application(borrower, app_id)

    @staticmethod
    def _sniff_ok(data: bytes, ext: str) -> bool:
        head = data[:8]
        return {".pdf": head.startswith(b"%PDF"), ".png": head.startswith(b"\x89PNG"),
                ".jpg": head.startswith(b"\xff\xd8\xff")}[ext]

    def document_link(self, user: dict, doc_id: int) -> dict:
        d = self._one("SELECT * FROM documents WHERE id=? AND deleted_at IS NULL", (doc_id,))
        a = self._get_app(d["application_id"]) if d else None
        allowed = a and ((user["role"] == "borrower" and a["borrower_id"] == user["id"])
                         or (user["role"] in ("officer", "admin") and a["org_id"] == user["org_id"]))
        if not allowed:
            raise NotFound("Document not found.", code="DOCUMENT_NOT_FOUND")
        token = sign_path(f"doc:{doc_id}", minutes=5)
        return {"url": f"/v1/files/{token}", "expires_in": 300, "filename": d["filename"]}

    def read_file(self, token: str) -> tuple[bytes, str, str]:
        ref = verify_signed_path(token)
        if not ref.startswith("doc:"):
            raise NotFound("File not found.", code="DOCUMENT_NOT_FOUND")
        d = self._one("SELECT * FROM documents WHERE id=? AND deleted_at IS NULL", (int(ref[4:]),))
        if not d:
            raise NotFound("File not found.", code="DOCUMENT_NOT_FOUND")
        return self.storage.load(d["storage_path"]), d["content_type"], d["filename"]

    # ================================================================ shadow model
    def _shadow_score(self, app_id: int, clean: dict, threshold: float) -> None:
        if self.shadow is None or not self.flag("shadow_scoring"):
            return
        svc, version_id = self.shadow
        try:
            # Features the shadow model needs but the form no longer asks for get the population default.
            sp = svc.predict({f: clean.get(f, py(svc.baseline[f])) for f in svc.features})
        except Exception:
            return                        # a shadow model must never break a real application
        active = self._get_app(app_id)
        self.db.execute("""INSERT INTO shadow_scores (application_id, model_version_id, probability, odds,
                           active_probability, active_odds, created_at) VALUES (?,?,?,?,?,?,?)""",
                        (app_id, version_id, sp["default_probability"],
                         odds_for(sp["risk_score"], svc.threshold_for(self._settings(active["org_id"])["cost_ratio"])),
                         active["default_probability"], active["odds"], db.now()))
