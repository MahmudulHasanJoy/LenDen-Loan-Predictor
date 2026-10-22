"""Decision engine v3: odds, offers, counterfactuals, reason codes, credit ladder, model checks."""
import json

import pytest

from credit_risk.ladder import earned_level
from credit_risk.odds import ODDS, odds_for
from credit_risk.offers import RulesError, clean_rules, ladder_cap, offer_for
from credit_risk.reasons import PROTECTED, code_for, reason_codes
from lenden.settings import MODEL_DIR, MODEL_PATH

pytestmark = pytest.mark.skipif(not MODEL_PATH.exists(), reason="train the v3 model first")

RISKY = {"Income": 45000, "LoanAmount": 120000, "CreditScore": 610, "MonthsEmployed": 24, "NumCreditLines": 2,
         "InterestRate": 18.5, "LoanTerm": 60, "DTIRatio": 0.65, "Education": "Bachelor's",
         "EmploymentType": "Part-time", "HasMortgage": "No", "LoanPurpose": "Home", "HasCoSigner": "No"}
SAFE = {**RISKY, "Income": 140000, "LoanAmount": 20000, "CreditScore": 800, "MonthsEmployed": 100,
        "DTIRatio": 0.2, "EmploymentType": "Full-time"}


@pytest.fixture(scope="module")
def svc():
    from credit_risk.service import CreditRiskService
    return CreditRiskService(MODEL_PATH)


def test_odds_bands_follow_the_lender_threshold():
    t = 0.3
    assert [odds_for(x, t) for x in (0.1, 0.25, 0.4, 0.6)] == list(ODDS)
    # A stricter lender (lower threshold) never gives better odds for the same score.
    for score in (0.1, 0.2, 0.3, 0.5):
        assert ODDS.index(odds_for(score, 0.2)) >= ODDS.index(odds_for(score, 0.3))


def test_reason_codes_skip_protected_attributes():
    reasons = [{"feature": "MaritalStatus", "value": "Single", "typical": "Married", "impact": 0.2},
               {"feature": "DTIRatio", "value": 0.8, "typical": 0.5, "impact": 0.1},
               {"feature": "LoanTerm", "value": 60, "typical": 36, "impact": 0.05},
               {"feature": "CreditScore", "value": 800, "typical": 570, "impact": -0.1}]
    assert reason_codes(reasons) == ["DTI_HIGH", "TERM_LONG"]
    assert all(code_for({"feature": f, "value": 1, "typical": 0, "impact": 1}) is None for f in PROTECTED)


def test_v3_model_has_no_protected_features_and_passes_checks(svc):
    """Model checks that run in CI: a model that regresses cannot ship."""
    assert not set(svc.features) & PROTECTED
    test = svc.metrics["test"]
    assert test["roc_auc"] >= 0.70
    assert test["savings_pct"] >= 0.60
    assert test["brier_calibrated"] <= 0.10
    worst = min(g["disparate_impact"] for groups in svc.metrics["fairness"].values() for g in groups)
    assert worst >= 0.80, "every monitored group must pass the four-fifths rule"


def test_v2_model_fails_four_fifths_which_is_why_v3_exists():
    m = json.loads((MODEL_DIR / "metrics_fair.json").read_text())
    assert min(g["disparate_impact"] for g in m["fairness"]["HasDependents"]) < 0.8


def test_rules_validation(svc):
    r = clean_rules(None, svc.schema)
    assert r["ladder_caps"][-1] == 1.0
    with pytest.raises(RulesError) as e:
        clean_rules({"terms": [7], "base_rate": 99}, svc.schema)
    assert {"terms", "base_rate"} <= set(e.value.fields)


def test_offer_for_safe_borrower_is_eligible_and_affordable(svc):
    rules = clean_rules(None, svc.schema)
    o = offer_for(svc, SAFE, rules, svc.threshold, ladder_level=4)
    assert o["eligible"] and o["best"]["odds"] in ("excellent", "good")
    assert o["best"]["income_share"] <= rules["max_income_share"]
    assert o["amount_min"] <= o["best"]["amount"] <= o["amount_max"] <= SAFE["LoanAmount"]


def test_offer_respects_ladder_cap_and_policy(svc):
    rules = clean_rules({"min_income": 50000}, svc.schema)
    o = offer_for(svc, RISKY, rules, svc.threshold, ladder_level=1)
    assert o["best"]["amount"] <= ladder_cap(rules, 1) and o["capped_by_ladder"]
    assert "POLICY_MIN_INCOME" in o["policy"] and not o["eligible"]


def test_counterfactual_improves_odds_with_actionable_changes(svc):
    from credit_risk.counterfactual import next_step
    step = next_step(svc, RISKY, svc.threshold)
    assert step is not None
    assert ODDS.index(step["odds"]) < ODDS.index(step["from_odds"])
    assert {c["feature"] for c in step["changes"]} <= {"LoanAmount", "LoanTerm", "HasCoSigner", "DTIRatio", "InterestRate"}
    assert 1 <= len(step["changes"]) <= 3


def test_counterfactual_none_when_already_excellent(svc):
    from credit_risk.counterfactual import next_step
    best = {**SAFE, "LoanAmount": 5000, "LoanTerm": 12, "HasCoSigner": "Yes", "InterestRate": 3.0, "DTIRatio": 0.1}
    assert next_step(svc, best, svc.threshold) is None


def test_ladder_levels():
    on_time = {"on_time": True, "max_days_late": 0}
    late = {"on_time": False, "max_days_late": 12}
    assert earned_level([], 0) == 1
    assert earned_level([on_time], 0) == 2
    assert earned_level([on_time, on_time], 0) == 3
    assert earned_level([on_time, late], 0) == 2          # a payment over 7 days late blocks L3
    assert earned_level([on_time] * 4, 0) == 4
    assert earned_level([on_time] * 4, 1) == 3            # a missed payment in 12 months blocks L4
