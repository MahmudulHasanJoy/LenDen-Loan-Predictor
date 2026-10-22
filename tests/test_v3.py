"""Service-level tests for v3: drafts, offers, timeline, documents, loans, ladder, privacy, auth, models, jobs."""
import pytest

from conftest import make_db
from lenden import clock
from lenden.settings import MODEL_PATH

pytestmark = pytest.mark.skipif(not MODEL_PATH.exists(), reason="train the v3 model first")
PW = "password123"
QUICK = {"Income": 90000, "LoanAmount": 20000, "LoanPurpose": "Business", "LoanTerm": 24,
         "EmploymentType": "Full-time", "MonthsEmployed": 60}
FULL = {**QUICK, "CreditScore": 720, "NumCreditLines": 2, "DTIRatio": 0.3, "InterestRate": 12.0,
        "Education": "Bachelor's", "HasMortgage": "No", "HasCoSigner": "No"}
PDF = b"%PDF-1.4\n% demo\n"


@pytest.fixture()
def w():
    from credit_risk.service import CreditRiskService
    from lenden.services import Platform
    p = Platform(make_db(), CreditRiskService(MODEL_PATH))
    sup = p._create_user("owner@x.io", "Owner", PW, "superadmin")
    a = p.create_org(sup, "Alpha Lending", "pro", "admin@alpha.io", "Alpha Admin", PW)
    b = p.create_org(sup, "Beta Credit", "free", "admin@beta.io", "Beta Admin", PW)
    w = {"p": p, "super": sup, "alpha": a["org"], "beta": b["org"], "alpha_admin": a["admin"], "beta_admin": b["admin"]}
    w["off"] = p.add_team_member(a["admin"], "off@alpha.io", "Alpha Officer", PW)
    w["off2"] = p.add_team_member(a["admin"], "off2@alpha.io", "Second Officer", PW)
    w["beta_off"] = p.add_team_member(b["admin"], "off@beta.io", "Beta Officer", PW)
    w["ann"] = p.register_borrower("ann@mail.io", "Ann", PW)["user"]
    p.db.commit()
    yield w
    p.db.rollback()          # PostgreSQL: end the transaction so the next test can drop the tables
    p.db.close()


def _apply_via_offer(w, user="ann", org="alpha", inputs=FULL):
    p = w["p"]
    d = p.create_draft(w[user], inputs, step=4)["draft"]
    offers = p.draft_offers(d["id"], w[user], None)["offers"]
    offer = next(o for o in offers if o["org_id"] == w[org]["id"])
    return p.apply(w[user], consent=True, offer_id=offer["offer_id"]), offer


# ------------------------------------------------------------------ drafts and the wizard
def test_anonymous_draft_autosaves_and_is_claimed_at_signup(w):
    p = w["p"]
    out = p.create_draft(None, {"Income": 90000, "LoanAmount": 20000}, step=1)
    token, did = out["anon_token"], out["draft"]["id"]
    assert not out["draft"]["quick_check_done"]
    upd = p.update_draft(did, None, token, {"LoanPurpose": "Business", "LoanTerm": 24, "EmploymentType": "Full-time",
                                            "MonthsEmployed": 60}, step=2)
    assert upd["draft"]["quick_check_done"] and upd["draft"]["step"] == 2
    from lenden.errors import NotFound
    with pytest.raises(NotFound):
        p.get_draft(did, None, "wrong-token")
    bob = p.register_borrower("bob@mail.io", "Bob", PW, anon_token=token)["user"]
    assert p.get_draft(did, bob, None)["draft"]["inputs"]["Income"] == 90000
    with pytest.raises(NotFound):                         # the anonymous token stops working once claimed
        p.get_draft(did, None, token)


def test_draft_validation_reports_fields(w):
    from credit_risk.service import ValidationError
    with pytest.raises(ValidationError) as e:
        w["p"].create_draft(None, {"Income": -5, "Colour": "blue"})
    assert {"Income", "Colour"} <= set(e.value.errors)


def test_offers_need_the_quick_check(w):
    from lenden.errors import BadRequest
    p = w["p"]
    d = p.create_draft(w["ann"], {"Income": 90000})["draft"]
    with pytest.raises(BadRequest) as e:
        p.draft_offers(d["id"], w["ann"], None)
    assert e.value.code == "QUICK_CHECK_INCOMPLETE"


