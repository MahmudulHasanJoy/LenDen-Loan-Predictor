"""Loans after approval: repayment schedule, (mock) payments, and the credit ladder."""
from __future__ import annotations

import calendar
from datetime import date, timedelta

from credit_risk.ladder import LEVELS, earned_level, next_requirement
from credit_risk.offers import ladder_cap

from .. import clock, db
from ..errors import BadRequest, Conflict, NotFound
from ..security import require
from .base import Base, py

GRACE_DAYS = 3        # paid within 3 days of the due date still counts as on time
MISSED_DAYS = 30      # unpaid 30 days after the due date = missed (drops one ladder level)


def add_months(d: date, n: int) -> date:
    m = d.month - 1 + n
    y, m = d.year + m // 12, m % 12 + 1
    return date(y, m, min(d.day, calendar.monthrange(y, m)[1]))


class Loans(Base):
    # ================================================================ creation
    def _create_loan(self, app: dict, terms: dict) -> int:
        start = clock.today()
        loan_id = self.db.insert(
            """INSERT INTO loans (application_id, org_id, borrower_id, principal, annual_rate, term_months, emi,
               start_date, created_at) VALUES (?,?,?,?,?,?,?,?,?)""",
            (app["id"], app["org_id"], app["borrower_id"], terms["amount"], terms["rate"], terms["term"],
             terms["emi"], start.isoformat(), db.now()))
        total = round(terms["emi"] * terms["term"], 2)
        paid_so_far = 0.0
        for i in range(1, terms["term"] + 1):
            amount = terms["emi"] if i < terms["term"] else round(total - paid_so_far, 2)
            paid_so_far = round(paid_so_far + amount, 2)
            self.db.execute("INSERT INTO repayments (loan_id, seq, due_date, amount_due) VALUES (?,?,?,?)",
                            (loan_id, i, add_months(start, i).isoformat(), amount))
        self._ensure_level(app["borrower_id"], app["org_id"])
        self._audit({"id": None}, "loan.created", f"loan:{loan_id}", {"application_id": app["id"]},
                    org_id=app["org_id"])
        return loan_id

    # ================================================================ views
    def _loan_view(self, loan: dict, with_schedule: bool = True) -> dict:
        sched = self._q("SELECT id, seq, due_date, amount_due, amount_paid, paid_at, status FROM repayments "
                        "WHERE loan_id=? ORDER BY seq", (loan["id"],))
        paid = sum(r["amount_paid"] for r in sched)
        due_total = sum(r["amount_due"] for r in sched)
        nxt = next((r for r in sched if r["status"] != "paid"), None)
        out = {**loan, "lender": self._org(loan["org_id"])["name"], "total_repayable": round(due_total, 2),
               "paid": round(paid, 2), "outstanding": round(due_total - paid, 2),
               "installments_paid": sum(r["status"] == "paid" for r in sched), "installments": len(sched),
               "next_due": nxt, "overdue": [r for r in sched if r["status"] in ("late", "missed")]}
        if with_schedule:
            out["schedule"] = sched
        return py(out)

    def _get_loan(self, user: dict, loan_id: int) -> dict:
        loan = self._one("SELECT * FROM loans WHERE id=?", (loan_id,))
        ok = loan and ((user["role"] == "borrower" and loan["borrower_id"] == user["id"])
                       or (user["role"] in ("officer", "admin") and loan["org_id"] == user["org_id"]))
        if not ok:
            raise NotFound("Loan not found.", code="LOAN_NOT_FOUND")
        return loan

    def my_loans(self, borrower: dict) -> list[dict]:
        require(borrower, "borrower")
        loans = self._q("SELECT * FROM loans WHERE borrower_id=? ORDER BY id DESC", (borrower["id"],))
        return [self._loan_view(loan, with_schedule=False) for loan in loans]

    def loan_detail(self, user: dict, loan_id: int) -> dict:
        return self._loan_view(self._get_loan(user, loan_id))

    def org_loans(self, user: dict, status: str | None = None) -> list[dict]:
        require(user, "officer", "admin")
        where, args = "l.org_id=?", [user["org_id"]]
        if status:
            where += " AND l.status=?"
            args.append(status)
        loans = self._q(f"SELECT l.*, u.name AS borrower_name FROM loans l JOIN users u ON u.id=l.borrower_id "
                        f"WHERE {where} ORDER BY l.id DESC LIMIT 200", args)
        return [self._loan_view(loan, with_schedule=False) for loan in loans]

    # ================================================================ payments (mock gateway)
    def pay(self, borrower: dict, loan_id: int, amount: float | None = None) -> dict:
        require(borrower, "borrower")
        loan = self._get_loan(borrower, loan_id)
        if loan["status"] != "active":
            raise Conflict("This loan is already closed.", code="LOAN_CLOSED")
        unpaid = self._q("SELECT * FROM repayments WHERE loan_id=? AND status<>'paid' ORDER BY seq", (loan_id,))
        if not unpaid:
            raise Conflict("Nothing is due on this loan.", code="NOTHING_DUE")
        left = round(float(amount if amount is not None else unpaid[0]["amount_due"] - unpaid[0]["amount_paid"]), 2)
        outstanding = round(sum(r["amount_due"] - r["amount_paid"] for r in unpaid), 2)
        if left <= 0:
            raise BadRequest("Enter an amount above zero.", code="AMOUNT_INVALID")
        if left > outstanding + 0.01:
            raise BadRequest(f"The most you can pay is {outstanding:,.2f}.", code="AMOUNT_TOO_HIGH",
                             fields={"max": outstanding})
        now = db.now()
        for r in unpaid:
            if left <= 0:
                break
            owed = round(r["amount_due"] - r["amount_paid"], 2)
            take = min(owed, left)
            left = round(left - take, 2)
            new_paid = round(r["amount_paid"] + take, 2)
            if new_paid + 0.005 >= r["amount_due"]:
                self.db.execute("UPDATE repayments SET amount_paid=?, paid_at=?, status='paid' WHERE id=?",
                                (r["amount_due"], now, r["id"]))
            else:
                self.db.execute("UPDATE repayments SET amount_paid=? WHERE id=?", (new_paid, r["id"]))
        self._audit(borrower, "repayment.recorded", f"loan:{loan_id}", {"amount": amount}, org_id=loan["org_id"])
        if not self._scalar("SELECT COUNT(*) FROM repayments WHERE loan_id=? AND status<>'paid'", (loan_id,)):
            self.db.execute("UPDATE loans SET status='closed', closed_at=? WHERE id=?", (now, loan_id))
            before = self._level(borrower["id"], loan["org_id"])
            after = self._recompute_level(borrower["id"], loan["org_id"])
            self._notify(borrower["id"], "loan.closed", {"loan_id": loan_id, "lender": self._org(loan["org_id"])["name"],
                                                         "level_before": before, "level_after": after})
        return self.loan_detail(borrower, loan_id)

    # ================================================================ credit ladder
    def _level(self, borrower_id: int | None, org_id: int) -> int:
        if not borrower_id:
            return 1
        v = self._scalar("SELECT level FROM borrower_levels WHERE borrower_id=? AND org_id=?", (borrower_id, org_id))
        return int(v) if v else 1

    def _ensure_level(self, borrower_id: int, org_id: int) -> None:
        if self._scalar("SELECT level FROM borrower_levels WHERE borrower_id=? AND org_id=?", (borrower_id, org_id)) is None:
            self.db.execute("INSERT INTO borrower_levels (borrower_id, org_id, level, loans_repaid, updated_at) "
                            "VALUES (?,?,?,?,?)", (borrower_id, org_id, 1, 0, db.now()))

    def _set_level(self, borrower_id: int, org_id: int, level: int, loans_repaid: int | None = None) -> None:
        self._ensure_level(borrower_id, org_id)
        if loans_repaid is None:
            self.db.execute("UPDATE borrower_levels SET level=?, updated_at=? WHERE borrower_id=? AND org_id=?",
                            (level, db.now(), borrower_id, org_id))
        else:
            self.db.execute("UPDATE borrower_levels SET level=?, loans_repaid=?, updated_at=? WHERE borrower_id=? "
                            "AND org_id=?", (level, loans_repaid, db.now(), borrower_id, org_id))

    def _recompute_level(self, borrower_id: int, org_id: int) -> int:
        """Promotion after a loan is repaid. Levels only go down through missed payments."""
        closed = []
        for loan in self._q("SELECT id FROM loans WHERE borrower_id=? AND org_id=? AND status='closed'",
                            (borrower_id, org_id)):
            late_days = [max(0, (clock.parse(r["paid_at"]).date() - date.fromisoformat(r["due_date"])).days)
                         for r in self._q("SELECT due_date, paid_at FROM repayments WHERE loan_id=?", (loan["id"],))]
            worst = max(late_days or [0])
            closed.append({"on_time": worst <= GRACE_DAYS, "max_days_late": worst})
        year_ago = (clock.today() - timedelta(days=365)).isoformat()
        missed = 0
        for r in self._q("""SELECT r.due_date, r.paid_at, r.status FROM repayments r JOIN loans l ON l.id=r.loan_id
                            WHERE l.borrower_id=? AND l.org_id=? AND r.due_date>=?""", (borrower_id, org_id, year_ago)):
            if r["status"] == "missed" or (r["paid_at"] and (clock.parse(r["paid_at"]).date()
                                                             - date.fromisoformat(r["due_date"])).days > MISSED_DAYS):
                missed += 1
        current = self._level(borrower_id, org_id)
        new = max(current, earned_level(closed, missed))
        self._set_level(borrower_id, org_id, new, loans_repaid=len(closed))
        if new > current:
            self._audit({"id": borrower_id}, "ladder.promoted", f"user:{borrower_id}", {"from": current, "to": new},
                        org_id=org_id)
        return new

    def _demote(self, borrower_id: int, org_id: int) -> int:
        current = self._level(borrower_id, org_id)
        new = max(1, current - 1)
        if new != current:
            self._set_level(borrower_id, org_id, new)
            self._audit({"id": borrower_id}, "ladder.demoted", f"user:{borrower_id}", {"from": current, "to": new},
                        org_id=org_id)
        return new

    def my_levels(self, borrower: dict) -> list[dict]:
        out = []
        for org in self._q("SELECT id, name, currency FROM orgs WHERE active=1 ORDER BY name"):
            lvl = self._level(borrower["id"], org["id"])
            rules = self._settings(org["id"])["offer_rules"]
            repaid = self._scalar("SELECT loans_repaid FROM borrower_levels WHERE borrower_id=? AND org_id=?",
                                  (borrower["id"], org["id"])) or 0
            out.append({"org_id": org["id"], "lender": org["name"], "currency": org["currency"], "level": lvl,
                        "name": LEVELS[lvl - 1]["name"], "max_amount": round(ladder_cap(rules, lvl), 2),
                        "next_level_max": round(ladder_cap(rules, lvl + 1), 2) if lvl < 4 else None,
                        "loans_repaid": repaid, "next_requirement": next_requirement(lvl)})
        return out

    # ================================================================ daily job
    def run_repayment_checks(self) -> dict:
        """Mark late and missed instalments, remind borrowers 3 days before a due date."""
        today = clock.today()
        late = missed = reminded = 0
        for r in self._q("""SELECT r.*, l.borrower_id, l.org_id FROM repayments r JOIN loans l ON l.id=r.loan_id
                            WHERE l.status='active' AND r.status IN ('due','late') AND r.due_date<?""",
                         (today.isoformat(),)):
            overdue = (today - date.fromisoformat(r["due_date"])).days
            if overdue > MISSED_DAYS and r["status"] != "missed":
                self.db.execute("UPDATE repayments SET status='missed' WHERE id=?", (r["id"],))
                level = self._demote(r["borrower_id"], r["org_id"])
                self._notify(r["borrower_id"], "repayment.missed", {"loan_id": r["loan_id"], "seq": r["seq"],
                                                                     "amount": r["amount_due"], "level": level})
                missed += 1
            elif overdue > GRACE_DAYS and r["status"] == "due":
                self.db.execute("UPDATE repayments SET status='late' WHERE id=?", (r["id"],))
                self._notify(r["borrower_id"], "repayment.late", {"loan_id": r["loan_id"], "seq": r["seq"],
                                                                   "amount": r["amount_due"], "days": overdue})
                late += 1
        soon = (today + timedelta(days=3)).isoformat()
        for r in self._q("""SELECT r.*, l.borrower_id FROM repayments r JOIN loans l ON l.id=r.loan_id
                            WHERE l.status='active' AND r.status='due' AND r.due_date=?""", (soon,)):
            self._notify(r["borrower_id"], "repayment.due_soon", {"loan_id": r["loan_id"], "seq": r["seq"],
                                                                   "amount": r["amount_due"], "due_date": r["due_date"]})
            reminded += 1
        return {"late": late, "missed": missed, "reminded": reminded}
