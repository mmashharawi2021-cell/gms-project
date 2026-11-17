import 'dart:convert';

import 'package:material_ui/material_ui.dart';

import '../app_state.dart';
import '../models.dart';
import 'common.dart';
import 'visit_form.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen(this.app, {super.key});
  final AppState app;
  @override
  State<HomeScreen> createState() => _HomeState();
}

class _HomeState extends State<HomeScreen> {
  int _tab = 0;
  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    final pending = (app.counts['visits_pending'] ?? 0) + (app.counts['photos_pending'] ?? 0) + (app.counts['reports_pending'] ?? 0);
    return Scaffold(
      appBar: AppBar(
        title: Text(app.employeeName ?? 'GMS'),
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(children: [
              Icon(app.wifi ? Icons.wifi : Icons.wifi_off, color: app.wifi ? Colors.green : Colors.grey),
              const SizedBox(width: 4),
              if (app.syncing) const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
            ]),
          ),
          IconButton(onPressed: app.lock, icon: const Icon(Icons.lock), tooltip: 'قفل'),
        ],
      ),
      body: Column(children: [
        if (app.deviceRevoked || app.message != null)
          MaterialBanner(
            content: Text(app.message ?? ''),
            backgroundColor: app.deviceRevoked ? Colors.red.shade50 : null,
            actions: [TextButton(onPressed: () => setState(() => app.message = null), child: const Text('حسنًا'))],
          ),
        Expanded(child: [TasksTab(app, key: ValueKey('t${app.lastSync}${app.counts}')), SubscribersTab(app, key: ValueKey('s${app.lastSync}')), HistoryTab(app, key: ValueKey('h${app.lastSync}${app.counts}')), SyncTab(app)][_tab]),
      ]),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: [
          const NavigationDestination(icon: Icon(Icons.checklist), label: 'المهام'),
          const NavigationDestination(icon: Icon(Icons.people), label: 'المشتركون'),
          const NavigationDestination(icon: Icon(Icons.history), label: 'السجل'),
          NavigationDestination(icon: Badge(isLabelVisible: pending > 0, label: Text('$pending'), child: const Icon(Icons.sync)), label: 'المزامنة'),
        ],
      ),
    );
  }
}

Future<void> openVisit(BuildContext context, AppState app, Subscriber s, TaskItem? t) =>
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => VisitForm(app: app, subscriber: s, task: t)));

class TasksTab extends StatefulWidget {
  const TasksTab(this.app, {super.key});
  final AppState app;
  @override
  State<TasksTab> createState() => _TasksState();
}

class _TasksState extends State<TasksTab> {
  late Future<(List<TaskItem>, Map<String, Subscriber>)> _data = _load();
  Future<(List<TaskItem>, Map<String, Subscriber>)> _load() async {
    final subs = {for (final s in await widget.app.store.subscribers()) s.id: s};
    return (await widget.app.store.openTasks(), subs);
  }

  @override
  Widget build(BuildContext context) => FutureBuilder(
        future: _data,
        builder: (context, snap) {
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final (tasks, subs) = snap.data!;
          if (tasks.isEmpty) {
            return const Center(child: Padding(padding: EdgeInsets.all(24), child: Text('لا توجد مهام مفتوحة على الهاتف. زامن عبر Wi-Fi لتنزيل التكليفات.', textAlign: TextAlign.center)));
          }
          return RefreshIndicator(
            onRefresh: () async {
              await widget.app.syncNow();
              setState(() => _data = _load());
            },
            child: ListView.separated(
              itemCount: tasks.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final t = tasks[i];
                final s = subs[t.subscriberId];
                return ListTile(
                  title: Text(s?.fullName ?? 'مشترك غير متاح'),
                  subtitle: Text('${s?.subscriptionNo ?? ''} — ${s?.zoneName ?? ''}\nالموعد ${t.plannedFor.replaceAll('-', '/')}${t.source == 'revisit' ? ' — إعادة زيارة' : ''}'),
                  isThreeLine: true,
                  trailing: const Icon(Icons.chevron_left),
                  enabled: s != null,
                  onTap: s == null ? null : () async {
                    await openVisit(context, widget.app, s, t);
                    setState(() => _data = _load());
                  },
                );
              },
            ),
          );
        },
      );
}