def test_offers_from_every_lender_with_defaults_marked(w):
    p = w["p"]
    d = p.create_draft(w["ann"], QUICK, step=2)["draft"]
    out = p.draft_offers(d["id"], w["ann"], None)
    assert {o["org_id"] for o in out["offers"]} == {w["alpha"]["id"], w["beta"]["id"]}
    assert "CreditScore" in out["estimated_fields"]
    for o in out["offers"]:
        assert o["best"]["amount"] <= o["ladder_cap"]          # new borrowers start at level 1
        assert o["ladder_level"] == 1


def test_simulator_matches_odds_and_suggests_next_step(w):
    p = w["p"]
    risky = {**FULL, "Income": 30000, "LoanAmount": 200000, "LoanTerm": 60, "DTIRatio": 0.8, "CreditScore": 450}
    s = p.simulate(risky)
    assert s["odds"] in ("fair", "low") and s["next_step"]
    better = p.simulate(risky, {c["feature"]: c["to"] for c in s["next_step"]["changes"]})
    assert better["odds"] == s["next_step"]["odds"]
    assert p.simulate(QUICK)["estimated_fields"]


# ------------------------------------------------------------------ applying and the timeline
def test_apply_with_offer_uses_offer_terms_and_records_consent(w):
    p = w["p"]
    app, offer = _apply_via_offer(w)
    assert app["terms"]["amount"] == offer["best"]["amount"] and app["terms"]["term"] == offer["best"]["term"]
    assert [e["to_status"] for e in app["timeline"]] == ["submitted"]
    assert p.list_consents(w["ann"])[0]["purpose"] == "share_application"
    from lenden.errors import Conflict
    with pytest.raises(Conflict) as e:                         # offer already used
        p.apply(w["ann"], consent=True, offer_id=offer["offer_id"])
    assert e.value.code in ("OFFER_EXPIRED", "APPLICATION_OPEN")
    assert p.list_notifications(w["ann"])["unread"] >= 2       # welcome + submitted


def test_ladder_limit_blocks_large_first_loans(w):
    from lenden.errors import BadRequest
    with pytest.raises(BadRequest) as e:
        w["p"].apply(w["ann"], w["alpha"]["id"], {**FULL, "LoanAmount": 200000}, consent=True)
    assert e.value.code == "LADDER_LIMIT" and e.value.fields["ladder_level"] == 1


def test_claim_review_and_reject_with_reason_codes(w):
    from lenden.errors import BadRequest, Conflict
    p = w["p"]
    app, _ = _apply_via_offer(w)
    claimed = p.claim(w["off"], app["id"])
    assert claimed["status"] == "in_review" and claimed["assigned_name"] == "Alpha Officer"
    with pytest.raises(Conflict):
        p.claim(w["off2"], app["id"])
    with pytest.raises(BadRequest):
        p.decide(w["off"], app["id"], "rejected")
    with pytest.raises(BadRequest):
        p.decide(w["off"], app["id"], "rejected", reason_codes=["NOT_A_CODE"])
    p.decide(w["off"], app["id"], "rejected", "", reason_codes=["DTI_HIGH", "INCOME_LOW"])
    mine = p.borrower_application(w["ann"], app["id"])
    assert mine["status"] == "rejected" and mine["reason_codes"] == ["DTI_HIGH", "INCOME_LOW"]
    assert [e["to_status"] for e in mine["timeline"]] == ["submitted", "in_review", "rejected"]
    assert "risk_score" not in mine


def test_documents_request_upload_and_back_to_review(w):
    from lenden.errors import BadRequest
    p = w["p"]
    app, _ = _apply_via_offer(w)
    p.claim(w["off"], app["id"])
    p.decide(w["off"], app["id"], "needs_docs", "Please upload", documents=["bank_statements_3m", "salary_slip"])
    with pytest.raises(BadRequest):
        p.upload_document(w["ann"], app["id"], "salary_slip", "x.exe", "application/x-msdownload", b"MZ")
    with pytest.raises(BadRequest):                            # says PDF but is not one
        p.upload_document(w["ann"], app["id"], "salary_slip", "x.pdf", "application/pdf", b"hello")
    p.upload_document(w["ann"], app["id"], "bank_statements_3m", "bank.pdf", "application/pdf", PDF)
    assert p.borrower_application(w["ann"], app["id"])["status"] == "needs_docs"
    after = p.upload_document(w["ann"], app["id"], "salary_slip", "slip.pdf", "application/pdf", PDF)
    assert after["status"] == "in_review" and after["document_requests"][0]["status"] == "fulfilled"
    doc_id = after["documents"][0]["id"]
    link = p.document_link(w["off"], doc_id)
    data, ctype, _ = p.read_file(link["url"].rsplit("/", 1)[1])
    assert data == PDF and ctype == "application/pdf"
    from lenden.errors import NotFound
    with pytest.raises(NotFound):                              # other tenant
        p.document_link(w["beta_off"], doc_id)
    clock.advance(minutes=6)
    from lenden.errors import Forbidden
    with pytest.raises(Forbidden):                             # links expire after 5 minutes
        p.read_file(link["url"].rsplit("/", 1)[1])


