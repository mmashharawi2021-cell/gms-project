import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:local_auth/local_auth.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_sqlcipher/sqflite.dart' as cipher;
import 'package:uuid/uuid.dart';

import 'api.dart';
import 'clock.dart';
import 'models.dart';
import 'photo_vault.dart';
import 'secure.dart';
import 'store.dart';
import 'sync.dart';

enum Phase { loading, setup, changePassword, setPin, locked, ready }

/// Opens the encrypted database + photo vault. The foreground app uses the shared connection; the background
/// WorkManager job MUST pass shared:false and close only its own connection (sqflite shares one native
/// connection per path across engines, so closing a shared one would break the running app).
Future<(Store, PhotoVault)> openLocal({bool shared = true}) async {
  final dbPath = p.join(await cipher.getDatabasesPath(), 'gms_field.db');
  final db = await cipher.openDatabase(dbPath, password: await SecureVault.dbKey(), version: Store.schemaVersion, onCreate: Store.create,
      singleInstance: shared, onConfigure: (db) => db.rawQuery('PRAGMA busy_timeout = 10000'));
  final dir = Directory(p.join((await getApplicationSupportDirectory()).path, 'photos'));
  await dir.create(recursive: true);
  return (Store(db), PhotoVault(dir, await SecureVault.photoKey()));
}

Future<bool> onWifi() async => (await Connectivity().checkConnectivity()).contains(ConnectivityResult.wifi);

class AppState extends ChangeNotifier {
  Phase phase = Phase.loading;
  late Store store;
  late PhotoVault vault;
  ApiClient? api;
  SyncEngine? engine;
  String? serverUrl, employeeName, lastSync, message;
  String? _tempPassword;
  bool wifi = false, syncing = false, deviceRevoked = false, biometricAvailable = false, biometricEnabled = false;
  Map<String, int> counts = const {};
  SyncReport? lastReport;
  DateTime? _pausedAt;
  StreamSubscription? _conn;
  Timer? _timer;
  final _uuid = const Uuid();

  /// Default production server URL. Can be overridden via build-time --dart-define=GMS_API_URL=...
  static const defaultServer = String.fromEnvironment('GMS_API_URL', defaultValue: 'https://gms-project-production.up.railway.app');

  Future<void> init() async {
    final local = await openLocal();
    store = local.$1;
    vault = local.$2;
    serverUrl = await SecureVault.read('server_url');
    biometricEnabled = (await SecureVault.read('biometric')) == '1';
    try {
      final la = LocalAuthentication();
      biometricAvailable = await la.canCheckBiometrics && await la.isDeviceSupported();
    } catch (_) {}
    if (serverUrl != null) _makeApi(serverUrl!);
    if (await SecureVault.read('refresh_token') == null) {
      phase = Phase.setup;
    } else if (!await SecureVault.hasPin()) {
      phase = Phase.setPin;
    } else {
      phase = Phase.locked;
    }
    await refreshCounts();
    wifi = await onWifi();
    _conn = Connectivity().onConnectivityChanged.listen((r) {
      wifi = r.contains(ConnectivityResult.wifi);
      notifyListeners();
      if (wifi && phase == Phase.ready) syncNow(auto: true);
    });
    _timer = Timer.periodic(const Duration(minutes: 3), (_) {
      if (wifi && phase == Phase.ready) syncNow(auto: true);
    });
    notifyListeners();
  }

  void _makeApi(String url) {
    api = ApiClient(url);
    engine = SyncEngine(store, api!, vault.read, evidence: DeviceClock.evidence);
  }

  @override
  void dispose() {
    _conn?.cancel();
    _timer?.cancel();
    super.dispose();
  }

  // ------------------------------------------------------------------ lifecycle lock
  void paused() => _pausedAt = DateTime.now();
  void resumed() {
    if (phase == Phase.ready && _pausedAt != null && DateTime.now().difference(_pausedAt!) > const Duration(minutes: 3)) {
      phase = Phase.locked;
      notifyListeners();
    }
    _pausedAt = null;
  }

  // ------------------------------------------------------------------ session
  static final _urlRe = RegExp(r'^https?://[^\s/]+');

  Future<void> login(String url, String username, String password, [String? code]) async {
    var clean = url.trim();
    if (clean.isEmpty) clean = defaultServer;
    while (clean.endsWith('/')) {
      clean = clean.substring(0, clean.length - 1);
    }
    if (!_urlRe.hasMatch(clean)) throw ApiException(0, 'server_url_required', 'أدخل عنوان الخادم كما زوّدك به المدير');
    if (!kDebugMode && !clean.startsWith('https://')) throw ApiException(0, 'https_required', 'عنوان الخادم يجب أن يبدأ بـ https://');
    _makeApi(clean);
    final cleanCode = (code != null && code.trim().isNotEmpty) ? code.trim() : null;
    final d = await api!.login(username.trim().toLowerCase(), password, await SecureVault.installId(), enrollmentCode: cleanCode);
    await SecureVault.write('server_url', clean);
    serverUrl = clean;
    final user = d['user'] as Map<String, dynamic>;
    employeeName = user['full_name'] as String?;
    await store.setMeta('employee_name', employeeName);
    deviceRevoked = false;
    if (user['must_change_password'] == true) {
      _tempPassword = password;
      phase = Phase.changePassword;
    } else {
      phase = Phase.setPin;
    }
    notifyListeners();
  }

