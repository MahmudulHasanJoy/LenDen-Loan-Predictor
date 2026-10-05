"""Population Stability Index (PSI) for input-drift monitoring.

Rule of thumb: PSI < 0.10 stable, 0.10-0.25 moderate shift, > 0.25 major shift.
"""
import numpy as np
import pandas as pd

EPS = 1e-6


def _psi(expected_pct: np.ndarray, actual_pct: np.ndarray) -> float:
    e = np.clip(expected_pct, EPS, None)
    a = np.clip(actual_pct, EPS, None)
    return float(np.sum((a - e) * np.log(a / e)))


def psi_numeric(expected, actual, bins: int = 10) -> float:
    expected = np.asarray(expected, dtype=float)
    actual = np.asarray(actual, dtype=float)
    edges = np.unique(np.quantile(expected, np.linspace(0, 1, bins + 1)))
    edges[0], edges[-1] = -np.inf, np.inf
    e = np.histogram(expected, edges)[0] / len(expected)
    a = np.histogram(actual, edges)[0] / len(actual)
    return _psi(e, a)


def psi_categorical(expected, actual) -> float:
    e = pd.Series(expected).value_counts(normalize=True)
    a = pd.Series(actual).value_counts(normalize=True)
    cats = e.index.union(a.index)
    return _psi(e.reindex(cats, fill_value=0).values, a.reindex(cats, fill_value=0).values)


def psi_report(reference: pd.DataFrame, current: pd.DataFrame,
               num_cols, cat_cols, bins: int = 10) -> pd.DataFrame:
    rows = [{"feature": c, "psi": psi_numeric(reference[c], current[c], bins)} for c in num_cols]
    rows += [{"feature": c, "psi": psi_categorical(reference[c], current[c])} for c in cat_cols]
    out = pd.DataFrame(rows).sort_values("psi", ascending=False).reset_index(drop=True)
    out["status"] = pd.cut(out["psi"], [-np.inf, 0.10, 0.25, np.inf],
                           labels=["stable", "moderate shift", "major shift"]).astype(str)
    return out
