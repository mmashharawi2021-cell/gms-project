from __future__ import annotations

from contextlib import contextmanager
from typing import Any, Iterator
from uuid import UUID

import psycopg
from psycopg.rows import dict_row
from psycopg_pool import ConnectionPool

from app.errors import from_db


class Database:
    def __init__(self, url: str, max_size: int = 10):
        self.pool = ConnectionPool(url, min_size=1, max_size=max_size, open=False,
                                   kwargs={"row_factory": dict_row, "autocommit": True})

    def open(self):
        self.pool.open(wait=True, timeout=30)

    def close(self):
        self.pool.close()

    @contextmanager
    def tx(self, actor: UUID | None = None) -> Iterator[psycopg.Connection]:
        """One atomic transaction. The authenticated user id is bound with SET LOCAL semantics,
        so it can never leak to another request that reuses the pooled connection."""
        with self.pool.connection() as conn:
            try:
                with conn.transaction():
                    if actor is not None:
                        conn.execute("SELECT set_config('gms.actor_id', %s, true)", (str(actor),))
                    yield conn
            except psycopg.Error as exc:
                mapped = from_db(exc)
                if mapped:
                    raise mapped from exc
                raise

    def all(self, actor: UUID | None, sql: str, params: Any = ()) -> list[dict]:
        with self.tx(actor) as c:
            return c.execute(sql, params).fetchall()

    def one(self, actor: UUID | None, sql: str, params: Any = ()) -> dict | None:
        with self.tx(actor) as c:
            return c.execute(sql, params).fetchone()

    def scalar(self, actor: UUID | None, sql: str, params: Any = ()):
        row = self.one(actor, sql, params)
        return next(iter(row.values())) if row else None
