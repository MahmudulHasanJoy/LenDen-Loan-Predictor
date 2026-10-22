"""Model registry: versions, shadow scoring and promotion (candidate -> shadow -> active)."""
from __future__ import annotations

import hashlib
from pathlib import Path

from credit_risk.odds import odds_for
from credit_risk.scoring import score_frame
from credit_risk.service import CreditRiskService

from .. import db
from ..errors import BadRequest, Conflict, NotFound
from ..security import require
from ..settings import MODEL_DIR
from .base import Base, jdump, py

KNOWN = {
    "model_v3.joblib": ("lenden-v3", "Trained without age, marital status or dependants."),
    "model_fair.joblib": ("lenden-v2-fair", "v2 model: trained without age."),
}
TRANSITIONS = {("candidate", "shadow"), ("shadow", "active"), ("shadow", "candidate"),
               ("candidate", "retired"), ("retired", "candidate")}


def file_hash(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()[:16]


class Models(Base):
    risk: CreditRiskService
    model_version_id: int | None = None
    model_version_label: str = "unregistered"
    shadow: tuple | None = None
    shadow_label: str | None = None
    _risk_file: str | None = None

    # ================================================================ registry
    def _register(self, path: Path, status: str, version: str | None = None, notes: str | None = None) -> int:
        name = path.name
        row = self._one("SELECT id FROM model_versions WHERE artifact_path=?", (name,))
        if row:
            return row["id"]
        svc = CreditRiskService(path)
        default_version, default_notes = KNOWN.get(name, (path.stem, None))
        version = version or default_version
        if self._one("SELECT id FROM model_versions WHERE version=?", (version,)):
            version = f"{version}-{file_hash(path)[:6]}"
        return self.db.insert(
            """INSERT INTO model_versions (version, artifact_path, data_hash, model_name, metrics, features, notes,
               status, created_at, promoted_at) VALUES (?,?,?,?,?,?,?,?,?,?)""",
            (version, name, file_hash(path), svc.model_name, jdump(_summary(svc)), jdump(svc.features),
             notes or default_notes, status, db.now(), db.now() if status == "active" else None))

    def ensure_registry(self, active_path: Path | None = None) -> None:
        """Register the loaded model (active if none is) and any other known artifacts as candidates."""
        has_active = self._one("SELECT id FROM model_versions WHERE status='active'")
        if active_path is not None and active_path.exists():
            self._register(active_path, "candidate" if has_active else "active")
        for name in KNOWN:
            p = MODEL_DIR / name
            if p.exists():
                self._register(p, "retired" if name == "model_fair.joblib" else "candidate")
        self.db.commit()

    def load_models(self) -> None:
        """Load the active (and shadow) model named in the registry, if it differs from what is loaded."""
        active = self._one("SELECT * FROM model_versions WHERE status='active'")
        if active:
            if active["artifact_path"] != self._risk_file:
                path = MODEL_DIR / active["artifact_path"]
                if path.exists():
                    self._set_risk(CreditRiskService(path), active["artifact_path"])
            self.model_version_id, self.model_version_label = active["id"], active["version"]
        shadow = self._one("SELECT * FROM model_versions WHERE status='shadow'")
        if shadow and (MODEL_DIR / shadow["artifact_path"]).exists():
            if not self.shadow or self.shadow[1] != shadow["id"]:
                self.shadow = (CreditRiskService(MODEL_DIR / shadow["artifact_path"]), shadow["id"])
            self.shadow_label = shadow["version"]
        else:
            self.shadow, self.shadow_label = None, None

    def _set_risk(self, svc: CreditRiskService, file: str | None) -> None:
        self.risk = svc
        self._risk_file = file
        ref = svc.reference_sample
        self._ref_inputs = ref[svc.features] if ref is not None else None
        self._ref_scores = svc.pipeline.predict_proba(self._ref_inputs)[:, 1] if ref is not None else None

    # ================================================================ platform owner
    def list_models(self, user: dict) -> list[dict]:
        require(user, "superadmin")
        rows = self._q("""SELECT m.*, (SELECT COUNT(*) FROM shadow_scores s WHERE s.model_version_id=m.id) AS shadow_n,
                          (SELECT COUNT(*) FROM applications a WHERE a.model_version_id=m.id) AS scored
                          FROM model_versions m ORDER BY m.id""")
        return rows

    def promote(self, user: dict, version_id: int, to: str) -> list[dict]:
        require(user, "superadmin")
        m = self._one("SELECT * FROM model_versions WHERE id=?", (version_id,))
        if not m:
            raise NotFound("Model version not found.", code="MODEL_NOT_FOUND")
        if (m["status"], to) not in TRANSITIONS:
            raise Conflict(f"A {m['status']} model cannot move to {to}.", code="MODEL_TRANSITION",
                           fields={"allowed": sorted(t for f, t in TRANSITIONS if f == m["status"])})
        path = MODEL_DIR / m["artifact_path"]
        if to in ("shadow", "active"):
            if not path.exists():
                raise BadRequest("The model file is not available on this server.", code="MODEL_FILE_MISSING")
            svc = CreditRiskService(path)
            if svc.reference_sample is not None:
                score_frame(svc, svc.reference_sample.head(5))      # must score without errors
        if to == "shadow":
            self.db.execute("UPDATE model_versions SET status='candidate' WHERE status='shadow'")
        if to == "active":
            self.db.execute("UPDATE model_versions SET status='retired' WHERE status='active'")
        self.db.execute("UPDATE model_versions SET status=?, promoted_at=? WHERE id=?", (to, db.now(), version_id))
        self._audit(user, "model.promoted", f"model:{version_id}", {"version": m["version"], "from": m["status"], "to": to})
        self.db.commit()
        self.load_models()
        return self.list_models(user)

    def shadow_report(self, user: dict, version_id: int) -> dict:
        require(user, "superadmin")
        m = self._one("SELECT * FROM model_versions WHERE id=?", (version_id,))
        if not m:
            raise NotFound("Model version not found.", code="MODEL_NOT_FOUND")
        live = self._q("SELECT * FROM shadow_scores WHERE model_version_id=?", (version_id,))
        good = ("excellent", "good")
        live_part = {
            "n": len(live),
            "agreement": round(sum(s["odds"] == s["active_odds"] for s in live) / len(live), 4) if live else None,
            "would_tighten": sum(1 for s in live if s["active_odds"] in good and s["odds"] not in good),
            "would_loosen": sum(1 for s in live if s["active_odds"] not in good and s["odds"] in good),
            "mean_abs_probability_change": (round(sum(abs(s["probability"] - s["active_probability"]) for s in live)
                                                  / len(live), 4) if live else None),
        }
        offline = None
        path = MODEL_DIR / m["artifact_path"]
        if path.exists() and self.risk.reference_sample is not None:
            other = CreditRiskService(path)
            ref = self.risk.reference_sample
            missing = [f for f in other.features if f not in ref.columns]
            if not missing:
                ra, pa = score_frame(self.risk, ref)
                rb, pb = score_frame(other, ref)
                oa = [odds_for(float(x), self.risk.threshold) for x in ra]
                ob = [odds_for(float(x), other.threshold) for x in rb]
                offline = {"n": len(ref), "agreement": round(sum(a == b for a, b in zip(oa, ob)) / len(ref), 4),
                           "would_tighten": sum(1 for a, b in zip(oa, ob) if a in good and b not in good),
                           "would_loosen": sum(1 for a, b in zip(oa, ob) if a not in good and b in good),
                           "mean_abs_probability_change": round(float(abs(pa - pb).mean()), 4)}
        return py({"version": m["version"], "status": m["status"], "metrics": m["metrics"],
                   "active_metrics": self._active_metrics(), "live": live_part, "offline": offline})

    def _active_metrics(self) -> dict | None:
        a = self._one("SELECT metrics FROM model_versions WHERE status='active'")
        return a["metrics"] if a else None


def _summary(svc: CreditRiskService) -> dict:
    m = svc.metrics
    test = m.get("test", {})
    fair = {}
    for attr, groups in (m.get("fairness") or {}).items():
        dis = [g.get("disparate_impact") for g in groups if g.get("disparate_impact") is not None]
        if dis:
            fair[attr] = round(min(dis), 4)
    return {"roc_auc": test.get("roc_auc"), "pr_auc": test.get("pr_auc"), "savings_pct": test.get("savings_pct"),
            "brier_calibrated": test.get("brier_calibrated"), "threshold": svc.threshold,
            "trained_at": m.get("trained_at"), "excluded_features": m.get("excluded_features", []),
            "worst_disparate_impact": fair}
