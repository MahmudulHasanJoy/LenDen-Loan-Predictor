"""Create a demo database: 2 fictional lenders, staff, 200 borrowers with drafts, applications,
loans, repayment history and credit-ladder levels.

    python -m lenden.seed                    # local SQLite: var/lenden.db (overwritten)
    python -m lenden.seed --reset            # DATABASE_URL set: wipes and re-seeds PostgreSQL

All demo accounts use the password  demo1234. Demographics (gender, age band) are synthetic and
exist only to demonstrate fairness monitoring.
"""
from __future__ import annotations

import argparse
import random
from datetime import timedelta
from pathlib import Path

import pandas as pd

from credit_risk.offers import ladder_cap

from . import clock, db
from .services import Platform
from .settings import MODEL_PATH, ROOT, database_target

PASSWORD = "demo1234"
FIRST = ["Ayesha", "Tanvir", "Nusrat", "Rafiq", "Farhana", "Imran", "Sadia", "Karim", "Mitu", "Arif",
         "Tania", "Jahid", "Rumana", "Sohel", "Lamia", "Fahim", "Shirin", "Rakib", "Nadia", "Hasan"]
LAST = ["Rahman", "Hossain", "Ahmed", "Islam", "Chowdhury", "Khan", "Akter", "Sarker", "Uddin", "Begum"]
PROFILES = ROOT / "artifacts" / "demo_profiles.csv.gz"

LENDERS = [
    {"name": "GreenField Microfinance", "plan": "pro", "slug": "greenfield",
     "staff": [("admin", "Nasrin Sultana"), ("officer", "Mahmud Karim"), ("officer", "Sharmin Akter")],
     "rules": {"base_rate": 11.0, "rate_step": 2.5}, "settings": {}},
    {"name": "Riverside Credit Union", "plan": "free", "slug": "riverside",
     "staff": [("admin", "Kamal Uddin"), ("officer", "Rina Das")],
     "rules": {"base_rate": 13.0, "rate_step": 3.0, "max_amount": 150000, "terms": [12, 24, 36]},
     "settings": {"cost_ratio": 15, "review_capacity": 0.30, "sla_hours": 72}},
]
REJECT_CODES = [["INCOME_LOW", "DTI_HIGH"], ["CREDIT_SCORE_LOW"], ["EMPLOYMENT_SHORT", "INCOME_LOW"], ["AMOUNT_HIGH"]]


