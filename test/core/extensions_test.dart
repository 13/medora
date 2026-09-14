import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:medora/core/extensions.dart';

void main() {
  setUpAll(() async {
    await initializeDateFormatting('de');
    await initializeDateFormatting('it');
    await initializeDateFormatting('en');
  });

  test('formatted follows Intl.defaultLocale', () {
    final d = DateTime(2026, 3, 5, 14, 7);
    Intl.defaultLocale = 'en';
    expect(d.formatted, 'Mar 5, 2026');
    Intl.defaultLocale = 'de';
    // intl's bundled CLDR data renders the yMMMd skeleton for German as
    // 'd. MMM y' (spelled abbreviated month), not a numeric 'dd.MM.yyyy'
    // pattern — verified directly against package:intl 0.20.2.
    expect(d.formatted, '5. März 2026');
    Intl.defaultLocale = 'it';
    expect(d.formatted, '5 mar 2026');
    expect(d.timeFormatted, '14:07');
  });
}
