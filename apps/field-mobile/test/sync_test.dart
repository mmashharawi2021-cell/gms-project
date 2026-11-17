import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gms_field/src/api.dart';
import 'package:gms_field/src/models.dart';
import 'package:gms_field/src/store.dart';
import 'package:gms_field/src/sync.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Fake server with the same idempotency semantics as the real one (operation_id / visit_id / fingerprint).
class FakeServer implements FieldApi {
  final visits = <String, Map<String, dynamic>>{};
  final photos = <String, String>{};
  final reports = <String>{};
  int failNextSync = 0, failUploads = 0, syncCalls = 0;
  bool loseAckOnce = false;

  @override
  Future<List<Map<String, dynamic>>> sync(List<Map<String, dynamic>> operations, {String? bootId, int? elapsedMs}) async {
    syncCalls++;
    if (failNextSync > 0) {
      failNextSync--;
      throw NetworkException('down');
    }
    final out = <Map<String, dynamic>>[];
    for (final op in operations) {
      if (op['kind'] == 'error_report') {
        final dup = !reports.add(op['report_id'] as String);
        out.add({'operation_id': op['operation_id'], 'result': dup ? 'already_received' : 'accepted'});
        continue;
      }
      final id = op['visit_id'] as String;
      final payload = op['payload'] as Map<String, dynamic>;
      if (payload['reading_value_kwh'] == '121.987') {
        out.add({'operation_id': op['operation_id'], 'result': 'rejected', 'reason': 'invalid_precision'});
      } else if (visits.containsKey(id)) {
        final same = visits[id].toString() == payload.toString();
        out.add({'operation_id': op['operation_id'], 'result': same ? 'already_received' : 'conflict', 'record_status': 'awaiting_photo'});
      } else {
        visits[id] = payload;
        out.add({'operation_id': op['operation_id'], 'result': 'accepted', 'record_status': 'awaiting_photo', 'flags': []});
      }
    }
    if (loseAckOnce) {
      loseAckOnce = false;
      throw NetworkException('connection dropped after the server committed');
    }
    return out;
  }

  @override
  Future<Map<String, dynamic>> uploadPhoto(String photoId, String visitId, bool primary, String sha256, Uint8List bytes) async {
    if (failUploads > 0) {
      failUploads--;
      throw NetworkException('wifi lost');
    }
    if (!visits.containsKey(visitId)) throw ApiException(404, 'visit_not_found', 'x');
    photos[photoId] = sha256;
    return {'state': 'ready', 'record_status': 'pending_review'};
  }

  @override
  Future<List<Map<String, dynamic>>> status(List<String> visitIds) async =>
      [for (final id in visitIds) if (visits.containsKey(id)) {'visit_id': id, 'record_status': 'approved', 'flags': [], 'last_decision': 'approve_reading'}];

  @override
  Future<Map<String, dynamic>> bootstrap() async => {
        'employee': {'full_name': 'QA'}, 'business_timezone': 'Asia/Gaza',
        'zones': [{'id': 'z1', 'name': 'Z', 'generator_name': 'G'}],
        'subscribers': [{'id': 's1', 'subscription_no': 'QA-1', 'full_name': 'QA', 'zone_id': 'z1', 'installation_id': 'i1', 'meter_serial': 'M'}],
        'tasks': [],
      };
}

