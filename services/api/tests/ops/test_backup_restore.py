"""AT-15 / AT-31: back up database + photos, restore into a NEW database and empty photo store, compare everything."""
import psycopg

from app.ops.backup import COUNT_TABLES, prune, restore, run_backup, verify
from app.storage import FileStorage
from tests.conftest import ADMIN_URL
from tests.world import World


def test_backup_and_restore_database_and_photos(world: World, owner_url, tmp_path, db_name):
    w = world
    c, sub, inst, task = w.week()
    v = w.visit(sub, inst, "101.43", w.at(-10), task=task, photo=False)
    store = FileStorage(str(tmp_path / "live-objects"))
    # put two real photo objects in storage and register them through the normal functions
    import hashlib
    import uuid
    for primary in (True, False):
        pid, data = uuid.uuid4(), b"\xff\xd8\xff" + uuid.uuid4().bytes * 50
        sha = hashlib.sha256(data).hexdigest()
        key = w.call(w.employee, "SELECT gms.begin_photo(%s,%s,%s,%s,'image/jpeg',%s)", (pid, v, sha, len(data), primary))["object_key"]
        store.put(key, data, "image/jpeg")
        w.call(w.employee, "SELECT gms.complete_photo(%s,%s,%s)", (pid, sha, len(data)))
    w.approve(v)
    w.finalize(c, "15")
    w.pay(sub, "21")
    before = verify(owner_url, store)
    assert before["photos_checked"] == 2 and not before["photos_bad"]
    out = run_backup(owner_url, store, tmp_path / "backups", kind="manual")
    assert {p.name for p in out.iterdir()} == {"database.dump", "photos.tar", "manifest.json"}
    with psycopg.connect(owner_url) as conn:
        job = conn.execute("SELECT succeeded, notes FROM gms.backup_job_log ORDER BY started_at DESC LIMIT 1").fetchone()
    assert job[0] is True
    # restore into a brand-new database and an EMPTY photo store
    new_db = db_name + "_restored"
    target_store = FileStorage(str(tmp_path / "restored-objects"))
    target = restore(out, ADMIN_URL, new_db, target_store)
    try:
        after = verify(target, target_store, out)
        assert after["counts"] == before["counts"] | {"audit_logs": after["counts"]["audit_logs"]}
        assert after["counts"]["audit_logs"] >= before["counts"]["audit_logs"]
        assert after["ledger_sum_ils"] == before["ledger_sum_ils"] == "0.45000000"
        assert after["photos_checked"] == 2 and after["photos_bad"] == [] and after["manifest_photos"] == 2
        # the restored database keeps all protections (append-only ledger)
        with psycopg.connect(target, autocommit=True) as conn:
            try:
                conn.execute("DELETE FROM gms.ledger_entries")
                raise AssertionError("ledger delete was allowed after restore")
            except psycopg.Error as e:
                assert "append_only" in (e.diag.message_detail or "")
        # refusing to overwrite an existing database
        try:
            restore(out, ADMIN_URL, new_db, target_store)
            raise AssertionError("restore overwrote an existing database")
        except RuntimeError as e:
            assert "already exists" in str(e)
        # a corrupted backup is detected before anything is restored
        (out / "photos.tar").write_bytes(b"corrupted")
        try:
            restore(out, ADMIN_URL, new_db + "x", target_store)
            raise AssertionError("corrupt backup accepted")
        except RuntimeError as e:
            assert "corrupt" in str(e)
    finally:
        with psycopg.connect(ADMIN_URL, autocommit=True) as conn:
            conn.execute(f'DROP DATABASE IF EXISTS "{new_db}" WITH (FORCE)')
    assert prune(tmp_path / "backups", 30) == []
    assert set(COUNT_TABLES) <= set(after["counts"])


def test_backup_download_requires_reauth(api, tmp_path):
    import io
    import tarfile as tf
    from pathlib import Path

    from tests.apiclient import expect

    w = api.setup()
    settings = api.app.state.settings
    owner = psycopg.conninfo.make_conninfo(api.db_url, user="postgres", password="gms_test_only")
    out = run_backup(owner, FileStorage(settings.storage_dir), Path(settings.backup_dir), kind="manual")
    b = expect(w.m.get("/api/v1/backups"), 200)[0]
    assert b["succeeded"] and b["artifact_name"] == out.name
    expect(w.m.post(f"/api/v1/backups/{b['id']}/download", {"password": "wrong"}), 401, "reauth_failed")
    expect(w.e.post(f"/api/v1/backups/{b['id']}/download", {"password": w.e.password}), 403)
    r = w.m.post(f"/api/v1/backups/{b['id']}/download", {"password": "Manager-Pass-1"})
    assert r.status_code == 200
    names = tf.open(fileobj=io.BytesIO(r.content)).getnames()
    assert f"{out.name}/database.dump" in names and f"{out.name}/manifest.json" in names
    d = expect(w.m.get("/api/v1/dashboard"), 200)
    assert d["last_backup"]["succeeded"] is True and d["counts"]["employees"] == 1
    actions = [a["action_code"] for a in expect(w.m.get("/api/v1/audit", params={"entity_type": "backup_job_log"}), 200)]
    assert "BACKUP_DOWNLOAD" in actions and "BACKUP_DOWNLOAD_DENIED" in actions
