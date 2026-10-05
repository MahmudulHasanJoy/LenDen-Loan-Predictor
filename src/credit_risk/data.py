"""Loading and splitting the loan-default dataset."""
from pathlib import Path

import pandas as pd
from sklearn.model_selection import train_test_split

from .config import DATA_PATH, FEATURES, ID_COLS, NUM_COLS, CAT_COLS, RANDOM_STATE, TARGET


def load_data(path: str | Path = DATA_PATH) -> pd.DataFrame:
    path = Path(path)
    if not path.exists():
        raise FileNotFoundError(
            f"{path} not found. Download Loan_default.csv from Kaggle "
            "(nikhil1e9/loan-default) and place it in the data/ folder.")
    df = pd.read_csv(path)
    missing = set(FEATURES + [TARGET]) - set(df.columns)
    if missing:
        raise ValueError(f"Dataset is missing columns: {sorted(missing)}")
    return df


def split(df: pd.DataFrame, test_size: float = 0.20):
    """Stratified train/test split. LoanID is dropped (it leaks the label)."""
    X = df.drop(columns=[TARGET] + [c for c in ID_COLS if c in df.columns])[FEATURES]
    y = df[TARGET].astype(int)
    return train_test_split(X, y, test_size=test_size, stratify=y,
                            random_state=RANDOM_STATE)


def feature_schema(X: pd.DataFrame, features=FEATURES) -> dict:
    """Ranges and allowed values, used to validate API input and build the app form."""
    schema = {}
    for c in [c for c in NUM_COLS if c in features]:
        is_int = pd.api.types.is_integer_dtype(X[c])
        schema[c] = {
            "type": "integer" if is_int else "number",
            "min": float(X[c].min()), "max": float(X[c].max()),
            "median": float(X[c].median()),
        }
        if X[c].nunique() <= 6:
            schema[c]["options"] = sorted(int(v) for v in X[c].unique())
    for c in [c for c in CAT_COLS if c in features]:
        schema[c] = {"type": "category",
                     "options": sorted(map(str, X[c].unique())),
                     "mode": str(X[c].mode()[0])}
    return schema


def age_band(age: pd.Series) -> pd.Series:
    return pd.cut(age, bins=[17, 25, 35, 45, 55, 70],
                  labels=["18-25", "26-35", "36-45", "46-55", "56-69"]).astype(str)
