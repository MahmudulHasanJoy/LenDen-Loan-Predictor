"""Approval-odds labels relative to a lender's own threshold.

The model's raw risk score is compared with the lender's cost-optimal threshold t (the same
number the officer queue uses), so the label stays honest when a lender tightens or loosens policy:

    excellent  score < 0.75 t       good  0.75 t <= score < t
    fair       t <= score < 1.75 t  low   score >= 1.75 t

The bands were set on the model's reference population: with the default 20:1 cost ratio about
10% of applicants are "excellent", 10% "good", 45% "fair" and 35% "low". Below t the officer
queue recommends approval; between t and 1.75 t the case goes to an officer with a real chance.
"""
from __future__ import annotations

ODDS = ("excellent", "good", "fair", "low")
RANK = {o: i for i, o in enumerate(ODDS)}


def odds_for(score: float, threshold: float) -> str:
    if score < 0.75 * threshold:
        return "excellent"
    if score < threshold:
        return "good"
    if score < 1.75 * threshold:
        return "fair"
    return "low"


def better(a: str, b: str) -> bool:
    """True when odds `a` are better than `b`."""
    return RANK[a] < RANK[b]
