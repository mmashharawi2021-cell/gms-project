import 'package:sqflite_common/sqlite_api.dart';

import 'models.dart';

/// Durable local store (SQLCipher-encrypted on the phone). The outbox lives here: a visit/photo/report row
/// is only marked done after the server acknowledged it, so kill/restart/offline never loses captured data.
class Store {
  final Database db;
  Store(this.db);

  static const schemaVersion = 1;

  static Future<void> create(Database db, int version) async {
    final b = db.batch();
    b.execute('CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT)');
    b.execute('CREATE TABLE zones(id TEXT PRIMARY KEY, name TEXT NOT NULL, generator_name TEXT)');
    b.execute('''CREATE TABLE subscribers(id TEXT PRIMARY KEY, subscription_no TEXT NOT NULL, full_name TEXT NOT NULL, zone_id TEXT NOT NULL,
      zone_name TEXT, installation_id TEXT NOT NULL, meter_serial TEXT, address TEXT, phone TEXT, meter_type TEXT, last_value TEXT, last_at TEXT)''');
    b.execute('''CREATE TABLE tasks(id TEXT PRIMARY KEY, cycle_id TEXT, subscriber_id TEXT NOT NULL, installation_id TEXT NOT NULL,
      zone_id TEXT NOT NULL, planned_for TEXT NOT NULL, source TEXT, status TEXT)''');
    b.execute('''CREATE TABLE visits(id TEXT PRIMARY KEY, operation_id TEXT NOT NULL UNIQUE, subscriber_id TEXT NOT NULL, installation_id TEXT NOT NULL,
      zone_id TEXT NOT NULL, event_kind TEXT NOT NULL, captured_at TEXT NOT NULL, created_at TEXT NOT NULL, task_id TEXT, reading_value TEXT,
      reason TEXT, note TEXT, incident_category TEXT, boot_id TEXT, offset_min INTEGER, elapsed_ms INTEGER, sync_state TEXT NOT NULL,
      sync_reason TEXT, server_status TEXT, server_flags TEXT, last_decision TEXT, next_attempt_at TEXT, attempts INTEGER NOT NULL DEFAULT 0)''');
    b.execute('''CREATE TABLE photos(id TEXT PRIMARY KEY, visit_id TEXT NOT NULL REFERENCES visits(id), path TEXT NOT NULL, sha256 TEXT NOT NULL,
      size INTEGER NOT NULL, is_primary INTEGER NOT NULL, state TEXT NOT NULL, error TEXT, next_attempt_at TEXT, attempts INTEGER NOT NULL DEFAULT 0)''');
    b.execute('''CREATE TABLE reports(id TEXT PRIMARY KEY, operation_id TEXT NOT NULL UNIQUE, visit_id TEXT NOT NULL, explanation TEXT NOT NULL,
      created_at TEXT NOT NULL, sync_state TEXT NOT NULL, sync_reason TEXT, next_attempt_at TEXT, attempts INTEGER NOT NULL DEFAULT 0)''');
    b.execute('CREATE INDEX ix_visits_sync ON visits(sync_state, next_attempt_at)');
    b.execute('CREATE INDEX ix_photos_state ON photos(state, visit_id)');
    await b.commit(noResult: true);
  }

  // ---------------------------------------------------------------- meta
  Future<String?> meta(String key) async =>
      (await db.query('meta', where: 'key=?', whereArgs: [key])).map((r) => r['value'] as String?).firstOrNull;
  Future<void> setMeta(String key, String? value) =>
      db.insert('meta', {'key': key, 'value': value}, conflictAlgorithm: ConflictAlgorithm.replace);

  // ---------------------------------------------------------------- assignments (replaced on every download)
  Future<void> replaceAssignments(List<Zone> zones, List<Subscriber> subs, List<TaskItem> tasks) => db.transaction((tx) async {
        await tx.delete('zones');
        await tx.delete('subscribers');
        await tx.delete('tasks');
        final b = tx.batch();
        for (final z in zones) {
          b.insert('zones', z.toRow());
        }
        for (final s in subs) {
          b.insert('subscribers', s.toRow());
        }
        for (final t in tasks) {
          b.insert('tasks', t.toRow());
        }
        await b.commit(noResult: true);
      });

