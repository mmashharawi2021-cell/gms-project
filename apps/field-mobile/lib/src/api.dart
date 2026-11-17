import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'secure.dart';

class ApiException implements Exception {
  final int status;
  final String code, message;
  ApiException(this.status, this.code, this.message);
  bool get isAuth => status == 401;
  bool get deviceRevoked => code == 'device_revoked';
  @override
  String toString() => '$status $code: $message';
}

/// Transport failure (no route, timeout, TLS…): always retried later, never treated as a server verdict.
class NetworkException implements Exception {
  final String detail;
  NetworkException(this.detail);
  @override
  String toString() => 'network: $detail';
}

/// What the sync engine needs (lets tests run against a fake server).
abstract class FieldApi {
  Future<Map<String, dynamic>> bootstrap();
  Future<List<Map<String, dynamic>>> sync(List<Map<String, dynamic>> operations, {String? bootId, int? elapsedMs});
  Future<Map<String, dynamic>> uploadPhoto(String photoId, String visitId, bool primary, String sha256, Uint8List bytes);
  Future<List<Map<String, dynamic>>> status(List<String> visitIds);
}

class ApiClient implements FieldApi {
  ApiClient(this.baseUrl, {http.Client? client}) : _http = client ?? http.Client();
  final String baseUrl;
  final http.Client _http;
  static const _timeout = Duration(seconds: 30);
  Completer<void>? _refreshing;

  Uri _u(String path) => Uri.parse('${baseUrl.replaceAll(RegExp(r'/+$'), '')}/api/v1/$path');

  Future<http.Response> _send(Future<http.Response> Function() fn) async {
    try {
      return await fn().timeout(_timeout);
    } on TimeoutException {
      throw NetworkException('timeout');
    } on SocketException catch (e) {
      throw NetworkException(e.message);
    } on HandshakeException catch (e) {
      throw NetworkException('tls: ${e.message}');
    } on http.ClientException catch (e) {
      throw NetworkException(e.message);
    }
  }

  dynamic _decode(http.Response r) {
    final body = r.bodyBytes.isEmpty ? null : jsonDecode(utf8.decode(r.bodyBytes));
    if (r.statusCode >= 200 && r.statusCode < 300) return body;
    final e = (body is Map && body['error'] is Map) ? body['error'] as Map : const {};
    throw ApiException(r.statusCode, (e['code'] ?? 'http_${r.statusCode}').toString(), (e['message'] ?? 'تعذر تنفيذ الطلب').toString());
  }

  // ------------------------------------------------------------------ session
  Future<Map<String, dynamic>> login(String username, String password, String installId, {String? enrollmentCode, String? label}) async {
    final r = await _send(() => _http.post(_u('auth/login'), headers: {'content-type': 'application/json'}, body: jsonEncode({
          'username': username, 'password': password, 'client': 'mobile', 'install_id': installId,
          if (enrollmentCode != null && enrollmentCode.isNotEmpty) 'enrollment_code': enrollmentCode,
          'device_label': label ?? 'Android',
        })));
    final d = _decode(r) as Map<String, dynamic>;
    await _saveTokens(d);
    return d;
  }

  Future<Map<String, dynamic>> changePassword(String current, String next) async {
    final d = await _authed('POST', 'auth/change-password', {'current_password': current, 'new_password': next}) as Map<String, dynamic>;
    await _saveTokens(d);
    return d;
  }

  Future<void> _saveTokens(Map<String, dynamic> d) async {
    await SecureVault.write('access_token', d['access_token'] as String);
    await SecureVault.write('access_exp', DateTime.now().add(Duration(seconds: (d['expires_in'] as int) - 30)).toIso8601String());
    await SecureVault.write('refresh_token', d['refresh_token'] as String);
  }

  /// Single-flight refresh: concurrent callers wait for the same rotation (the server revokes reused tokens).
  Future<void> refresh() async {
    if (_refreshing != null) return _refreshing!.future;
    final c = _refreshing = Completer<void>();
    try {
      final rt = await SecureVault.read('refresh_token');
      if (rt == null) throw ApiException(401, 'no_session', 'يلزم تسجيل الدخول عبر الإنترنت');
      final installId = await SecureVault.installId();
      final r = await _send(() => _http.post(_u('auth/refresh'), headers: {'content-type': 'application/json'},
          body: jsonEncode({'refresh_token': rt, 'install_id': installId})));
      await _saveTokens(_decode(r) as Map<String, dynamic>);
      c.complete();
    } catch (e, st) {
      c.completeError(e, st);
      rethrow;
    } finally {
      _refreshing = null;
    }
  }

  Future<String> _token() async {
    final exp = await SecureVault.read('access_exp');
    if (exp == null || DateTime.parse(exp).isBefore(DateTime.now())) await refresh();
    return (await SecureVault.read('access_token'))!;
  }

  Future<dynamic> _authed(String method, String path, Object? body, {bool retried = false}) async {
    final token = await _token();
    final headers = {'authorization': 'Bearer $token', 'content-type': 'application/json'};
    final r = await _send(() => method == 'GET'
        ? _http.get(_u(path), headers: headers)
        : _http.post(_u(path), headers: headers, body: jsonEncode(body)));
    if (r.statusCode == 401 && !retried) {
      await refresh();
      return _authed(method, path, body, retried: true);
    }
    return _decode(r);
  }

  // ------------------------------------------------------------------ field operations
  @override
  Future<Map<String, dynamic>> bootstrap() async => await _authed('GET', 'mobile/bootstrap', null) as Map<String, dynamic>;

  @override
  Future<List<Map<String, dynamic>>> sync(List<Map<String, dynamic>> operations, {String? bootId, int? elapsedMs}) async {
    final d = await _authed('POST', 'mobile/sync', {
      'device_now': DateTime.now().toUtc().toIso8601String(),
      if (bootId != null) 'boot_id': bootId,
      if (elapsedMs != null) 'elapsed_ms': elapsedMs,
      'operations': operations,
    }) as Map<String, dynamic>;
    return (d['results'] as List).cast<Map<String, dynamic>>();
  }

  @override
  Future<Map<String, dynamic>> uploadPhoto(String photoId, String visitId, bool primary, String sha256, Uint8List bytes, {bool retried = false}) async {
    final token = await _token();
    final uri = _u('mobile/photos/$photoId').replace(queryParameters: {'visit_id': visitId, 'is_primary': '$primary', 'sha256': sha256});
    final r = await _send(() => _http.put(uri, headers: {'authorization': 'Bearer $token', 'content-type': 'application/octet-stream'}, body: bytes));
    if (r.statusCode == 401 && !retried) {
      await refresh();
      return uploadPhoto(photoId, visitId, primary, sha256, bytes, retried: true);
    }
    return _decode(r) as Map<String, dynamic>;
  }

  @override
  Future<List<Map<String, dynamic>>> status(List<String> visitIds) async =>
      ((await _authed('POST', 'mobile/status', {'visit_ids': visitIds})) as List).cast<Map<String, dynamic>>();
}
