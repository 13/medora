/// Medora - Notification port.
///
/// The scheduler talks to this interface; [ReminderService] implements it
/// with flutter_local_notifications, tests use a fake.
library;

import 'package:medora/domain/entities/dose_log.dart';
import 'package:medora/services/stock_expiry_reminders.dart';

abstract class ReminderPort {
  /// Cancel every pending notification owned by the app, of every kind.
  ///
  /// A blunt instrument: it takes the stock and expiry alerts too, so only
  /// a caller that owns *both* schedulers may use it, and it must then tell
  /// both to forget their snapshots. A scheduler recovering its own state
  /// wants [cancelAllDoses] instead.
  Future<void> cancelAll();

  /// Cancel every pending dose reminder, leaving the stock and expiry
  /// alerts alone.
  ///
  /// The dose scheduler's recovery move when it has no snapshot to diff
  /// against. The id spaces are disjoint ([StockAlert.id] uses offsets 8 and
  /// 9), which is what makes sparing them possible.
  Future<void> cancelAllDoses();

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

  /// Ask the OS for permission to show notifications, and report whether it
  /// is granted.
  ///
  /// Safe to call repeatedly: the platform prompts at most once and answers
  /// from the stored decision afterwards.
  Future<bool> ensurePermissions();

  /// Cancel one stock or expiry notification by its [StockAlert.id].
  Future<void> cancelStockAlert(int id);
}
