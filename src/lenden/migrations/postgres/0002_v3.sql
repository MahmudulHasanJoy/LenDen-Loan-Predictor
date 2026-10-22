-- 0002: LenDen v3. New columns on v2 tables plus drafts, offers, timeline, documents, loans,
-- repayments, credit ladder, consents, notifications, outbox, auth tokens and the model registry.

ALTER TABLE orgs ADD COLUMN IF NOT EXISTS currency TEXT NOT NULL DEFAULT 'BDT';
ALTER TABLE orgs ADD COLUMN IF NOT EXISTS locale TEXT NOT NULL DEFAULT 'en';

ALTER TABLE users ADD COLUMN IF NOT EXISTS phone TEXT;
ALTER TABLE users ADD COLUMN IF NOT EXISTS locale TEXT NOT NULL DEFAULT 'en';
ALTER TABLE users ADD COLUMN IF NOT EXISTS email_verified_at TEXT;
ALTER TABLE users ADD COLUMN IF NOT EXISTS phone_verified_at TEXT;
ALTER TABLE users ADD COLUMN IF NOT EXISTS totp_secret TEXT;
ALTER TABLE users ADD COLUMN IF NOT EXISTS totp_enabled INTEGER NOT NULL DEFAULT 0;
ALTER TABLE users ADD COLUMN IF NOT EXISTS notification_prefs TEXT NOT NULL DEFAULT '{"email": true}';
ALTER TABLE users ADD COLUMN IF NOT EXISTS deleted_at TEXT;

ALTER TABLE org_settings ADD COLUMN IF NOT EXISTS offer_rules TEXT;
ALTER TABLE org_settings ADD COLUMN IF NOT EXISTS sla_hours INTEGER NOT NULL DEFAULT 48;

ALTER TABLE applications DROP CONSTRAINT IF EXISTS applications_status_check;
ALTER TABLE applications ADD CONSTRAINT applications_status_check
    CHECK (status IN ('submitted','in_review','needs_docs','approved','rejected','withdrawn'));
ALTER TABLE applications ADD CONSTRAINT applications_amount_check CHECK (loan_amount > 0);
ALTER TABLE applications ADD CONSTRAINT applications_probability_check
    CHECK (default_probability BETWEEN 0 AND 1);
ALTER TABLE applications ADD COLUMN IF NOT EXISTS draft_id INTEGER;
ALTER TABLE applications ADD COLUMN IF NOT EXISTS offer_id INTEGER;
ALTER TABLE applications ADD COLUMN IF NOT EXISTS model_version_id INTEGER;
ALTER TABLE applications ADD COLUMN IF NOT EXISTS odds TEXT;
ALTER TABLE applications ADD COLUMN IF NOT EXISTS reason_codes TEXT NOT NULL DEFAULT '[]';
ALTER TABLE applications ADD COLUMN IF NOT EXISTS terms TEXT;
ALTER TABLE applications ADD COLUMN IF NOT EXISTS demographics TEXT NOT NULL DEFAULT '{}';
ALTER TABLE applications ADD COLUMN IF NOT EXISTS assigned_to INTEGER REFERENCES users(id);
ALTER TABLE applications ADD COLUMN IF NOT EXISTS sla_due_at TEXT;
ALTER TABLE applications ADD COLUMN IF NOT EXISTS updated_at TEXT;
UPDATE applications SET updated_at = COALESCE(decided_at, created_at) WHERE updated_at IS NULL;

CREATE INDEX IF NOT EXISTS ix_app_org_status ON applications(org_id, status);
CREATE INDEX IF NOT EXISTS ix_app_borrower ON applications(borrower_id);
CREATE INDEX IF NOT EXISTS ix_app_decided_by ON applications(decided_by);
CREATE INDEX IF NOT EXISTS ix_app_assigned ON applications(assigned_to);
CREATE UNIQUE INDEX IF NOT EXISTS ux_app_open ON applications(borrower_id, org_id)
    WHERE status IN ('submitted','in_review','needs_docs');
CREATE UNIQUE INDEX IF NOT EXISTS ux_users_phone ON users(phone);


