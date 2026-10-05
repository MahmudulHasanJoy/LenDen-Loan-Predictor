"""Service-level tests for the LenDen platform (roles, tenancy, workflow, readiness)."""
import os

import pytest

from credit_risk.readiness import affordability, emi, light_for
from lenden.settings import MODEL_PATH

pytestmark = pytest.mark.skipif(not MODEL_PATH.exists(), reason="train the fair model first")

INPUTS = {
    "Income": 45000, "LoanAmount": 120000, "CreditScore": 610, "MonthsEmployed": 24,
    "NumCreditLines": 2, "InterestRate": 18.5, "LoanTerm": 60, "DTIRatio": 0.65,
    "Education": "Bachelor's", "EmploymentType": "Part-time", "MaritalStatus": "Single",
    "HasMortgage": "No", "HasDependents": "No", "LoanPurpose": "Home", "HasCoSigner": "No",
}
SAFE = {**INPUTS, "Income": 140000, "LoanAmount": 10000, "InterestRate": 4.0, "LoanTerm": 12,
        "MonthsEmployed": 110, "CreditScore": 820, "HasCoSigner": "Yes", "EmploymentType": "Full-time"}
PW = "password123"


@pytest.fixture()
def world():
    """Fresh in-memory platform with two lenders, staff and two borrowers."""
    from credit_risk.service import CreditRiskService
    from lenden import db
    from lenden.services import Platform
    # CI also runs this suite against PostgreSQL by setting TEST_DATABASE_URL.
    database = db.connect(os.getenv("TEST_DATABASE_URL") or ":memory:")
    if database.dialect == "postgres":
        database.drop_all()
        database.init_schema()
    p = Platform(database, CreditRiskService(MODEL_PATH))
    sup = p._create_user("owner@x.io", "Owner", PW, "superadmin")
    a = p.create_org(sup, "Alpha Lending", "pro", "admin@alpha.io", "Alpha Admin", PW)
    b = p.create_org(sup, "Beta Credit", "free", "admin@beta.io", "Beta Admin", PW)
    w = {"p": p, "super": sup, "alpha": a["org"], "beta": b["org"],
         "alpha_admin": a["admin"], "beta_admin": b["admin"]}
    w["alpha_officer"] = p.add_team_member(a["admin"], "off@alpha.io", "Alpha Officer", PW)
    w["beta_officer"] = p.add_team_member(b["admin"], "off@beta.io", "Beta Officer", PW)
    w["ann"] = p.register_borrower("ann@mail.io", "Ann", PW)["user"]
    w["bob"] = p.register_borrower("bob@mail.io", "Bob", PW)["user"]
    return w


# ------------------------------------------------------------------ readiness engine
def test_emi_matches_known_value():
    assert round(emi(100_000, 12, 12), 2) == 8884.88
    assert emi(1200, 0, 12) == 100


def test_affordability_levels():
    assert affordability(10_000, 10, 36, 100_000)["level"] == "comfortable"
    assert affordability(120_000, 18.5, 60, 45_000)["level"] == "risky"


def test_light_cutoffs():
    assert (light_for(0.05), light_for(0.10), light_for(0.30)) == ("green", "yellow", "red")


def test_readiness_gives_light_tips_and_plan(world):
    r = world["p"].check_readiness(INPUTS)
    assert r["light"] in {"green", "yellow", "red"}
    assert r["tips"], "a risky profile should get improvement tips"
    assert all(t["new_probability"] < r["default_probability"] for t in r["tips"])
    assert r["plan"]["new_probability"] <= min(t["new_probability"] for t in r["tips"])
    assert "monthly_payment" in r["affordability"]


def test_readiness_tips_never_touch_identity(world):
    r = world["p"].check_readiness(INPUTS)
    actionable = {"LoanAmount", "LoanTerm", "HasCoSigner", "DTIRatio", "InterestRate"}
    assert {t["feature"] for t in r["tips"]} <= actionable


# ------------------------------------------------------------------ accounts
def test_register_login_and_bad_password(world):
    from lenden.security import AuthError, decode_token
    p = world["p"]
    out = p.login("ann@mail.io", PW)
    assert decode_token(out["token"])["role"] == "borrower"
    with pytest.raises(AuthError):
        p.login("ann@mail.io", "wrong-password")


def test_duplicate_email_conflict(world):
    from lenden.services import Conflict
    with pytest.raises(Conflict):
        world["p"].register_borrower("ANN@mail.io", "Ann again", PW)


# ------------------------------------------------------------------ borrower -> officer workflow
def test_apply_requires_consent(world):
    from lenden.services import BadRequest
    with pytest.raises(BadRequest):
        world["p"].apply(world["ann"], world["alpha"]["id"], INPUTS, consent=False)


def test_borrower_view_hides_internal_scores(world):
    app = world["p"].apply(world["ann"], world["alpha"]["id"], INPUTS, consent=True)
    assert app["status"] == "submitted" and app["light"] in {"green", "yellow", "red"}
    assert "risk_score" not in app and "reasons" not in app


