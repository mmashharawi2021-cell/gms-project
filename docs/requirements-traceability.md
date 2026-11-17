# مصفوفة التتبع BR → FR → AT → الكود → الاختبار

الحالات: **PASS** = اختبار آلي شُغّل فعلًا ونجح (المرجع `docs/evidence/`)؛ **PARTIAL** = الطبقة المذكورة فقط؛ **NOT RUN**؛ **BLOCKED**.
مسارات الاختبارات نسبةً إلى `services/api/tests/`.

| AT | BR / FR | الكود | الاختبار | الحالة |
|---|---|---|---|---|
| AT-01 | BR-03/04/05; FR-08/09 | `gms.next_due_date`, `generate_due_tasks`, `create_task`, `cancel_task` (0004) | `db/test_workflow.py::test_flexible_intervals_generate_tasks_and_close_without_not_due`؛ `api/test_flow.py::test_full_week_over_http` | PASS (DB+HTTP) |
| AT-02 | BR-06/07; FR-05/11 | `install_meter`, CHECK `scale<=2` (0001), `receive_visit` | `db/test_integrity.py::test_three_decimals_rejected_never_rounded`؛ `api/test_flow.py::test_sync_protocol_photos_and_scope`، E2E المتصفح (رفض 100.123)، `field-mobile/test/validators_test.dart` | PASS (DB+HTTP+Web+تطبيق) |
| AT-03 | BR-08/09; FR-11/12 | `begin_photo`/`complete_photo`, `approve_visit`, `resolve_unreadable` | `db/test_integrity.py::test_photo_is_mandatory_and_verified`؛ `api/test_flow.py::test_sync_protocol_photos_and_scope` | PASS (DB+HTTP) |
| AT-04 | BR-11/12; FR-14/15 | `approve_visit` (earlier_visit_pending/out_of_order) | `db/test_workflow.py::test_raw_readings_wait_for_sequential_manager_approval` | PASS (DB) |
| AT-05 | BR-15/16; FR-12/28 | `resolve_unreadable`, `request_revisit`, `move_task` | `db/test_workflow.py::test_unreadable_closes_without_charge_and_follow_up_uses_new_week`, `::test_revisit_creates_linked_task_and_blocks_its_own_week` | PASS (DB) |
| AT-06 | BR-13/14; FR-16/17 | `receive_visit` flags | `db/test_workflow.py::test_offline_assignment_change_and_zone_authorization`؛ `api/test_flow.py::test_sync_protocol_photos_and_scope` | PASS (DB+HTTP) |
| AT-07 | BR-17/18; FR-22/23 | `set_provisional_rate`, `finalize_cycle` | `db/test_finance.py::test_provisional_rate_changes_never_post_and_final_rate_recomputes`, `::test_reading_spanning_weeks_uses_current_week_rate`؛ `api/test_flow.py::test_full_week_over_http` | PASS (DB+HTTP) |
| AT-08 | BR-19/20; FR-24 | `finalize_cycle` | `db/test_finance.py::test_two_readings_one_week_one_statement`؛ `api/test_flow.py::test_full_week_over_http`، E2E المتصفح | PASS (DB+HTTP+Web) |
| AT-09 | BR-21/22; FR-25 | `correct_approved_reading` | `db/test_finance.py::test_open_cycle_correction_recomputes_without_ledger`, `::test_closed_cycle_correction_posts_single_adjustment`؛ `api/test_flow.py::test_full_week_over_http` (تصحيح دورة مغلقة) | PASS (DB+HTTP) |
| AT-10 | BR-29; FR-26/27 | `record_payment`, `reverse_payment`, `v_subscriber_account` | `db/test_finance.py::test_partial_payments_reversal_and_idempotency`؛ `api/test_flow.py`، E2E المتصفح (دفعة جزئية + عكس) | PASS (DB+HTTP+Web) |
| AT-11 | BR-24/25; FR-18/21 | `receive_visit` time flags, `verify_capture_time`, late approval | `db/test_workflow.py::test_untrusted_device_clock_needs_manager_decision`, `db/test_finance.py::test_late_reading_for_closed_week_becomes_adjustment`؛ `api/test_flow.py::test_clock_evidence_same_boot` | PASS (DB+HTTP) |
| AT-12 | BR-26; FR-17 | `receive_visit`, `sync_operations` | `db/test_workflow.py::test_sync_is_idempotent_per_uuid`, `db/test_concurrency.py::test_same_visit_uuid_from_ten_sessions_stored_once`؛ `api/test_flow.py::test_sync_protocol_photos_and_scope` (10 إعادات)، `field-mobile/test/sync_test.dart` | PASS (DB+HTTP+منطق التطبيق) |
| AT-13 | BR-27/28; FR-01/02/10 | `enroll_device`, `revoke_device`, `routers/auth.py`, `apps/field-mobile/lib/src/{secure,app_state}.dart` | `db/test_workflow.py`، `api/test_auth_security.py`، تشغيل على محاكي Android (docs/acceptance-report.md §3) | PASS |
| AT-14 | BR-30; FR-19/20 | chain indexes + `tg_approved_validate` | `db/test_workflow.py::test_raw_readings_wait...`, `db/test_concurrency.py::test_concurrent_approvals_on_one_meter_keep_linear_chain`؛ `api/test_flow.py::test_full_week_over_http` (اعتماد جماعي يتخطى الاستثناءات) | PASS (DB+HTTP) |
| AT-15 | BR-31; FR-30 | `app/ops/backup.py`, خدمة `backup`, `/backups/{id}/download` | `ops/test_backup_restore.py` (2 اختبارات)؛ تشغيل نسخة داخل حاوية Compose | PASS |
| AT-16 | FR-06 | `routers/imports.py` (inspect + ربط أعمدة + قيم ثابتة) | `api/test_import.py` (قالب + ملف بأعمدة مختلفة وتواريخ dd/mm/yyyy)، E2E `admin-extras.spec.ts` | PASS (ملف العميل الحقيقي لم يُجرَّب بعد) |
| AT-17 | FR-04/13 | `replace_meter`, `meter_incident_reports` | `db/test_workflow.py::test_meter_replacement_starts_a_new_chain`؛  | PASS (DB) |
| AT-18 | FR-29 | `app/reports.py`, `routers/reports.py`, إيصال `GET /payments/{id}/receipt` | `api/test_reports.py`، `api/test_identity_receipts.py` (إيصال + حماية صيغ Excel + طباعة متوازية) | PASS |
| AT-19 | BR-20/22; FR-24/25 | ledger projection | `db/test_finance.py::test_zero_consumption_keeps_fraction_and_posts_nothing`, `::test_credit_larger_than_next_charge_survives` | PASS (DB) |
| AT-20 | BR-23; FR-03 | `stop_subscriber` | `db/test_workflow.py::test_stop_subscription_keeps_history_and_debt` | PASS (DB) |
| AT-21 | FIX-01 | CHECK scale + function checks | `db/test_integrity.py::test_three_decimals_rejected_never_rounded` | PASS |
| AT-22 | FIX-02 | `tg_visit_guard`, `tg_approved_guard` | `db/test_integrity.py::test_history_is_immutable_even_for_table_owner` | PASS |
| AT-23 | FIX-03 | `tg_cycle_guard`, `tg_price_decision_guard`, append-only | نفسه | PASS |
| AT-24 | FIX-06 | `tg_ledger_source_validate` | نفسه | PASS |
| AT-25 | FIX-09; FR-01 | `require_role` + grants (0006) | `db/test_integrity.py::test_role_enforcement_inside_database`, `::test_api_login_has_no_direct_dml_on_protected_tables`؛ `api/test_auth_security.py::test_employee_cannot_reach_any_manager_operation` (37 نقطة) + E2E | PASS (DB+HTTP+Web) |
| AT-26 | BR-20 | ledger | `db/test_finance.py::test_fraction_carry_payment_and_credit_srs_17_3` | PASS |
| AT-27 | BR-22 | ledger | نفسه + `::test_credit_larger_than_next_charge_survives` | PASS |
| AT-28 | FIX-09 | idempotency keys + advisory locks | `db/test_concurrency.py::test_same_payment_key_ten_sessions_one_receipt`, `::test_concurrent_reversal_posts_single_counter_entry`, `::test_concurrent_closed_cycle_correction_posts_once` | PASS |
| AT-29 | FIX-04 | `final_reading_allocations` PK | `db/test_finance.py::test_two_readings_one_week_one_statement`, `::test_random_scenarios_match_oracle`, `db/test_concurrency.py::test_concurrent_finalize_creates_statements_once` | PASS |
| AT-30 | BR-05; FR-28 | `cycle_blockers`, `finalize_cycle` | `db/test_workflow.py::test_close_blocked_until_everything_is_decided`, `db/test_concurrency.py::test_approval_racing_with_close_never_leaves_unbilled_reading` | PASS |
| AT-31 | FR-30 | `app/ops/backup.py restore` | `ops/test_backup_restore.py::test_backup_and_restore_database_and_photos` | PASS |
| AT-32 | BR-26/27 | `apps/field-mobile` (SQLCipher، PhotoVault AES-GCM، SyncEngine، WorkManager unmetered) | `field-mobile/test/sync_test.dart` (7) + `validators_test.dart` (3) + تشغيل على محاكي Android | PASS |
