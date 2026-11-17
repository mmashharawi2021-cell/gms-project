"""GMS baseline: schema gms, guards, finance engine, operations, field/review, grants.

Revision ID: 0001
Revises:
"""
import sys
from pathlib import Path

from alembic import op

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from sqlfiles import run_sql_file  # noqa: E402

revision = "0001"
down_revision = None
branch_labels = None
depends_on = None

OWNER_FILES = [
    "0001_schema.sql",
    "0002_guards.sql",
    "0003_finance.sql",
    "0004_operations.sql",
    "0005_field_review.sql",
    "0006_grants.sql",
]


def upgrade() -> None:
    run_sql_file("0000_roles.sql")
    op.execute("SET ROLE gms_owner")
    for name in OWNER_FILES:
        run_sql_file(name)
    op.execute("RESET ROLE")


def downgrade() -> None:
    # Rollback policy: the baseline is only ever rolled back on an EMPTY/disposable database.
    # Refuse when business rows exist; production rollback = restore the pre-migration backup.
    bind = op.get_bind()
    if bind.exec_driver_sql("SELECT EXISTS (SELECT 1 FROM gms.subscribers) OR EXISTS (SELECT 1 FROM gms.ledger_entries)").scalar():
        raise RuntimeError("Refusing to drop schema gms: it contains business data. Restore from backup instead.")
    op.execute("DROP SCHEMA gms CASCADE")
