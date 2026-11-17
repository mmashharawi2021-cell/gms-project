"""NFR load test (SRS §12): 5,000 subscribers, 20 employees, 20 zones, one week of real readings with photos.
Measures API latency for normal searches (target: 95% < 3 s) and the duration of heavy operations.
Runs ONLY against the local disposable test container. Usage:  python -m tests.perf.run_perf [subscribers] [employees]
"""
from __future__ import annotations

import json
import os
import statistics
import subprocess
import sys
import time
import uuid
from datetime import timedelta
from decimal import Decimal
from pathlib import Path

import psycopg
from fastapi.testclient import TestClient

from app.config import Settings
from app.main import create_app
from app.security import hash_password
from tests.conftest import ADMIN_URL, API_DIR, APP_LOGIN, APP_PASSWORD, _url
from tests.world import World

N_SUBS = int(sys.argv[1]) if len(sys.argv) > 1 else 5000
N_EMP = int(sys.argv[2]) if len(sys.argv) > 2 else 20


def timed(label, fn, results):
    t = time.perf_counter()
    out = fn()
    results[label] = round(time.perf_counter() - t, 2)
    print(f"{label}: {results[label]} s", flush=True)
    return out


def main() -> None:
    import logging
    logging.getLogger("httpx").setLevel(logging.WARNING)
    results: dict = {"subscribers": N_SUBS, "employees": N_EMP}
    name = "gms_perf_" + uuid.uuid4().hex[:8]
    with psycopg.connect(ADMIN_URL, autocommit=True) as c:
        c.execute(f'CREATE DATABASE "{name}"')
        if not c.execute("SELECT 1 FROM pg_roles WHERE rolname=%s", (APP_LOGIN,)).fetchone():
            c.execute(f"CREATE ROLE {APP_LOGIN} LOGIN PASSWORD '{APP_PASSWORD}'")
    info = psycopg.conninfo.conninfo_to_dict(ADMIN_URL)
    env = dict(os.environ, GMS_MIGRATION_DATABASE_URL=f"postgresql://{info['user']}:{info['password']}@{info['host']}:{info['port']}/{name}")
    subprocess.run([sys.executable, "-m", "alembic", "upgrade", "head"], cwd=API_DIR, env=env, check=True, capture_output=True)
    with psycopg.connect(ADMIN_URL, autocommit=True) as c:
        c.execute(f"GRANT gms_api TO {APP_LOGIN}")
        c.execute(f'GRANT CONNECT ON DATABASE "{name}" TO {APP_LOGIN}')
    app_url = _url(name, APP_LOGIN, APP_PASSWORD)
    try:
        w = World(app_url)
        w.bootstrap()
        with w.tx(w.manager) as c:
            c.execute("UPDATE gms.app_users SET password_hash=%s WHERE id=%s", (hash_password("Perf-Manager-1"), w.manager))
        emps, zones, devices = [], [], []
        for i in range(N_EMP):
            z = w.add_zone(f"PERF-Z{i:02d}")
            e = w.add_employee(f"perf-emp-{i:02d}")
            w.grant(e, z)
            emps.append(e); zones.append(z); devices.append(w.add_device(e))

        def seed_subscribers():
            subs = []
            for i in range(N_SUBS):
                subs.append((*w.add_subscriber(f"{1000 + i % 900}.{i % 100:02d}", zone=zones[i % N_EMP]), i % N_EMP))
            return subs
        subs = timed("seed_subscribers_s", seed_subscribers, results)

        cycle = w.cycle("PERF-W1", -6, 0, rate="14.5")
        with w.tx(w.manager) as c:
            c.execute("UPDATE gms.subscriber_schedules SET next_due_override=%s, changed_by=%s", (w.today - timedelta(days=3), w.manager))
        results["generated_tasks"] = timed("generate_due_tasks_s", lambda: w.call(w.manager, "SELECT gms.generate_due_tasks(%s)", (cycle,)), results)
        tasks = {r["subscriber_id"]: r["id"] for r in w.q("SELECT id, subscriber_id FROM gms.reading_tasks WHERE cycle_id=%s", (cycle,))}

        def field_day():
            visits = []
            for idx, (sub, inst, k) in enumerate(subs):
                p = w.payload(sub, inst, str(Decimal(2000) + Decimal(idx % 500) / 100), w.at(-3, 6 + idx % 12), task=tasks[sub], zone=zones[k])
                res = w.receive(p, employee=emps[k], device=devices[k])
                assert res["result"] == "accepted", res
                w.photo(res["visit_id"], employee=emps[k])
                visits.append(res["visit_id"])
            return visits
        visits = timed("sync_visits_with_photos_s", field_day, results)
        results["sync_ms_per_visit"] = round(results["sync_visits_with_photos_s"] * 1000 / N_SUBS, 1)

        def approve_all():
            for v in visits:
                w.approve(v)
        timed("approve_all_s", approve_all, results)
        results["approve_ms_per_visit"] = round(results["approve_all_s"] * 1000 / N_SUBS, 1)

        settings = Settings(database_url=app_url, jwt_secret="perf-" + "x" * 40, storage_dir=str(Path(os.environ.get("TEMP", "/tmp")) / "gms-perf"))
        with TestClient(create_app(settings)) as client:
            tok = client.post("/api/v1/auth/login", json={"username": "qa-manager", "password": "Perf-Manager-1", "client": "web"}).json()["access_token"]
            h = {"Authorization": f"Bearer {tok}"}
            gen = w.generator
            queries = [
                ("dashboard", "/api/v1/dashboard"),
                ("subscribers_page", "/api/v1/subscribers?limit=50"),
                ("subscribers_search_name", "/api/v1/subscribers?q=QA%20Subscriber%2042&limit=50"),
                ("subscribers_search_meter", "/api/v1/subscribers?q=QA-M-3999&limit=50"),
                ("subscribers_zone", f"/api/v1/subscribers?zone_id={zones[3 % len(zones)]}&limit=50"),
                ("subscriber_detail", f"/api/v1/subscribers/{subs[1234 % len(subs)][0]}"),
                ("visits_open", "/api/v1/visits?open_only=true&limit=100"),
                ("visits_by_employee", f"/api/v1/visits?employee_id={emps[5 % len(emps)]}&limit=100"),
                ("visit_detail", f"/api/v1/visits/{visits[777 % len(visits)]}"),
                ("tasks_cycle", f"/api/v1/tasks?cycle_id={cycle}&limit=200"),
                ("cycle_detail", f"/api/v1/cycles/{cycle}"),
                ("ledger", f"/api/v1/subscribers/{subs[1234 % len(subs)][0]}/ledger"),
            ]
            lat: dict[str, list[float]] = {k: [] for k, _ in queries}
            for _ in range(10):
                for k, url in queries:
                    t = time.perf_counter()
                    r = client.get(url, headers=h)
                    assert r.status_code == 200, (url, r.status_code, r.text[:200])
                    lat[k].append(time.perf_counter() - t)
            allv = sorted(x for v in lat.values() for x in v)
            results["search_p95_s"] = round(allv[int(len(allv) * 0.95) - 1], 3)
            results["search_max_s"] = round(allv[-1], 3)
            results["per_query_median_ms"] = {k: round(statistics.median(v) * 1000, 1) for k, v in lat.items()}

            def heavy(label, method, url, **kw):
                t = time.perf_counter()
                r = getattr(client, method)(url, headers=h, **kw)
                assert r.status_code in (200, 201), (url, r.status_code, r.text[:300])
                results[label] = round(time.perf_counter() - t, 2)
                print(f"{label}: {results[label]} s", flush=True)
                return r
            heavy("estimate_provisional_s", "get", f"/api/v1/cycles/{cycle}/estimate")
            heavy("report_consumption_pdf_provisional_s", "get", f"/api/v1/reports/consumption?format=pdf&cycle_id={cycle}")
            r = heavy("finalize_cycle_s", "post", f"/api/v1/cycles/{cycle}/finalize", json={"final_rate_ils_per_kwh": "14.5", "confirm": True})
            results["statements"] = r.json()["statements"]
            heavy("report_statements_xlsx_s", "get", f"/api/v1/reports/statements?format=xlsx&cycle_id={cycle}")
            heavy("report_statements_pdf_s", "get", f"/api/v1/reports/statements?format=pdf&cycle_id={cycle}")
            heavy("print_statements_one_generator_pdf_s", "get", f"/api/v1/reports/statements/{cycle}/print?generator_id={gen}")
            heavy("report_arrears_xlsx_s", "get", "/api/v1/reports/arrears?format=xlsx")
            results["ledger_rows"] = w.val("SELECT count(*) FROM gms.ledger_entries")
            results["ledger_sum_ils"] = str(w.val("SELECT sum(signed_amount_ils) FROM gms.ledger_entries"))
            results["expected_sum_ils"] = str(sum((Decimal(2000) + Decimal(i % 500) / 100 - Decimal(f"{1000 + i % 900}.{i % 100:02d}")) * Decimal("14.5") for i in range(N_SUBS)))
            results["target_met"] = results["search_p95_s"] < 3
        print(json.dumps(results, ensure_ascii=False, indent=1))
        out = API_DIR.parents[1] / "docs" / "evidence" / "perf-5000.json"
        out.write_text(json.dumps(results, ensure_ascii=False, indent=1), encoding="utf-8")
        w.close()
    finally:
        with psycopg.connect(ADMIN_URL, autocommit=True) as c:
            c.execute(f'DROP DATABASE IF EXISTS "{name}" WITH (FORCE)')


if __name__ == "__main__":
    main()