class SubscribersTab extends StatefulWidget {
  const SubscribersTab(this.app, {super.key});
  final AppState app;
  @override
  State<SubscribersTab> createState() => _SubsState();
}

class _SubsState extends State<SubscribersTab> {
  String _q = '';
  @override
  Widget build(BuildContext context) => Column(children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: TextField(decoration: const InputDecoration(prefixIcon: Icon(Icons.search), labelText: 'بحث بالاسم أو رقم الاشتراك أو العداد'),
              onChanged: (v) => setState(() => _q = v.trim())),
        ),
        const Padding(padding: EdgeInsets.symmetric(horizontal: 12), child: Text('قراءة إضافية خارج المهام تتطلب سببًا وصورة، وتنتظر موافقة المدير.', style: TextStyle(fontSize: 12.5))),
        Expanded(
          child: FutureBuilder(
            future: widget.app.store.subscribers(q: _q),
            builder: (context, snap) {
              if (!snap.hasData) return const Center(child: CircularProgressIndicator());
              final list = snap.data!;
              if (list.isEmpty) return const Center(child: Text('لا يوجد مشتركون في مناطقك (زامن عبر Wi-Fi)'));
              return ListView.builder(
                itemCount: list.length,
                itemBuilder: (context, i) => ListTile(
                  title: Text(list[i].fullName),
                  subtitle: Text('${list[i].subscriptionNo} — ${list[i].zoneName} — عداد ${list[i].meterSerial}'),
                  onTap: () => openVisit(context, widget.app, list[i], null),
                ),
              );
            },
          ),
        ),
      ]);
}

class HistoryTab extends StatefulWidget {
  const HistoryTab(this.app, {super.key});
  final AppState app;
  @override
  State<HistoryTab> createState() => _HistoryState();
}

class _HistoryState extends State<HistoryTab> {
  @override
  Widget build(BuildContext context) => FutureBuilder(
        future: Future.wait([widget.app.store.visits(), widget.app.store.subscribers()]),
        builder: (context, snap) {
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final visits = snap.data![0] as List<LocalVisit>;
          final subs = {for (final s in snap.data![1] as List<Subscriber>) s.id: s};
          if (visits.isEmpty) return const Center(child: Text('لم تُسجل زيارات بعد'));
          return ListView.builder(
            itemCount: visits.length,
            itemBuilder: (context, i) {
              final v = visits[i];
              final local = switch (v.syncState) {
                'pending' => const Chip2('محفوظة على الهاتف — بانتظار Wi-Fi', Colors.orange),
                'sent' => const Chip2('وصلت للخادم', Colors.green),
                'conflict' => const Chip2('تعارض — راجع المدير', Colors.red),
                _ => Chip2('رفضها الخادم: ${rejectReasons[v.syncReason] ?? v.syncReason ?? ''}', Colors.red),
              };
              final server = visitStatus[v.serverStatus];
              return ListTile(
                title: Text('${subs[v.subscriberId]?.fullName ?? v.subscriberId.substring(0, 8)} — ${kinds[v.eventKind]}${v.readingValue != null ? ': ${v.readingValue}' : ''}'),
                subtitle: Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Wrap(spacing: 6, runSpacing: 4, children: [
                    Text(localTime(v.capturedAt)),
                    local,
                    if (server != null) Chip2(server.$1, server.$2),
                  ]),
                ),
                onTap: () => _details(v),
              );
            },
          );
        },
      );

  Future<void> _details(LocalVisit v) async {
    final photos = await widget.app.store.photosOf(v.id);
    final reports = await widget.app.store.reportsOf(v.id);
    if (!mounted) return;
    final text = TextEditingController();
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(16, 16, 16, MediaQuery.of(ctx).viewInsets.bottom + 16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${kinds[v.eventKind]} ${v.readingValue ?? ''}', style: Theme.of(ctx).textTheme.titleLarge),
          Text('التقاط: ${localTime(v.capturedAt)}'),
          for (final p in photos) Text('${p.isPrimary ? 'صورة أساسية' : 'صورة إضافية'}: ${p.state == 'uploaded' ? 'تم الرفع والتحقق' : p.state == 'failed' ? 'فشل: ${p.error}' : 'بانتظار الرفع'}'),
          if (v.serverFlags != null && v.serverFlags != '[]') Text('ملاحظات الخادم: ${(jsonDecode(v.serverFlags!) as List).join('، ')}'),
          for (final r in reports) Text('بلاغ: ${r.explanation} (${r.syncState == 'sent' ? 'أُرسل' : 'بانتظار الإرسال'})'),
          const Divider(),
          const Text('هل في هذه الزيارة خطأ؟ لا يمكن تعديل البيانات المسجلة، لكن يمكنك إبلاغ المدير:'),
          TextField(controller: text, maxLines: 2, decoration: const InputDecoration(labelText: 'وصف الخطأ')),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: () async {
              if (text.text.trim().isEmpty) return;
              await widget.app.reportError(v.id, text.text);
              if (ctx.mounted) Navigator.pop(ctx);
              if (mounted) toast(context, 'حُفظ البلاغ وسيرسل مع المزامنة');
            },
            child: const Text('إبلاغ المدير'),
          ),
        ]),
      ),
    );
    setState(() {});
  }
}

