/// Medora - Notification port.
///
/// The scheduler talks to this interface; [ReminderService] implements it
/// with flutter_local_notifications, tests use a fake.
library;

import 'package:medora/domain/entities/dose_log.dart';

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
}
