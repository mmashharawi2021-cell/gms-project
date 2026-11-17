"""P1 — deliberate corruption attempts against a real PostgreSQL (AT-02/03/21/22/23/24/25)."""
import uuid
from decimal import Decimal

import psycopg
import pytest
from psycopg.rows import dict_row

from tests.world import DbError, World


def fails(code: str, state: str | None = None):
    class _Ctx:
        def __enter__(self):
            return self

        def __exit__(self, et, ev, tb):
            assert et is not None, f"expected failure {code}, but the statement succeeded"
            assert issubclass(et, DbError), f"unexpected {et}: {ev}"
            assert code in ev.code or code in ev.message, f"expected {code}, got {ev}"
            if state:
                assert ev.sqlstate == state, ev
            return True

    return _Ctx()


def test_three_decimals_rejected_never_rounded(world: World, owner_url):
    w = world.bootstrap()
    c = w.cycle("QA-C1", -6, 0)
    # AT-02: 21.2 and 21.98 are valid, stored exactly
    sub, inst = w.add_subscriber("21.2")
    assert w.val("SELECT opening_value_kwh FROM gms.opening_baselines WHERE installation_id=%s", (inst,)) == Decimal("21.2")
    v = w.visit(sub, inst, "21.98", w.now(), task=w.task(c, sub, 0))
    assert w.val("SELECT reading_value_kwh::text FROM gms.field_visits WHERE id=%s", (v,)) == "21.98"
    # opening reading with 3 decimals
    sid = w.call(w.manager, "INSERT INTO gms.subscribers(subscription_no,full_name,generator_id,zone_id) VALUES ('QA-P','p',%s,%s) RETURNING id", (w.generator, w.zone))
    with fails("invalid_precision", "GM422"):
        w.call(w.manager, "SELECT gms.install_meter(%s,'QA-MP','digital',%s,%s,NULL)", (sid, w.at(-5), Decimal("121.987")))
    # field reading with 3 decimals: refused, nothing stored, and NOT turned into 121.99
    res = w.receive(w.payload(sub, inst, "121.987", w.now(), reason="x"))
    assert res["result"] == "rejected" and res["reason"] == "invalid_precision"
    assert w.val("SELECT count(*) FROM gms.field_visits WHERE id=%s", (res["visit_id"],)) == 0
    assert w.val("SELECT count(*) FROM gms.field_visits WHERE reading_value_kwh = 121.99") == 0
    with fails("invalid_precision", "GM422"):
        w.approve(v, corrected=Decimal("22.001"), rationale="x")
    # even the table owner cannot store a third decimal (CHECK on numeric without typmod)
    with psycopg.connect(owner_url) as oc:
        with pytest.raises(psycopg.errors.CheckViolation):
            oc.execute("SELECT set_config('gms.actor_id', %s, false)", (str(w.manager),))
            oc.execute("INSERT INTO gms.opening_baselines(installation_id,opening_value_kwh,entered_by) SELECT id, 121.987, %s FROM gms.meter_installations LIMIT 1", (w.manager,))


