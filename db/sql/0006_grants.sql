-- GMS | 0006 | Privileges. The API login gets: read everything, write master data only
-- (guarded by manager triggers), and EXECUTE on the public business functions.
-- It has NO direct INSERT/UPDATE/DELETE on readings, reviews, cycles, prices, statements,
-- payments, adjustments, ledger, devices, tasks, photos, audit.
REVOKE ALL ON SCHEMA gms FROM PUBLIC;
REVOKE ALL ON ALL TABLES IN SCHEMA gms FROM PUBLIC;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA gms FROM PUBLIC;
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA gms FROM PUBLIC;
ALTER DEFAULT PRIVILEGES IN SCHEMA gms REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;

GRANT USAGE ON SCHEMA gms TO gms_api;
GRANT SELECT ON ALL TABLES IN SCHEMA gms TO gms_api;
GRANT INSERT, UPDATE ON gms.app_users, gms.auth_refresh_tokens, gms.generators, gms.zones, gms.subscribers,
 gms.subscriber_schedules, gms.user_zone_grants, gms.import_batches, gms.backup_job_log, gms.system_settings TO gms_api;
GRANT INSERT ON gms.device_enrollment_codes, gms.sync_rejections TO gms_api;
GRANT USAGE ON SEQUENCE gms.sync_rejections_id_seq TO gms_api;

DO $$ DECLARE f record;
BEGIN
 FOR f IN SELECT p.oid::regprocedure AS sig FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'gms' AND p.proname NOT LIKE '\_%' AND p.proname NOT LIKE 'tg\_%' LOOP
  EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO gms_api', f.sig);
 END LOOP;
END $$;
