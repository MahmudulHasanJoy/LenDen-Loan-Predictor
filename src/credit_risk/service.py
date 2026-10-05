"""Framework-free scoring service. The FastAPI app is a thin layer over this."""
from pathlib import Path

import joblib
import pandas as pd

from .config import FEATURES, LABELS, MODEL_PATH
from .explain import explain

RISK_BANDS = [(0.08, "Low"), (0.15, "Moderate"), (0.30, "High"), (1.01, "Very high")]


class ValidationError(ValueError):
    def __init__(self, errors: dict[str, str]):
        super().__init__("; ".join(f"{k}: {v}" for k, v in errors.items()))
        self.errors = errors


class CreditRiskService:
    def __init__(self, model_path: str | Path = MODEL_PATH):
        model_path = Path(model_path)
        if not model_path.exists():
            raise FileNotFoundError(
                f"{model_path} not found. Train first: python -m credit_risk.train")
        a = joblib.load(model_path)
        self.pipeline = a["pipeline"]
        self.features = list(a.get("features", FEATURES))
        self.calibrator = a["calibrator"]
        self.model_name = a["model_name"]
        self.threshold = a["threshold"]
        self.default_cost_ratio = a["default_cost_ratio"]
        self.threshold_by_ratio = {int(k): v for k, v in a["threshold_by_ratio"].items()}
        self.schema = a["schema"]
        self.baseline = a["baseline"]
        self.metrics = a["metrics"]
        self.reference_sample = a.get("reference_sample")
        self.version = self.metrics.get("version", "unknown")

    # ------------------------------------------------------------------ input
    def validate(self, applicant: dict) -> pd.DataFrame:
        errors = {}
        row = {}
        for f in self.features:
            spec = self.schema[f]
            if f not in applicant or applicant[f] is None:
                errors[f] = "is required"
                continue
            v = applicant[f]
            if spec["type"] == "category":
                if str(v) not in spec["options"]:
                    errors[f] = f"must be one of {spec['options']}"
                row[f] = str(v)
            else:
                try:
                    v = float(v)
                except (TypeError, ValueError):
                    errors[f] = "must be a number"
                    continue
                if not spec["min"] <= v <= spec["max"]:
                    errors[f] = f"must be between {spec['min']:g} and {spec['max']:g}"
                if "options" in spec and int(v) not in spec["options"]:
                    errors[f] = f"must be one of {spec['options']}"
                row[f] = int(v) if spec["type"] == "integer" else v
        if errors:
            raise ValidationError(errors)
        return pd.DataFrame([row], columns=self.features)

    def threshold_for(self, cost_ratio: float | None) -> float:
        if cost_ratio is None:
            return self.threshold
        r = int(min(max(round(cost_ratio), 1), max(self.threshold_by_ratio)))
        return self.threshold_by_ratio[r]

    # ---------------------------------------------------------------- scoring
    def predict(self, applicant: dict, cost_ratio: float | None = None,
                explain_top_k: int = 5) -> dict:
        X = self.validate(applicant)
        score = float(self.pipeline.predict_proba(X)[0, 1])
        prob = float(self.calibrator.predict([score])[0])
        thr = self.threshold_for(cost_ratio)
        band = next(name for cut, name in RISK_BANDS if prob < cut)
        return {
            "decision": "REVIEW" if score >= thr else "APPROVE",
            "risk_score": round(score, 4),
            "default_probability": round(prob, 4),
            "risk_band": band,
            "threshold": thr,
            "cost_ratio": cost_ratio if cost_ratio is not None else self.default_cost_ratio,
            "model": self.model_name,
            "reasons": explain(self.pipeline, X, self.baseline, top_k=explain_top_k,
                               features=self.features),
        }

    def metadata(self) -> dict:
        fields = []
        for f in self.features:
            spec = dict(self.schema[f])
            spec["name"], spec["label"] = f, LABELS[f]
            spec["default"] = spec.get("median", spec.get("mode"))
            fields.append(spec)
        m = self.metrics
        return {
            "model": self.model_name,
            "version": m["version"],
            "trained_at": m["trained_at"],
            "threshold": self.threshold,
            "default_cost_ratio": self.default_cost_ratio,
            "max_cost_ratio": max(self.threshold_by_ratio),
            "fields": fields,
            "performance": m["test"],
        }
