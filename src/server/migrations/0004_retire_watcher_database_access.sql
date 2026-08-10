\set ON_ERROR_STOP on

BEGIN;

-- The deployed watcher now uses the metadata-only HTTPS feed. Retire the old
-- direct-database experiment completely: remove every member rather than
-- depending on environment-specific IAM usernames, then remove the role's
-- object privileges. The role itself remains as an inert historical object.
DO $$
DECLARE
  member_name text;
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'wristmemo_watcher') THEN
    FOR member_name IN
      SELECT member_role.rolname
      FROM pg_auth_members membership
      JOIN pg_roles granted_role ON granted_role.oid = membership.roleid
      JOIN pg_roles member_role ON member_role.oid = membership.member
      WHERE granted_role.rolname = 'wristmemo_watcher'
    LOOP
      EXECUTE format('REVOKE wristmemo_watcher FROM %I', member_name);
    END LOOP;

    EXECUTE 'REVOKE SELECT ON wristmemo.memos FROM wristmemo_watcher';
    EXECUTE 'REVOKE USAGE ON SCHEMA wristmemo FROM wristmemo_watcher';
  END IF;
END
$$;

COMMIT;