void main() {
  sqfliteFfiInit();
  late Database db;
  late Store store;
  late FakeServer server;
  var clock = DateTime.utc(2026, 11, 15, 8);
  late SyncEngine engine;

  LocalVisit visit(String id, String value) => LocalVisit(
      id: id, operationId: 'op-$id', subscriberId: 's1', installationId: 'i1', zoneId: 'z1', eventKind: 'reading',
      capturedAt: clock.toIso8601String(), createdAt: clock.toIso8601String(), readingValue: value, reason: 'extra');
  LocalPhoto photo(String visitId) =>
      LocalPhoto(id: 'ph-$visitId', visitId: visitId, path: '/x/$visitId', sha256: 'a' * 64, size: 10, isPrimary: true);

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath, options: OpenDatabaseOptions(version: 1, onCreate: Store.create));
    store = Store(db);
    server = FakeServer();
    clock = DateTime.utc(2026, 11, 15, 8);
    engine = SyncEngine(store, server, (_) async => Uint8List.fromList([1, 2, 3]), now: () => clock);
  });
  tearDown(() => db.close());

  test('nothing is sent without Wi-Fi', () async {
    await store.saveVisit(visit('v1', '101.43'), [photo('v1')]);
    final r = await engine.run(onWifi: false);
    expect(r.skippedNoWifi, isTrue);
    expect(server.syncCalls, 0);
    expect((await store.counts())['visits_pending'], 1);
  });

  test('a full day offline is delivered once, with photos after their visits', () async {
    for (var i = 0; i < 120; i++) {
      await store.saveVisit(visit('v$i', '${100 + i}.5'), [photo('v$i')]);
    }
    final r = await engine.run(onWifi: true);
    expect(r.sent, 120);
    expect(server.visits.length, 120);
    expect(server.photos.length, 120);
    final c = await store.counts();
    expect(c['visits_pending'], 0);
    expect(c['photos_pending'], 0);
    expect((await store.visits()).every((v) => v.serverStatus == 'approved'), isTrue); // status refresh
    expect(r.downloaded, isTrue);
    expect((await store.subscribers()).single.subscriptionNo, 'QA-1');
  });

  test('network failure keeps everything and retries later without duplicates', () async {
    await store.saveVisit(visit('v1', '101.43'), [photo('v1')]);
    server.failNextSync = 1;
    var r = await engine.run(onWifi: true);
    expect(r.stopReason, startsWith('network'));
    expect((await store.counts())['visits_pending'], 1);
    r = await engine.run(onWifi: true); // backoff not elapsed yet
    expect(server.visits, isEmpty);
    clock = clock.add(const Duration(minutes: 2));
    r = await engine.run(onWifi: true);
    expect(server.visits.length, 1);
    expect((await store.counts())['photos_pending'], 0);
  });

  test('acknowledgement lost after commit: resend yields already_received, not a second visit', () async {
    await store.saveVisit(visit('v1', '101.43'), [photo('v1')]);
    server.loseAckOnce = true;
    await engine.run(onWifi: true);
    expect(server.visits.length, 1);
    expect((await store.counts())['visits_pending'], 1); // still pending locally: never assume success
    clock = clock.add(const Duration(minutes: 5));
    final r = await engine.run(onWifi: true);
    expect(r.duplicates, 1);
    expect(server.visits.length, 1);
    expect((await store.visits()).single.syncState, 'sent');
  });

  test('photo upload interrupted is resumed; server verdicts are kept for the employee', () async {
    await store.saveVisit(visit('v1', '101.43'), [photo('v1')]);
    await store.saveVisit(visit('v2', '121.987'), [photo('v2')]);
    server.failUploads = 1;
    await engine.run(onWifi: true);
    expect(server.photos, isEmpty);
    expect((await store.photosOf('v1')).single.state, 'pending');
    final v2 = (await store.visits()).firstWhere((v) => v.id == 'v2');
    expect([v2.syncState, v2.syncReason], ['rejected', 'invalid_precision']);
    expect((await store.photosOf('v2')).single.state, 'pending'); // never uploaded for a rejected visit
    clock = clock.add(const Duration(minutes: 5));
    await engine.run(onWifi: true);
    expect(server.photos.keys, ['ph-v1']);
  });

  test('error reports are sent after their visit and only once', () async {
    await store.saveVisit(visit('v1', '101.43'), [photo('v1')]);
    await store.saveReport(LocalReport(id: 'r1', operationId: 'op-r1', visitId: 'v1', explanation: 'خطأ', createdAt: clock.toIso8601String()));
    final r = await engine.run(onWifi: true);
    expect(r.reports, 1);
    await engine.run(onWifi: true);
    expect(server.reports.length, 1);
  });

  test('housekeeping never removes undecided or unsent data', () async {
    await store.saveVisit(visit('v1', '101.43'), [photo('v1')]);
    await store.purge(0);
    expect((await store.visits()).length, 1);
  });
}
