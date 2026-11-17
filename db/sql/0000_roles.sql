-- GMS | 0000 | Cluster roles + schema. Run by the migration login (needs CREATEROLE/superuser).
-- gms_owner : owns every object, NOLOGIN (nobody connects as the owner).
-- gms_api   : group role of the API service login. No DML on financial/reading tables.
DO $$
BEGIN
 IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'gms_owner') THEN CREATE ROLE gms_owner NOLOGIN; END IF;
 IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'gms_api') THEN CREATE ROLE gms_api NOLOGIN; END IF;
 EXECUTE format('GRANT gms_owner TO %I', current_user);
END $$;
CREATE SCHEMA gms AUTHORIZATION gms_owner;
