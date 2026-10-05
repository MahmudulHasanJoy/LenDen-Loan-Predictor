"""Per-applicant explanations that work for any model (no SHAP dependency).

For each feature we ask: how much would this applicant's risk score change if
this one feature were set to a typical value (training median / most common
category)? Positive impact = this feature pushes risk UP.
"""
import pandas as pd

from .config import CAT_COLS, FEATURES, LABELS, NUM_COLS


def baseline_row(X: pd.DataFrame, features=FEATURES) -> dict:
    base = {c: X[c].median() for c in NUM_COLS if c in features}
    base.update({c: X[c].mode()[0] for c in CAT_COLS if c in features})
    return base


def explain(pipeline, applicant: pd.DataFrame, baseline: dict, top_k: int = 5,
            features=FEATURES) -> list[dict]:
    """applicant: one-row DataFrame with FEATURES columns."""
    p0 = float(pipeline.predict_proba(applicant)[0, 1])
    variants = []
    for c in features:
        row = applicant.copy()
        row[c] = baseline[c]
        variants.append(row)
    batch = pd.concat(variants, ignore_index=True)
    p = pipeline.predict_proba(batch)[:, 1]          # one call for all 16 features
    reasons = []
    for c, pc in zip(features, p):
        impact = p0 - float(pc)
        if abs(impact) < 1e-4:
            continue
        reasons.append({
            "feature": c,
            "label": LABELS[c],
            "value": applicant[c].iloc[0].item() if hasattr(applicant[c].iloc[0], "item")
                     else applicant[c].iloc[0],
            "typical": baseline[c].item() if hasattr(baseline[c], "item") else baseline[c],
            "impact": round(impact, 4),
            "direction": "increases risk" if impact > 0 else "decreases risk",
        })
    reasons.sort(key=lambda r: abs(r["impact"]), reverse=True)
    return reasons[:top_k]
