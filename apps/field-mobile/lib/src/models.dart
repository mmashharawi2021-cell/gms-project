/// Local data model. Raw captured visit content is immutable once saved (only sync/review fields change).
class Zone {
  final String id, name, generatorName;
  Zone(this.id, this.name, this.generatorName);
  Map<String, Object?> toRow() => {'id': id, 'name': name, 'generator_name': generatorName};
  static Zone fromRow(Map<String, Object?> r) => Zone(r['id'] as String, r['name'] as String, (r['generator_name'] ?? '') as String);
}

class Subscriber {
  final String id, subscriptionNo, fullName, zoneId, zoneName, installationId, meterSerial;
  final String? address, phone, meterType, lastValue, lastAt;
  Subscriber({required this.id, required this.subscriptionNo, required this.fullName, required this.zoneId, required this.zoneName,
      required this.installationId, required this.meterSerial, this.address, this.phone, this.meterType, this.lastValue, this.lastAt});
  static Subscriber fromJson(Map<String, dynamic> j) => Subscriber(
      id: j['id'], subscriptionNo: j['subscription_no'], fullName: j['full_name'], zoneId: j['zone_id'], zoneName: j['zone_name'] ?? '',
      installationId: j['installation_id'], meterSerial: j['meter_serial'] ?? '', address: j['address'], phone: j['phone'],
      meterType: j['meter_type'], lastValue: j['last_approved_value_kwh']?.toString(), lastAt: j['last_approved_at']);
  Map<String, Object?> toRow() => {
        'id': id, 'subscription_no': subscriptionNo, 'full_name': fullName, 'zone_id': zoneId, 'zone_name': zoneName,
        'installation_id': installationId, 'meter_serial': meterSerial, 'address': address, 'phone': phone, 'meter_type': meterType,
        'last_value': lastValue, 'last_at': lastAt,
      };
  static Subscriber fromRow(Map<String, Object?> r) => Subscriber(
      id: r['id'] as String, subscriptionNo: r['subscription_no'] as String, fullName: r['full_name'] as String, zoneId: r['zone_id'] as String,
      zoneName: (r['zone_name'] ?? '') as String, installationId: r['installation_id'] as String, meterSerial: (r['meter_serial'] ?? '') as String,
      address: r['address'] as String?, phone: r['phone'] as String?, meterType: r['meter_type'] as String?, lastValue: r['last_value'] as String?,
      lastAt: r['last_at'] as String?);
}

class TaskItem {
  final String id, cycleId, subscriberId, installationId, zoneId, plannedFor, source, status;
  TaskItem(this.id, this.cycleId, this.subscriberId, this.installationId, this.zoneId, this.plannedFor, this.source, this.status);
  static TaskItem fromJson(Map<String, dynamic> j) =>
      TaskItem(j['id'], j['cycle_id'], j['subscriber_id'], j['installation_id'], j['zone_id'], j['planned_for'], j['source'], j['status']);
  Map<String, Object?> toRow() => {'id': id, 'cycle_id': cycleId, 'subscriber_id': subscriberId, 'installation_id': installationId,
        'zone_id': zoneId, 'planned_for': plannedFor, 'source': source, 'status': status};
  static TaskItem fromRow(Map<String, Object?> r) => TaskItem(r['id'] as String, r['cycle_id'] as String, r['subscriber_id'] as String,
      r['installation_id'] as String, r['zone_id'] as String, r['planned_for'] as String, r['source'] as String, r['status'] as String);
}

/// sync_state: pending -> sent | conflict | rejected. A visit is never deleted before the server acknowledged it.
class LocalVisit {
  final String id, operationId, subscriberId, installationId, zoneId, eventKind, capturedAt, createdAt;
  final String? taskId, readingValue, reason, note, incidentCategory, bootId;
  final int? offsetMinutes, elapsedMs;
  String syncState;
  String? syncReason, serverStatus, serverFlags, lastDecision, nextAttemptAt;
  int attempts;
  LocalVisit({required this.id, required this.operationId, required this.subscriberId, required this.installationId, required this.zoneId,
      required this.eventKind, required this.capturedAt, required this.createdAt, this.taskId, this.readingValue, this.reason, this.note,
      this.incidentCategory, this.bootId, this.offsetMinutes, this.elapsedMs, this.syncState = 'pending', this.syncReason, this.serverStatus,
      this.serverFlags, this.lastDecision, this.nextAttemptAt, this.attempts = 0});

