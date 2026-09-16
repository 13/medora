/// Medora - Notification port.
///
/// The scheduler talks to this interface; [ReminderService] implements it
/// with flutter_local_notifications, tests use a fake.
library;

import 'package:medora/domain/entities/dose_log.dart';
import 'package:medora/services/stock_expiry_reminders.dart';

abstract class ReminderPort {
  /// Cancel every pending notification owned by the app.
  Future<void> cancelAll();

  /// Cancel the pending notifications for one dose.
  Future<void> cancelForDose(String doseId);

  /// Schedule the notifications for one dose (currently two: 60 min before
  /// and at the scheduled time). Past times are skipped.
  Future<void> scheduleForDose({
    required DoseLog dose,
    required String medicationName,
  });

  /// Schedule one stock or expiry notification.
  ///
  /// Uses [StockAlert.id], which is disjoint from the dose reminder ids, so
  /// the two schedulers never cancel each other's notifications.
  Future<void> scheduleStockAlert(StockAlert alert);

  /// Cancel one stock or expiry notification by its [StockAlert.id].
  Future<void> cancelStockAlert(int id);
}
