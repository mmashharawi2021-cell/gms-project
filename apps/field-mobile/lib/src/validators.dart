/// Reading/PIN validation. The value typed by the employee is kept as TEXT end-to-end:
/// it is never parsed into a double, so 121.98 stays exactly "121.98" and 121.987 is refused (never rounded).
class Validators {
  static final _reading = RegExp(r'^\d{1,14}(\.\d{1,2})?$');
  static final _tooPrecise = RegExp(r'^\d+\.\d{3,}$');

  /// Returns an Arabic error message, or null when the value is acceptable.
  static String? reading(String? raw) {
    final v = normalizeDigits((raw ?? '').trim());
    if (v.isEmpty) return 'أدخل قراءة العداد';
    if (_tooPrecise.hasMatch(v)) return 'مسموح بمنزلتين عشريتين فقط — لن يتم التقريب، صحّح القيمة';
    if (!_reading.hasMatch(v)) return 'قراءة غير صالحة (أرقام فقط مع فاصلة عشرية اختيارية)';
    return null;
  }

  /// Canonical text sent to the server ("0101.5" -> "101.5"); call only after [reading] returned null.
  static String canonicalReading(String raw) {
    var v = normalizeDigits(raw.trim());
    final parts = v.split('.');
    var intPart = parts[0].replaceFirst(RegExp(r'^0+(?=\d)'), '');
    return parts.length == 2 ? '$intPart.${parts[1]}' : intPart;
  }

  /// Arabic-Indic and Eastern Arabic-Indic digits + Arabic decimal separator -> ASCII.
  static String normalizeDigits(String s) {
    const ar = '٠١٢٣٤٥٦٧٨٩';
    const fa = '۰۱۲۳۴۵۶۷۸۹';
    final b = StringBuffer();
    for (final ch in s.split('')) {
      final i = ar.indexOf(ch), j = fa.indexOf(ch);
      if (i >= 0) {
        b.write(i);
      } else if (j >= 0) {
        b.write(j);
      } else if (ch == '٫' || ch == ',') {
        b.write('.');
      } else {
        b.write(ch);
      }
    }
    return b.toString();
  }

  static String? pin(String? raw) {
    final v = normalizeDigits(raw ?? '');
    if (!RegExp(r'^\d{4,8}$').hasMatch(v)) return 'الرمز من 4 إلى 8 أرقام';
    if (RegExp(r'^(\d)\1+$').hasMatch(v) || '0123456789'.contains(v) || '9876543210'.contains(v)) return 'رمز سهل التخمين؛ اختر غيره';
    return null;
  }

  /// Exact difference of two ≤2-decimal strings (for display only).
  static String? diff(String current, String? previous) {
    if (previous == null) return null;
    int cents(String s) {
      final p = s.split('.');
      final f = (p.length > 1 ? p[1] : '').padRight(2, '0').substring(0, 2);
      return int.parse(p[0]) * 100 + int.parse(f);
    }
    try {
      final d = cents(current) - cents(previous);
      final a = d.abs();
      return '${d < 0 ? '-' : ''}${a ~/ 100}.${(a % 100).toString().padLeft(2, '0')}';
    } catch (_) {
      return null;
    }
  }
}
