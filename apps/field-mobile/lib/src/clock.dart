import 'package:flutter/services.dart';

/// Monotonic-clock evidence (SystemClock.elapsedRealtime + boot count) so the server can check the wall clock
/// of the phone (BR-24). Falls back to nulls when the platform channel is unavailable (tests).
class DeviceClock {
  static const _ch = MethodChannel('ps.gms/clock');

  static Future<({String? bootId, int? elapsedMs})> evidence() async {
    try {
      final m = await _ch.invokeMapMethod<String, Object?>('evidence');
      return (bootId: m?['boot_id'] as String?, elapsedMs: (m?['elapsed_ms'] as num?)?.toInt());
    } catch (_) {
      return (bootId: null, elapsedMs: null);
    }
  }
}