def test_api_login_has_no_direct_dml_on_protected_tables(world: World):
    w = world
    c, sub, inst, task = w.week()
    w.approve(w.visit(sub, inst, "101.43", w.at(-10), task=task))
    w.finalize(c, "15")
    w.pay(sub, "5")
    attempts = [
        "UPDATE gms.ledger_entries SET signed_amount_ils = 1",
        "DELETE FROM gms.ledger_entries",
        "INSERT INTO gms.ledger_entries(subscriber_id,source_type,source_id,signed_amount_ils,posted_by) SELECT subscriber_id,'adjustment',gen_random_uuid(),-5,posted_by FROM gms.ledger_entries LIMIT 1",
        "INSERT INTO gms.payment_receipts(subscriber_id,receipt_no,amount_ils,paid_at,received_by,payment_method,idempotency_key) SELECT subscriber_id,'X',1,now(),received_by,'cash',gen_random_uuid() FROM gms.payment_receipts LIMIT 1",
        "UPDATE gms.approved_readings SET current_value_kwh = 9999",
        "UPDATE gms.field_visits SET reading_value_kwh = 9999",
        "DELETE FROM gms.field_visits",
        "UPDATE gms.reading_cycles SET state = 'open'",
        "UPDATE gms.statement_versions SET requested_whole_ils = 0",
        "UPDATE gms.cycle_price_decisions SET final_rate_ils_per_kwh = 1",
        "INSERT INTO gms.visit_reviews(visit_id,reviewed_by,decision) SELECT id, employee_id, 'approve_reading' FROM gms.field_visits LIMIT 1",
        "UPDATE gms.mobile_devices SET is_active = true, revoked_at = NULL",
        "UPDATE gms.reading_tasks SET status = 'completed_reading'",
        "UPDATE gms.visit_photos SET state = 'ready', ready_at = now()",
        "DELETE FROM gms.audit_logs",
        "UPDATE gms.billing_accounts SET balance_exact_ils = 0",
        "SELECT gms._post_adjustment(NULL,NULL,1,'x',gen_random_uuid(),'manual',NULL,NULL,NULL)",
        "SELECT gms._lock_account(gen_random_uuid())",
    ]
    for sql in attempts:
        with pytest.raises(DbError) as ei:
            w.call(w.manager, sql)  # even with a manager context
        assert ei.value.sqlstate == "42501", f"{sql} -> {ei.value}"


def test_history_is_immutable_even_for_table_owner(world: World, owner_url):
    w = world
    c, sub, inst, task = w.week()
    v = w.visit(sub, inst, "101.43", w.at(-10), task=task)
    r = w.approve(v)
    w.finalize(c, "15")
    pay = w.pay(sub, "5")
    st = w.statement(c, sub)["id"]
    attempts = {
        "approved_immutable": ("UPDATE gms.approved_readings SET current_value_kwh = 9999 WHERE id = %s", (r,)),
        "visit_immutable": ("UPDATE gms.field_visits SET reading_value_kwh = 9999 WHERE id = %s", (v,)),
        "no_delete:field_visits": ("DELETE FROM gms.field_visits WHERE id = %s", (v,)),
        "no_delete:approved_readings": ("DELETE FROM gms.approved_readings WHERE id = %s", (r,)),
        "append_only:statement_versions": ("UPDATE gms.statement_versions SET requested_whole_ils = 999 WHERE id = %s", (st,)),
        "append_only:statement_reading_lines": ("UPDATE gms.statement_reading_lines SET exact_charge_ils = 0 WHERE statement_id = %s", (st,)),
        "final_rate_locked": ("UPDATE gms.cycle_price_decisions SET final_rate_ils_per_kwh = 999 WHERE cycle_id = %s", (c,)),
        "cycle_closed": ("UPDATE gms.reading_cycles SET ends_on = ends_on + 1 WHERE id = %s", (c,)),
        "append_only:ledger_entries": ("UPDATE gms.ledger_entries SET signed_amount_ils = 1 WHERE subscriber_id = %s", (sub,)),
        "append_only:payment_receipts": ("DELETE FROM gms.payment_receipts WHERE id = %s", (pay,)),
        "append_only:audit_logs": ("DELETE FROM gms.audit_logs WHERE id = (SELECT min(id) FROM gms.audit_logs)", ()),
        "append_only:opening_baselines": ("UPDATE gms.opening_baselines SET opening_value_kwh = 1 WHERE installation_id = %s", (inst,)),
        "append_only:visit_reviews": ("UPDATE gms.visit_reviews SET decision = 'reject' WHERE visit_id = %s", (v,)),
        # AT-24: phantom source, and real source with a different amount
        "ledger_source_invalid": ("INSERT INTO gms.ledger_entries(subscriber_id,source_type,source_id,signed_amount_ils,posted_by) VALUES (%s,'final_statement',gen_random_uuid(),10,%s)", (sub, w.manager)),
        "ledger_source_invalid#2": ("INSERT INTO gms.ledger_entries(subscriber_id,source_type,source_id,signed_amount_ils,posted_by) VALUES (%s,'payment_reversal',%s,-999,%s)", (sub, pay, w.manager)),
        "statement_requires_finalize": ("INSERT INTO gms.statement_versions(statement_no,subscriber_id,cycle_id,revision,state,provisional,rate_snapshot_ils_per_kwh,finalized_at) VALUES ('X',%s,%s,2,'final',false,15,now())", (sub, c)),
    }
    with psycopg.connect(owner_url, row_factory=dict_row, autocommit=True) as oc:
        oc.execute("SELECT set_config('gms.actor_id', %s, false)", (str(w.manager),))
        for code, (sql, params) in attempts.items():
            with pytest.raises(psycopg.Error) as ei:
                oc.execute(sql, params)
            assert code.split("#")[0] in (ei.value.diag.message_detail or ""), f"{sql} -> {ei.value}"
        with pytest.raises(psycopg.Error) as ei:
            oc.execute("TRUNCATE gms.ledger_entries")
        assert "append_only" in (ei.value.diag.message_detail or "")
        # a brand new cycle cannot be closed directly, bypassing finalize (no statements would exist)
        c2 = w.cycle("QA-C2", -6, 0)
        with pytest.raises(psycopg.Error) as ei:
            oc.execute("UPDATE gms.reading_cycles SET state='closed', closed_by=%s, closed_at=now() WHERE id=%s", (w.manager, c2))
        assert "close_requires_finalize" in ei.value.diag.message_detail
    assert w.balance(sub) == Decimal("16.45")
    assert w.val("SELECT current_value_kwh FROM gms.approved_readings WHERE id=%s", (r,)) == Decimal("101.43")


