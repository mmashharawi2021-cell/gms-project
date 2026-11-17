"""Business identity settings (name, phone, statement footer).

Revision ID: 0002
Revises: 0001
"""
import sys
from pathlib import Path

from alembic import op

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from sqlfiles import run_sql_file  # noqa: E402

revision = "0002"
down_revision = "0001"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.execute("SET ROLE gms_owner")
    run_sql_file("0007_identity_settings.sql")
    op.execute("RESET ROLE")


def downgrade() -> None:
    op.execute("SET ROLE gms_owner")
    op.execute("ALTER TABLE gms.system_settings DISABLE TRIGGER trg_manager_guard")
    op.execute("DELETE FROM gms.system_settings WHERE key IN ('business_name','business_phone','statement_footer')")
    op.execute("ALTER TABLE gms.system_settings ENABLE TRIGGER trg_manager_guard")
    op.execute("RESET ROLE")
