"""Train all candidate models, pick a champion on training cost, save the artifact.

Usage:
    python -m credit_risk.train                 # all models (RandomForest CV takes a few minutes)
    python -m credit_risk.train --no-rf         # faster: LogReg + HistGB only
"""
import argparse
import json
import time
from datetime import datetime, timezone
from pathlib import Path

import joblib
import numpy as np
from sklearn.isotonic import IsotonicRegression
from sklearn.metrics import average_precision_score, brier_score_loss, roc_auc_score
from sklearn.model_selection import StratifiedKFold, cross_val_predict

from . import __version__
from .config import (CAT_COLS, COST_FN, COST_FP, DATA_PATH, FEATURES, METRICS_PATH,
                     MODEL_PATH, NUM_COLS, RANDOM_STATE, SENSITIVE)
from .costs import optimal_threshold, threshold_table, total_cost
from .data import age_band, feature_schema, load_data, split
from .explain import baseline_row
from .fairness import audit
from .models import candidate_models, fit_params


def oof_proba(pipe, X, y, params, cv):
    try:   # scikit-learn >= 1.4
        p = cross_val_predict(pipe, X, y, cv=cv, method="predict_proba", n_jobs=-1, params=params)
    except TypeError:
        p = cross_val_predict(pipe, X, y, cv=cv, method="predict_proba", n_jobs=-1, fit_params=params)
    return p[:, 1]


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--data", default=str(DATA_PATH))
    ap.add_argument("--no-rf", action="store_true", help="skip RandomForest (much faster)")
    ap.add_argument("--exclude", default="",
                    help="comma-separated features to leave out, e.g. Age (fairness-aware model)")
    ap.add_argument("--out", default=str(MODEL_PATH), help="where to save the model artifact")
    ap.add_argument("--metrics", default=str(METRICS_PATH), help="where to save metrics JSON")
    args = ap.parse_args(argv)
    exclude = [c.strip() for c in args.exclude.split(",") if c.strip()]
    unknown = set(exclude) - set(FEATURES)
    if unknown:
        ap.error(f"unknown features in --exclude: {sorted(unknown)}")
    features = [f for f in FEATURES if f not in exclude]
    num_cols = [c for c in NUM_COLS if c in features]
    cat_cols = [c for c in CAT_COLS if c in features]
    model_path, metrics_path = Path(args.out), Path(args.metrics)

    df = load_data(args.data)
    X_train, X_test, y_train, y_test = split(df)
    print(f"train {X_train.shape}  test {X_test.shape}  default rate {y_train.mean():.4f}")

    cv = StratifiedKFold(n_splits=5, shuffle=True, random_state=RANDOM_STATE)
    results, fitted, oofs = {}, {}, {}
    for name, (pipe, needs_w) in candidate_models(include_rf=not args.no_rf,
                                                  num_cols=num_cols, cat_cols=cat_cols).items():
        t = time.time()
        oof = oof_proba(pipe, X_train, y_train, fit_params(y_train, needs_w), cv)
        thr, oof_cost = optimal_threshold(y_train, oof)
        pipe.fit(X_train, y_train, **fit_params(y_train, needs_w))
        p = pipe.predict_proba(X_test)[:, 1]
        results[name] = {
            "threshold": thr,
            "oof_cost_train": oof_cost,
            "roc_auc_test": round(roc_auc_score(y_test, p), 4),
            "pr_auc_test": round(average_precision_score(y_test, p), 4),
            "cost_test": total_cost(y_test, (p >= thr).astype(int)),
        }
        fitted[name], oofs[name] = pipe, oof
        print(f"{name:<20} thr={thr:.2f}  OOF cost ${oof_cost:,.0f}  "
              f"test AUC {results[name]['roc_auc_test']}  test cost ${results[name]['cost_test']:,.0f}  "
              f"({time.time() - t:.0f}s)")

    # Champion is chosen on TRAINING out-of-fold cost - never on the test set.
    champion = min(results, key=lambda k: results[k]["oof_cost_train"])
    pipe, oof, thr = fitted[champion], oofs[champion], results[champion]["threshold"]
    p_test = pipe.predict_proba(X_test)[:, 1]
    flagged = (p_test >= thr).astype(int)

    # Calibrator maps the (class-weighted) risk score to a real default probability.
    calibrator = IsotonicRegression(out_of_bounds="clip").fit(oof, y_train)
    p_cal = calibrator.predict(p_test)

    baseline_cost = total_cost(y_test, np.zeros_like(y_test))
    champ_cost = results[champion]["cost_test"]

    fair_frame = X_test.assign(AgeBand=age_band(X_test["Age"]))
    fairness = {col: rep.round(4).reset_index().to_dict(orient="records")
                for col, rep in audit(fair_frame, y_test, flagged, SENSITIVE).items()}

    metrics = {
        "trained_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "version": __version__,
        "n_train": int(len(X_train)), "n_test": int(len(X_test)),
        "default_rate": round(float(y_train.mean()), 4),
        "costs": {"false_negative": COST_FN, "false_positive": COST_FP},
        "champion": champion,
        "features": features,
        "excluded_features": exclude,
        "threshold": thr,
        "models": results,
        "test": {
            "roc_auc": results[champion]["roc_auc_test"],
            "pr_auc": results[champion]["pr_auc_test"],
            "brier_raw": round(brier_score_loss(y_test, p_test), 4),
            "brier_calibrated": round(brier_score_loss(y_test, p_cal), 4),
            "cost_approve_all": baseline_cost,
            "cost_model": champ_cost,
            "savings": baseline_cost - champ_cost,
            "savings_pct": round((baseline_cost - champ_cost) / baseline_cost, 4),
            "review_rate": round(float(flagged.mean()), 4),
        },
        "fairness": fairness,
    }

    model_path.parent.mkdir(parents=True, exist_ok=True)
    joblib.dump({
        "pipeline": pipe,
        "features": features,
        "calibrator": calibrator,
        "model_name": champion,
        "threshold": thr,
        "default_cost_ratio": int(round(COST_FN / COST_FP)),
        "threshold_by_ratio": threshold_table(y_train, oof),
        "schema": feature_schema(X_train, features),
        "baseline": baseline_row(X_train, features),
        "reference_sample": X_train.sample(5000, random_state=RANDOM_STATE).reset_index(drop=True),
        "metrics": metrics,
    }, model_path, compress=3)
    metrics_path.write_text(json.dumps(metrics, indent=2, default=float))

    print(f"\nChampion: {champion} @ {thr:.2f}")
    print(f"Test cost ${champ_cost:,.0f} vs approve-all ${baseline_cost:,.0f} "
          f"-> savings ${baseline_cost - champ_cost:,.0f} ({metrics['test']['savings_pct']:.1%})")
    print(f"Saved {model_path} and {metrics_path}")
    return metrics


if __name__ == "__main__":
    main()
