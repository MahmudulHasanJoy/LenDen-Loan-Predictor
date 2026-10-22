"""Credit ladder: start small, grow with on-time repayment.

    L1 Starter  10% of the lender's max amount   verified account, consent given
    L2 Builder  25%                              1 loan repaid on time
    L3 Trusted  50%                              2 loans repaid, no payment over 7 days late
    L4 Prime   100%                              4 loans repaid, no missed payment in 12 months

A payment missed by more than 30 days drops the borrower one level.
"""
from __future__ import annotations

LEVELS = [
    {"level": 1, "name": "Starter"},
    {"level": 2, "name": "Builder"},
    {"level": 3, "name": "Trusted"},
    {"level": 4, "name": "Prime"},
]


def earned_level(closed_loans: list[dict], missed_last_12m: int) -> int:
    """closed_loans: [{"on_time": bool, "max_days_late": int}] for loans repaid in full."""
    repaid = len(closed_loans)
    on_time = sum(1 for loan in closed_loans if loan["on_time"])
    within_week = all(loan["max_days_late"] <= 7 for loan in closed_loans)
    if repaid >= 4 and missed_last_12m == 0:
        return 4
    if repaid >= 2 and within_week:
        return 3
    if on_time >= 1:
        return 2
    return 1


def next_requirement(level: int) -> str | None:
    return {1: "LADDER_REPAY_ONE", 2: "LADDER_REPAY_TWO", 3: "LADDER_REPAY_FOUR"}.get(level)