CREATE TABLE IF NOT EXISTS model_versions (
    id            SERIAL PRIMARY KEY,
    version       TEXT NOT NULL UNIQUE,
    artifact_path TEXT NOT NULL,
    data_hash     TEXT,
    model_name    TEXT,
    metrics       TEXT NOT NULL DEFAULT '{}',
    features      TEXT NOT NULL DEFAULT '[]',
    notes         TEXT,
    status        TEXT NOT NULL DEFAULT 'candidate'
                  CHECK (status IN ('candidate','shadow','active','retired')),
    created_at    TEXT NOT NULL,
    promoted_at   TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS ux_model_active ON model_versions(status) WHERE status = 'active';
CREATE UNIQUE INDEX IF NOT EXISTS ux_model_shadow ON model_versions(status) WHERE status = 'shadow';

CREATE TABLE IF NOT EXISTS drafts (
    id              SERIAL PRIMARY KEY,
    user_id         INTEGER REFERENCES users(id),
    anon_token_hash TEXT UNIQUE,
    step            INTEGER NOT NULL DEFAULT 1 CHECK (step BETWEEN 1 AND 4),
    inputs          TEXT NOT NULL DEFAULT '{}',
    demographics    TEXT NOT NULL DEFAULT '{}',
    locale          TEXT NOT NULL DEFAULT 'en',
    status          TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active','submitted','expired')),
    reminders_sent  INTEGER NOT NULL DEFAULT 0,
    created_at      TEXT NOT NULL,
    updated_at      TEXT NOT NULL,
    expires_at      TEXT NOT NULL,
    CHECK (user_id IS NOT NULL OR anon_token_hash IS NOT NULL)
);
CREATE INDEX IF NOT EXISTS ix_drafts_user ON drafts(user_id, updated_at);
CREATE INDEX IF NOT EXISTS ix_drafts_status ON drafts(status, updated_at);

CREATE TABLE IF NOT EXISTS offers (
    id               SERIAL PRIMARY KEY,
    draft_id         INTEGER NOT NULL REFERENCES drafts(id) ON DELETE CASCADE,
    org_id           INTEGER NOT NULL REFERENCES orgs(id),
    eligible         INTEGER NOT NULL,
    amount_min       DOUBLE PRECISION,
    amount_max       DOUBLE PRECISION,
    rate_min         DOUBLE PRECISION,
    rate_max         DOUBLE PRECISION,
    best_amount      DOUBLE PRECISION NOT NULL CHECK (best_amount > 0),
    best_term        INTEGER NOT NULL,
    best_rate        DOUBLE PRECISION NOT NULL,
    best_emi         DOUBLE PRECISION NOT NULL,
    odds             TEXT NOT NULL CHECK (odds IN ('excellent','good','fair','low')),
    probability      DOUBLE PRECISION NOT NULL CHECK (probability BETWEEN 0 AND 1),
    ladder_level     INTEGER NOT NULL DEFAULT 1,
    model_version_id INTEGER REFERENCES model_versions(id),
    status           TEXT NOT NULL DEFAULT 'estimate' CHECK (status IN ('estimate','used','expired')),
    created_at       TEXT NOT NULL,
    expires_at       TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS ix_offers_draft ON offers(draft_id);

CREATE TABLE IF NOT EXISTS application_events (
    id             SERIAL PRIMARY KEY,
    application_id INTEGER NOT NULL REFERENCES applications(id) ON DELETE CASCADE,
    from_status    TEXT,
    to_status      TEXT NOT NULL,
    actor_id       INTEGER REFERENCES users(id),
    note           TEXT,
    created_at     TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS ix_events_app ON application_events(application_id, id);

CREATE TABLE IF NOT EXISTS document_requests (
    id             SERIAL PRIMARY KEY,
    application_id INTEGER NOT NULL REFERENCES applications(id) ON DELETE CASCADE,
    items          TEXT NOT NULL,
    note           TEXT,
    status         TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open','fulfilled','expired','cancelled')),
    reminders_sent INTEGER NOT NULL DEFAULT 0,
    created_by     INTEGER REFERENCES users(id),
    created_at     TEXT NOT NULL,
    due_at         TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS ix_docreq_app ON document_requests(application_id);
CREATE INDEX IF NOT EXISTS ix_docreq_status ON document_requests(status, due_at);

CREATE TABLE IF NOT EXISTS documents (
    id             SERIAL PRIMARY KEY,
    application_id INTEGER NOT NULL REFERENCES applications(id) ON DELETE CASCADE,
    request_id     INTEGER REFERENCES document_requests(id),
    kind           TEXT NOT NULL,
    filename       TEXT NOT NULL,
    content_type   TEXT NOT NULL,
    size           INTEGER NOT NULL CHECK (size > 0),
    storage_path   TEXT NOT NULL,
    uploaded_by    INTEGER REFERENCES users(id),
    uploaded_at    TEXT NOT NULL,
    deleted_at     TEXT
);
CREATE INDEX IF NOT EXISTS ix_documents_app ON documents(application_id);

CREATE TABLE IF NOT EXISTS loans (
    id             SERIAL PRIMARY KEY,
    application_id INTEGER NOT NULL UNIQUE REFERENCES applications(id),
    org_id         INTEGER NOT NULL REFERENCES orgs(id),
    borrower_id    INTEGER NOT NULL REFERENCES users(id),
    principal      DOUBLE PRECISION NOT NULL CHECK (principal > 0),
    annual_rate    DOUBLE PRECISION NOT NULL CHECK (annual_rate >= 0),
    term_months    INTEGER NOT NULL CHECK (term_months > 0),
    emi            DOUBLE PRECISION NOT NULL,
    start_date     TEXT NOT NULL,
    status         TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active','closed','defaulted')),
    created_at     TEXT NOT NULL,
    closed_at      TEXT
);
CREATE INDEX IF NOT EXISTS ix_loans_borrower ON loans(borrower_id);
CREATE INDEX IF NOT EXISTS ix_loans_org ON loans(org_id, status);

CREATE TABLE IF NOT EXISTS repayments (
    id          SERIAL PRIMARY KEY,
    loan_id     INTEGER NOT NULL REFERENCES loans(id) ON DELETE CASCADE,
    seq         INTEGER NOT NULL,
    due_date    TEXT NOT NULL,
    amount_due  DOUBLE PRECISION NOT NULL CHECK (amount_due > 0),
    amount_paid DOUBLE PRECISION NOT NULL DEFAULT 0 CHECK (amount_paid >= 0),
    paid_at     TEXT,
    status      TEXT NOT NULL DEFAULT 'due' CHECK (status IN ('due','paid','late','missed')),
    UNIQUE (loan_id, seq)
);
CREATE INDEX IF NOT EXISTS ix_repayments_loan ON repayments(loan_id, due_date);
CREATE INDEX IF NOT EXISTS ix_repayments_status ON repayments(status, due_date);

CREATE TABLE IF NOT EXISTS borrower_levels (
    borrower_id     INTEGER NOT NULL REFERENCES users(id),
    org_id          INTEGER NOT NULL REFERENCES orgs(id),
    level           INTEGER NOT NULL DEFAULT 1 CHECK (level BETWEEN 1 AND 4),
    loans_repaid    INTEGER NOT NULL DEFAULT 0,
    updated_at      TEXT NOT NULL,
    PRIMARY KEY (borrower_id, org_id)
);

CREATE TABLE IF NOT EXISTS consents (
    id           SERIAL PRIMARY KEY,
    user_id      INTEGER NOT NULL REFERENCES users(id),
    org_id       INTEGER REFERENCES orgs(id),
    purpose      TEXT NOT NULL,
    text_version TEXT NOT NULL,
    granted_at   TEXT NOT NULL,
    revoked_at   TEXT
);
CREATE INDEX IF NOT EXISTS ix_consents_user ON consents(user_id);

CREATE TABLE IF NOT EXISTS notifications (
    id         SERIAL PRIMARY KEY,
    user_id    INTEGER NOT NULL REFERENCES users(id),
    event      TEXT NOT NULL,
    payload    TEXT NOT NULL DEFAULT '{}',
    created_at TEXT NOT NULL,
    read_at    TEXT
);
CREATE INDEX IF NOT EXISTS ix_notifications_user ON notifications(user_id, read_at);

CREATE TABLE IF NOT EXISTS outbox (
    id           SERIAL PRIMARY KEY,
    event        TEXT NOT NULL,
    payload      TEXT NOT NULL,
    created_at   TEXT NOT NULL,
    processed_at TEXT,
    attempts     INTEGER NOT NULL DEFAULT 0,
    last_error   TEXT
);
CREATE INDEX IF NOT EXISTS ix_outbox_pending ON outbox(id) WHERE processed_at IS NULL;

CREATE TABLE IF NOT EXISTS refresh_tokens (
    id          SERIAL PRIMARY KEY,
    user_id     INTEGER NOT NULL REFERENCES users(id),
    token_hash  TEXT NOT NULL UNIQUE,
    family      TEXT NOT NULL,
    created_at  TEXT NOT NULL,
    expires_at  TEXT NOT NULL,
    revoked_at  TEXT
);
CREATE INDEX IF NOT EXISTS ix_refresh_family ON refresh_tokens(family);

CREATE TABLE IF NOT EXISTS otp_codes (
    id         SERIAL PRIMARY KEY,
    phone      TEXT NOT NULL,
    code_hash  TEXT NOT NULL,
    purpose    TEXT NOT NULL,
    attempts   INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL,
    expires_at TEXT NOT NULL,
    used_at    TEXT
);
CREATE INDEX IF NOT EXISTS ix_otp_phone ON otp_codes(phone, id);

CREATE TABLE IF NOT EXISTS password_resets (
    id         SERIAL PRIMARY KEY,
    user_id    INTEGER NOT NULL REFERENCES users(id),
    token_hash TEXT NOT NULL UNIQUE,
    created_at TEXT NOT NULL,
    expires_at TEXT NOT NULL,
    used_at    TEXT
);

CREATE TABLE IF NOT EXISTS feature_flags (
    key        TEXT PRIMARY KEY,
    enabled    INTEGER NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS job_runs (
    name        TEXT PRIMARY KEY,
    last_run_at TEXT NOT NULL,
    last_result TEXT
);

CREATE TABLE IF NOT EXISTS idempotency_keys (
    key         TEXT NOT NULL,
    user_id     INTEGER NOT NULL,
    route       TEXT NOT NULL,
    status_code INTEGER NOT NULL,
    response    TEXT NOT NULL,
    created_at  TEXT NOT NULL,
    PRIMARY KEY (key, user_id)
);

CREATE TABLE IF NOT EXISTS drift_snapshots (
    id               SERIAL PRIMARY KEY,
    org_id           INTEGER NOT NULL REFERENCES orgs(id),
    model_version_id INTEGER REFERENCES model_versions(id),
    report           TEXT NOT NULL,
    created_at       TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS ix_drift_org ON drift_snapshots(org_id, id);

CREATE TABLE IF NOT EXISTS shadow_scores (
    id                 SERIAL PRIMARY KEY,
    application_id     INTEGER NOT NULL REFERENCES applications(id) ON DELETE CASCADE,
    model_version_id   INTEGER NOT NULL REFERENCES model_versions(id),
    probability        DOUBLE PRECISION NOT NULL,
    odds               TEXT NOT NULL,
    active_probability DOUBLE PRECISION NOT NULL,
    active_odds        TEXT NOT NULL,
    created_at         TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS ix_shadow_model ON shadow_scores(model_version_id);

-- Supabase exposes the public schema through its REST API. LenDen does not use that API,
-- so row-level security with no policies blocks it entirely. The backend connects as the
-- table owner, which bypasses RLS, so the app is unaffected.
ALTER TABLE model_versions ENABLE ROW LEVEL SECURITY;
ALTER TABLE drafts ENABLE ROW LEVEL SECURITY;
ALTER TABLE offers ENABLE ROW LEVEL SECURITY;
ALTER TABLE application_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE document_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE documents ENABLE ROW LEVEL SECURITY;
ALTER TABLE loans ENABLE ROW LEVEL SECURITY;
ALTER TABLE repayments ENABLE ROW LEVEL SECURITY;
ALTER TABLE borrower_levels ENABLE ROW LEVEL SECURITY;
ALTER TABLE consents ENABLE ROW LEVEL SECURITY;
ALTER TABLE notifications ENABLE ROW LEVEL SECURITY;
ALTER TABLE outbox ENABLE ROW LEVEL SECURITY;
ALTER TABLE refresh_tokens ENABLE ROW LEVEL SECURITY;
ALTER TABLE otp_codes ENABLE ROW LEVEL SECURITY;
ALTER TABLE password_resets ENABLE ROW LEVEL SECURITY;
ALTER TABLE feature_flags ENABLE ROW LEVEL SECURITY;
ALTER TABLE job_runs ENABLE ROW LEVEL SECURITY;
ALTER TABLE idempotency_keys ENABLE ROW LEVEL SECURITY;
ALTER TABLE drift_snapshots ENABLE ROW LEVEL SECURITY;
ALTER TABLE shadow_scores ENABLE ROW LEVEL SECURITY;
