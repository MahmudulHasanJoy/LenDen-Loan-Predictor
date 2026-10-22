"""HTTP-level tests for the /v1 API (FastAPI TestClient)."""
import os
import tempfile

import pytest

from lenden.settings import MODEL_PATH

pytestmark = pytest.mark.skipif(not MODEL_PATH.exists(), reason="train the v3 model first")
PW = "password123"
FULL = {"Income": 90000, "LoanAmount": 20000, "LoanPurpose": "Business", "LoanTerm": 24,
        "EmploymentType": "Full-time", "MonthsEmployed": 60, "CreditScore": 720, "NumCreditLines": 2,
        "DTIRatio": 0.3, "InterestRate": 12.0, "Education": "Bachelor's", "HasMortgage": "No", "HasCoSigner": "No"}
PDF = b"%PDF-1.4\n% demo\n"


@pytest.fixture(scope="module")
def api():
    import sys
    reuse = "api.main" in sys.modules          # test_api.py already started the app on a fresh database
    if not reuse:
        os.environ["LENDEN_DB"] = os.path.join(tempfile.mkdtemp(), "api3.db")
    pg = os.getenv("TEST_DATABASE_URL")
    if pg and not reuse:
        from lenden import db
        fresh = db.connect(pg, migrate=False)
        fresh.drop_all()
        fresh.close()
        os.environ["DATABASE_URL"] = pg
    from fastapi.testclient import TestClient
    import api.main as m
    p = m.platform
    with p.db.session():
        sup = p._create_user("owner3@x.io", "Owner", PW, "superadmin")
        org = p.create_org(sup, "Delta Finance", "pro", "admin@delta.io", "Delta Admin", PW)["org"]
        admin = p.get_user(p._one("SELECT id FROM users WHERE email='admin@delta.io'")["id"])
        p.add_team_member(admin, "off@delta.io", "Delta Officer", PW)
    c = TestClient(m.app)

    def auth(email, password=PW):
        r = c.post("/v1/auth/login", json={"email": email, "password": password})
        assert r.status_code == 200, r.text
        return {"Authorization": "Bearer " + r.json()["access_token"]}

    return {"c": c, "org": org, "auth": auth, "p": p}


def test_health_request_id_and_security_headers(api):
    r = api["c"].get("/health", headers={"X-Request-ID": "abc123"})
    assert r.json()["model_version"] and r.headers["x-request-id"] == "abc123"
    assert r.headers["x-content-type-options"] == "nosniff" and r.headers["x-frame-options"] == "DENY"
    assert api["c"].get("/v1/health").status_code == 200


def test_error_shape_has_code_detail_fields(api):
    c = api["c"]
    r = c.post("/v1/readiness", json={**FULL, "CreditScore": 5})
    assert r.status_code == 422 and r.json()["code"] == "INPUT_INVALID" and "CreditScore" in r.json()["fields"]
    r = c.post("/v1/emi", json={"principal": -1})
    assert r.status_code == 422 and r.json()["code"] == "VALIDATION_ERROR"
    r = c.get("/v1/me")
    assert r.status_code == 401 and r.json()["code"] == "AUTH_REQUIRED"
    r = c.get("/v1/me", headers={"Authorization": "Bearer nonsense"})
    assert r.json()["code"] == "TOKEN_INVALID"


def test_metadata_has_steps_and_no_protected_fields(api):
    m = api["c"].get("/v1/metadata?locale=bn").json()
    names = {f["name"] for f in m["fields"]}
    assert m["locale"] == "bn" and set(m["steps"]["1"]) <= names
    assert not names & {"Age", "MaritalStatus", "HasDependents"}