def test_role_enforcement_inside_database(world: World):
    """AT-25: whatever the client sends, employee/anonymous/disabled actors cannot run manager operations."""
    w = world
    c, sub, inst, task = w.week()
    v = w.visit(sub, inst, "101.43", w.at(-10), task=task)
    r_other_manager = w.call(w.manager, "INSERT INTO gms.app_users(username,password_hash,full_name,role,is_active) VALUES ('qa-old-manager','x','Old','manager',false) RETURNING id")
    key = uuid.uuid4()
    manager_ops = [
        ("SELECT gms.approve_visit(%s,NULL,NULL,false,false)", (v,)),
        ("SELECT gms.reject_visit(%s,'reject','x')", (v,)),
        ("SELECT gms.request_revisit(%s,%s,NULL,'x')", (v, w.today)),
        ("SELECT gms.verify_capture_time(%s,now(),'x')", (v,)),
        ("SELECT gms.finalize_cycle(%s,1)", (c,)),
        ("SELECT gms.cycle_blockers(%s)", (c,)),
        ("SELECT gms.set_provisional_rate(%s,%s,1,'x')", (c, w.today)),
        ("SELECT gms.create_cycle('X',%s,%s)", (w.today, w.today)),
        ("SELECT gms.open_cycle(%s)", (c,)),
        ("SELECT gms.record_payment(%s,10,now(),'cash',NULL,%s)", (sub, key)),
        ("SELECT gms.reverse_payment(%s,'x')", (key,)),
        ("SELECT gms.record_adjustment(%s,-5,'x',%s,NULL)", (sub, key)),
        ("SELECT gms.record_opening_receivable(%s,50,%s,'x')", (sub, w.today)),
        ("SELECT gms.correct_approved_reading(%s,1,'x',%s)", (key, key)),
        ("SELECT gms.install_meter(%s,'S','digital',now(),0,NULL)", (sub,)),
        ("SELECT gms.replace_meter(%s,'reset',now(),'x',NULL,NULL,0,NULL)", (sub,)),
        ("SELECT gms.create_task(%s,%s,%s,'manager_extra',NULL,NULL)", (c, sub, w.today)),
        ("SELECT gms.generate_due_tasks(%s)", (c,)),
        ("SELECT gms.assign_task(%s,NULL)", (task,)),
        ("SELECT gms.cancel_task(%s,'x')", (task,)),
        ("SELECT gms.stop_subscriber(%s,'x')", (sub,)),
        ("SELECT gms.revoke_device(%s,'x')", (w.device,)),
        ("SELECT gms.resolve_unreadable(%s,%s,NULL)", (v, w.today)),
        ("SELECT gms.acknowledge_error_report(%s,'x')", (key,)),
        ("INSERT INTO gms.generators(name) VALUES ('EVIL') RETURNING id", ()),
        ("INSERT INTO gms.app_users(username,password_hash,full_name,role) VALUES ('evil','x','x','manager') RETURNING id", ()),
        ("UPDATE gms.app_users SET role='manager' WHERE id=%s RETURNING id", (w.employee,)),
        ("UPDATE gms.app_users SET password_hash='pwned' WHERE id=%s RETURNING id", (w.manager,)),
        ("UPDATE gms.subscribers SET full_name='x' WHERE id=%s RETURNING id", (sub,)),
        ("INSERT INTO gms.user_zone_grants(employee_id,zone_id,granted_by) VALUES (%s,%s,%s) RETURNING id", (w.employee, w.zone, w.employee)),
        ("UPDATE gms.system_settings SET value='UTC' WHERE key='business_timezone' RETURNING key", ()),
        ("INSERT INTO gms.device_enrollment_codes(employee_id,code_sha256,created_by,expires_at) VALUES (%s,%s,%s,now()+interval '1 day') RETURNING id", (w.employee, "a" * 64, w.employee)),
    ]
    for actor in (w.employee, None, r_other_manager, uuid.uuid4()):
        for sql, params in manager_ops:
            with pytest.raises(DbError) as ei:
                w.call(actor, sql, params)
            assert ei.value.sqlstate == "GM403", f"actor={actor} {sql} -> {ei.value}"
    # a manager is not a field device either
    with fails("role_required:employee", "GM403"):
        w.receive(w.payload(sub, inst, "102", w.now(), reason="x"), employee=w.manager)
    # nothing changed
    assert w.val("SELECT count(*) FROM gms.approved_readings") == 0
    assert w.val("SELECT count(*) FROM gms.ledger_entries") == 0
    assert w.val("SELECT count(*) FROM gms.app_users WHERE role='manager' AND is_active") == 1
    # an employee may change only their own password
    w.call(w.employee, "UPDATE gms.app_users SET password_hash='new-hash' WHERE id=%s RETURNING id", (w.employee,))
    other = w.add_employee("qa-employee2")
    with fails("role_required:manager", "GM403"):
        w.call(w.employee, "UPDATE gms.app_users SET password_hash='pwned' WHERE id=%s RETURNING id", (other,))


