"""Short-lived signed links so the manager's browser can show private meter photos in <img> tags."""
from __future__ import annotations

import hashlib
import hmac
import time
import uuid


def sign(secret: str, photo_id: uuid.UUID, ttl_seconds: int = 600) -> str:
    exp = int(time.time()) + ttl_seconds
    sig = hmac.new(secret.encode(), f"photo:{photo_id}:{exp}".encode(), hashlib.sha256).hexdigest()
    return f"/api/v1/photos/{photo_id}/content?exp={exp}&sig={sig}"


def verify(secret: str, photo_id: uuid.UUID, exp: int, sig: str) -> bool:
    if exp < int(time.time()):
        return False
    expected = hmac.new(secret.encode(), f"photo:{photo_id}:{exp}".encode(), hashlib.sha256).hexdigest()
    return hmac.compare_digest(expected, sig)
