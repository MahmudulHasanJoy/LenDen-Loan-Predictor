"""Batch scoring helpers shared by odds, offers, the simulator and counterfactuals."""
from __future__ import annotations

import numpy as np
import pandas as pd


def score_frame(service, X: pd.DataFrame) -> tuple[np.ndarray, np.ndarray]:
    """(raw risk scores, calibrated default probabilities) for every row of X."""
    raw = service.pipeline.predict_proba(X[service.features])[:, 1]
    return raw, np.clip(service.calibrator.predict(raw), 0.0, 1.0)


def variants(service, inputs: dict, changes: list[dict]) -> pd.DataFrame:
    base = service.validate(inputs)
    return pd.concat([base.assign(**c) for c in changes], ignore_index=True)