def test_one_open_application_per_lender(world):
    from lenden.services import Conflict
    p = world["p"]
    p.apply(world["ann"], world["alpha"]["id"], INPUTS, consent=True)
    with pytest.raises(Conflict):
        p.apply(world["ann"], world["alpha"]["id"], INPUTS, consent=True)
    p.apply(world["ann"], world["beta"]["id"], INPUTS, consent=True)      # other lender is fine


def test_queue_sorted_by_risk_and_scoped_to_org(world):
    p = world["p"]
    p.apply(world["ann"], world["alpha"]["id"], INPUTS, consent=True)
    p.apply(world["bob"], world["alpha"]["id"], SAFE, consent=True)
    q = p.list_applications(world["alpha_officer"], status="pending")
    assert q["total"] == 2
    scores = [i["risk_score"] for i in q["items"]]
    assert scores == sorted(scores, reverse=True)
    assert p.list_applications(world["beta_officer"])["total"] == 0


def test_tenant_isolation(world):
    from lenden.services import NotFound
    p = world["p"]
    app = p.apply(world["ann"], world["alpha"]["id"], INPUTS, consent=True)
    with pytest.raises(NotFound):
        p.get_application(world["beta_officer"], app["id"])
    with pytest.raises(NotFound):
        p.decide(world["beta_officer"], app["id"], "approved")


def test_decision_flow_and_borrower_sees_result(world):
    from lenden.services import BadRequest, Conflict
    p = world["p"]
    app = p.apply(world["ann"], world["alpha"]["id"], INPUTS, consent=True)
    with pytest.raises(BadRequest):
        p.decide(world["alpha_officer"], app["id"], "rejected", note="")       # reason required
    p.decide(world["alpha_officer"], app["id"], "needs_docs", "Upload payslips")
    done = p.decide(world["alpha_officer"], app["id"], "rejected", "Income too low for this amount")
    assert done["status"] == "rejected" and done["decided_by_name"] == "Alpha Officer"
    with pytest.raises(Conflict):
        p.decide(world["alpha_officer"], app["id"], "approved")
    mine = p.my_applications(world["ann"])[0]
    assert mine["status"] == "rejected" and "Income too low" in mine["decision_note"]
    actions = [a["action"] for a in p.audit_log(world["alpha_admin"])]
    assert "application.rejected" in actions and "application.needs_docs" in actions


def test_borrower_cannot_use_officer_endpoints(world):
    from lenden.security import Forbidden
    with pytest.raises(Forbidden):
        world["p"].list_applications(world["ann"])


# ------------------------------------------------------------------ admin
def test_only_admin_changes_settings_and_capacity_raises_threshold(world):
    from lenden.security import Forbidden
    p = world["p"]
    with pytest.raises(Forbidden):
        p.update_settings(world["alpha_officer"], cost_ratio=10)
    before = p.get_settings(world["alpha_admin"])["recommendation_threshold"]
    after = p.update_settings(world["alpha_admin"], review_capacity=0.2)["recommendation_threshold"]
    assert after >= before
    cleared = p.update_settings(world["alpha_admin"], clear_capacity=True)
    assert cleared["review_capacity"] is None


def test_team_management_and_deactivation(world):
    from lenden.security import AuthError
    from lenden.services import NotFound
    p = world["p"]
    new = p.add_team_member(world["alpha_admin"], "new@alpha.io", "New Officer", PW)
    assert any(m["id"] == new["id"] for m in p.list_team(world["alpha_admin"]))
    with pytest.raises(NotFound):
        p.set_member_active(world["beta_admin"], new["id"], False)            # other tenant
    p.set_member_active(world["alpha_admin"], new["id"], False)
    with pytest.raises(AuthError):
        p.login("new@alpha.io", PW)


def test_dashboard_counts(world):
    p = world["p"]
    a1 = p.apply(world["ann"], world["alpha"]["id"], INPUTS, consent=True)
    p.apply(world["bob"], world["alpha"]["id"], SAFE, consent=True)
    p.decide(world["alpha_officer"], a1["id"], "approved", "ok")
    d = p.dashboard(world["alpha_admin"])
    assert d["totals"]["applications"] == 2
    assert d["totals"]["approved"] == 1 and d["totals"]["pending"] == 1
    assert d["approval_rate"] == 1.0
    assert d["drift"]["status"] == "not enough data"
    assert len(d["trend"]) == 14


# ------------------------------------------------------------------ super admin
def test_super_admin_creates_and_suspends_orgs(world):
    from lenden.security import AuthError, Forbidden
    p = world["p"]
    with pytest.raises(Forbidden):
        p.list_orgs(world["alpha_admin"])
    made = p.create_org(world["super"], "Gamma Bank", "enterprise", "boss@gamma.io", "Gamma Boss", PW)
    assert made["org"]["slug"] == "gamma-bank"
    assert len(p.list_orgs(world["super"])) == 3
    p.set_org_active(world["super"], world["beta"]["id"], False)
    with pytest.raises(AuthError):
        p.login("admin@beta.io", PW)
    assert world["beta"]["id"] not in [o["id"] for o in p.list_lenders()]
    assert p.platform_stats(world["super"])["orgs"] == 3