  Future<void> changePassword(String next) async {
    await api!.changePassword(_tempPassword!, next);
    _tempPassword = null;
    phase = Phase.setPin;
    notifyListeners();
  }

  Future<void> setPin(String pin, bool biometric) async {
    await SecureVault.setPin(pin);
    await SecureVault.write('biometric', biometric ? '1' : null);
    biometricEnabled = biometric;
    phase = Phase.ready;
    notifyListeners();
    unawaited(syncNow(auto: true));
  }

  /// Returns null on success, else an Arabic message. 10 wrong PINs end the session (data stays).
  Future<String?> unlock(String pin) async {
    final failures = await SecureVault.pinFailures();
    if (failures >= 5) {
      final wait = Duration(seconds: 30 * (failures - 4));
      final last = DateTime.tryParse(await SecureVault.read('pin_last_fail') ?? '');
      if (last != null && DateTime.now().difference(last) < wait) return 'انتظر ${wait.inSeconds} ثانية قبل المحاولة';
    }
    if (await SecureVault.checkPin(pin)) {
      await _unlocked();
      return null;
    }
    await SecureVault.write('pin_last_fail', DateTime.now().toIso8601String());
    if (await SecureVault.pinFailures() >= 10) {
      await SecureVault.clearSession();
      phase = Phase.setup;
      notifyListeners();
      return 'محاولات كثيرة: يلزم تسجيل الدخول عبر الإنترنت (بياناتك المحفوظة لم تُحذف)';
    }
    return 'الرمز غير صحيح';
  }

  Future<String?> unlockBiometric() async {
    try {
      final ok = await LocalAuthentication().authenticate(localizedReason: 'افتح تطبيق GMS', biometricOnly: true);
      if (ok) {
        await _unlocked();
        return null;
      }
      return 'لم يتم التحقق';
    } catch (e) {
      return 'البصمة غير متاحة؛ استخدم الرمز';
    }
  }

  Future<void> _unlocked() async {
    employeeName = await store.meta('employee_name');
    lastSync = await store.meta('last_sync');
    phase = Phase.ready;
    notifyListeners();
    if (wifi) unawaited(syncNow(auto: true));
  }

  void lock() {
    phase = Phase.locked;
    notifyListeners();
  }

  Future<String?> logout() async {
    await refreshCounts();
    if ((counts['visits_pending'] ?? 0) + (counts['photos_pending'] ?? 0) + (counts['reports_pending'] ?? 0) > 0) {
      return 'توجد بيانات لم تُرسل بعد. زامن عبر Wi-Fi قبل تسجيل الخروج.';
    }
    await SecureVault.clearSession();
    phase = Phase.setup;
    notifyListeners();
    return null;
  }

  // ------------------------------------------------------------------ data
  Future<void> refreshCounts() async {
    counts = await store.counts();
    lastSync = await store.meta('last_sync');
    notifyListeners();
  }

  String newId() => _uuid.v4();

  Future<({String path, String sha256, int size})> keepPhoto(String photoId, Uint8List bytes) => vault.store(photoId, bytes);

  Future<void> saveVisit(LocalVisit v, List<LocalPhoto> photos) async {
    await store.saveVisit(v, photos);
    await refreshCounts();
    if (wifi) unawaited(syncNow(auto: true));
  }

  Future<void> reportError(String visitId, String explanation) async {
    await store.saveReport(LocalReport(id: newId(), operationId: newId(), visitId: visitId, explanation: explanation.trim(),
        createdAt: DateTime.now().toUtc().toIso8601String()));
    await refreshCounts();
  }

  // ------------------------------------------------------------------ sync
  Future<void> syncNow({bool auto = false}) async {
    if (engine == null || syncing) return;
    wifi = await onWifi();
    if (!wifi) {
      message = 'المزامنة تتم عبر Wi-Fi فقط';
      notifyListeners();
      return;
    }
    syncing = true;
    message = null;
    notifyListeners();
    try {
      lastReport = await engine!.run(onWifi: true);
      if (lastReport!.stopReason != null && !auto) message = 'انقطع الاتصال؛ ستُستأنف المزامنة تلقائيًا';
      await store.purge(30);
    } on ApiException catch (e) {
      if (e.deviceRevoked) {
        deviceRevoked = true;
        message = 'أوقف المدير هذا الجهاز. البيانات غير المرسلة محفوظة على الهاتف؛ راجع المدير.';
      } else if (e.isAuth) {
        message = 'انتهت الجلسة؛ سجّل الدخول عبر الإنترنت (البيانات المحفوظة لن تُحذف)';
        await SecureVault.clearSession();
        phase = Phase.setup;
      } else {
        message = e.message;
      }
    } catch (e) {
      message = 'تعذرت المزامنة: $e';
    } finally {
      syncing = false;
      await refreshCounts();
    }
  }
}
