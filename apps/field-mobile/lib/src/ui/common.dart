import 'package:material_ui/material_ui.dart';

const amber = Color(0xFFB45309);

ThemeData gmsTheme(Brightness b) => ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: amber, brightness: b),
      useMaterial3: true,
      inputDecorationTheme: const InputDecorationTheme(border: OutlineInputBorder()),
    );

const visitStatus = <String, (String, Color)>{
  'awaiting_photo': ('بانتظار الصورة', Colors.orange),
  'pending_review': ('بانتظار مراجعة المدير', Colors.blue),
  'exception': ('استثناء — بانتظار قرار المدير', Colors.deepOrange),
  'approved': ('اعتمدها المدير', Colors.green),
  'rejected': ('رفضها المدير', Colors.red),
  'needs_revisit': ('طُلبت إعادة زيارة', Colors.orange),
  'unreadable_resolved': ('أُغلق التعذر', Colors.grey),
  'incident_resolved': ('حُسم البلاغ', Colors.grey),
};

const rejectReasons = <String, String>{
  'invalid_precision': 'أكثر من منزلتين عشريتين',
  'forbidden_zone': 'خارج مناطقك المصرح بها',
  'reason_required': 'السبب مطلوب',
  'malformed_payload': 'بيانات غير مكتملة',
  'unknown_reference': 'مشترك أو عداد غير معروف',
  'visit_id_reused': 'تعارض في معرّف الزيارة',
  'operation_reused': 'تعارض في معرّف العملية',
  'invalid_reading': 'قراءة غير صالحة',
};

const kinds = <String, String>{'reading': 'قراءة', 'unreadable': 'تعذر القراءة', 'meter_incident': 'بلاغ عن العداد'};

class Chip2 extends StatelessWidget {
  const Chip2(this.text, this.color, {super.key});
  final String text;
  final Color color;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(12)),
        child: Text(text, style: TextStyle(color: color, fontSize: 12.5)),
      );
}

void toast(BuildContext context, String text) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

String localTime(String iso) {
  final d = DateTime.parse(iso).toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${d.year}/${two(d.month)}/${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
}