def test_anonymous_wizard_offers_signup_and_apply(api):
    c = api["c"]
    d = c.post("/v1/drafts", json={"inputs": {"Income": 90000, "LoanAmount": 20000, "LoanPurpose": "Business"}}).json()
    tok, did = d["anon_token"], d["draft"]["id"]
    hdr = {"X-Draft-Token": tok}
    assert c.get(f"/v1/drafts/{did}").status_code == 404            # token required
    r = c.put(f"/v1/drafts/{did}", json={"inputs": {"LoanTerm": 24, "EmploymentType": "Full-time",
                                                      "MonthsEmployed": 60}, "step": 2}, headers=hdr)
    assert r.json()["draft"]["quick_check_done"]
    offers = c.get(f"/v1/drafts/{did}/offers", headers=hdr).json()
    assert offers["offers"] and offers["estimated_fields"]
    sim = c.post("/v1/simulate", json={"draft_id": did, "overrides": {"LoanAmount": 10000}}, headers=hdr).json()
    assert sim["inputs"]["LoanAmount"] == 10000 and sim["odds"] in ("excellent", "good", "fair", "low")

    reg = c.post("/v1/auth/register", json={"email": "zara@mail.io", "name": "Zara", "password": PW,
                                            "anon_token": tok, "locale": "bn"})
    assert reg.status_code == 200 and reg.json()["refresh_token"]
    me = {"Authorization": "Bearer " + reg.json()["access_token"]}
    assert c.get("/v1/drafts", headers=me).json()[0]["id"] == did
    c.put(f"/v1/drafts/{did}", json={"inputs": {k: v for k, v in FULL.items()}, "step": 4}, headers=me)
    offer = next(o for o in c.get(f"/v1/drafts/{did}/offers", headers=me).json()["offers"]
                 if o["org_id"] == api["org"]["id"])
    key = {"Idempotency-Key": "apply-zara-1", **me}
    a1 = c.post("/v1/applications", json={"offer_id": offer["offer_id"], "consent": True}, headers=key)
    a2 = c.post("/v1/applications", json={"offer_id": offer["offer_id"], "consent": True}, headers=key)
    assert a1.status_code == 200 and a2.json()["id"] == a1.json()["id"]          # retry replays, no duplicate
    assert len(c.get("/v1/applications/mine", headers=me).json()) == 1
    api["zara"], api["zara_app"] = me, a1.json()["id"]


def test_officer_claims_requests_docs_borrower_uploads_officer_approves(api):
    c, app_id, zara = api["c"], api["zara_app"], api["zara"]
    off = api["auth"]("off@delta.io")
    q = c.get("/v1/org/applications?status=pending&assigned=unassigned", headers=off).json()
    assert any(i["id"] == app_id for i in q["items"])
    assert c.post(f"/v1/org/applications/{app_id}/claim", headers=off).json()["status"] == "in_review"
    r = c.post(f"/v1/org/applications/{app_id}/decision", headers=off,
               json={"decision": "needs_docs", "documents": ["salary_slip"], "note": "Latest slip please"})
    assert r.json()["status"] == "needs_docs"
    up = c.post(f"/v1/applications/{app_id}/documents", headers=zara, data={"kind": "salary_slip"},
                files={"file": ("slip.pdf", PDF, "application/pdf")})
    assert up.status_code == 200, up.text
    assert up.json()["status"] == "in_review"
    bad = c.post(f"/v1/applications/{app_id}/documents", headers=zara, data={"kind": "salary_slip"},
                 files={"file": ("slip.txt", b"hello", "text/plain")})
    assert bad.status_code == 422 and bad.json()["code"] == "FILE_TYPE"
    detail = c.get(f"/v1/org/applications/{app_id}", headers=off).json()
    link = c.get(f"/v1/documents/{detail['documents'][0]['id']}/link", headers=off).json()
    f = c.get(link["url"])
    assert f.status_code == 200 and f.content == PDF and f.headers["cache-control"] == "no-store"
    assert c.get("/v1/files/not-a-token").status_code == 403
    ok = c.post(f"/v1/org/applications/{app_id}/decision", headers=off,
                json={"decision": "approved", "note": "Welcome", "terms": {"term": 2}})
    assert ok.json()["status"] == "approved" and ok.json()["loan"]["id"]
    api["loan_id"] = ok.json()["loan"]["id"]


