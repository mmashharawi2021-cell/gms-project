from __future__ import annotations

import datetime as dt
import json
import uuid
from decimal import Decimal
from typing import Annotated, Any

from fastapi import Response
from pydantic import BeforeValidator, Field


def dec_str(d: Decimal) -> str:
    """Exact decimal text without exponent and without meaningless trailing zeros."""
    s = format(d, "f")
    if "." in s:
        s = s.rstrip("0").rstrip(".")
    return "0" if s in ("-0", "") else s


def _default(o: Any):
    if isinstance(o, Decimal):
        return dec_str(o)
    if isinstance(o, uuid.UUID):
        return str(o)
    if isinstance(o, (dt.datetime, dt.date)):
        return o.isoformat()
    raise TypeError(f"not serialisable: {type(o).__name__}")


def dumps(content: Any) -> bytes:
    return json.dumps(content, ensure_ascii=False, default=_default, separators=(",", ":")).encode()


class JSON(Response):
    """Decimals are always sent as exact strings (never floats)."""

    media_type = "application/json"

    def render(self, content: Any) -> bytes:
        return dumps(content)


def ok(content: Any = None, status: int = 200) -> JSON:
    return JSON(content if content is not None else {"ok": True}, status_code=status)


def _no_float(v: Any):
    if isinstance(v, float):
        raise ValueError("القيم العشرية تُرسل كنص (مثل \"121.98\") لتجنب أي تقريب")
    if isinstance(v, str):
        v = v.strip()
    return v


Kwh = Annotated[Decimal, BeforeValidator(_no_float), Field(ge=0, lt=Decimal("100000000000000"), decimal_places=2)]
Money = Annotated[Decimal, BeforeValidator(_no_float), Field(decimal_places=2, gt=Decimal("-1000000000"), lt=Decimal("1000000000"))]
PositiveMoney = Annotated[Decimal, BeforeValidator(_no_float), Field(gt=0, decimal_places=2, lt=Decimal("1000000000"))]
Rate = Annotated[Decimal, BeforeValidator(_no_float), Field(ge=0, decimal_places=6, lt=Decimal("10000000000"))]
Text = Annotated[str, Field(min_length=1, max_length=500)]
LongText = Annotated[str, Field(min_length=1, max_length=2000)]


def page(limit: int, offset: int) -> tuple[int, int]:
    return max(1, min(limit, 500)), max(0, offset)
