import os
from pathlib import Path

from alembic import op


def sql_dir() -> Path:
    env = os.environ.get("GMS_SQL_DIR")
    if env:
        return Path(env)
    here = Path(__file__).resolve()
    for parent in here.parents:
        candidate = parent / "db" / "sql"
        if candidate.is_dir():
            return candidate
    raise RuntimeError("db/sql directory not found; set GMS_SQL_DIR")


def run_sql_file(name: str) -> None:
    text = (sql_dir() / name).read_text(encoding="utf-8")
    # Raw driver cursor, no parameters: psycopg sends the script verbatim (simple protocol),
    # so multi-statement files and literal % characters work. Same transaction as Alembic.
    raw = op.get_bind().connection.dbapi_connection
    with raw.cursor() as cur:
        cur.execute(text)
