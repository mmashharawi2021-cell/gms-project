import 'dart:typed_data';

import 'package:image_picker/image_picker.dart';
import 'package:material_ui/material_ui.dart';

import '../app_state.dart';
import '../clock.dart';
import '../models.dart';
import '../validators.dart';
import 'common.dart';

/// Reading / unreadable / meter incident. One primary photo is mandatory for EVERY kind (BR-08).
/// The capture instant + monotonic evidence are taken when the primary photo is shot.
class VisitForm extends StatefulWidget {
  const VisitForm({super.key, required this.app, required this.subscriber, this.task});
  final AppState app;
  final Subscriber subscriber;
  final TaskItem? task;
  @override
  State<VisitForm> createState() => _VisitFormState();
}

class _Shot {
  final String id;
  final Uint8List bytes;
  final bool primary;
  _Shot(this.id, this.bytes, this.primary);
}

class _VisitFormState extends State<VisitForm> {
  final _form = GlobalKey<FormState>();
  final _reading = TextEditingController(), _reason = TextEditingController(), _note = TextEditingController();
  String _kind = 'reading', _category = 'fault';
  final _shots = <_Shot>[];
  DateTime? _capturedAt;
  ({String? bootId, int? elapsedMs})? _evidence;
  bool _saving = false;
  final _picker = ImagePicker();

  bool get _extra => widget.task == null;

