"""Alembic environment. Migrations are plain SQL files in db/sql executed in order.

The migration login must be allowed to create roles (first run) and becomes a member of
gms_owner; all objects are created while SET ROLE gms_owner is active.
"""
import os

from alembic import context
from sqlalchemy import create_engine, pool

url = os.environ.get("GMS_MIGRATION_DATABASE_URL")
if not url:
    raise RuntimeError("Set GMS_MIGRATION_DATABASE_URL (postgresql+psycopg://...) to run migrations")
if url.startswith("postgresql://"):
    url = "postgresql+psycopg://" + url[len("postgresql://"):]


def run_migrations_online() -> None:
    engine = create_engine(url, poolclass=pool.NullPool)
    with engine.connect() as connection:
        context.configure(connection=connection, target_metadata=None, transaction_per_migration=True)
        with context.begin_transaction():
            context.run_migrations()


if context.is_offline_mode():
    raise RuntimeError("Offline mode is not supported: SQL files are executed directly")
run_migrations_online()
