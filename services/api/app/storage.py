"""Object storage for meter photos. Filesystem for dev/tests, S3-compatible (MinIO) otherwise."""
from __future__ import annotations

import io
import os
from pathlib import Path

from app.config import Settings


class Storage:
    def put(self, key: str, data: bytes, content_type: str) -> None: ...
    def get(self, key: str) -> bytes | None: ...


def _safe_key(key: str) -> str:
    parts = key.split("/")
    if not key or key.startswith("/") or any(p in ("", ".", "..") or "\\" in p for p in parts):
        raise ValueError("unsafe object key")
    return key


class FileStorage(Storage):
    def __init__(self, root: str):
        self.root = Path(root).resolve()
        self.root.mkdir(parents=True, exist_ok=True)

    def _path(self, key: str) -> Path:
        p = (self.root / _safe_key(key)).resolve()
        if self.root not in p.parents:
            raise ValueError("unsafe object key")
        return p

    def put(self, key, data, content_type):
        p = self._path(key)
        p.parent.mkdir(parents=True, exist_ok=True)
        tmp = p.with_suffix(p.suffix + ".part")
        with open(tmp, "wb") as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, p)  # atomic: a half-written object is never visible

    def get(self, key):
        p = self._path(key)
        return p.read_bytes() if p.is_file() else None


class S3Storage(Storage):
    def __init__(self, s: Settings):
        from minio import Minio

        self.bucket = s.s3_bucket
        self.client = Minio(s.s3_endpoint, access_key=s.s3_access_key, secret_key=s.s3_secret_key, secure=s.s3_secure)
        if not self.client.bucket_exists(self.bucket):
            self.client.make_bucket(self.bucket)

    def put(self, key, data, content_type):
        self.client.put_object(self.bucket, _safe_key(key), io.BytesIO(data), len(data), content_type=content_type)

    def get(self, key):
        from minio.error import S3Error

        try:
            resp = self.client.get_object(self.bucket, _safe_key(key))
        except S3Error as e:
            if e.code in ("NoSuchKey", "NoSuchObject"):
                return None
            raise
        try:
            return resp.read()
        finally:
            resp.close()
            resp.release_conn()


def make_storage(s: Settings) -> Storage:
    return S3Storage(s) if s.storage_backend == "s3" else FileStorage(s.storage_dir)


def sniff_image(data: bytes) -> str | None:
    if data.startswith(b"\xff\xd8\xff"):
        return "image/jpeg"
    if data.startswith(b"\x89PNG\r\n\x1a\n"):
        return "image/png"
    if len(data) > 12 and data[:4] == b"RIFF" and data[8:12] == b"WEBP":
        return "image/webp"
    return None
