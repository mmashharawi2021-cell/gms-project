"""Idempotent database setup for a deployment:
1) apply migrations (Alembic, revision 0001+), 2) create/refresh the restricted API login and grant it gms_api only.

Env: GMS_MIGRATION_DATABASE_URL (admin/owner login), GMS_DB_APP_USER, GMS_DB_APP_PASSWORD.
"""
from __future__ import annotations

import os
import re
import subprocess
import sys
from pathlib import Path

import psycopg
from psycopg import sql


def main() -> int:
    admin = os.environ["GMS_MIGRATION_DATABASE_URL"]
    user, password = os.environ["GMS_DB_APP_USER"], os.environ["GMS_DB_APP_PASSWORD"]
    if not re.fullmatch(r"[a-z_][a-z0-9_]{2,40}", user):
        print("GMS_DB_APP_USER must be a simple lowercase identifier", file=sys.stderr)
        return 2
    if len(password) < 16:
        print("GMS_DB_APP_PASSWORD must be at least 16 characters", file=sys.stderr)
        return 2
    subprocess.run([sys.executable, "-m", "alembic", "upgrade", "head"], cwd=Path(__file__).resolve().parents[2], check=True)
    with psycopg.connect(admin, autocommit=True) as c:
        exists = c.execute("SELECT 1 FROM pg_roles WHERE rolname=%s", (user,)).fetchone()
        stmt = "ALTER ROLE {} LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE INHERIT PASSWORD {}" if exists else \
               "CREATE ROLE {} LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE INHERIT PASSWORD {}"
        c.execute(sql.SQL(stmt).format(sql.Identifier(user), sql.Literal(password)))
        c.execute(sql.SQL("GRANT gms_api TO {}").format(sql.Identifier(user)))
        db = c.execute("SELECT current_database()").fetchone()[0]
        c.execute(sql.SQL("REVOKE ALL ON DATABASE {} FROM PUBLIC").format(sql.Identifier(db)))
        c.execute(sql.SQL("GRANT CONNECT ON DATABASE {} TO {}").format(sql.Identifier(db), sql.Identifier(user)))
        c.execute("REVOKE CREATE ON SCHEMA public FROM PUBLIC")
        # The API login must never own objects nor be able to become the owner role.
        if c.execute("SELECT pg_has_role(%s,'gms_owner','MEMBER')", (user,)).fetchone()[0]:
            print("API login must NOT be a member of gms_owner", file=sys.stderr)
            return 3
    print(f"database ready; API login '{user}' has gms_api privileges only")
    return 0


if __name__ == "__main__":
    sys.exit(main())
