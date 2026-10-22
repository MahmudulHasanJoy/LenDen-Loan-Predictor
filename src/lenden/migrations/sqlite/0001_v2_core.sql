-- 0001: LenDen v2 schema (orgs, users, org_settings, applications, audit_log).
-- Idempotent so it can run on a v2 database that was created before migrations existed.


CREATE TABLE IF NOT EXISTS orgs (
    id          INTEGER PRIMARY KEY,
    name        TEXT NOT NULL,
    slug        TEXT NOT NULL UNIQUE,
    plan        TEXT NOT NULL DEFAULT 'free',
    active      INTEGER NOT NULL DEFAULT 1,
    created_at  TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS users (
    id            INTEGER PRIMARY KEY,
    email         TEXT NOT NULL UNIQUE,
    name          TEXT NOT NULL,
    password_hash TEXT NOT NULL,
    role          TEXT NOT NULL CHECK (role IN ('borrower','officer','admin','superadmin')),
    org_id        INTEGER REFERENCES orgs(id),
    active        INTEGER NOT NULL DEFAULT 1,
    created_at    TEXT NOT NULL,
    CHECK ((role IN ('officer','admin')) = (org_id IS NOT NULL))
);

CREATE TABLE IF NOT EXISTS org_settings (
    org_id          INTEGER PRIMARY KEY REFERENCES orgs(id),
    cost_ratio      INTEGER NOT NULL DEFAULT 20,
    review_capacity REAL,
    updated_at      TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS applications (
    id                  INTEGER PRIMARY KEY,
    org_id              INTEGER NOT NULL REFERENCES orgs(id),
    borrower_id         INTEGER NOT NULL REFERENCES users(id),
    inputs              TEXT NOT NULL,
    loan_amount         REAL NOT NULL,
    loan_purpose        TEXT NOT NULL,
    risk_score          REAL NOT NULL,
    default_probability REAL NOT NULL,
    light               TEXT NOT NULL,
    recommendation      TEXT NOT NULL CHECK (recommendation IN ('APPROVE','REVIEW')),
    threshold           REAL NOT NULL,
    reasons             TEXT NOT NULL,
    model_version       TEXT NOT NULL,
    status              TEXT NOT NULL DEFAULT 'submitted'
                        CHECK (status IN ('submitted','needs_docs','approved','rejected')),
    consent_at          TEXT NOT NULL,
    created_at          TEXT NOT NULL,
    decided_at          TEXT,
    decided_by          INTEGER REFERENCES users(id),
    decision_note       TEXT
);
CREATE INDEX IF NOT EXISTS ix_app_org_status ON applications(org_id, status);
CREATE INDEX IF NOT EXISTS ix_app_borrower ON applications(borrower_id);
CREATE INDEX IF NOT EXISTS ix_app_decided_by ON applications(decided_by);
CREATE INDEX IF NOT EXISTS ix_users_org ON users(org_id);

CREATE TABLE IF NOT EXISTS audit_log (
    id         INTEGER PRIMARY KEY,
    org_id     INTEGER,
    user_id    INTEGER,
    action     TEXT NOT NULL,
    target     TEXT,
    detail     TEXT,
    created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS ix_audit_org ON audit_log(org_id, id);
