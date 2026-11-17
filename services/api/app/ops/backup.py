"""Backup / restore of the database AND the meter photos (BR-31, FR-30, AT-15, AT-31).

    python -m app.ops.backup run                         # scheduled/manual backup -> GMS_BACKUP_DIR/gms-YYYYmmddTHHMMSSZ/
    python -m app.ops.backup restore <dir> <new_db>      # restore into a NEW, empty database + target photo storage, then verify
    python -m app.ops.backup verify <dir> <db_url>       # compare a database + storage with a backup manifest

Environment:
  GMS_BACKUP_DATABASE_URL  owner/admin login of the live database (read-only use: pg_dump)
  GMS_RESTORE_ADMIN_URL    admin login on the cluster where the restore database is created
  GMS_PG_BIN               folder containing pg_dump / pg_restore (optional)
  GMS_BACKUP_DIR, GMS_STORAGE_* as for the API; GMS_BACKUP_RETENTION_DAYS (default 30)
A restore never touches an existing database: the target name must not exist.
"""
from __future__ import annotations

import hashlib
import json
import os
import shutil
import subprocess
import sys
import tarfile
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path

import psycopg

from app.storage import FileStorage, Storage

COUNT_TABLES = ["app_users", "generators", "zones", "subscribers", "meter_installations", "opening_baselines", "reading_cycles",
                "reading_tasks", "field_visits", "visit_photos", "visit_reviews", "approved_readings", "statement_versions",
                "statement_reading_lines", "final_reading_allocations", "payment_receipts", "payment_reversals",
                "financial_adjustments", "ledger_entries", "audit_logs"]


def _bin(name: str) -> str:
    folder = os.environ.get("GMS_PG_BIN")
    if folder:
        return str(Path(folder) / name)
    found = shutil.which(name)
    if found:
        return found
    for cand in sorted(Path("C:/Program Files/PostgreSQL").glob(f"*/bin/{name}.exe"), reverse=True):
        return str(cand)
    raise RuntimeError(f"{name} not found; install the PostgreSQL client or set GMS_PG_BIN")


def _pg_tool(tool: str, url: str, args: list[str], stdin=None, stdout=None) -> None:
    """Run pg_dump/pg_restore. Client major version must match the server: with GMS_PG_DOCKER=<container>
    the tool runs inside that PostgreSQL container (talking to its local server)."""
    container = os.environ.get("GMS_PG_DOCKER")
    if container:
        info = psycopg.conninfo.conninfo_to_dict(url)
        inner = psycopg.conninfo.make_conninfo(url, host="127.0.0.1", port="5432")
        cmd = ["docker", "exec", "-i", "-e", f"PGPASSWORD={info.get('password', '')}", container, tool, *args, "--dbname", inner]
    else:
        cmd = [_bin(tool), *args, "--dbname", url]
    proc = subprocess.run(cmd, stdin=stdin, stdout=stdout, stderr=subprocess.PIPE)
    if proc.returncode != 0:
        raise RuntimeError(f"{tool} failed: " + proc.stderr.decode(errors="replace").strip()[-2000:])


def _sha_file(p: Path) -> str:
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def snapshot(conn) -> dict:
    counts = {t: conn.execute(f"SELECT count(*) FROM gms.{t}").fetchone()[0] for t in COUNT_TABLES}
    ledger = conn.execute("SELECT COALESCE(sum(signed_amount_ils),0)::text FROM gms.ledger_entries").fetchone()[0]
    return {"counts": counts, "ledger_sum_ils": ledger}


def run_backup(db_url: str, storage: Storage, out_root: Path, kind: str = "scheduled", initiated_by=None) -> Path:
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    out = out_root / f"gms-{stamp}"
    out.mkdir(parents=True, exist_ok=False)
    with psycopg.connect(db_url, autocommit=True) as conn:
        job = conn.execute("INSERT INTO gms.backup_job_log(kind, initiated_by, artifact_name) VALUES (%s,%s,%s) RETURNING id",
                           (kind, initiated_by, out.name)).fetchone()[0]
        try:
            dump = out / "database.dump"
            with open(dump, "wb") as f:
                _pg_tool("pg_dump", db_url, ["--format=custom", "--no-password"], stdout=f)
            # snapshot AFTER the dump is a lower bound; the dump is a consistent snapshot, so verify uses the restored DB
            photos = conn.execute("SELECT id, object_key, sha256_hex, size_bytes FROM gms.visit_photos WHERE state='ready' ORDER BY id").fetchall()
            missing = []
            with tarfile.open(out / "photos.tar", "w") as tar:
                for _pid, key, sha, _size in photos:
                    data = storage.get(key)
                    if data is None or hashlib.sha256(data).hexdigest() != sha:
                        missing.append(key)
                        continue
                    info = tarfile.TarInfo(name=key)
                    info.size, info.mtime = len(data), int(time.time())
                    import io
                    tar.addfile(info, io.BytesIO(data))
            manifest = {"created_at": datetime.now(timezone.utc).isoformat(), "photos": [{"key": k, "sha256": s, "size": z} for _, k, s, z in photos],
                        "photos_missing_in_storage": missing,
                        "files": {"database.dump": _sha_file(dump), "photos.tar": _sha_file(out / "photos.tar")}}
            (out / "manifest.json").write_text(json.dumps(manifest, indent=1), encoding="utf-8")
            size = sum(p.stat().st_size for p in out.iterdir())
            conn.execute("""UPDATE gms.backup_job_log SET ended_at=now(), succeeded=%s, size_bytes=%s, sha256_hex=%s, notes=%s WHERE id=%s""",
                         (not missing, size, _sha_file(out / "manifest.json"),
                          f"{len(photos)} photos" + (f"; {len(missing)} missing/corrupt in storage" if missing else ""), job))
        except Exception as exc:
            conn.execute("UPDATE gms.backup_job_log SET ended_at=now(), succeeded=false, notes=%s WHERE id=%s", (type(exc).__name__, job))
            raise
    return out


