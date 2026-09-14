import 'package:flutter_test/flutter_test.dart';
import 'package:medora/services/reminder_service.dart';

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
}
