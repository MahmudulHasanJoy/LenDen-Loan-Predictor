"""HTTP-level tests for the LenDen API (FastAPI TestClient)."""
import os
import tempfile

import pytest

from lenden.settings import MODEL_PATH

pytestmark = pytest.mark.skipif(not MODEL_PATH.exists(), reason="train the fair model first")

INPUTS = {
    "Income": 45000, "LoanAmount": 120000, "CreditScore": 610, "MonthsEmployed": 24,
    "NumCreditLines": 2, "InterestRate": 18.5, "LoanTerm": 60, "DTIRatio": 0.65,
    "Education": "Bachelor's", "EmploymentType": "Part-time",
    "HasMortgage": "No", "LoanPurpose": "Home", "HasCoSigner": "No",
}
PW = "password123"


@pytest.fixture(scope="module")
def ctx():
    os.environ["LENDEN_DB"] = os.path.join(tempfile.mkdtemp(), "test.db")
    os.environ["LENDEN_SEED_DEMO"] = "0"
    pg = os.getenv("TEST_DATABASE_URL")
    if pg:                                    # CI: run the API against PostgreSQL
        from lenden import db
        fresh = db.connect(pg)
        fresh.drop_all()
        fresh.close()
        os.environ["DATABASE_URL"] = pg
    from fastapi.testclient import TestClient
    import api.main as m
    p = m.platform
    sup = p._create_user("owner@x.io", "Owner", PW, "superadmin")
    p.set_flag(sup, "credit_ladder", False)
    org = p.create_org(sup, "Alpha Lending", "pro", "admin@alpha.io", "Alpha Admin", PW)["org"]
    p.add_team_member(p.get_user(p._one("SELECT id FROM users WHERE email='admin@alpha.io'")["id"]),
                      "off@alpha.io", "Alpha Officer", PW)
    p.db.commit()
    client = TestClient(m.app)

    def token(email):
        return {"Authorization": "Bearer " + client.post(
            "/auth/login", json={"email": email, "password": PW}).json()["token"]}

    return {"c": client, "org": org, "token": token}


def test_health_and_metadata(ctx):
    c = ctx["c"]
    assert c.get("/health").json()["status"] == "ok"
    fields = [f["name"] for f in c.get("/metadata").json()["fields"]]
    assert not {"Age", "MaritalStatus", "HasDependents"} & set(fields) and len(fields) == 13


def test_public_readiness_and_emi(ctx):
    c = ctx["c"]
    r = c.post("/readiness", json=INPUTS)
    assert r.status_code == 200 and r.json()["light"] in {"green", "yellow", "red"}
    e = c.post("/emi", json={"principal": 100000, "annual_rate": 12, "months": 12, "annual_income": 60000})
    assert e.json()["monthly_payment"] == 8884.88


def test_invalid_inputs_return_422(ctx):
    r = ctx["c"].post("/readiness", json={**INPUTS, "CreditScore": 5})
    assert r.status_code == 422 and "CreditScore" in r.json()["detail"]


def test_auth_required(ctx):
    assert ctx["c"].get("/me").status_code == 401
    assert ctx["c"].get("/me", headers={"Authorization": "Bearer nonsense"}).status_code == 401


def test_full_borrower_to_officer_flow(ctx):
    c, org = ctx["c"], ctx["org"]
    reg = c.post("/auth/register", json={"email": "ann@mail.io", "name": "Ann", "password": PW})
    assert reg.status_code == 200
    ann = {"Authorization": "Bearer " + reg.json()["token"]}
    assert org["id"] in [l["id"] for l in c.get("/lenders").json()]

    r = c.post("/applications", json={"org_id": org["id"], "inputs": INPUTS, "consent": True}, headers=ann)
    assert r.status_code == 200
    app_id = r.json()["id"]
    dup = c.post("/applications", json={"org_id": org["id"], "inputs": INPUTS, "consent": True}, headers=ann)
    assert dup.status_code == 409

    off = ctx["token"]("off@alpha.io")
    assert c.get("/org/applications", headers=ann).status_code == 403
    q = c.get("/org/applications?status=pending&sort=risk", headers=off).json()
    assert q["total"] == 1 and q["items"][0]["id"] == app_id
    detail = c.get(f"/org/applications/{app_id}", headers=off).json()
    assert detail["borrower"]["name"] == "Ann" and detail["reasons"]

    d = c.post(f"/org/applications/{app_id}/decision", json={"decision": "approved", "note": "Welcome"},
               headers=off)
    assert d.status_code == 200 and d.json()["status"] == "approved"
    assert c.get("/applications/mine", headers=ann).json()[0]["status"] == "approved"


def test_admin_settings_team_dashboard(ctx):
    c = ctx["c"]
    admin, off = ctx["token"]("admin@alpha.io"), ctx["token"]("off@alpha.io")
    assert c.put("/org/settings", json={"cost_ratio": 10}, headers=off).status_code == 403
    s = c.put("/org/settings", json={"cost_ratio": 10, "review_capacity": 0.3}, headers=admin).json()
    assert s["cost_ratio"] == 10 and s["review_capacity"] == 0.3
    new = c.post("/org/team", json={"email": "two@alpha.io", "name": "Second Officer", "password": PW},
                 headers=admin)
    assert new.status_code == 200
    assert c.patch(f"/org/team/{new.json()['id']}", json={"active": False}, headers=admin).json()["active"] == 0
    dash = c.get("/org/dashboard", headers=admin).json()
    assert dash["totals"]["applications"] >= 1 and "fairness" in dash
    assert c.get("/org/audit", headers=admin).status_code == 200


def test_super_admin_routes(ctx):
    c = ctx["c"]
    sup = ctx["token"]("owner@x.io")
    assert c.get("/admin/orgs", headers=ctx["token"]("admin@alpha.io")).status_code == 403
    made = c.post("/admin/orgs", json={"name": "Gamma Bank", "plan": "enterprise", "admin_email": "boss@gamma.io",
                                       "admin_name": "Gamma Boss", "admin_password": PW}, headers=sup)
    assert made.status_code == 200
    assert c.get("/admin/stats", headers=sup).json()["orgs"] == 2
