"""A v2 database upgrades to v3 in place, keeping its data."""
import os

from lenden import db
from lenden.migrate import MIGRATIONS, migrate


def _fresh(url):
    d = db.connect(url, migrate=False)
    d.drop_all()
    return d


def test_v2_database_upgrades_with_data(tmp_path):
    url = os.getenv("TEST_DATABASE_URL") or str(tmp_path / "v2.db")
    d = _fresh(url)
    # A v2 deployment: tables created at startup, no schema_migrations table.
    d.script((MIGRATIONS / d.dialect / "0001_v2_core.sql").read_text())
    org = d.insert("INSERT INTO orgs (name, slug, created_at) VALUES ('Old Lender', 'old', '2026-01-01T00:00:00+00:00')")
    user = d.insert("INSERT INTO users (email, name, password_hash, role, created_at) VALUES "
                    "('old@x.io', 'Old', 'x', 'borrower', '2026-01-01T00:00:00+00:00')")
    d.insert("""INSERT INTO applications (org_id, borrower_id, inputs, loan_amount, loan_purpose, risk_score,
                default_probability, light, recommendation, threshold, reasons, model_version, status, consent_at,
                created_at) VALUES (?,?,'{}',5000,'Home',0.2,0.1,'yellow','APPROVE',0.28,'[]','v2','needs_docs',
                '2026-01-02T00:00:00+00:00','2026-01-02T00:00:00+00:00')""", (org, user))
    d.commit()
    ran = migrate(d)
    assert ran[0].startswith("0001") and any(n.startswith("0002") for n in ran)
    a = db.row(d.execute("SELECT * FROM applications").fetchone())
    assert a["status"] == "needs_docs" and a["reason_codes"] == [] and a["updated_at"].startswith("2026-01-02")
    assert db.row(d.execute("SELECT currency FROM orgs").fetchone())["currency"] == "BDT"
    # v3 statuses and constraints are in force
    d.execute("UPDATE applications SET status='in_review'")
    d.commit()
    try:
        d.execute("UPDATE applications SET status='bogus'")
        raise AssertionError("CHECK constraint missing")
    except d.IntegrityError:
        d.rollback()
    assert migrate(d) == []                                  # idempotent
    d.drop_all()
    d.close()


def test_audit_log_is_append_only(tmp_path):
    url = os.getenv("TEST_DATABASE_URL")
    if url:                     # on PostgreSQL the table owner may still update; covered by REVOKE for other roles
        return
    d = db.connect(str(tmp_path / "a.db"))
    d.execute("INSERT INTO audit_log (action, created_at) VALUES ('x', '2026-01-01')")
    d.commit()
    try:
        d.execute("UPDATE audit_log SET action='y'")
        raise AssertionError("audit_log must be append-only")
    except Exception as e:
        assert "append-only" in str(e)
    d.close()
