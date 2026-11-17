import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'api.dart';
import 'models.dart';
import 'store.dart';

class SyncReport {
  int sent = 0, duplicates = 0, conflicts = 0, rejected = 0, photos = 0, photoFailures = 0, reports = 0;
  bool skippedNoWifi = false, downloaded = false;
  String? stopReason;
  @override
  String toString() => 'sent=$sent dup=$duplicates conflict=$conflicts rejected=$rejected photos=$photos reports=$reports stop=$stopReason';
}

/// Outbox sync (BR-26 / FR-17): Wi-Fi only, stable UUIDs, per-item acknowledgements, retry with backoff.
/// Local rows are only marked done after the server answered for that exact item.
class SyncEngine {
  SyncEngine(this.store, this.api, this.readPhoto, {this.evidence, DateTime Function()? now}) : _now = now ?? DateTime.now;
  final Store store;
  final FieldApi api;
  final Future<Uint8List> Function(String path) readPhoto;
  final Future<({String? bootId, int? elapsedMs})> Function()? evidence;
  final DateTime Function() _now;
  bool _running = false;

  static Duration backoff(int attempts) => Duration(seconds: min(3600, 30 * pow(2, min(attempts, 7)).toInt()));

  Future<SyncReport> run({required bool onWifi, bool download = true}) async {
    final rep = SyncReport();
    if (!onWifi) {
      rep.skippedNoWifi = true;
      return rep;
    }
    if (_running) {
      rep.stopReason = 'already_running';
      return rep;
    }
    _running = true;
    try {
      if (!await _visits(rep)) return rep;
      if (!await _photos(rep)) return rep;
      if (!await _reports(rep)) return rep;
      await _statuses();
      if (download) {
        await _download();
        rep.downloaded = true;
      }
      await store.setMeta('last_sync', _now().toUtc().toIso8601String());
      return rep;
    } on NetworkException catch (e) {
      rep.stopReason = 'network: ${e.detail}';
      return rep;
    } finally {
      _running = false;
    }
  }

  Future<bool> _visits(SyncReport rep) async {
    while (true) {
      final due = await store.dueVisits(_now());
      if (due.isEmpty) return true;
      final ev = evidence == null ? (bootId: null, elapsedMs: null) : await evidence!();
      final ops = [
        for (final v in due)
          {
            'kind': 'visit', 'operation_id': v.operationId, 'visit_id': v.id, 'payload': v.payload(),
            if (v.bootId != null) 'capture_boot_id': v.bootId,
            if (v.elapsedMs != null) 'capture_elapsed_ms': v.elapsedMs,
          }
      ];
      List<Map<String, dynamic>> results;
      try {
        results = await api.sync(ops, bootId: ev.bootId, elapsedMs: ev.elapsedMs);
      } on NetworkException catch (e) {
        for (final v in due) {
          await store.retryVisit(v.id, _now().add(backoff(v.attempts)));
        }
        rep.stopReason = 'network: ${e.detail}';
        return false;
      }
      final byOp = {for (final r in results) r['operation_id'] as String: r};
      for (final v in due) {
        final r = byOp[v.operationId];
        final code = r?['result'] as String?;
        switch (code) {
          case 'accepted':
          case 'already_received':
            code == 'accepted' ? rep.sent++ : rep.duplicates++;
            await store.markVisit(v.id, 'sent', serverStatus: r!['record_status'] as String?, flags: jsonEncode(r['flags'] ?? []));
          case 'conflict':
            rep.conflicts++;
            await store.markVisit(v.id, 'conflict', reason: r!['reason'] as String?);
          case 'rejected':
            rep.rejected++;
            await store.markVisit(v.id, 'rejected', reason: r!['reason'] as String?);
          default: // retry_required or no answer for this item
            await store.retryVisit(v.id, _now().add(backoff(v.attempts)));
        }
      }
      if (results.isEmpty) return true;
    }
  }

  Future<bool> _photos(SyncReport rep) async {
    for (final p in await store.duePhotos(_now())) {
      try {
        final bytes = await readPhoto(p.path);
        final r = await api.uploadPhoto(p.id, p.visitId, p.isPrimary, p.sha256, bytes);
        if (r['state'] == 'ready') {
          rep.photos++;
          await store.markPhoto(p.id, 'uploaded');
          if (r['record_status'] != null) await store.updateServerStatus(p.visitId, r['record_status'] as String, null, null);
        } else {
          await store.retryPhoto(p.id, _now().add(backoff(p.attempts)), r['reason'] as String?);
        }
      } on NetworkException catch (e) {
        await store.retryPhoto(p.id, _now().add(backoff(p.attempts)), 'network');
        rep.stopReason = 'network: ${e.detail}';
        return false;
      } on ApiException catch (e) {
        if (e.isAuth || e.deviceRevoked) rethrow;
        const permanent = {'photo_conflict', 'primary_exists', 'not_an_image', 'photo_too_large', 'visit_not_found'};
        if (permanent.contains(e.code) || p.attempts >= 6) {
          rep.photoFailures++;
          await store.markPhoto(p.id, 'failed', error: e.message);
        } else {
          await store.retryPhoto(p.id, _now().add(backoff(p.attempts)), e.code);
        }
      }
    }
    return true;
  }

  Future<bool> _reports(SyncReport rep) async {
    final due = await store.dueReports(_now());
    if (due.isEmpty) return true;
    final ops = [
      for (final r in due)
        {'kind': 'error_report', 'operation_id': r.operationId, 'visit_id': r.visitId, 'report_id': r.id, 'explanation': r.explanation}
    ];
    try {
      final results = {for (final r in await api.sync(ops)) r['operation_id'] as String: r};
      for (final r in due) {
        final code = results[r.operationId]?['result'];
        if (code == 'accepted' || code == 'already_received') {
          rep.reports++;
          await store.markReport(r.id, 'sent');
        } else if (code == 'rejected' || code == 'conflict') {
          await store.markReport(r.id, code as String, reason: results[r.operationId]?['reason'] as String?);
        } else {
          await store.retryReport(r.id, _now().add(backoff(r.attempts)));
        }
      }
      return true;
    } on NetworkException catch (e) {
      for (final r in due) {
        await store.retryReport(r.id, _now().add(backoff(r.attempts)));
      }
      rep.stopReason = 'network: ${e.detail}';
      return false;
    }
  }

  Future<void> _statuses() async {
    final ids = await store.visitsAwaitingDecision();
    if (ids.isEmpty) return;
    for (final s in await api.status(ids)) {
      await store.updateServerStatus(s['visit_id'] as String, s['record_status'] as String, jsonEncode(s['flags'] ?? []), s['last_decision'] as String?);
    }
  }

  Future<void> _download() async {
    final b = await api.bootstrap();
    await store.replaceAssignments(
      [for (final z in (b['zones'] as List).cast<Map<String, dynamic>>()) Zone(z['id'], z['name'], z['generator_name'] ?? '')],
      [for (final s in (b['subscribers'] as List).cast<Map<String, dynamic>>()) Subscriber.fromJson(s)],
      [for (final t in (b['tasks'] as List).cast<Map<String, dynamic>>()) TaskItem.fromJson(t)],
    );
    await store.setMeta('employee_name', (b['employee'] as Map)['full_name'] as String?);
    await store.setMeta('business_timezone', b['business_timezone'] as String?);
    await store.setMeta('last_download', _now().toUtc().toIso8601String());
  }
}
