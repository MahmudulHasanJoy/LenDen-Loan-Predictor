"""Dollar-cost evaluation and cost-optimal thresholds."""
import numpy as np

from .config import COST_FN, COST_FP

THRESHOLDS = np.round(np.linspace(0.01, 0.99, 99), 2)


def total_cost(y_true, y_pred, c_fn: float = COST_FN, c_fp: float = COST_FP) -> float:
    y_true = np.asarray(y_true)
    y_pred = np.asarray(y_pred)
    fn = int(((y_true == 1) & (y_pred == 0)).sum())
    fp = int(((y_true == 0) & (y_pred == 1)).sum())
    return c_fn * fn + c_fp * fp


def cost_curve(y_true, proba, c_fn=COST_FN, c_fp=COST_FP, thresholds=THRESHOLDS):
    """Total cost at each threshold. Vectorised over thresholds."""
    y_true = np.asarray(y_true).astype(bool)
    proba = np.asarray(proba)
    flagged = proba[None, :] >= thresholds[:, None]          # (n_thr, n_rows)
    fn = ((~flagged) & y_true[None, :]).sum(axis=1)
    fp = (flagged & ~y_true[None, :]).sum(axis=1)
    return c_fn * fn + c_fp * fp


def optimal_threshold(y_true, proba, c_fn=COST_FN, c_fp=COST_FP,
                      thresholds=THRESHOLDS) -> tuple[float, float]:
    """Threshold that minimises total cost, and that cost."""
    costs = cost_curve(y_true, proba, c_fn, c_fp, thresholds)
    i = int(np.argmin(costs))
    return float(thresholds[i]), float(costs[i])


def threshold_table(y_true, proba, ratios=range(1, 51)) -> dict[int, float]:
    """Cost-optimal threshold for each FN:FP cost ratio (FP cost fixed at 1)."""
    return {int(r): optimal_threshold(y_true, proba, c_fn=r, c_fp=1)[0] for r in ratios}
