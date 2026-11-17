import 'package:material_ui/material_ui.dart';

import '../api.dart';
import '../app_state.dart';
import '../validators.dart';

class SetupScreen extends StatefulWidget {
  const SetupScreen(this.app, {super.key});
  final AppState app;
  @override
  State<SetupScreen> createState() => _SetupState();
}

class _SetupState extends State<SetupScreen> {
  late final _url = TextEditingController(text: widget.app.serverUrl ?? AppState.defaultServer);
  final _user = TextEditingController();
  final _pw = TextEditingController();
  bool _obscure = true;
  bool _busy = false;
  String? _error;

  Future<void> _go() async {
    final username = _user.text.trim();
    final password = _pw.text;
    if (username.isEmpty || password.isEmpty) {
      setState(() => _error = 'يرجى إدخال اسم المستخدم وكلمة المرور');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final targetUrl = _url.text.trim().isNotEmpty ? _url.text.trim() : AppState.defaultServer;
      await widget.app.login(targetUrl, username, password, null);
    } on ApiException catch (e) {
      _error = e.message;
    } on NetworkException {
      _error = 'تعذر الاتصال بالخادم السحابي. تحقق من توفر الإنترنت.';
    } catch (e) {
      _error = '$e';
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: const Color(0xFF020617),
        body: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Color(0xFF0F172A), // Midnight Slate
                Color(0xFF020617), // Deep Obsidian
              ],
            ),
          ),
          child: SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Executive Power Shield Crest
                    Container(
                      width: 82,
                      height: 82,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: const LinearGradient(
                          colors: [Color(0xFFD97706), Color(0xFFF59E0B)],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: const Color(0xFFF59E0B).withValues(alpha: 0.35),
                            blurRadius: 28,
                            offset: const Offset(0, 8),
                          ),
                        ],
                      ),
                      child: const Center(
                        child: Icon(Icons.bolt_rounded, size: 50, color: Colors.white),
                      ),
                    ),
                    const SizedBox(height: 18),
                    const Text(
                      'نظام إدارة المولدات الكهربائية',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                        letterSpacing: -0.3,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF59E0B).withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: const Color(0xFFF59E0B).withValues(alpha: 0.3)),
                      ),
                      child: const Text(
                        'بوابة الموظف الميداني — GMS Mobile',
                        style: TextStyle(
                          color: Color(0xFFFBBF24),
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(height: 30),

                    // Luxury Glassmorphic Card
                    Container(
                      padding: const EdgeInsets.all(24),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1E293B).withValues(alpha: 0.92),
                        borderRadius: BorderRadius.circular(24),
                        border: Border.all(color: const Color(0xFF334155).withValues(alpha: 0.85)),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.45),
                            blurRadius: 30,
                            offset: const Offset(0, 16),
                          ),
                        ],
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const Text(
                            'تسجيل الدخول الميداني',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 17,
                              fontWeight: FontWeight.w700,
                            ),
                            textAlign: TextAlign.right,
                          ),
                          const SizedBox(height: 4),
                          const Text(
                            'أدخل اسم المستخدم وكلمة المرور المعتمدة من الإدارة',
                            style: TextStyle(
                              color: Color(0xFF94A3B8),
                              fontSize: 12.5,
                            ),
                            textAlign: TextAlign.right,
                          ),
                          const SizedBox(height: 22),

                          // 1. Username
                          TextField(
                            controller: _user,
                            style: const TextStyle(color: Colors.white, fontSize: 15),
                            textDirection: TextDirection.ltr,
                            decoration: InputDecoration(
                              labelText: 'اسم المستخدم',
                              labelStyle: const TextStyle(color: Color(0xFF94A3B8)),
                              prefixIcon: const Icon(Icons.person_outline_rounded, color: Color(0xFFF59E0B)),
                              filled: true,
                              fillColor: const Color(0xFF0F172A),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(14),
                                borderSide: const BorderSide(color: Color(0xFF334155)),
                              ),
                              enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(14),
                                borderSide: const BorderSide(color: Color(0xFF334155)),
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(14),
                                borderSide: const BorderSide(color: Color(0xFFF59E0B), width: 1.8),
                              ),
                            ),
                          ),
                          const SizedBox(height: 16),

                          // 2. Password
                          TextField(
                            controller: _pw,
                            obscureText: _obscure,
                            style: const TextStyle(color: Colors.white, fontSize: 15),
                            textDirection: TextDirection.ltr,
                            decoration: InputDecoration(
                              labelText: 'كلمة المرور',
                              labelStyle: const TextStyle(color: Color(0xFF94A3B8)),
                              prefixIcon: const Icon(Icons.lock_outline_rounded, color: Color(0xFFF59E0B)),
                              suffixIcon: IconButton(
                                icon: Icon(
                                  _obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                                  color: const Color(0xFF94A3B8),
                                ),
                                onPressed: () => setState(() => _obscure = !_obscure),
                              ),
                              filled: true,
                              fillColor: const Color(0xFF0F172A),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(14),
                                borderSide: const BorderSide(color: Color(0xFF334155)),
                              ),
                              enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(14),
                                borderSide: const BorderSide(color: Color(0xFF334155)),
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(14),
                                borderSide: const BorderSide(color: Color(0xFFF59E0B), width: 1.8),
                              ),
                            ),
                          ),

                          if (_error != null)
                            Container(
                              margin: const EdgeInsets.only(top: 16),
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: Colors.red.shade900.withValues(alpha: 0.35),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(color: Colors.red.shade500.withValues(alpha: 0.5)),
                              ),
                              child: Row(
                                children: [
                                  const Icon(Icons.error_outline_rounded, color: Colors.redAccent, size: 20),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      _error!,
                                      style: const TextStyle(color: Colors.white, fontSize: 13),
                                      textAlign: TextAlign.right,
                                    ),
                                  ),
                                ],
                              ),
                            ),

                          const SizedBox(height: 24),

                          // Luxury Golden Button
                          Container(
                            height: 52,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(14),
                              gradient: const LinearGradient(
                                colors: [Color(0xFFD97706), Color(0xFFF59E0B)],
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: const Color(0xFFF59E0B).withValues(alpha: 0.35),
                                  blurRadius: 16,
                                  offset: const Offset(0, 6),
                                ),
                              ],
                            ),
                            child: ElevatedButton(
                              onPressed: _busy ? null : _go,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.transparent,
                                shadowColor: Colors.transparent,
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                              ),
                              child: _busy
                                  ? const SizedBox(
                                      height: 22,
                                      width: 22,
                                      child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5),
                                    )
                                  : const Row(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      children: [
                                        Icon(Icons.login_rounded, color: Colors.white, size: 20),
                                        SizedBox(width: 10),
                                        Text(
                                          'دخول النظام الميداني',
                                          style: TextStyle(
                                            color: Colors.white,
                                            fontSize: 16,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                      ],
                                    ),
                            ),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 24),

                    // Security & Cloud Connection Footer
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.verified_user_rounded, color: const Color(0xFFF59E0B).withValues(alpha: 0.85), size: 16),
                        const SizedBox(width: 6),
                        Text(
                          'اتصال سحابي آمن ومشفر بأعلى المعايير (256-bit SSL)',
                          style: TextStyle(
                            color: const Color(0xFF94A3B8).withValues(alpha: 0.9),
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'GMS Enterprise Cloud Edition © 2026',
                      style: TextStyle(
                        color: const Color(0xFF64748B).withValues(alpha: 0.8),
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
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
    setState(() {
      _busy = true;
      _error = null;
    });
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
        appBar: AppBar(title: const Text('تغيير كلمة المرور')),
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
        backgroundColor: const Color(0xFF020617),
        appBar: AppBar(
          title: const Text('رمز فتح التطبيق السريع'),
          backgroundColor: const Color(0xFF0F172A),
          foregroundColor: Colors.white,
        ),
        body: ListView(padding: const EdgeInsets.all(20), children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF1E293B),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFF334155)),
            ),
            child: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.security_rounded, color: Color(0xFFF59E0B)),
                    SizedBox(width: 8),
                    Text(
                      'رمز القفل السريع (PIN)',
                      style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
                    ),
                  ],
                ),
                SizedBox(height: 8),
                Text(
                  'اختر رمزًا سريًا (4–8 أرقام) لفتح التطبيق دون اتصال. لا يُرسل الرمز إلى الخادم ويُحفظ مشفرًا داخل شريحة الهاتف.',
                  style: TextStyle(color: Color(0xFF94A3B8), fontSize: 13),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          TextField(
            controller: _a,
            obscureText: true,
            keyboardType: TextInputType.number,
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              labelText: 'الرمز السري الجديد',
              labelStyle: const TextStyle(color: Color(0xFF94A3B8)),
              filled: true,
              fillColor: const Color(0xFF0F172A),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
            ),
            textDirection: TextDirection.ltr,
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _b,
            obscureText: true,
            keyboardType: TextInputType.number,
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              labelText: 'تأكيد الرمز السري',
              labelStyle: const TextStyle(color: Color(0xFF94A3B8)),
              filled: true,
              fillColor: const Color(0xFF0F172A),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
            ),
            textDirection: TextDirection.ltr,
          ),
          const SizedBox(height: 14),
          if (widget.app.biometricAvailable)
            Container(
              decoration: BoxDecoration(
                color: const Color(0xFF1E293B),
                borderRadius: BorderRadius.circular(14),
              ),
              child: SwitchListTile(
                value: _bio,
                onChanged: (v) => setState(() => _bio = v),
                title: const Text('السماح بالفتح بالبصمة البيومترية', style: TextStyle(color: Colors.white)),
                activeThumbColor: const Color(0xFFF59E0B),
              ),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(_error!, style: const TextStyle(color: Colors.redAccent), textAlign: TextAlign.center),
            ),
          const SizedBox(height: 24),
          Container(
            height: 50,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              gradient: const LinearGradient(colors: [Color(0xFFD97706), Color(0xFFF59E0B)]),
            ),
            child: ElevatedButton(
              onPressed: () async {
                final err = Validators.pin(_a.text) ?? (_a.text != _b.text ? 'الرمزان غير متطابقين' : null);
                if (err != null) return setState(() => _error = err);
                await widget.app.setPin(Validators.normalizeDigits(_a.text), _bio);
              },
              style: ElevatedButton.styleFrom(backgroundColor: Colors.transparent, shadowColor: Colors.transparent),
              child: const Text('حفظ ومتابعة العمل', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
            ),
          ),
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
    if (mounted) {
      setState(() {
        _busy = false;
        _error = e;
      });
    }
    _pin.clear();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: const Color(0xFF020617),
        body: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0xFF0F172A), Color(0xFF020617)],
            ),
          ),
          child: SafeArea(
            child: Center(
              child: ListView(shrinkWrap: true, padding: const EdgeInsets.all(28), children: [
                Center(
                  child: Container(
                    width: 72,
                    height: 72,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: const LinearGradient(colors: [Color(0xFFD97706), Color(0xFFF59E0B)]),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFFF59E0B).withValues(alpha: 0.35),
                          blurRadius: 20,
                          offset: const Offset(0, 6),
                        ),
                      ],
                    ),
                    child: const Icon(Icons.bolt_rounded, size: 44, color: Colors.white),
                  ),
                ),
                const SizedBox(height: 16),
                const Text(
                  'GMS Field — المنظومة الميدانية',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 6),
                Text(
                  widget.app.employeeName != null ? 'مرحباً، ${widget.app.employeeName}' : 'أدخل الرمز السري للمتابعة',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 13),
                ),
                const SizedBox(height: 28),
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1E293B).withValues(alpha: 0.9),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: const Color(0xFF334155)),
                  ),
                  child: Column(
                    children: [
                      TextField(
                        controller: _pin,
                        obscureText: true,
                        autofocus: true,
                        keyboardType: TextInputType.number,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.white, fontSize: 22, letterSpacing: 8),
                        decoration: InputDecoration(
                          labelText: 'الرمز السري (PIN)',
                          labelStyle: const TextStyle(color: Color(0xFF94A3B8)),
                          filled: true,
                          fillColor: const Color(0xFF0F172A),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
                        ),
                        onSubmitted: (_) => _go(),
                      ),
                      if (_error != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: Text(_error!, style: const TextStyle(color: Colors.redAccent), textAlign: TextAlign.center),
                        ),
                      const SizedBox(height: 20),
                      Container(
                        height: 48,
                        width: double.infinity,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(12),
                          gradient: const LinearGradient(colors: [Color(0xFFD97706), Color(0xFFF59E0B)]),
                        ),
                        child: ElevatedButton(
                          onPressed: _busy ? null : _go,
                          style: ElevatedButton.styleFrom(backgroundColor: Colors.transparent, shadowColor: Colors.transparent),
                          child: _busy
                              ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                              : const Text('فتح التطبيق', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15)),
                        ),
                      ),
                      if (widget.app.biometricEnabled) ...[
                        const SizedBox(height: 12),
                        TextButton.icon(
                          onPressed: _bio,
                          icon: const Icon(Icons.fingerprint, color: Color(0xFFFBBF24)),
                          label: const Text('فتح عبر البصمة', style: TextStyle(color: Color(0xFFFBBF24))),
                        ),
                      ],
                    ],
                  ),
                ),
              ]),
            ),
          ),
        ),
      );
}