  Future<void> _shoot(bool primary) async {
    final x = await _picker.pickImage(source: ImageSource.camera, maxWidth: 1600, imageQuality: 80);
    if (x == null) return;
    final bytes = await x.readAsBytes();
    if (primary) {
      _capturedAt = DateTime.now().toUtc();
      _evidence = await DeviceClock.evidence();
    }
    setState(() {
      if (primary) _shots.removeWhere((s) => s.primary);
      _shots.add(_Shot(widget.app.newId(), bytes, primary));
    });
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    if (!_shots.any((s) => s.primary)) return toast(context, 'صورة العداد الأساسية إلزامية حتى عند تعذر القراءة');
    setState(() => _saving = true);
    try {
      final app = widget.app;
      final visitId = app.newId();
      final photos = <LocalPhoto>[];
      for (final s in _shots) {
        final kept = await app.keepPhoto(s.id, s.bytes);
        photos.add(LocalPhoto(id: s.id, visitId: visitId, path: kept.path, sha256: kept.sha256, size: kept.size, isPrimary: s.primary));
      }
      final captured = _capturedAt ?? DateTime.now().toUtc();
      final v = LocalVisit(
        id: visitId, operationId: app.newId(), subscriberId: widget.subscriber.id, installationId: widget.subscriber.installationId,
        zoneId: widget.subscriber.zoneId, taskId: widget.task?.id, eventKind: _kind,
        readingValue: _kind == 'reading' ? Validators.canonicalReading(_reading.text) : null,
        reason: _reason.text.trim().isEmpty ? null : _reason.text.trim(), note: _note.text.trim().isEmpty ? null : _note.text.trim(),
        incidentCategory: _kind == 'meter_incident' ? _category : null, capturedAt: captured.toIso8601String(),
        offsetMinutes: captured.toLocal().timeZoneOffset.inMinutes, bootId: _evidence?.bootId, elapsedMs: _evidence?.elapsedMs,
        createdAt: DateTime.now().toUtc().toIso8601String(),
      );
      await app.saveVisit(v, photos);
      if (mounted) {
        toast(context, 'حُفظت الزيارة على الهاتف — سترسل عند توفر Wi-Fi');
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      if (mounted) toast(context, 'تعذر الحفظ: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.subscriber;
    final diff = _kind == 'reading' && Validators.reading(_reading.text) == null
        ? Validators.diff(Validators.canonicalReading(_reading.text), s.lastValue)
        : null;
    return Scaffold(
      appBar: AppBar(title: Text(_extra ? 'زيارة إضافية' : 'تنفيذ مهمة')),
      body: Form(
        key: _form,
        child: ListView(padding: const EdgeInsets.all(16), children: [
          Text(s.fullName, style: Theme.of(context).textTheme.titleLarge),
          Text('اشتراك ${s.subscriptionNo} — ${s.zoneName} — عداد ${s.meterSerial}'),
          if (s.lastValue != null) Text('آخر قراءة معتمدة: ${s.lastValue}', style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 16),
          SegmentedButton<String>(
            segments: [for (final e in kinds.entries) ButtonSegment(value: e.key, label: Text(e.value))],
            selected: {_kind},
            onSelectionChanged: (v) => setState(() => _kind = v.first),
          ),
          const SizedBox(height: 16),
          if (_kind == 'reading') ...[
            TextFormField(
              controller: _reading,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              textDirection: TextDirection.ltr,
              style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
              decoration: const InputDecoration(labelText: 'القراءة (kWh)', helperText: 'منزلتان عشريتان كحد أقصى'),
              validator: Validators.reading,
              autovalidateMode: AutovalidateMode.onUserInteraction,
              onChanged: (_) => setState(() {}),
            ),
            if (diff != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: diff.startsWith('-')
                    ? const Text('القراءة أقل من آخر قراءة معتمدة — تُحفظ ويقرر المدير', style: TextStyle(color: Colors.deepOrange))
                    : Text('الاستهلاك منذ آخر قراءة: $diff kWh'),
              ),
          ],
          if (_kind == 'meter_incident') ...[
            DropdownButtonFormField<String>(
              initialValue: _category,
              decoration: const InputDecoration(labelText: 'نوع البلاغ'),
              items: const [
                DropdownMenuItem(value: 'fault', child: Text('عطل')),
                DropdownMenuItem(value: 'reset', child: Text('تصفير')),
                DropdownMenuItem(value: 'replacement', child: Text('استبدال العداد')),
                DropdownMenuItem(value: 'other', child: Text('أخرى')),
              ],
              onChanged: (v) => setState(() => _category = v!),
            ),
            const SizedBox(height: 12),
          ],
          const SizedBox(height: 12),
          TextFormField(
            controller: _reason,
            maxLines: 2,
            decoration: InputDecoration(labelText: _kind != 'reading' ? 'السبب (إلزامي)' : _extra ? 'سبب الزيارة الإضافية (إلزامي)' : 'سبب/ملاحظة (اختياري)'),
            validator: (v) => (_kind != 'reading' || _extra) && (v == null || v.trim().isEmpty) ? 'السبب مطلوب' : null,
          ),
          const SizedBox(height: 12),
          TextFormField(controller: _note, maxLines: 2, decoration: const InputDecoration(labelText: 'ملاحظة إضافية')),
          const SizedBox(height: 16),
          Wrap(spacing: 8, runSpacing: 8, children: [
            FilledButton.icon(onPressed: () => _shoot(true), icon: const Icon(Icons.photo_camera),
                label: Text(_shots.any((s) => s.primary) ? 'إعادة تصوير العداد' : 'تصوير العداد (إلزامي)')),
            OutlinedButton.icon(onPressed: _shots.any((s) => s.primary) ? () => _shoot(false) : null, icon: const Icon(Icons.add_a_photo), label: const Text('صورة إضافية')),
          ]),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final s in _shots)
              Stack(children: [
                ClipRRect(borderRadius: BorderRadius.circular(8), child: Image.memory(s.bytes, width: 110, height: 110, fit: BoxFit.cover)),
                if (s.primary) const Positioned(top: 4, right: 4, child: Chip2('أساسية', amber)),
                if (!s.primary)
                  Positioned(top: 0, left: 0, child: IconButton(icon: const Icon(Icons.close), onPressed: () => setState(() => _shots.remove(s)))),
              ]),
          ]),
          const SizedBox(height: 24),
          FilledButton(onPressed: _saving ? null : _save, child: _saving ? const CircularProgressIndicator() : const Text('حفظ الزيارة')),
        ]),
      ),
    );
  }
}
