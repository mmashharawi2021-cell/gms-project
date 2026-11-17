-- GMS | 0007 | Business identity printed on statements, receipts and reports (manager-editable).
-- Values are neutral placeholders; the manager sets the real name/phone from the Settings page.
-- Settings rows are manager-guarded; this migration (run by the owner, no human actor) bypasses the
-- guard trigger only for these idempotent inserts.
ALTER TABLE gms.system_settings DISABLE TRIGGER trg_manager_guard;
INSERT INTO gms.system_settings(key, value) VALUES
 ('business_name', 'GMS'),
 ('business_phone', '-'),
 ('statement_footer', '-')
ON CONFLICT (key) DO NOTHING;
ALTER TABLE gms.system_settings ENABLE TRIGGER trg_manager_guard;
