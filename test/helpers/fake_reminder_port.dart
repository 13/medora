import 'package:medora/domain/entities/dose_log.dart';
import 'package:medora/services/reminder_port.dart';
import 'package:medora/services/stock_expiry_reminders.dart';

/// Minimal in-memory [ReminderPort] for widget/unit tests.
class FakePort implements ReminderPort {
  int cancelAllCalls = 0;
  int cancelAllDosesCalls = 0;
  final scheduled = <DoseLog>[];
  final cancelledDoses = <String>[];
  final stockAlerts = <StockAlert>[];
  final cancelledStockAlerts = <int>[];

  /// What the OS would still hold pending for the stock and expiry alerts.
  ///
  /// [stockAlerts] is a log of everything ever booked; this is the live set,
  /// which is what makes one scheduler cancelling another's work visible.
  final pendingStockAlertIds = <int>{};

  /// When true, [scheduleForDose] throws instead of recording — simulates
  /// the underlying notification plugin failing mid-reconcile.
  bool throwOnSchedule = false;

  /// What [ensurePermissions] reports, and how often it was asked.
  bool permissionGranted = true;
  int ensurePermissionsCalls = 0;

  @override
  Future<bool> ensurePermissions() async {
    ensurePermissionsCalls++;
    return permissionGranted;
  }

  @override
  Future<void> cancelAll() async {
    cancelAllCalls++;
    // Everything the app owns, stock and expiry alerts included — that is
    // exactly what the real `cancelAll()` does.
    pendingStockAlertIds.clear();
  }

  @override
  Future<void> cancelAllDoses() async {
    cancelAllDosesCalls++;
    // Deliberately does not touch [pendingStockAlertIds]: sparing them is
    // the whole point of this method existing.
  }

  @override
  Future<void> cancelForDose(String doseId) async => cancelledDoses.add(doseId);

  @override
  Future<void> scheduleForDose({
    required DoseLog dose,
    required String medicationName,
  }) async {
    if (throwOnSchedule) {
      throw StateError('scheduleForDose failed');
    }
    scheduled.add(dose);
  }

  @override
  Future<void> scheduleStockAlert(StockAlert alert) async {
    if (throwOnSchedule) {
      throw StateError('scheduleStockAlert failed');
    }
    stockAlerts.add(alert);
    pendingStockAlertIds.add(alert.id);
  }

  @override
  Future<void> cancelStockAlert(int id) async {
    cancelledStockAlerts.add(id);
    pendingStockAlertIds.remove(id);
  }
}