def _fit(amount: float, cap: float, share: float = 1.0) -> float:
    """An amount within the ladder cap, rounded down to a thousand."""
    return float(max(5000, int(min(amount, cap) * share // 1000) * 1000))


def _age_band(age) -> str:
    try:
        a = int(age)
    except (TypeError, ValueError):
        return "undisclosed"
    return "18-25" if a <= 25 else "26-35" if a <= 35 else "36-45" if a <= 45 else "46-55" if a <= 55 else "56+"


def _profiles(platform: Platform, n: int, seed: int) -> pd.DataFrame:
    if PROFILES.exists():
        return pd.read_csv(PROFILES).sample(n, random_state=seed).reset_index(drop=True)
    return platform.risk.reference_sample.sample(n, random_state=seed).reset_index(drop=True)


def _at(dt):
    clock.freeze(dt)


def _history(platform: Platform, borrower: dict, org: dict, officer: dict, inputs: dict, loans: int,
             start, rng: random.Random, demo: dict) -> None:
    """Past 6-month loans, repaid on time, that earned the borrower their credit level."""
    t = start
    for _ in range(loans):
        level = platform._level(borrower["id"], org["org"]["id"])
        cap = ladder_cap(platform._settings(org["org"]["id"])["offer_rules"], level)
        amount = _fit(inputs["LoanAmount"], cap, rng.uniform(0.6, 1.0))
        _at(t)
        app = platform.apply(borrower, org["org"]["id"], {**inputs, "LoanAmount": amount, "LoanTerm": 12}, consent=True,
                             demographics=demo)
        _at(t + timedelta(hours=rng.randint(3, 30)))
        platform.claim(officer, app["id"])
        platform.decide(officer, app["id"], "approved", "Approved.", terms={"term": 6})
        loan = platform._one("SELECT * FROM loans WHERE application_id=?", (app["id"],))
        for r in platform._q("SELECT * FROM repayments WHERE loan_id=? ORDER BY seq", (loan["id"],)):
            due = clock.parse(r["due_date"] + "T10:00:00")
            _at(due - timedelta(days=rng.randint(0, 3)))
            platform.pay(borrower, loan["id"])
        t = clock.utcnow() + timedelta(days=rng.randint(5, 25))


def _open_loan(platform: Platform, borrower: dict, org: dict, officer: dict, inputs: dict, start, now,
               rng: random.Random, demo: dict) -> None:
    """A 12-month loan taken a few months ago, paid with some delays (shows arrears in the portfolio)."""
    level = platform._level(borrower["id"], org["org"]["id"])
    cap = ladder_cap(platform._settings(org["org"]["id"])["offer_rules"], level)
    amount = _fit(inputs["LoanAmount"], cap, 0.8)
    _at(start)
    app = platform.apply(borrower, org["org"]["id"], {**inputs, "LoanAmount": amount, "LoanTerm": 12}, consent=True,
                         demographics=demo)
    _at(start + timedelta(hours=20))
    platform.claim(officer, app["id"])
    platform.decide(officer, app["id"], "approved", "Approved.")
    loan = platform._one("SELECT * FROM loans WHERE application_id=?", (app["id"],))
    for r in platform._q("SELECT * FROM repayments WHERE loan_id=? ORDER BY seq", (loan["id"],)):
        due = clock.parse(r["due_date"] + "T10:00:00")
        if due >= now or rng.random() < 0.18:
            break                                  # stops paying: later instalments go late or missed
        _at(min(due + timedelta(days=rng.choice([0, 0, 1, 2, 6, 11])), now - timedelta(hours=1)))
        platform.pay(borrower, loan["id"])


def build(platform: Platform, n_borrowers: int = 200, seed: int = 7) -> dict:
    rng = random.Random(seed)
    conn = platform.db
    platform.hash_iterations = 20_000      # demo accounts only: fast to create on a free server
    platform.lean = True
    real_now = clock.utcnow()
    try:
        super_admin = platform._create_user("super@lenden.app", "Platform Owner", PASSWORD, "superadmin")
        orgs = []
        for spec in LENDERS:
            created = platform.create_org(super_admin, spec["name"], spec["plan"], f"admin@{spec['slug']}.demo",
                                          spec["staff"][0][1], PASSWORD)
            admin = created["admin"]
            officers = [platform.add_team_member(admin, f"{name.split()[0].lower()}@{spec['slug']}.demo",
                                                 name, PASSWORD, role) for role, name in spec["staff"][1:]]
            platform.update_offer_rules(admin, spec["rules"])
            if spec["settings"]:
                platform.update_settings(admin, **spec["settings"])
            orgs.append({"org": created["org"], "admin": admin, "officers": officers})
        conn.commit()

        profiles = _profiles(platform, n_borrowers, seed)
        features = platform.risk.features
        history_start = real_now - timedelta(days=1000)
        for i, p in profiles.iterrows():
            idx = i + 1
            name = f"{rng.choice(FIRST)} {rng.choice(LAST)}"
            inputs = {k: (p[k].item() if hasattr(p[k], "item") else p[k]) for k in features}
            demo = {"gender": rng.choices(["female", "male", "undisclosed"], [45, 45, 10])[0],
                    "age_band": _age_band(p.get("Age")) if rng.random() > 0.1 else "undisclosed"}
            target = orgs[0] if rng.random() < 0.65 else orgs[1]
            officer = rng.choice(target["officers"])
            joined = history_start + timedelta(days=rng.randint(0, 30))
            _at(joined)
            phone = f"+88017{idx:08d}"
            b = platform._create_user(f"borrower{idx}@demo.app", name, PASSWORD, "borrower", phone=phone)
            conn.execute("UPDATE users SET phone_verified_at=? WHERE id=?", (db.now(), b["id"]))

            # Credit history: about 1 in 3 borrowers repaid earlier loans and climbed the ladder.
            roll = rng.random()
            past = 4 if roll < 0.08 else 2 if roll < 0.20 else 1 if roll < 0.40 else 0
            if past:
                _history(platform, b, target, officer, inputs, past, joined + timedelta(days=2), rng, demo)
            if rng.random() < 0.12:
                _open_loan(platform, b, target, officer, inputs, real_now - timedelta(days=rng.randint(70, 200)),
                           real_now, rng, demo)

            # Today's application: within the last 14 days, amount within the borrower's ladder cap.
            created = real_now - timedelta(days=rng.randint(0, 13), hours=rng.randint(1, 20))
            level = platform._level(b["id"], target["org"]["id"])
            cap = ladder_cap(platform._settings(target["org"]["id"])["offer_rules"], level)
            amount = _fit(inputs["LoanAmount"], cap)
            cur = {**inputs, "LoanAmount": amount}
            _at(created)
            if rng.random() < 0.35:                       # came through the v3 wizard and offers
                d = platform.create_draft(b, cur, step=4, demographics=demo)["draft"]
                _at(created + timedelta(minutes=rng.randint(3, 11)))
                offers = platform.draft_offers(d["id"], b, None)["offers"]
                pick = next((o for o in offers if o["org_id"] == target["org"]["id"]), None)
                if pick and pick["best"]["amount"] <= cap + 0.5 and not pick["has_open_application"]:
                    app = platform.apply(b, consent=True, offer_id=pick["offer_id"])
                else:
                    app = platform.apply(b, target["org"]["id"], cur, consent=True, demographics=demo)
            else:
                app = platform.apply(b, target["org"]["id"], cur, consent=True, demographics=demo)

            r = rng.random()
            if r < 0.6:                                   # decided by an officer
                _at(created + timedelta(hours=rng.randint(1, 6)))
                platform.claim(officer, app["id"])
                full = platform.get_application(officer, app["id"])
                follow = rng.random() < 0.85
                approve = (full["recommendation"] == "APPROVE") == follow
                _at(min(created + timedelta(hours=rng.randint(8, 60)), real_now))
                if not approve and rng.random() < 0.3:
                    platform.decide(officer, app["id"], "needs_docs", "Please upload 3 months of bank statements.",
                                    documents=["bank_statements_3m"])
                elif approve:
                    platform.decide(officer, app["id"], "approved", "Approved. Welcome aboard!")
                else:
                    platform.decide(officer, app["id"], "rejected", "", reason_codes=rng.choice(REJECT_CODES))
            elif r < 0.75:                                # an officer has picked it up
                _at(created + timedelta(hours=rng.randint(1, 10)))
                platform.claim(officer, app["id"])

        # Abandoned drafts, so the funnel has drop-off to show.
        for k in range(max(4, n_borrowers // 5)):
            _at(real_now - timedelta(days=rng.randint(0, 6), hours=rng.randint(0, 23)))
            step = rng.choice([1, 1, 2, 2, 3])
            p = profiles.iloc[k % len(profiles)]
            inputs = {f: (p[f].item() if hasattr(p[f], "item") else p[f]) for f in features}
            keep = [f for s in range(1, step + 1) for f in {1: ["Income", "LoanAmount", "LoanPurpose"],
                                                             2: ["LoanTerm", "EmploymentType", "MonthsEmployed"],
                                                             3: ["CreditScore", "DTIRatio"]}[s]]
            platform.create_draft(None, {f: inputs[f] for f in keep}, step=step)
        conn.commit()
    finally:
        clock.reset()
        platform.hash_iterations = None
        platform.lean = False
    # Bring repayment statuses up to date (late / missed instalments, reminders).
    platform.run_repayment_checks()
    # Demo accounts have no real inboxes: mark the demo's emails and texts as already handled.
    conn.execute("UPDATE outbox SET processed_at=? WHERE processed_at IS NULL", (db.now(),))
    conn.commit()
    return {"orgs": orgs, "super_admin": super_admin}


def main(argv=None):
    from credit_risk.service import CreditRiskService
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--db", default=None, help="SQLite path or PostgreSQL URL (default: DATABASE_URL, else var/lenden.db)")
    ap.add_argument("--borrowers", type=int, default=200)
    ap.add_argument("--reset", action="store_true", help="delete ALL existing LenDen tables first (required for PostgreSQL)")
    args = ap.parse_args(argv)
    target = args.db or database_target()
    if db.is_postgres_url(target):
        if not args.reset:
            ap.error("refusing to touch a PostgreSQL database without --reset (it deletes all data)")
    else:
        Path(target).unlink(missing_ok=True)
    database = db.connect(target, migrate=not args.reset)
    if args.reset:
        database.drop_all()
        database.init_schema()
    platform = Platform(database, CreditRiskService(MODEL_PATH), model_path=MODEL_PATH)
    build(platform, args.borrowers)
    print(f"Demo data written to {'PostgreSQL' if database.dialect == 'postgres' else target}")
    print("Logins (password: demo1234):")
    print("  super admin : super@lenden.app")
    for spec in LENDERS:
        print(f"  {spec['name']}: admin@{spec['slug']}.demo, "
              + ", ".join(f"{n.split()[0].lower()}@{spec['slug']}.demo" for _, n in spec['staff'][1:]))
    print(f"  borrowers   : borrower1@demo.app ... borrower{args.borrowers}@demo.app")


if __name__ == "__main__":
    main()
