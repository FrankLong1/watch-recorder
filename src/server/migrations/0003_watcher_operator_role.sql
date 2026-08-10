\set ON_ERROR_STOP on

BEGIN;

-- The shared Cloud Workstation configuration gives its VM service account
-- restrictive OAuth scopes. The logged-in operator's pre-existing Cloud SQL
-- IAM database user is used for the initial wiring check, with the same
-- database-only, read-only role as the future dedicated watcher identity.
GRANT wristmemo_watcher TO :"watcher_operator_database_user";

COMMIT;
