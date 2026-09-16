import 'package:flutter_test/flutter_test.dart';
import 'package:medora/services/notification_budget.dart';
import 'package:medora/services/reminder_scheduler.dart';

/// iOS keeps only this many pending local notifications and drops the rest
/// silently — whichever scheduler asked last loses, with no error anywhere.
const _iosPendingCap = 64;

void main() {
  test('the two shares add up to the one budget', () {
    expect(
      kDoseNotificationBudget + kStockNotificationBudget,
      kMaxPendingNotifications,
    );
    expect(kMaxPendingNotifications, lessThanOrEqualTo(_iosPendingCap));
  });

  test('the dose scheduler spends its share of that budget', () {
    expect(ReminderScheduler.maxNotifications, kDoseNotificationBudget);
  });

  test('a full cabinet cannot request more than the platform allows', () {
    // The worst case: every dose slot taken (two notifications each) and
    // every stock slot taken. stockAlertsFor's default limit is the stock
    // share — see stock_expiry_reminders_test.
    const doses =
        ReminderScheduler.maxNotifications ~/
        ReminderScheduler.notificationsPerDose;
    expect(
      doses * ReminderScheduler.notificationsPerDose + kStockNotificationBudget,
      lessThanOrEqualTo(_iosPendingCap),
    );
  });
}