def test_photo_is_mandatory_and_verified(world: World):
    """AT-03 / BR-08 / BR-26."""
    w = world
    c, sub, inst, task = w.week()
    v = w.visit(sub, inst, "101", w.at(-10), task=task, photo=False)
    assert w.val("SELECT record_status FROM gms.field_visits WHERE id=%s", (v,)) == "awaiting_photo"
    with fails("photo_required", "GM409"):
        w.approve(v)
    pid = w.photo(v, ready=False)  # declared, bytes never verified
    with fails("photo_required"):
        w.approve(v)
    # stored object does not match the declared checksum -> failed, still not approvable
    res = w.call(w.employee, "SELECT gms.complete_photo(%s,%s,%s)", (pid, "0" * 64, 1234))
    assert res["state"] == "failed"
    with fails("photo_required"):
        w.approve(v)
    # retry with the right bytes
    sha = w.val("SELECT sha256_hex FROM gms.visit_photos WHERE id=%s", (pid,))
    assert w.call(w.employee, "SELECT gms.begin_photo(%s,%s,%s,1234,'image/jpeg',true)", (pid, v, sha))["state"] == "uploading"
    res = w.call(w.employee, "SELECT gms.complete_photo(%s,%s,%s)", (pid, sha, 1234))
    assert res == {"state": "ready", "record_status": "pending_review"}
    w.approve(v)
    # unreadable: reason mandatory, photo mandatory before the manager can close it
    t2 = w.task(c, sub, -9)
    res = w.receive(w.payload(sub, inst, None, w.at(-9), task=t2, kind="unreadable"))
    assert res["result"] == "rejected" and res["reason"] == "reason_required"
    u = w.visit(sub, inst, None, w.at(-9), task=t2, kind="unreadable", reason="باب مغلق", photo=False)
    with fails("photo_required"):
        w.call(w.manager, "SELECT gms.resolve_unreadable(%s,%s,NULL)", (u, w.today))
    # another employee cannot attach photos to someone else's visit
    other = w.add_employee("qa-other")
    with fails("visit_not_found", "GM404"):
        w.photo(u, employee=other)
