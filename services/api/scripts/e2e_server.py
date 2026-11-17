"""Start a disposable full API for browser E2E tests: NEW database in the local test container -> migrations ->
restricted API login -> one synthetic manager (E2E only) -> uvicorn. Never point this at a real database."""
from __future__ import annotations

import os
import subprocess
import sys
import tempfile
import uuid
from pathlib import Path

import psycopg

API_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(API_DIR))
from app.security import hash_password  # noqa: E402

ADMIN = os.environ.get("E2E_ADMIN_URL", "postgresql://postgres:gms_test_only@127.0.0.1:55432/postgres")
PORT = os.environ.get("E2E_API_PORT", "8011")


def main() -> None:
    info = psycopg.conninfo.conninfo_to_dict(ADMIN)
    if info.get("host") not in ("127.0.0.1", "localhost"):
        raise SystemExit("E2E server only runs against a local disposable PostgreSQL")
    name = "gms_e2e_" + uuid.uuid4().hex[:8]
    with psycopg.connect(ADMIN, autocommit=True) as c:
        for (old,) in c.execute("SELECT datname FROM pg_database WHERE datname LIKE 'gms\\_e2e\\_%'").fetchall():
            c.execute(f'DROP DATABASE IF EXISTS "{old}" WITH (FORCE)')
        c.execute(f'CREATE DATABASE "{name}"')
    mig = psycopg.conninfo.make_conninfo(ADMIN, dbname=name)
    env = dict(os.environ, GMS_MIGRATION_DATABASE_URL=f"postgresql://{info['user']}:{info['password']}@{info['host']}:{info['port']}/{name}",
               GMS_DB_APP_USER="gms_app_e2e", GMS_DB_APP_PASSWORD="e2e-only-password-0001")
    subprocess.run([sys.executable, "-m", "app.ops.dbsetup"], cwd=API_DIR, env=env, check=True)
    with psycopg.connect(mig, autocommit=True) as c:
        c.execute("INSERT INTO gms.app_users(username,password_hash,full_name,role) VALUES ('e2e-manager',%s,'مدير الاختبار','manager')",
                  (hash_password("E2e-Manager-Pass1"),))
    tmp = Path(tempfile.mkdtemp(prefix="gms-e2e-"))
    os.environ.update(GMS_DATABASE_URL=psycopg.conninfo.make_conninfo(mig, user="gms_app_e2e", password="e2e-only-password-0001"),
                      GMS_JWT_SECRET="e2e-secret-" + uuid.uuid4().hex + uuid.uuid4().hex,
                      GMS_STORAGE_DIR=str(tmp / "objects"), GMS_BACKUP_DIR=str(tmp / "backups"))
    print(f"E2E database {name}", flush=True)
    # stay in the foreground (os.execv on Windows detaches) so the test runner can stop the server
    sys.exit(subprocess.call([sys.executable, "-m", "uvicorn", "app.main:create_app", "--factory", "--host", os.environ.get("E2E_API_HOST", "127.0.0.1"), "--port", PORT]))


if __name__ == "__main__":
    main()
