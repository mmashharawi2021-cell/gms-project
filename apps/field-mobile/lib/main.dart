import 'package:material_ui/material_ui.dart';
import 'package:workmanager/workmanager.dart';

import 'src/api.dart';
import 'src/app_state.dart';
import 'src/secure.dart';
import 'src/sync.dart';
import 'src/clock.dart';
import 'src/ui/auth_screens.dart';
import 'src/ui/common.dart';
import 'src/ui/home.dart';

/// Background sync (Android WorkManager, UNMETERED network = Wi-Fi only). Uses the same outbox and
/// idempotent server API as the foreground, so an overlap can never duplicate a visit.
@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, input) async {
    try {
      final url = await SecureVault.read('server_url');
      if (url == null || await SecureVault.read('refresh_token') == null) return true;
      if (!await onWifi()) return true;
      final (store, vault) = await openLocal(shared: false);
      await SyncEngine(store, ApiClient(url), vault.read, evidence: DeviceClock.evidence).run(onWifi: true);
      await store.db.close();
      return true;
    } catch (_) {
      return false; // WorkManager retries with backoff
    }
  });
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final app = AppState();
  await app.init();
  try {
    await Workmanager().initialize(callbackDispatcher);
    await Workmanager().registerPeriodicTask('gms-sync', 'gms-sync',
        frequency: const Duration(minutes: 15),
        constraints: Constraints(networkType: NetworkType.unmetered),
        existingWorkPolicy: ExistingPeriodicWorkPolicy.keep);
  } catch (_) {
    // foreground sync still works when background scheduling is unavailable
  }
  runApp(GmsApp(app));
}

class GmsApp extends StatefulWidget {
  const GmsApp(this.app, {super.key});
  final AppState app;
  @override
  State<GmsApp> createState() => _GmsAppState();
}

class _GmsAppState extends State<GmsApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.paused) widget.app.paused();
    if (s == AppLifecycleState.resumed) widget.app.resumed();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'GMS الميداني',
        debugShowCheckedModeBanner: false,
        locale: const Locale('ar'),
        supportedLocales: const [Locale('ar')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        theme: gmsTheme(Brightness.light),
        darkTheme: gmsTheme(Brightness.dark),
        home: ListenableBuilder(
          listenable: widget.app,
          builder: (context, _) => switch (widget.app.phase) {
            Phase.loading => const Scaffold(body: Center(child: CircularProgressIndicator())),
            Phase.setup => SetupScreen(widget.app),
            Phase.changePassword => ChangePasswordScreen(widget.app),
            Phase.setPin => SetPinScreen(widget.app),
            Phase.locked => LockScreen(widget.app),
            Phase.ready => HomeScreen(widget.app),
          },
        ),
      );
}
