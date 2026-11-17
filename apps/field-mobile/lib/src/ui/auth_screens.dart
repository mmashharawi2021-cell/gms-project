import 'package:material_ui/material_ui.dart';

import '../api.dart';
import '../app_state.dart';
import '../validators.dart';
import 'common.dart';

class SetupScreen extends StatefulWidget {
  const SetupScreen(this.app, {super.key});
  final AppState app;
  @override
  State<SetupScreen> createState() => _SetupState();
}

class _SetupState extends State<SetupScreen> {
  late final _url = TextEditingController(text: widget.app.serverUrl ?? AppState.defaultServer);
  final _user = TextEditingController(), _pw = TextEditingController(), _code = TextEditingController();
  bool _busy = false;
  String? _error;

  Future<void> _go() async {
    setState(() { _busy = true; _error = null; });
    try {
      await widget.app.login(_url.text, _user.text, _pw.text, _code.text);
    } on ApiException catch (e) {
      _error = e.message;
    } on NetworkException {
      _error = 'تعذر الوصول إلى الخادم. تسجيل الدخول الأول يحتاج اتصالًا بالإنترنت.';
    } catch (e) {
      _error = '$e';
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('تسجيل الدخول — GMS')),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          const Text('تسجيل الدخول الأول يتم عبر الإنترنت. بعدها يُفتح التطبيق بالرمز السري أو البصمة دون اتصال.'),
          const SizedBox(height: 16),
          TextField(controller: _user, decoration: const InputDecoration(labelText: 'اسم المستخدم'), textDirection: TextDirection.ltr),
          const SizedBox(height: 12),
          TextField(controller: _pw, decoration: const InputDecoration(labelText: 'كلمة المرور'), obscureText: true, textDirection: TextDirection.ltr),
          const SizedBox(height: 12),
          TextField(controller: _code, decoration: const InputDecoration(labelText: 'رمز تفعيل الهاتف (من المدير — أول مرة فقط)'),
              textDirection: TextDirection.ltr, textCapitalization: TextCapitalization.characters),
          const SizedBox(height: 12),
          TextField(controller: _url, decoration: const InputDecoration(labelText: 'عنوان الخادم (من المدير)', hintText: 'https://...'),
              textDirection: TextDirection.ltr, keyboardType: TextInputType.url),
          if (_error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_error!, style: const TextStyle(color: Colors.red))),
          const SizedBox(height: 16),
          FilledButton(onPressed: _busy ? null : _go, child: _busy ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('دخول')),
        ]),
      );
}

class ChangePasswordScreen extends StatefulWidget {
  const ChangePasswordScreen(this.app, {super.key});
  final AppState app;
  @override
  State<ChangePasswordScreen> createState() => _ChangePwState();
}

class _ChangePwState extends State<ChangePasswordScreen> {
  final _a = TextEditingController(), _b = TextEditingController();
  String? _error;
  bool _busy = false;
  Future<void> _go() async {
    if (_a.text != _b.text) return setState(() => _error = 'كلمتا المرور غير متطابقتين');
    setState(() { _busy = true; _error = null; });
    try {
      await widget.app.changePassword(_a.text);
    } on ApiException catch (e) {
      _error = e.message;
    } catch (e) {
      _error = 'تعذر الاتصال بالخادم';
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('تغيير كلمة المرور المؤقتة')),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          const Text('8 أحرف على الأقل وتجمع بين أحرف وأرقام.'),
          const SizedBox(height: 12),
          TextField(controller: _a, obscureText: true, decoration: const InputDecoration(labelText: 'كلمة المرور الجديدة'), textDirection: TextDirection.ltr),
          const SizedBox(height: 12),
          TextField(controller: _b, obscureText: true, decoration: const InputDecoration(labelText: 'تأكيد كلمة المرور'), textDirection: TextDirection.ltr),
          if (_error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_error!, style: const TextStyle(color: Colors.red))),
          const SizedBox(height: 16),
          FilledButton(onPressed: _busy ? null : _go, child: const Text('حفظ')),
        ]),
      );
}

class SetPinScreen extends StatefulWidget {
  const SetPinScreen(this.app, {super.key});
  final AppState app;
  @override
  State<SetPinScreen> createState() => _SetPinState();
}

class _SetPinState extends State<SetPinScreen> {
  final _a = TextEditingController(), _b = TextEditingController();
  bool _bio = false;
  String? _error;
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('رمز فتح التطبيق')),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          const Text('اختر رمزًا سريًا (4–8 أرقام) لفتح التطبيق دون إنترنت. لا يُرسل الرمز إلى الخادم.'),
          const SizedBox(height: 12),
          TextField(controller: _a, obscureText: true, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'الرمز'), textDirection: TextDirection.ltr),
          const SizedBox(height: 12),
          TextField(controller: _b, obscureText: true, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'تأكيد الرمز'), textDirection: TextDirection.ltr),
          if (widget.app.biometricAvailable)
            SwitchListTile(value: _bio, onChanged: (v) => setState(() => _bio = v), title: const Text('السماح بالفتح بالبصمة أيضًا')),
          if (_error != null) Text(_error!, style: const TextStyle(color: Colors.red)),
          const SizedBox(height: 16),
          FilledButton(
              onPressed: () async {
                final err = Validators.pin(_a.text) ?? (_a.text != _b.text ? 'الرمزان غير متطابقين' : null);
                if (err != null) return setState(() => _error = err);
                await widget.app.setPin(Validators.normalizeDigits(_a.text), _bio);
              },
              child: const Text('حفظ')),
        ]),
      );
}

class LockScreen extends StatefulWidget {
  const LockScreen(this.app, {super.key});
  final AppState app;
  @override
  State<LockScreen> createState() => _LockState();
}

class _LockState extends State<LockScreen> {
  final _pin = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    if (widget.app.biometricEnabled) WidgetsBinding.instance.addPostFrameCallback((_) => _bio());
  }

  Future<void> _bio() async {
    final e = await widget.app.unlockBiometric();
    if (mounted && e != null) setState(() => _error = e);
  }

  Future<void> _go() async {
    setState(() => _busy = true);
    final e = await widget.app.unlock(Validators.normalizeDigits(_pin.text));
    if (mounted) setState(() { _busy = false; _error = e; });
    _pin.clear();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: Center(
            child: ListView(shrinkWrap: true, padding: const EdgeInsets.all(24), children: [
              const Icon(Icons.bolt, size: 56, color: amber),
              const SizedBox(height: 8),
              const Text('GMS — التطبيق الميداني', textAlign: TextAlign.center, style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
              const SizedBox(height: 24),
              TextField(controller: _pin, obscureText: true, autofocus: true, keyboardType: TextInputType.number, textAlign: TextAlign.center,
                  decoration: const InputDecoration(labelText: 'الرمز السري'), onSubmitted: (_) => _go()),
              if (_error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_error!, style: const TextStyle(color: Colors.red), textAlign: TextAlign.center)),
              const SizedBox(height: 16),
              FilledButton(onPressed: _busy ? null : _go, child: const Text('فتح')),
              if (widget.app.biometricEnabled) TextButton.icon(onPressed: _bio, icon: const Icon(Icons.fingerprint), label: const Text('الفتح بالبصمة')),
            ]),
          ),
        ),
      );
}