class SyncTab extends StatelessWidget {
  const SyncTab(this.app, {super.key});
  final AppState app;
  @override
  Widget build(BuildContext context) {
    final c = app.counts;
    Widget row(String l, Object? v) => ListTile(dense: true, title: Text(l), trailing: Text('${v ?? 0}', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)));
    return ListView(padding: const EdgeInsets.all(16), children: [
      Card(
        child: ListTile(
          leading: Icon(app.wifi ? Icons.wifi : Icons.wifi_off, color: app.wifi ? Colors.green : Colors.grey, size: 32),
          title: Text(app.wifi ? 'متصل بشبكة Wi-Fi' : 'لا توجد شبكة Wi-Fi'),
          subtitle: const Text('المزامنة تلقائية عبر Wi-Fi فقط. البيانات محفوظة ومشفرة على الهاتف حتى يؤكد الخادم استلامها.'),
        ),
      ),
      row('زيارات بانتظار الإرسال', c['visits_pending']),
      row('صور بانتظار الرفع', c['photos_pending']),
      row('بلاغات بانتظار الإرسال', c['reports_pending']),
      row('مشكلات تحتاج متابعة', c['problems']),
      row('زيارات اليوم', c['today']),
      ListTile(dense: true, title: const Text('آخر مزامنة ناجحة'), trailing: Text(app.lastSync == null ? '—' : localTime(app.lastSync!))),
      if (app.lastReport != null) Padding(padding: const EdgeInsets.all(8), child: Text('آخر نتيجة: أُرسل ${app.lastReport!.sent}، مكرر ${app.lastReport!.duplicates}، صور ${app.lastReport!.photos}، مرفوض ${app.lastReport!.rejected}، تعارض ${app.lastReport!.conflicts}')),
      const SizedBox(height: 12),
      FilledButton.icon(onPressed: app.wifi && !app.syncing ? app.syncNow : null, icon: const Icon(Icons.sync), label: Text(app.syncing ? 'جارٍ المزامنة…' : 'مزامنة الآن')),
      const SizedBox(height: 24),
      OutlinedButton(
        onPressed: () async {
          final e = await app.logout();
          if (e != null && context.mounted) toast(context, e);
        },
        child: const Text('تسجيل الخروج من هذا الهاتف'),
      ),
    ]);
  }
}