  Future<List<Zone>> zones() async => (await db.query('zones', orderBy: 'name')).map(Zone.fromRow).toList();

  Future<List<Subscriber>> subscribers({String? q}) async {
    final like = '%${q ?? ''}%';
    final rows = await db.query('subscribers',
        where: q == null || q.isEmpty ? null : 'full_name LIKE ? OR subscription_no LIKE ? OR meter_serial LIKE ?',
        whereArgs: q == null || q.isEmpty ? null : [like, like, like],
        orderBy: 'zone_name, subscription_no');
    return rows.map(Subscriber.fromRow).toList();
  }

  Future<Subscriber?> subscriber(String id) async =>
      (await db.query('subscribers', where: 'id=?', whereArgs: [id])).map(Subscriber.fromRow).firstOrNull;

  /// Open tasks that still have no locally captured visit.
  Future<List<TaskItem>> openTasks() async {
    final rows = await db.rawQuery('''SELECT t.* FROM tasks t WHERE NOT EXISTS (SELECT 1 FROM visits v WHERE v.task_id = t.id)
      ORDER BY t.planned_for, t.zone_id''');
    return rows.map(TaskItem.fromRow).toList();
  }

  // ---------------------------------------------------------------- capture (atomic: visit + its photos)
  Future<void> saveVisit(LocalVisit v, List<LocalPhoto> photos) => db.transaction((tx) async {
        await tx.insert('visits', v.toRow(), conflictAlgorithm: ConflictAlgorithm.abort);
        for (final p in photos) {
          await tx.insert('photos', p.toRow(), conflictAlgorithm: ConflictAlgorithm.abort);
        }
      });

  Future<void> addPhoto(LocalPhoto p) => db.insert('photos', p.toRow(), conflictAlgorithm: ConflictAlgorithm.abort);

  Future<void> saveReport(LocalReport r) => db.insert('reports', r.toRow(), conflictAlgorithm: ConflictAlgorithm.abort);

  Future<List<LocalVisit>> visits({int limit = 300}) async =>
      (await db.query('visits', orderBy: 'created_at DESC', limit: limit)).map(LocalVisit.fromRow).toList();

  Future<List<LocalPhoto>> photosOf(String visitId) async =>
      (await db.query('photos', where: 'visit_id=?', whereArgs: [visitId], orderBy: 'is_primary DESC')).map(LocalPhoto.fromRow).toList();

  Future<List<LocalReport>> reportsOf(String visitId) async =>
      (await db.query('reports', where: 'visit_id=?', whereArgs: [visitId])).map(LocalReport.fromRow).toList();

  // ---------------------------------------------------------------- outbox
  Future<List<LocalVisit>> dueVisits(DateTime now, {int limit = 50}) async => (await db.query('visits',
          where: "sync_state='pending' AND (next_attempt_at IS NULL OR next_attempt_at <= ?)",
          whereArgs: [now.toUtc().toIso8601String()], orderBy: 'captured_at', limit: limit))
      .map(LocalVisit.fromRow)
      .toList();

  /// Photos are only uploaded once the server has the visit.
  Future<List<LocalPhoto>> duePhotos(DateTime now) async => (await db.rawQuery('''SELECT p.* FROM photos p JOIN visits v ON v.id = p.visit_id
      WHERE p.state='pending' AND v.sync_state='sent' AND (p.next_attempt_at IS NULL OR p.next_attempt_at <= ?)
      ORDER BY p.is_primary DESC, v.captured_at''', [now.toUtc().toIso8601String()])).map(LocalPhoto.fromRow).toList();

  Future<List<LocalReport>> dueReports(DateTime now) async => (await db.rawQuery('''SELECT r.* FROM reports r JOIN visits v ON v.id = r.visit_id
      WHERE r.sync_state='pending' AND v.sync_state='sent' AND (r.next_attempt_at IS NULL OR r.next_attempt_at <= ?)''',
          [now.toUtc().toIso8601String()])).map(LocalReport.fromRow).toList();

  Future<List<String>> visitsAwaitingDecision() async => (await db.query('visits', columns: ['id'],
          where: "sync_state='sent' AND (server_status IS NULL OR server_status IN ('awaiting_photo','pending_review','exception'))",
          limit: 500))
      .map((r) => r['id'] as String)
      .toList();

