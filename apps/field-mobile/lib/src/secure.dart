import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Secrets in the Android Keystore-backed secure storage. Never: the PIN itself, nor anything in plain prefs.
/// resetOnError is DISABLED: wiping the store on a Keystore hiccup would orphan the encrypted database.
class SecureVault {
  static const _s = FlutterSecureStorage(aOptions: AndroidOptions(resetOnError: false));

  static Future<String?> read(String k) => _s.read(key: k);
  static Future<void> write(String k, String? v) => v == null ? _s.delete(key: k) : _s.write(key: k, value: v);

  static String _random(int bytes) {
    final r = Random.secure();
    return base64Url.encode(List<int>.generate(bytes, (_) => r.nextInt(256))).replaceAll('=', '');
  }

  /// Long random keys created once per installation.
  static Future<String> ensure(String k, {int bytes = 32}) async {
    final v = await read(k);
    if (v != null) return v;
    final n = _random(bytes);
    await write(k, n);
    return n;
  }

  static Future<String> dbKey() => ensure('db_key');
  static Future<List<int>> photoKey() async => base64Url.decode(base64Url.normalize(await ensure('photo_key')));
  static Future<String> installId() => ensure('install_id', bytes: 24);

  // ------------------------------------------------------------------ PIN (PBKDF2-HMAC-SHA256, salted)
  static final _kdf = Pbkdf2(macAlgorithm: Hmac.sha256(), iterations: 120000, bits: 256);

  static Future<String> _hash(String pin, String salt) async {
    final key = await _kdf.deriveKey(secretKey: SecretKey(utf8.encode(pin)), nonce: base64Url.decode(base64Url.normalize(salt)));
    return base64Url.encode(await key.extractBytes());
  }

  static Future<void> setPin(String pin) async {
    final salt = _random(16);
    await write('pin_salt', salt);
    await write('pin_hash', await _hash(pin, salt));
    await write('pin_failures', '0');
  }

  static Future<bool> hasPin() async => (await read('pin_hash')) != null;

  static Future<bool> checkPin(String pin) async {
    final salt = await read('pin_salt'), hash = await read('pin_hash');
    if (salt == null || hash == null) return false;
    final ok = await _hash(pin, salt) == hash;
    final failures = ok ? 0 : int.parse(await read('pin_failures') ?? '0') + 1;
    await write('pin_failures', '$failures');
    return ok;
  }

  static Future<int> pinFailures() async => int.parse(await read('pin_failures') ?? '0');

  /// Session secrets only (captured data and the DB key are kept so nothing unsent is lost).
  static Future<void> clearSession() async {
    for (final k in ['access_token', 'access_exp', 'refresh_token', 'pin_hash', 'pin_salt', 'pin_failures', 'biometric']) {
      await write(k, null);
    }
  }
}