def test_withdraw(w):
    from lenden.errors import Conflict
    p = w["p"]
    app, _ = _apply_via_offer(w)
    assert p.withdraw(w["ann"], app["id"])["status"] == "withdrawn"
    with pytest.raises(Conflict):
        p.withdraw(w["ann"], app["id"])


# ------------------------------------------------------------------ loans and the credit ladder
def test_approval_creates_loan_and_repayment_promotes_ladder(w):
    p = w["p"]
    app, _ = _apply_via_offer(w)
    p.claim(w["off"], app["id"])
    done = p.decide(w["off"], app["id"], "approved", "Welcome", terms={"term": 3})
    loan_id = done["loan"]["id"]
    loan = p.loan_detail(w["ann"], loan_id)
    assert loan["installments"] == 3 and abs(loan["total_repayable"] - 3 * loan["emi"]) < 0.05
    from lenden.errors import NotFound
    with pytest.raises(NotFound):
        p.loan_detail(w["beta_off"], loan_id)
    for _ in range(3):
        loan = p.pay(w["ann"], loan_id)
    assert loan["status"] == "closed" and loan["outstanding"] == 0
    levels = {lv["org_id"]: lv for lv in p.my_levels(w["ann"])}
    assert levels[w["alpha"]["id"]]["level"] == 2 and levels[w["beta"]["id"]]["level"] == 1
    assert levels[w["alpha"]["id"]]["max_amount"] > levels[w["beta"]["id"]]["max_amount"]
    events = [n["event"] for n in p.list_notifications(w["ann"])["items"]]
    assert "loan.closed" in events and "application.approved" in events


def test_overpayment_rejected_and_partial_payment_kept(w):
    from lenden.errors import BadRequest
    p = w["p"]
    app, _ = _apply_via_offer(w)
    loan_id = p.decide(w["off"], app["id"], "approved", terms={"term": 2})["loan"]["id"]
    with pytest.raises(BadRequest):
        p.pay(w["ann"], loan_id, 10**9)
    loan = p.pay(w["ann"], loan_id, 100)
    assert loan["paid"] == 100 and loan["installments_paid"] == 0


def test_missed_payment_marks_late_then_missed_and_demotes(w):
    p = w["p"]
    p._set_level(w["ann"]["id"], w["alpha"]["id"], 3)
    app, _ = _apply_via_offer(w)
    loan_id = p.decide(w["off"], app["id"], "approved", terms={"term": 6})["loan"]["id"]
    clock.advance(days=36)
    assert p.run_repayment_checks()["late"] == 1
    clock.advance(days=30)
    r = p.run_repayment_checks()
    assert r["missed"] == 1
    assert p._level(w["ann"]["id"], w["alpha"]["id"]) == 2
    assert p.portfolio(w["alpha_admin"])["missed"] >= 1
    assert p.loan_detail(w["ann"], loan_id)["overdue"]


# ------------------------------------------------------------------ jobs and notifications
def test_jobs_remind_drafts_and_documents_and_dispatch_outbox(w):
    from lenden.jobs import run_job
    p = w["p"]
    p.create_draft(w["ann"], {"Income": 50000})
    app, _ = _apply_via_offer(w, inputs={**FULL, "LoanAmount": 15000})
    p.decide(w["off"], app["id"], "needs_docs", documents=["salary_slip"])
    p.db.commit()
    clock.advance(days=3)
    assert run_job(p, "draft_reminders")["reminded"] == 1
    assert run_job(p, "doc_request_timers")["reminded"] == 1
    clock.advance(days=5)
    assert run_job(p, "doc_request_timers")["expired"] == 1
    out = run_job(p, "outbox_dispatch")
    assert out["sent"] >= 1 and out["failed"] == 0
    assert p._scalar("SELECT COUNT(*) FROM outbox WHERE processed_at IS NULL") == 0


