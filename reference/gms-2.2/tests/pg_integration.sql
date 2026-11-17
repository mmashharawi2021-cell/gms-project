-- Execute ONLY against a fresh, disposable PostgreSQL 16+ test database.
-- psql -v ON_ERROR_STOP=1 -d gms_test -f 10_baseline.sql -f 20_hardening.sql
--   -f 30_financial_engine.sql -f tests/pg_integration.sql
-- This script aborts on a missing invariant. NOT yet executed in this workspace.
BEGIN;
DO $qa$
<<qa>>
DECLARE manager_id uuid :=gen_random_uuid(); employee_id uuid:=gen_random_uuid();
 generator_id uuid:=gen_random_uuid(); zone_id uuid:=gen_random_uuid();
 subscriber_id uuid:=gen_random_uuid(); meter_id uuid:=gen_random_uuid(); installation_id uuid:=gen_random_uuid();
 device_id uuid:=gen_random_uuid(); grant_id uuid:=gen_random_uuid();
 cycle1 uuid:=gen_random_uuid(); cycle2 uuid:=gen_random_uuid();
 task1 uuid:=gen_random_uuid();task2 uuid:=gen_random_uuid();
 visit1 uuid:=gen_random_uuid();visit2 uuid:=gen_random_uuid();
 op1 uuid:=gen_random_uuid();op2 uuid:=gen_random_uuid();
 read1 uuid; read2 uuid; payment1 uuid; payment1_dup uuid; payment_key uuid:=gen_random_uuid();
 adjustment1 uuid; adjustment1_dup uuid; statement1 record;statement2 record;
 snap1 timestamptz; snap2 timestamptz;
 failed boolean; nb numeric; n integer; outcode text;