  /// Content sent to the server: identical on every retry (the server fingerprints it).
  Map<String, dynamic> payload() => {
        'subscriber_id': subscriberId, 'installation_id': installationId, 'zone_id': zoneId, 'event_kind': eventKind,
        'captured_at_device': capturedAt,
        if (taskId != null) 'task_id': taskId,
        if (readingValue != null) 'reading_value_kwh': readingValue,
        if (reason != null && reason!.isNotEmpty) 'reason': reason,
        if (note != null && note!.isNotEmpty) 'note': note,
        if (incidentCategory != null) 'incident_category': incidentCategory,
        if (offsetMinutes != null) 'captured_offset_minutes': offsetMinutes,
      };

  Map<String, Object?> toRow() => {
        'id': id, 'operation_id': operationId, 'subscriber_id': subscriberId, 'installation_id': installationId, 'zone_id': zoneId,
        'event_kind': eventKind, 'captured_at': capturedAt, 'created_at': createdAt, 'task_id': taskId, 'reading_value': readingValue,
        'reason': reason, 'note': note, 'incident_category': incidentCategory, 'boot_id': bootId, 'offset_min': offsetMinutes,
        'elapsed_ms': elapsedMs, 'sync_state': syncState, 'sync_reason': syncReason, 'server_status': serverStatus,
        'server_flags': serverFlags, 'last_decision': lastDecision, 'next_attempt_at': nextAttemptAt, 'attempts': attempts,
      };
  static LocalVisit fromRow(Map<String, Object?> r) => LocalVisit(
      id: r['id'] as String, operationId: r['operation_id'] as String, subscriberId: r['subscriber_id'] as String,
      installationId: r['installation_id'] as String, zoneId: r['zone_id'] as String, eventKind: r['event_kind'] as String,
      capturedAt: r['captured_at'] as String, createdAt: r['created_at'] as String, taskId: r['task_id'] as String?,
      readingValue: r['reading_value'] as String?, reason: r['reason'] as String?, note: r['note'] as String?,
      incidentCategory: r['incident_category'] as String?, bootId: r['boot_id'] as String?, offsetMinutes: r['offset_min'] as int?,
      elapsedMs: r['elapsed_ms'] as int?, syncState: r['sync_state'] as String, syncReason: r['sync_reason'] as String?,
      serverStatus: r['server_status'] as String?, serverFlags: r['server_flags'] as String?, lastDecision: r['last_decision'] as String?,
      nextAttemptAt: r['next_attempt_at'] as String?, attempts: (r['attempts'] ?? 0) as int);
}

/// state: pending -> uploaded | failed (terminal error needing attention). File content is encrypted at rest.
class LocalPhoto {
  final String id, visitId, path, sha256;
  final int size;
  final bool isPrimary;
  String state;
  String? error, nextAttemptAt;
  int attempts;
  LocalPhoto({required this.id, required this.visitId, required this.path, required this.sha256, required this.size, required this.isPrimary,
      this.state = 'pending', this.error, this.nextAttemptAt, this.attempts = 0});
  Map<String, Object?> toRow() => {'id': id, 'visit_id': visitId, 'path': path, 'sha256': sha256, 'size': size, 'is_primary': isPrimary ? 1 : 0,
        'state': state, 'error': error, 'next_attempt_at': nextAttemptAt, 'attempts': attempts};
  static LocalPhoto fromRow(Map<String, Object?> r) => LocalPhoto(id: r['id'] as String, visitId: r['visit_id'] as String, path: r['path'] as String,
      sha256: r['sha256'] as String, size: r['size'] as int, isPrimary: r['is_primary'] == 1, state: r['state'] as String,
      error: r['error'] as String?, nextAttemptAt: r['next_attempt_at'] as String?, attempts: (r['attempts'] ?? 0) as int);
}

class LocalReport {
  final String id, operationId, visitId, explanation, createdAt;
  String syncState;
  String? syncReason, nextAttemptAt;
  int attempts;
  LocalReport({required this.id, required this.operationId, required this.visitId, required this.explanation, required this.createdAt,
      this.syncState = 'pending', this.syncReason, this.nextAttemptAt, this.attempts = 0});
  Map<String, Object?> toRow() => {'id': id, 'operation_id': operationId, 'visit_id': visitId, 'explanation': explanation, 'created_at': createdAt,
        'sync_state': syncState, 'sync_reason': syncReason, 'next_attempt_at': nextAttemptAt, 'attempts': attempts};
  static LocalReport fromRow(Map<String, Object?> r) => LocalReport(id: r['id'] as String, operationId: r['operation_id'] as String,
      visitId: r['visit_id'] as String, explanation: r['explanation'] as String, createdAt: r['created_at'] as String,
      syncState: r['sync_state'] as String, syncReason: r['sync_reason'] as String?, nextAttemptAt: r['next_attempt_at'] as String?,
      attempts: (r['attempts'] ?? 0) as int);
}
