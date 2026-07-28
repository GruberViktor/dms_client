import 'package:dms_client/src/util/format.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';

void main() {
  setUpAll(() => Intl.defaultLocale = 'de_DE');

  group('formatMonetary', () {
    test('always two decimals, comma separator', () {
      expect(formatMonetary('1234.5'), '1.234,50');
      expect(formatMonetary('0'), '0,00');
      expect(formatMonetary('19.99'), '19,99');
      expect(formatMonetary('-42'), '-42,00');
    });

    test('groups thousands German-style', () {
      expect(formatMonetary('1234567.891'), '1.234.567,89');
    });

    test('accepts numbers and comma input as well as decimal strings', () {
      expect(formatMonetary(1234.5), '1.234,50');
      expect(formatMonetary('1234,5'), '1.234,50');
    });

    test('keeps precision beyond double for long decimal strings', () {
      expect(
        formatMonetary('12345678901234567890.125'),
        '12.345.678.901.234.567.890,13',
      );
    });

    test('passes unparseable values through', () {
      expect(formatMonetary(null), '—');
      expect(formatMonetary(''), '—');
      expect(formatMonetary('n/a'), 'n/a');
    });
  });
}