BEGIN
 snap1 := (current_date::text||' 12:00:00+00')::timestamptz;
 snap2 := ((current_date+4)::text||' 12:00:00+00')::timestamptz;
 INSERT INTO app_users(id,username,password_hash,full_name,role) VALUES
  (manager_id,'qa-manager','TEST-NOT-A-REAL-HASH','QA Manager','manager'),
  (employee_id,'qa-employee','TEST-NOT-A-REAL-HASH','QA Employee','employee');
 PERFORM set_config('gms.actor_id',manager_id::text,true);
 INSERT INTO generators(id,name) VALUES(generator_id,'QA-GEN');
 INSERT INTO zones(id,generator_id,name) VALUES(zone_id,generator_id,'QA-ZONE');
 INSERT INTO subscribers(id,subscription_no,full_name,generator_id,zone_id)
 VALUES(subscriber_id,'QA-1001','QA Subscriber',generator_id,zone_id);
 INSERT INTO meters(id,serial_no,meter_type) VALUES(meter_id,'QA-METER','digital');
 INSERT INTO meter_installations(id,subscriber_id,meter_id,installed_at,installed_by)
 VALUES(installation_id,subscriber_id,meter_id,snap1-interval '20 days',manager_id);
 INSERT INTO opening_baselines(installation_id,opening_value_kwh,entered_by)
 VALUES(installation_id,100.00,manager_id);
 INSERT INTO reading_cycles(id,label,starts_on,ends_on,state,opened_by)
 VALUES(cycle1,'QA-C1',current_date-1,current_date+1,'open',manager_id);
 INSERT INTO cycle_price_decisions(cycle_id,provisional_rate_ils_per_kwh)
 VALUES(cycle1,30);
 INSERT INTO user_zone_grants(id,employee_id,zone_id,valid_from,granted_by)
 VALUES(grant_id,employee_id,zone_id,snap1-interval '20 days',manager_id);
 INSERT INTO mobile_devices(id,employee_id,device_label)
 VALUES(device_id,employee_id,'QA Android');
 INSERT INTO reading_tasks(id,cycle_id,subscriber_id,installation_id,zone_id,
   assigned_employee_id,planned_for,source,created_by)
 VALUES(task1,cycle1,subscriber_id,installation_id,zone_id,employee_id,current_date,'scheduled',manager_id);

 -- Bad precision MUST fail, not round to 121.99.
 failed:=false;
 BEGIN
  UPDATE opening_baselines SET opening_value_kwh=121.987 WHERE installation_id=qa.installation_id;
 EXCEPTION WHEN OTHERS THEN failed:=true;
 END;
 IF NOT failed THEN RAISE EXCEPTION 'QA FAIL: immutable opening value updated'; END IF;

 PERFORM set_config('gms.actor_id',employee_id::text,true);
 failed:=false;
 BEGIN
  INSERT INTO visit_reviews(visit_id,reviewed_by,decision) VALUES(visit1,employee_id,'approve_reading');
 EXCEPTION WHEN OTHERS THEN failed:=true; END;
 IF NOT failed THEN RAISE EXCEPTION 'QA FAIL: employee reviewer accepted'; END IF;

 outcode:=gms_receive_visit(op1,visit1,device_id,jsonb_build_object(
  'task_id',task1::text,'subscriber_id',subscriber_id::text,
  'installation_id',installation_id::text,'zone_id',zone_id::text,
  'event_kind','reading','reading_value_kwh','101.43',
  'captured_at_device',snap1::text,'captured_offset_minutes',120),repeat('a',64)::char(64));
 IF outcode<>'accepted' THEN RAISE EXCEPTION 'QA FAIL: first visit not accepted'; END IF;
 IF gms_receive_visit(op1,visit1,device_id,jsonb_build_object('ignored',true),repeat('a',64)::char(64))<>'already_received'
 THEN RAISE EXCEPTION 'QA FAIL: retry not idempotent'; END IF;
 IF gms_receive_visit(op1,visit1,device_id,'{}'::jsonb,repeat('b',64)::char(64))<>'conflict'
 THEN RAISE EXCEPTION 'QA FAIL: collision not detected'; END IF;
 PERFORM gms_register_ready_photo(visit1,'qa/reading1.jpg',repeat('c',64)::char(64),1234,'image/jpeg',true);
 -- Verify bad-precision visit is REJECTED by base CHECK on numeric with no typmod.
 failed:=false;
 BEGIN
  PERFORM gms_receive_visit(gen_random_uuid(),gen_random_uuid(),device_id,
   jsonb_build_object('task_id',task1::text,'subscriber_id',subscriber_id::text,
    'installation_id',installation_id::text,'zone_id',zone_id::text,
    'event_kind','reading','reading_value_kwh','121.987',
    'captured_at_device',snap1::text),repeat('d',64)::char(64));
 EXCEPTION WHEN OTHERS THEN failed:=true; END;
 IF NOT failed THEN RAISE EXCEPTION 'QA FAIL: accepted 121.987 extra decimal place'; END IF;

 PERFORM set_config('gms.actor_id',manager_id::text,true);
 PERFORM gms_verify_capture_time(visit1,snap1,false,'QA validated');
 read1:=gms_approve_visit(visit1);
 failed:=false;
 BEGIN UPDATE approved_readings SET current_value_kwh=9999 WHERE id=read1;
 EXCEPTION WHEN OTHERS THEN failed:=true; END;
 IF NOT failed THEN RAISE EXCEPTION 'QA FAIL: approved value mutated'; END IF;
 failed:=false;
 BEGIN UPDATE field_visits SET reading_value_kwh=9999 WHERE id=visit1;
 EXCEPTION WHEN OTHERS THEN failed:=true; END;
 IF NOT failed THEN RAISE EXCEPTION 'QA FAIL: raw field value mutated'; END IF;
 failed:=false;
 BEGIN
  INSERT INTO ledger_entries(subscriber_id,source_type,source_id,signed_amount_ils)
   VALUES(subscriber_id,'final_statement',gen_random_uuid(),10);
 EXCEPTION WHEN OTHERS THEN failed:=true; END;
 IF NOT failed THEN RAISE EXCEPTION 'QA FAIL: phantom ledger source accepted'; END IF;
 failed:=false;
 BEGIN
  INSERT INTO tariff_change_events(cycle_id,effective_on,proposed_rate_ils_per_kwh,recorded_by)
   VALUES(cycle1,current_date+10,99,manager_id);
 EXCEPTION WHEN OTHERS THEN failed:=true; END;
 IF NOT failed THEN RAISE EXCEPTION 'QA FAIL: out-of-range price event accepted'; END IF;

 n:=gms_finalize_cycle(cycle1,15);
 IF n<>1 THEN RAISE EXCEPTION 'QA FAIL: wrong number of finalized statements'; END IF;
 SELECT * INTO statement1 FROM statement_versions WHERE cycle_id=cycle1 AND subscriber_id=qa.subscriber_id AND state='final';
 IF statement1.charge_exact_ils<>21.45 OR statement1.requested_whole_ils<>21
   OR statement1.carry_out_ils<>0.45 THEN
  RAISE EXCEPTION 'QA FAIL: 21.45 must yield 21 whole and 0.45 carried'; END IF;
 failed:=false;
 BEGIN UPDATE statement_versions SET requested_whole_ils=999 WHERE id=statement1.id;
 EXCEPTION WHEN OTHERS THEN failed:=true; END;
 IF NOT failed THEN RAISE EXCEPTION 'QA FAIL: final statement mutated'; END IF;
 failed:=false;
 BEGIN UPDATE cycle_price_decisions SET final_rate_ils_per_kwh=999 WHERE cycle_id=cycle1;
 EXCEPTION WHEN OTHERS THEN failed:=true; END;
 IF NOT failed THEN RAISE EXCEPTION 'QA FAIL: final tariff mutated'; END IF;
 failed:=false;
 BEGIN UPDATE reading_cycles SET ends_on=ends_on+1 WHERE id=cycle1;
 EXCEPTION WHEN OTHERS THEN failed:=true; END;
 IF NOT failed THEN RAISE EXCEPTION 'QA FAIL: closed period dates mutated'; END IF;

 payment1:=gms_record_payment(subscriber_id,21,snap1,'cash','QA-RECEIPT-1',payment_key);
 payment1_dup:=gms_record_payment(subscriber_id,21,snap1,'cash','QA-RECEIPT-1',payment_key);
 IF payment1<>payment1_dup OR (SELECT count(*) FROM payment_receipts WHERE idempotency_key=payment_key)<>1 THEN
  RAISE EXCEPTION 'QA FAIL: duplicate payment created'; END IF;
 IF gms_ledger_balance(subscriber_id)<>0.45 THEN
  RAISE EXCEPTION 'QA FAIL: payment failed to leave 0.45 in exact receivable'; END IF;

 INSERT INTO reading_cycles(id,label,starts_on,ends_on,state,opened_by)
 VALUES(cycle2,'QA-C2',current_date+2,current_date+8,'open',manager_id);
 INSERT INTO cycle_price_decisions(cycle_id,provisional_rate_ils_per_kwh) VALUES(cycle2,20);
 INSERT INTO reading_tasks(id,cycle_id,subscriber_id,installation_id,zone_id,
   assigned_employee_id,planned_for,source,created_by)
 VALUES(task2,cycle2,subscriber_id,installation_id,zone_id,employee_id,current_date+4,'scheduled',manager_id);
 PERFORM set_config('gms.actor_id',employee_id::text,true);
 outcode:=gms_receive_visit(op2,visit2,device_id,jsonb_build_object(
   'task_id',task2::text,'subscriber_id',subscriber_id::text,
   'installation_id',installation_id::text,'zone_id',zone_id::text,
   'event_kind','reading','reading_value_kwh','102.22',
   'captured_at_device',snap2::text),repeat('e',64)::char(64));
 IF outcode<>'accepted' THEN RAISE EXCEPTION 'QA FAIL: second visit'; END IF;
 PERFORM gms_register_ready_photo(visit2,'qa/reading2.jpg',repeat('f',64)::char(64),4321,'image/jpeg',true);
 PERFORM set_config('gms.actor_id',manager_id::text,true);
 PERFORM gms_verify_capture_time(visit2,snap2,false,'QA validated');
 read2:=gms_approve_visit(visit2);
 n:=gms_finalize_cycle(cycle2,20);
 SELECT * INTO statement2 FROM statement_versions WHERE cycle_id=cycle2 AND subscriber_id=qa.subscriber_id AND state='final';
 IF statement2.charge_exact_ils<>15.80 OR statement2.requested_whole_ils<>16
  OR statement2.carry_in_ils<>0.45 OR statement2.carry_out_ils<>0.25 THEN
  RAISE EXCEPTION 'QA FAIL: 0.45 + 15.80 must request 16 and carry 0.25'; END IF;
 IF gms_ledger_balance(subscriber_id)<>16.25 THEN
  RAISE EXCEPTION 'QA FAIL: exact ledger after two cycles'; END IF;
 IF (SELECT count(*) FROM final_reading_allocations) <> 2 THEN
  RAISE EXCEPTION 'QA FAIL: approved readings not uniquely allocated'; END IF;

 PERFORM gms_record_adjustment(subscriber_id,cycle1,NULL,-20,'QA old closed-cycle correction',gen_random_uuid());
 IF gms_ledger_balance(subscriber_id)<>-3.75 THEN
  RAISE EXCEPTION 'QA FAIL: negative credit balance not preserved'; END IF;
 IF (SELECT credit_balance_ils FROM billing_accounts WHERE subscriber_id=qa.subscriber_id)<>3.75 THEN
  RAISE EXCEPTION 'QA FAIL: credit balance projection'; END IF;
 RAISE NOTICE 'GMS QA PASS: precision, role guard, immutability, no phantom sources, pricing, two-cycle fractions, credit';
END qa;
$qa$;
ROLLBACK;
