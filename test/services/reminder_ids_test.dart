import 'package:flutter_test/flutter_test.dart';
import 'package:medora/services/reminder_service.dart';
import 'package:medora/services/stock_expiry_reminders.dart';

void main() {
  test(
    'notificationBaseId is stable, positive and leaves room for offsets',
    () {
      const id = '3f2504e0-4f89-11d3-9a0c-0305e82c3301';
      final a = ReminderService.notificationBaseId(id);
      final b = ReminderService.notificationBaseId(id);
      expect(a, b);
      expect(a, greaterThan(0));
      expect(a % 16, 0); // low 4 bits reserved for per-dose offsets
      expect(a + 15, lessThanOrEqualTo(0x7FFFFFFF));
    },
  );

  test('different ids map to different bases', () {
    final a = ReminderService.notificationBaseId('dose-a');
    final b = ReminderService.notificationBaseId('dose-b');
    expect(a, isNot(b));
  });

  test('prescription expiry ids use offset 10 of the block', () {
    final id = stockAlertId('r1', StockAlertKind.rxExpiry);
    expect(id & 0xF, 0xA);
    expect(id, isNot(stockAlertId('r1', StockAlertKind.expiry)));
  });

  test('0x8, 0x9 and 0xA are stock alert ids; 0x0-0x3 (dose offsets) are '
      'not', () {
    for (final offset in [0x8, 0x9, 0xA]) {
      expect(ReminderService.isStockAlertIdForTest(offset), isTrue);
    }
    for (final offset in [0x0, 0x1, 0x2, 0x3]) {
      expect(ReminderService.isStockAlertIdForTest(offset), isFalse);
    }
  });
}