  Future<void> markVisit(String id, String state, {String? reason, String? serverStatus, String? flags}) => db.update(
      'visits', {'sync_state': state, 'sync_reason': reason, 'server_status': serverStatus, 'server_flags': flags, 'next_attempt_at': null},
      where: 'id=?', whereArgs: [id]);

  Future<void> retryVisit(String id, DateTime next) =>
      db.rawUpdate('UPDATE visits SET attempts = attempts + 1, next_attempt_at = ? WHERE id = ?', [next.toUtc().toIso8601String(), id]);

  Future<void> updateServerStatus(String id, String status, String? flags, String? decision) =>
      db.update('visits', {'server_status': status, 'server_flags': flags, 'last_decision': decision}, where: 'id=?', whereArgs: [id]);

  Future<void> markPhoto(String id, String state, {String? error}) =>
      db.update('photos', {'state': state, 'error': error, 'next_attempt_at': null}, where: 'id=?', whereArgs: [id]);

  Future<void> retryPhoto(String id, DateTime next, String? error) => db.rawUpdate(
      'UPDATE photos SET attempts = attempts + 1, next_attempt_at = ?, error = ? WHERE id = ?', [next.toUtc().toIso8601String(), error, id]);

  Future<void> markReport(String id, String state, {String? reason}) =>
      db.update('reports', {'sync_state': state, 'sync_reason': reason, 'next_attempt_at': null}, where: 'id=?', whereArgs: [id]);

  Future<void> retryReport(String id, DateTime next) =>
      db.rawUpdate('UPDATE reports SET attempts = attempts + 1, next_attempt_at = ? WHERE id = ?', [next.toUtc().toIso8601String(), id]);

  Future<Map<String, int>> counts() async {
    int n(List<Map<String, Object?>> r) => (r.first.values.first as int?) ?? 0;
    return {
      'visits_pending': n(await db.rawQuery("SELECT count(*) FROM visits WHERE sync_state='pending'")),
      'photos_pending': n(await db.rawQuery("SELECT count(*) FROM photos WHERE state='pending'")),
      'reports_pending': n(await db.rawQuery("SELECT count(*) FROM reports WHERE sync_state='pending'")),
      'problems': n(await db.rawQuery("SELECT (SELECT count(*) FROM visits WHERE sync_state IN ('conflict','rejected')) + (SELECT count(*) FROM photos WHERE state='failed')")),
      'today': n(await db.rawQuery("SELECT count(*) FROM visits WHERE substr(created_at,1,10) = ?", [DateTime.now().toUtc().toIso8601String().substring(0, 10)])),
    };
  }

  /// Housekeeping: only rows fully acknowledged AND decided by the manager, older than [days], are removed.
  Future<List<String>> purgeable(int days) async => (await db.rawQuery('''SELECT p.path FROM photos p JOIN visits v ON v.id = p.visit_id
      WHERE v.sync_state='sent' AND p.state='uploaded' AND v.server_status NOT IN ('awaiting_photo','pending_review','exception')
        AND v.created_at < ?''', [DateTime.now().toUtc().subtract(Duration(days: days)).toIso8601String()])).map((r) => r['path'] as String).toList();

  Future<void> purge(int days) async {
    final limit = DateTime.now().toUtc().subtract(Duration(days: days)).toIso8601String();
    await db.transaction((tx) async {
      const done = "v.sync_state='sent' AND v.server_status NOT IN ('awaiting_photo','pending_review','exception') AND v.created_at < ?";
      await tx.rawDelete("DELETE FROM photos WHERE state='uploaded' AND visit_id IN (SELECT v.id FROM visits v WHERE $done)", [limit]);
      await tx.rawDelete("DELETE FROM reports WHERE sync_state='sent' AND visit_id IN (SELECT v.id FROM visits v WHERE $done)", [limit]);
      await tx.rawDelete("DELETE FROM visits WHERE id IN (SELECT v.id FROM visits v WHERE $done) AND NOT EXISTS (SELECT 1 FROM photos p WHERE p.visit_id = visits.id)", [limit]);
    });
  }
}
