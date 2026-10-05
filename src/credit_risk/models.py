"""Preprocessing and candidate models (all wrapped in leakage-safe Pipelines)."""
from sklearn.compose import ColumnTransformer
from sklearn.ensemble import HistGradientBoostingClassifier, RandomForestClassifier
from sklearn.linear_model import LogisticRegression
from sklearn.pipeline import Pipeline
from sklearn.preprocessing import OneHotEncoder, StandardScaler
from sklearn.utils.class_weight import compute_sample_weight

from .config import CAT_COLS, NUM_COLS, RANDOM_STATE


def build_preprocessor(num_cols=NUM_COLS, cat_cols=CAT_COLS) -> ColumnTransformer:
    return ColumnTransformer(
        transformers=[
            ("num", StandardScaler(), list(num_cols)),
            ("cat", OneHotEncoder(handle_unknown="ignore", drop="if_binary",
                                  sparse_output=False), list(cat_cols)),
        ],
        remainder="drop",
    )


def candidate_models(include_rf: bool = True, hgb_params: dict | None = None,
                     num_cols=NUM_COLS, cat_cols=CAT_COLS) -> dict:
    """name -> (pipeline, needs_sample_weight)."""
    hgb_params = {"max_iter": 400, "learning_rate": 0.05, "max_leaf_nodes": 31,
                  **(hgb_params or {})}
    models = {
        "LogReg (balanced)": (Pipeline([
            ("prep", build_preprocessor(num_cols, cat_cols)),
            ("model", LogisticRegression(max_iter=2000, class_weight="balanced",
                                         random_state=RANDOM_STATE)),
        ]), False),
        "HistGB (balanced)": (Pipeline([
            ("prep", build_preprocessor(num_cols, cat_cols)),
            ("model", HistGradientBoostingClassifier(
                early_stopping=True, validation_fraction=0.1,
                random_state=RANDOM_STATE, **hgb_params)),
        ]), True),
    }
    if include_rf:
        models["RandomForest"] = (Pipeline([
            ("prep", build_preprocessor(num_cols, cat_cols)),
            ("model", RandomForestClassifier(
                n_estimators=300, min_samples_leaf=25, max_features="sqrt",
                class_weight="balanced_subsample", n_jobs=-1,
                random_state=RANDOM_STATE)),
        ]), False)
    return models


def fit_params(y, needs_weight: bool) -> dict:
    return {"model__sample_weight": compute_sample_weight("balanced", y)} if needs_weight else {}
