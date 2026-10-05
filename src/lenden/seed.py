"""Create a demo database: 2 fictional lenders, staff, 200 borrowers and their applications.

    python -m lenden.seed                    # local SQLite: var/lenden.db (overwritten)
    python -m lenden.seed --reset            # DATABASE_URL set: wipes and re-seeds PostgreSQL

All demo accounts use the password  demo1234
"""
import argparse
import random
from datetime import datetime, timedelta, timezone
from pathlib import Path

from credit_risk.service import CreditRiskService

from . import db
from .services import Platform
from .settings import MODEL_PATH, database_target

PASSWORD = "demo1234"
FIRST = ["Ayesha", "Tanvir", "Nusrat", "Rafiq", "Farhana", "Imran", "Sadia", "Karim", "Mitu", "Arif",
         "Tania", "Jahid", "Rumana", "Sohel", "Lamia", "Fahim", "Shirin", "Rakib", "Nadia", "Hasan"]
LAST = ["Rahman", "Hossain", "Ahmed", "Islam", "Chowdhury", "Khan", "Akter", "Sarker", "Uddin", "Begum"]

LENDERS = [
    {"name": "GreenField Microfinance", "plan": "pro", "slug": "greenfield",
     "staff": [("admin", "Nasrin Sultana"), ("officer", "Mahmud Karim"), ("officer", "Sharmin Akter")]},
    {"name": "Riverside Credit Union", "plan": "free", "slug": "riverside",
     "staff": [("admin", "Kamal Uddin"), ("officer", "Rina Das")]},
]


def build(platform: Platform, n_borrowers: int = 200, seed: int = 7) -> dict:
    rng = random.Random(seed)
    conn = platform.db
    # Demo accounts only: fewer hashing rounds so 200 users seed in seconds on a free server.
    platform.hash_iterations = 20_000
    super_admin = platform._create_user("super@lenden.app", "Platform Owner", PASSWORD, "superadmin")
    conn.commit()

    orgs = []
    for spec in LENDERS:
        created = platform.create_org(super_admin, spec["name"], spec["plan"],
                                      f"admin@{spec['slug']}.demo", spec["staff"][0][1], PASSWORD)
        admin = created["admin"]
        officers = [platform.add_team_member(admin, f"{name.split()[0].lower()}@{spec['slug']}.demo",
                                             name, PASSWORD, role)
                    for role, name in spec["staff"][1:]]
        orgs.append({"org": created["org"], "admin": admin, "officers": officers})
    platform.update_settings(orgs[1]["admin"], cost_ratio=15, review_capacity=0.30)

    # Real applicant profiles from the training sample stored inside the model artifact,
    # so demo data can be created without the dataset (e.g. on a fresh server).
    profiles = platform.risk.reference_sample.sample(n_borrowers, random_state=seed)[platform.risk.features]
    now = datetime.now(timezone.utc)
    for i, (_, p) in enumerate(profiles.iterrows(), start=1):
        name = f"{rng.choice(FIRST)} {rng.choice(LAST)}"
        b = platform.register_borrower(f"borrower{i}@demo.app", name, PASSWORD)["user"]
        target = orgs[0] if rng.random() < 0.65 else orgs[1]
        inputs = {k: (v.item() if hasattr(v, "item") else v) for k, v in p.to_dict().items()}
        app = platform.apply(b, target["org"]["id"], inputs, consent=True)
        created = now - timedelta(days=rng.randint(0, 13), hours=rng.randint(0, 20))
        conn.execute("UPDATE applications SET created_at=?, consent_at=? WHERE id=?",
                     (created.isoformat(timespec="seconds"),) * 2 + (app["id"],))

        # About 60% already decided by an officer, mostly following the recommendation.
        if rng.random() < 0.6:
            officer = rng.choice(target["officers"])
            full = platform.get_application(officer, app["id"])
            follow = rng.random() < 0.85
            approve = (full["recommendation"] == "APPROVE") == follow
            if not approve and rng.random() < 0.3:
                decision, note = "needs_docs", "Please upload 3 months of bank statements."
            elif approve:
                decision, note = "approved", "Approved. Welcome aboard!"
            else:
                decision, note = "rejected", "Income is not sufficient for the requested amount right now."
            platform.decide(officer, app["id"], decision, note)
            decided = created + timedelta(hours=rng.randint(2, 60))
            conn.execute("UPDATE applications SET decided_at=? WHERE id=?",
                         (min(decided, now).isoformat(timespec="seconds"), app["id"]))
    conn.commit()
    platform.hash_iterations = None
    return {"orgs": orgs, "super_admin": super_admin}


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--db", default=None,
                    help="SQLite path or PostgreSQL URL (default: DATABASE_URL, else var/lenden.db)")
    ap.add_argument("--borrowers", type=int, default=200)
    ap.add_argument("--reset", action="store_true",
                    help="delete ALL existing LenDen tables first (required for PostgreSQL)")
    args = ap.parse_args(argv)
    target = args.db or database_target()
    if db.is_postgres_url(target):
        if not args.reset:
            ap.error("refusing to touch a PostgreSQL database without --reset (it deletes all data)")
    else:
        Path(target).unlink(missing_ok=True)
    database = db.connect(target)
    if args.reset:
        database.drop_all()
        database.init_schema()
    platform = Platform(database, CreditRiskService(MODEL_PATH))
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
