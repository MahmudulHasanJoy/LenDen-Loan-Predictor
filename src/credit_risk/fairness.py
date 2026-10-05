"""Group fairness audit for approve/review decisions."""
import numpy as np
import pandas as pd


def group_report(groups: pd.Series, y_true, flagged) -> pd.DataFrame:
    """Per-group approval rate, error rates and the disparate-impact ratio.

    flagged = 1 means the model sends the applicant to REVIEW (not approved).
    Disparate-impact ratio = group approval rate / highest group approval rate.
    The common "4/5ths rule" treats a ratio below 0.80 as a warning sign.
    """
    d = pd.DataFrame({"group": np.asarray(groups), "y": np.asarray(y_true),
                      "flag": np.asarray(flagged)})
    rows = []
    for g, s in d.groupby("group", sort=True):
        pos, neg = s["y"] == 1, s["y"] == 0
        rows.append({
            "group": g,
            "n": len(s),
            "actual_default_rate": s["y"].mean(),
            "approval_rate": 1 - s["flag"].mean(),
            # missed defaults among people who defaulted
            "false_negative_rate": ((s["flag"] == 0) & pos).sum() / max(pos.sum(), 1),
            # good borrowers wrongly sent to review
            "false_positive_rate": ((s["flag"] == 1) & neg).sum() / max(neg.sum(), 1),
        })
    out = pd.DataFrame(rows).set_index("group")
    out["disparate_impact"] = out["approval_rate"] / out["approval_rate"].max()
    out["passes_4_5ths"] = out["disparate_impact"] >= 0.80
    return out


def audit(frame: pd.DataFrame, y_true, flagged, columns) -> dict[str, pd.DataFrame]:
    return {c: group_report(frame[c], y_true, flagged) for c in columns}
