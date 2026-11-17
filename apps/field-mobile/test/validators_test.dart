import 'package:flutter_test/flutter_test.dart';
import 'package:gms_field/src/validators.dart';

void main() {
  test('readings keep at most two decimals and are never rounded', () {
    expect(Validators.reading('21.2'), isNull);
    expect(Validators.reading('21.98'), isNull);
    expect(Validators.reading('121.987'), contains('لن يتم التقريب'));
    expect(Validators.reading(''), isNotNull);
    expect(Validators.reading('-5'), isNotNull);
    expect(Validators.reading('1e3'), isNotNull);
    expect(Validators.reading('١٢١٫٩٨'), isNull); // Arabic-Indic digits and separator
    expect(Validators.canonicalReading('١٢١٫٩٨'), '121.98');
    expect(Validators.canonicalReading('0101.50'), '101.50');
  });

  test('exact difference without floating point', () {
    expect(Validators.diff('101.43', '100'), '1.43');
    expect(Validators.diff('100.1', '100.35'), '-0.25');
    expect(Validators.diff('0.3', '0.1'), '0.20');
  });

  test('PIN rules', () {
    expect(Validators.pin('1234'), isNotNull);
    expect(Validators.pin('1111'), isNotNull);
    expect(Validators.pin('12'), isNotNull);
    expect(Validators.pin('2580'), isNull);
  });
}