def test_notification_inbox(w):
    p = w["p"]
    inbox = p.list_notifications(w["ann"])
    assert inbox["unread"] == 1 and inbox["items"][0]["event"] == "account.welcome"
    p.mark_all_read(w["ann"])
    assert p.list_notifications(w["ann"])["unread"] == 0


# ------------------------------------------------------------------ privacy
def test_revoking_consent_withdraws_open_application(w):
    p = w["p"]
    app, _ = _apply_via_offer(w)
    consent = p.list_consents(w["ann"])[0]
    p.revoke_consent(w["ann"], consent["id"])
    assert p.borrower_application(w["ann"], app["id"])["status"] == "withdrawn"


def test_export_and_delete_account(w):
    from lenden.errors import AuthError
    p = w["p"]
    app, _ = _apply_via_offer(w)
    data = p.export_my_data(w["ann"])
    assert data["user"]["email"] == "ann@mail.io" and data["applications"][0]["id"] == app["id"]
    assert "risk_score" not in data["applications"][0]
    p.delete_account(w["ann"], password_ok=True)
    with pytest.raises(AuthError):
        p.login("ann@mail.io", PW)
    row = p._one("SELECT email, name, phone FROM users WHERE id=?", (w["ann"]["id"],))
    assert row["name"] == "Deleted user" and "ann" not in row["email"]
    assert p._one("SELECT status FROM applications WHERE id=?", (app["id"],))["status"] == "withdrawn"


# ------------------------------------------------------------------ auth
def test_refresh_rotation_and_reuse_detection(w):
    from lenden.errors import AuthError
    p = w["p"]
    s1 = p.login("ann@mail.io", PW)
    s2 = p.refresh(s1["refresh_token"])
    assert s2["refresh_token"] != s1["refresh_token"]
    with pytest.raises(AuthError) as e:
        p.refresh(s1["refresh_token"])                       # old token used again
    assert e.value.code == "REFRESH_REUSED"
    with pytest.raises(AuthError):
        p.refresh(s2["refresh_token"])                       # whole family revoked


def test_login_lockout_after_failures(w):
    from lenden.errors import AuthError, RateLimited
    p = w["p"]
    for _ in range(5):
        with pytest.raises(AuthError):
            p.login("ann@mail.io", "nope-nope", ip="1.2.3.4")
    with pytest.raises(RateLimited):
        p.login("ann@mail.io", PW, ip="1.2.3.4")


def test_password_reset_flow(w):
    p = w["p"]
    out = p.forgot_password("ann@mail.io")
    assert p.forgot_password("nobody@mail.io") == {"ok": True}     # same answer for unknown emails
    p.reset_password(out["dev_token"], "brand-new-pass")
    assert p.login("ann@mail.io", "brand-new-pass")["user"]["id"] == w["ann"]["id"]
    from lenden.errors import BadRequest
    with pytest.raises(BadRequest):
        p.reset_password(out["dev_token"], "another-pass")          # one use only


def test_phone_verify_then_otp_login(w):
    from lenden.errors import AuthError
    p = w["p"]
    code = p.request_otp("01712345678", "verify", w["ann"])["dev_code"]
    with pytest.raises(AuthError):
        p.verify_otp("01712345678", "000000" if code != "000000" else "111111", "verify", w["ann"])
    p.verify_otp("01712345678", code, "verify", w["ann"])
    assert p.get_user(w["ann"]["id"])["phone"] == "+8801712345678"
    login_code = p.request_otp("+8801712345678", "login")["dev_code"]
    s = p.verify_otp("01712345678", login_code, "login")
    assert s["user"]["id"] == w["ann"]["id"] and s["refresh_token"]
    assert "dev_code" not in p.request_otp("01899999999", "login")  # unknown numbers get no code


def test_totp_for_staff(w):
    from lenden.errors import AuthError
    from lenden.security import totp_now
    p = w["p"]
    setup = p.totp_setup(w["alpha_admin"])
    p.totp_enable(w["alpha_admin"], totp_now(setup["secret"]))
    with pytest.raises(AuthError) as e:
        p.login("admin@alpha.io", PW)
    assert e.value.code == "TOTP_REQUIRED"
    assert p.login("admin@alpha.io", PW, totp=totp_now(setup["secret"]))["user"]["totp_enabled"]


