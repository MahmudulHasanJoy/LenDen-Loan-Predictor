"""Unit tests for the framework-free parts: costs, PSI, fairness, service."""
import numpy as np
import pandas as pd
import pytest

from credit_risk.config import MODEL_PATH
from credit_risk.costs import cost_curve, optimal_threshold, total_cost
from credit_risk.fairness import group_report
from credit_risk.monitoring import psi_categorical, psi_numeric


def test_total_cost_counts_fn_and_fp():
    y = [1, 1, 0, 0]
    pred = [0, 1, 1, 0]          # one FN, one FP
    assert total_cost(y, pred, c_fn=10, c_fp=1) == 11


def test_cost_curve_matches_total_cost():
    rng = np.random.default_rng(0)
    y = rng.integers(0, 2, 500)
    p = rng.random(500)
    thr = np.array([0.2, 0.5, 0.8])
    expected = [total_cost(y, (p >= t).astype(int)) for t in thr]
    assert list(cost_curve(y, p, thresholds=thr)) == expected


def test_threshold_moves_down_when_missed_defaults_cost_more():
    rng = np.random.default_rng(1)
    y = rng.integers(0, 2, 2000)
    p = np.clip(y * 0.3 + rng.random(2000) * 0.7, 0, 1)
    t_cheap, _ = optimal_threshold(y, p, c_fn=1, c_fp=1)
    t_costly, _ = optimal_threshold(y, p, c_fn=20, c_fp=1)
    assert t_costly <= t_cheap


def test_psi_is_near_zero_for_same_distribution_and_large_for_shift():
    rng = np.random.default_rng(2)
    a = rng.normal(0, 1, 20_000)
    assert psi_numeric(a, rng.normal(0, 1, 20_000)) < 0.01
    assert psi_numeric(a, rng.normal(1.5, 1, 20_000)) > 0.25
    assert psi_categorical(["a"] * 50 + ["b"] * 50, ["a"] * 50 + ["b"] * 50) == pytest.approx(0, abs=1e-9)


def test_fairness_disparate_impact():
    groups = pd.Series(["A"] * 10 + ["B"] * 10)
    y = np.zeros(20)
    flagged = np.array([0] * 10 + [1] * 5 + [0] * 5)   # A approved 100%, B 50%
    rep = group_report(groups, y, flagged)
    assert rep.loc["A", "disparate_impact"] == 1.0
    assert rep.loc["B", "disparate_impact"] == 0.5
    assert not rep.loc["B", "passes_4_5ths"]


needs_model = pytest.mark.skipif(not MODEL_PATH.exists(), reason="train the model first")

APPLICANT = {
    "Age": 32, "Income": 45000, "LoanAmount": 120000, "CreditScore": 610,
    "MonthsEmployed": 24, "NumCreditLines": 2, "InterestRate": 14.5, "LoanTerm": 36,
    "DTIRatio": 0.45, "Education": "Bachelor's", "EmploymentType": "Full-time",
    "MaritalStatus": "Single", "HasMortgage": "No", "HasDependents": "No",
    "LoanPurpose": "Home", "HasCoSigner": "No",
}


@needs_model
def test_service_predict_shape_and_ranges():
    from credit_risk.service import CreditRiskService
    s = CreditRiskService()
    r = s.predict(APPLICANT)
    assert r["decision"] in {"APPROVE", "REVIEW"}
    assert 0 <= r["default_probability"] <= 1
    assert 0 <= r["risk_score"] <= 1
    assert 1 <= len(r["reasons"]) <= 5


@needs_model
def test_lower_cost_ratio_never_makes_decisions_stricter():
    from credit_risk.service import CreditRiskService
    s = CreditRiskService()
    assert s.threshold_for(5) >= s.threshold_for(20) >= s.threshold_for(50)


@needs_model
def test_service_rejects_bad_input():
    from credit_risk.service import CreditRiskService, ValidationError
    s = CreditRiskService()
    with pytest.raises(ValidationError) as e:
        s.predict({**APPLICANT, "Age": 12, "Education": "Kindergarten"})
    assert set(e.value.errors) == {"Age", "Education"}
