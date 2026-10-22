-- 0003: audit_log and application_events are append-only for everyone except the table owner.
-- The API connects as the owner; other roles (e.g. Supabase's anon and authenticated) cannot
-- change history even if RLS policies are added later.
REVOKE UPDATE, DELETE, TRUNCATE ON audit_log, application_events FROM PUBLIC;
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
        EXECUTE 'REVOKE ALL ON audit_log, application_events FROM anon';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
        EXECUTE 'REVOKE ALL ON audit_log, application_events FROM authenticated';
    END IF;
END $$;