def test_borrower_sees_timeline_loan_pays_and_levels_up(api):
    c, zara = api["c"], api["zara"]
    mine = c.get(f"/v1/applications/{api['zara_app']}", headers=zara).json()
    assert [e["to_status"] for e in mine["timeline"]] == ["submitted", "in_review", "needs_docs", "in_review", "approved"]
    loan_id = api["loan_id"]
    for i in range(2):
        r = c.post(f"/v1/loans/{loan_id}/repayments", json={}, headers={"Idempotency-Key": f"pay-{i}", **zara})
        assert r.status_code == 200
    assert c.get(f"/v1/loans/{loan_id}", headers=zara).json()["status"] == "closed"
    levels = c.get("/v1/me/levels", headers=zara).json()
    assert next(lv for lv in levels if lv["org_id"] == api["org"]["id"])["level"] == 2
    inbox = c.get("/v1/notifications", headers=zara).json()
    assert inbox["unread"] > 0
    c.post("/v1/notifications/read-all", headers=zara)
    assert c.get("/v1/notifications", headers=zara).json()["unread"] == 0


def test_refresh_and_logout(api):
    c = api["c"]
    s = c.post("/v1/auth/login", json={"email": "zara@mail.io", "password": PW}).json()
    s2 = c.post("/v1/auth/refresh", json={"refresh_token": s["refresh_token"]}).json()
    assert s2["access_token"]
    c.post("/v1/auth/logout", json={"refresh_token": s2["refresh_token"]})
    r = c.post("/v1/auth/refresh", json={"refresh_token": s2["refresh_token"]})
    assert r.status_code == 401


def test_admin_offer_rules_portfolio_fairness_drift(api):
    c = api["c"]
    adm = api["auth"]("admin@delta.io")
    r = c.put("/v1/org/offer-rules", json={"base_rate": 10.5}, headers=adm)
    assert r.json()["rules"]["base_rate"] == 10.5
    bad = c.put("/v1/org/offer-rules", json={"terms": [7]}, headers=adm)
    assert bad.status_code == 422 and bad.json()["code"] == "RULES_INVALID"
    port = c.get("/v1/org/portfolio", headers=adm).json()
    assert port["loans"]["closed"] == 1 and port["currency"] == "BDT"
    assert c.get("/v1/org/fairness", headers=adm).status_code == 200
    assert c.get("/v1/org/drift", headers=adm).json()["status"] == "not enough data"
    assert c.get("/v1/org/portfolio", headers=api["zara"]).status_code == 403


def test_owner_models_flags_jobs(api):
    c = api["c"]
    sup = api["auth"]("owner3@x.io")
    models = c.get("/v1/admin/models", headers=sup).json()
    assert any(m["status"] == "active" for m in models)
    flags = {f["key"]: f for f in c.put("/v1/admin/flags/phone_login", json={"enabled": False}, headers=sup).json()}
    assert flags["phone_login"]["enabled"] is False
    jobs = c.get("/v1/admin/jobs", headers=sup).json()
    assert {"outbox_dispatch", "repayment_due"} <= {j["name"] for j in jobs}
    r = c.post("/v1/admin/jobs/outbox_dispatch/run", headers=sup).json()
    assert r["result"]["failed"] == 0
    stats = c.get("/v1/admin/stats", headers=sup).json()
    assert stats["funnel_7d"]["submitted"] >= 1


def test_export_and_privacy_endpoints(api):
    c, zara = api["c"], api["zara"]
    data = c.get("/v1/me/export", headers=zara).json()
    assert data["user"]["email"] == "zara@mail.io" and data["loans"]
    assert c.get("/v1/me/consents", headers=zara).json()[0]["purpose"] == "share_application"
    r = c.put("/v1/me", json={"locale": "en", "notification_prefs": {"email": False}}, headers=zara).json()
    assert r["locale"] == "en" and r["notification_prefs"]["email"] is False


def test_legacy_v2_paths_still_work(api):
    c = api["c"]
    tok = c.post("/auth/login", json={"email": "zara@mail.io", "password": PW}).json()["token"]
    assert c.get("/applications/mine", headers={"Authorization": "Bearer " + tok}).status_code == 200
    assert c.post("/readiness", json=FULL).json()["light"] in {"green", "yellow", "red"}