def prune(out_root: Path, days: int) -> list[str]:
    """Retention: only removes folders this tool created (gms-<stamp>) older than `days`."""
    removed = []
    limit = datetime.now(timezone.utc) - timedelta(days=days)
    for d in out_root.glob("gms-*"):
        try:
            ts = datetime.strptime(d.name[4:], "%Y%m%dT%H%M%SZ").replace(tzinfo=timezone.utc)
        except ValueError:
            continue
        if ts < limit and (d / "manifest.json").exists():
            shutil.rmtree(d)
            removed.append(d.name)
    return removed


def restore(backup: Path, admin_url: str, new_db: str, storage: Storage) -> str:
    manifest = json.loads((backup / "manifest.json").read_text(encoding="utf-8"))
    for name, sha in manifest["files"].items():
        if _sha_file(backup / name) != sha:
            raise RuntimeError(f"backup file {name} is corrupt (checksum mismatch)")
    with psycopg.connect(admin_url, autocommit=True) as conn:
        if conn.execute("SELECT 1 FROM pg_database WHERE datname=%s", (new_db,)).fetchone():
            raise RuntimeError(f"database {new_db} already exists: restore only into a NEW database")
        for role in ("gms_owner", "gms_api"):
            if not conn.execute("SELECT 1 FROM pg_roles WHERE rolname=%s", (role,)).fetchone():
                conn.execute(f"CREATE ROLE {role} NOLOGIN")
        conn.execute(f'CREATE DATABASE "{new_db}"')
    target = psycopg.conninfo.make_conninfo(admin_url, dbname=new_db)
    with open(backup / "database.dump", "rb") as f:
        _pg_tool("pg_restore", target, ["--exit-on-error", "--no-password"], stdin=f)
    with tarfile.open(backup / "photos.tar") as tar:
        for m in tar.getmembers():
            if not m.isfile():
                continue
            data = tar.extractfile(m).read()
            storage.put(m.name, data, "application/octet-stream")
    return target


def verify(db_url: str, storage: Storage, backup: Path | None = None) -> dict:
    with psycopg.connect(db_url) as conn:
        snap = snapshot(conn)
        photos = conn.execute("SELECT object_key, sha256_hex FROM gms.visit_photos WHERE state='ready'").fetchall()
    bad = [k for k, sha in photos if (lambda d: d is None or hashlib.sha256(d).hexdigest() != sha)(storage.get(k))]
    result = {**snap, "photos_checked": len(photos), "photos_bad": bad}
    if backup:
        manifest = json.loads((backup / "manifest.json").read_text(encoding="utf-8"))
        result["manifest_photos"] = len(manifest["photos"])
    return result


def main(argv: list[str]) -> int:
    from app.config import Settings
    from app.storage import make_storage

    s = Settings(database_url=os.environ.get("GMS_BACKUP_DATABASE_URL", "postgresql://unused"), jwt_secret="x" * 32)
    out_root = Path(os.environ.get("GMS_BACKUP_DIR", s.backup_dir))
    if argv[:1] == ["run"]:
        out = run_backup(os.environ["GMS_BACKUP_DATABASE_URL"], make_storage(s), out_root, kind=argv[1] if len(argv) > 1 else "scheduled")
        print(json.dumps({"backup": str(out), "pruned": prune(out_root, int(os.environ.get("GMS_BACKUP_RETENTION_DAYS", "30")))}))
        return 0
    if argv[:1] == ["restore"] and len(argv) == 4:
        target_storage = FileStorage(argv[3])
        url = restore(Path(argv[1]), os.environ["GMS_RESTORE_ADMIN_URL"], argv[2], target_storage)
        print(json.dumps(verify(url, target_storage, Path(argv[1])), indent=1))
        return 0
    if argv[:1] == ["verify"] and len(argv) == 3:
        print(json.dumps(verify(argv[2], make_storage(s), Path(argv[1])), indent=1))
        return 0
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
