import 'package:medora/domain/entities/dose_log.dart';
import 'package:medora/services/reminder_port.dart';

/// Minimal in-memory [ReminderPort] for widget/unit tests.
class FakePort implements ReminderPort {
  int cancelAllCalls = 0;
  final scheduled = <DoseLog>[];
  final cancelledDoses = <String>[];

  /// When true, [scheduleForDose] throws instead of recording — simulates
  /// the underlying notification plugin failing mid-reconcile.
  bool throwOnSchedule = false;

  @override
  Future<void> cancelAll() async => cancelAllCalls++;

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
}