# ------------------------------------------------------------------ model registry
def test_registry_shadow_and_promotion(w):
    from lenden.errors import Conflict
    p = w["p"]
    models = {m["version"]: m for m in p.list_models(w["super"])}
    assert models["lenden-v3"]["status"] == "active" and models["lenden-v2-fair"]["status"] == "retired"
    v2 = models["lenden-v2-fair"]["id"]
    with pytest.raises(Conflict):
        p.promote(w["super"], v2, "active")                       # retired -> active is not allowed
    p.promote(w["super"], v2, "candidate")
    p.promote(w["super"], v2, "shadow")
    assert p.shadow_label == "lenden-v2-fair"
    app, _ = _apply_via_offer(w)
    detail = p.get_application(w["off"], app["id"])
    assert detail["shadow"]["version"] == "lenden-v2-fair"
    rep = p.shadow_report(w["super"], v2)
    assert rep["live"]["n"] == 1 and rep["offline"]["n"] > 1000
    p.promote(w["super"], v2, "active")
    assert p.model_version_label == "lenden-v2-fair" and "MaritalStatus" in p.risk.features
    v3 = models["lenden-v3"]["id"]
    p.promote(w["super"], v3, "candidate")
    p.promote(w["super"], v3, "shadow")
    p.promote(w["super"], v3, "active")
    assert p.model_version_label == "lenden-v3"


def test_feature_flags(w):
    p = w["p"]
    p.set_flag(w["super"], "credit_ladder", False)
    app = p.apply(w["ann"], w["alpha"]["id"], {**FULL, "LoanAmount": 200000}, consent=True)
    assert app["status"] == "submitted"


def test_platform_stats_funnel(w):
    p = w["p"]
    p.create_draft(None, {"Income": 1e5}, step=1)
    _apply_via_offer(w)
    s = p.platform_stats(w["super"])
    assert s["funnel_7d"]["started"] == 2 and s["funnel_7d"]["submitted"] == 1
    assert s["drop_off_7d"] == 0.5 and s["model"]["active"] == "lenden-v3"


def test_offer_rules_validation_and_effect(w):
    from lenden.errors import BadRequest
    p = w["p"]
    with pytest.raises(BadRequest) as e:
        p.update_offer_rules(w["alpha_admin"], {"terms": [7]})
    assert "terms" in e.value.fields
    p.update_offer_rules(w["alpha_admin"], {"base_rate": 9.0, "rate_step": 1.0})
    d = p.create_draft(w["ann"], FULL)["draft"]
    offers = {o["org_id"]: o for o in p.draft_offers(d["id"], w["ann"], None)["offers"]}
    assert offers[w["alpha"]["id"]]["best"]["rate"] < offers[w["beta"]["id"]]["best"]["rate"]


def test_fairness_report_uses_self_reported_groups_only(w):
    p = w["p"]
    rep = p.fairness_report(w["alpha_admin"])
    assert {g["attribute"] for g in rep["groups"]} == {"gender", "age_band"}
    assert rep["groups"][0]["status"] == "not enough data"


def test_seed_builds_consistent_demo(w):
    """The demo seeder runs end to end on a small population."""
    from credit_risk.service import CreditRiskService
    from lenden.seed import build
    from lenden.services import Platform
    w["p"].db.rollback()
    p = Platform(make_db(), CreditRiskService(MODEL_PATH))
    build(p, n_borrowers=12)
    assert p._scalar("SELECT COUNT(*) FROM users WHERE role='borrower'") == 12
    assert p._scalar("SELECT COUNT(*) FROM outbox WHERE processed_at IS NULL") == 0
    assert p._scalar("SELECT COUNT(*) FROM applications WHERE status IN ('submitted','in_review','needs_docs') "
                     "GROUP BY borrower_id, org_id ORDER BY 1 DESC LIMIT 1") in (None, 1)
    p.db.rollback()
    p.db.close()


def test_demo_mode_only_reveals_codes_for_demo_accounts(w, monkeypatch):
    from lenden.domain import identity
    monkeypatch.setattr(identity, "EXPOSE_CODES_FOR_ALL", False)
    p = w["p"]
    assert "dev_token" not in p.forgot_password("ann@mail.io")
    p._create_user("someone@demo.app", "Demo Person", PW, "borrower")
    assert "dev_token" in p.forgot_password("someone@demo.app")
