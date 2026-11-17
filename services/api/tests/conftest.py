"""Shared fixtures. Every test runs on its OWN database cloned from a freshly migrated template
inside the disposable PostgreSQL container (never a real/production database).

Required: GMS_TEST_ADMIN_URL (default points at the local docker test container on 55432).
"""
from __future__ import annotations

import os
import subprocess
import sys
import uuid
from pathlib import Path

import psycopg
import pytest

from tests.world import World

API_DIR = Path(__file__).resolve().parents[1]
ADMIN_URL = os.environ.get("GMS_TEST_ADMIN_URL", "postgresql://postgres:gms_test_only@127.0.0.1:55432/postgres")
APP_LOGIN = "gms_app_test"
# pg_dump/pg_restore must match the server major version: by default use the tools inside the test container.
if "GMS_TEST_ADMIN_URL" not in os.environ:
    os.environ.setdefault("GMS_PG_DOCKER", "gms-pg-test")
    os.environ.setdefault("MSYS_NO_PATHCONV", "1")
APP_PASSWORD = "gms_app_test_pw"


def _url(dbname: str, user: str | None = None, password: str | None = None) -> str:
    info = psycopg.conninfo.conninfo_to_dict(ADMIN_URL)
    info["dbname"] = dbname
    if user:
        info["user"], info["password"] = user, password
    return psycopg.conninfo.make_conninfo(**info)


def _admin():
    return psycopg.connect(ADMIN_URL, autocommit=True)


@pytest.fixture(scope="session")
def template_db() -> str:
    name = "gms_tpl_" + uuid.uuid4().hex[:10]
    with _admin() as conn:
        host = conn.info.host
        if host not in ("127.0.0.1", "localhost", "::1") and not os.environ.get("GMS_TEST_ALLOW_REMOTE"):
            raise RuntimeError(f"Refusing to run destructive tests against non-local host {host}")
        conn.execute(f'CREATE DATABASE "{name}"')
        if not conn.execute("SELECT 1 FROM pg_roles WHERE rolname = %s", (APP_LOGIN,)).fetchone():
            conn.execute(f"CREATE ROLE {APP_LOGIN} LOGIN PASSWORD '{APP_PASSWORD}'")
    info = psycopg.conninfo.conninfo_to_dict(ADMIN_URL)
    mig_url = f"postgresql://{info['user']}:{info['password']}@{info['host']}:{info['port']}/{name}"
    env = dict(os.environ, GMS_MIGRATION_DATABASE_URL=mig_url)
    subprocess.run([sys.executable, "-m", "alembic", "upgrade", "head"], cwd=API_DIR, env=env, check=True, capture_output=True)
    with _admin() as conn:
        conn.execute(f"GRANT gms_api TO {APP_LOGIN}")
    yield name
    with _admin() as conn:
        conn.execute(f'DROP DATABASE IF EXISTS "{name}" WITH (FORCE)')


@pytest.fixture()
def db_name(template_db: str) -> str:
    name = "gms_t_" + uuid.uuid4().hex[:12]
    with _admin() as conn:
        conn.execute(f'CREATE DATABASE "{name}" TEMPLATE "{template_db}"')
        conn.execute(f'GRANT CONNECT ON DATABASE "{name}" TO {APP_LOGIN}')
    yield name
    with _admin() as conn:
        conn.execute(f'DROP DATABASE IF EXISTS "{name}" WITH (FORCE)')


@pytest.fixture()
def app_url(db_name: str) -> str:
    """Connection string of the restricted API login (member of gms_api only)."""
    return _url(db_name, APP_LOGIN, APP_PASSWORD)


@pytest.fixture()
def owner_url(db_name: str) -> str:
    return _url(db_name)


@pytest.fixture()
def world(app_url: str) -> World:
    w = World(app_url)
    yield w
    w.close()


# ---------------------------------------------------------------- API fixtures
@pytest.fixture()
def api(app_url, tmp_path):
    from fastapi.testclient import TestClient

    from app.config import Settings
    from app.main import create_app
    from app.security import hash_password
    from tests.apiclient import ApiWorld

    settings = Settings(database_url=app_url, jwt_secret="test-secret-" + "x" * 40, storage_dir=str(tmp_path / "objects"),
                        backup_dir=str(tmp_path / "backups"))
    app = create_app(settings)
    with psycopg.connect(app_url, autocommit=True) as c:
        c.execute("INSERT INTO gms.app_users(username,password_hash,full_name,role) VALUES ('qa-manager',%s,'QA Manager','manager')",
                  (hash_password("Manager-Pass-1"),))
    with TestClient(app) as client:
        yield ApiWorld(client, app, app_url)
