/// Medora - Intake Count
///
/// What was taken of one prescription, derived from its dose history.
library;

import 'package:medora/domain/entities/dose_log.dart';
import 'package:medora/domain/entities/prescription.dart';

/// What was taken of one prescription, read from its dose log.
///
/// A scheduled prescription reads "[taken] of [due]", where [due] counts only
/// the doses whose time has come: a dose later today is not "not taken".
/// - **Taken:** a dose with status taken.
/// - **Due:** every dose recorded as taken, skipped or missed, whatever its
///   time (a dose taken or skipped ahead of time counts), plus every pending
///   dose whose time is at or before now. So [taken] never exceeds [due].
/// - A missed dose counts as due and not taken, whether the user marked it
///   or the app did. The app's own "missed" stays on this device and every
///   device draws it from its own copy; a dose taken on another device
///   replaces it on the next pull.
/// - A pending dose of a paused prescription or an ended treatment is not
///   due: the app no longer expects it (it neither reminds nor marks it
///   missed), and when the stop happened is not recorded.
///
/// An as-needed prescription has no schedule, so it has no [due]; it reads
/// the number of doses taken and when the first and last were taken.
class IntakeCount {
  const IntakeCount._({
    required this.asNeeded,
    required this.taken,
    required this.due,
    this.firstTaken,
    this.lastTaken,
  });

  /// Counts [prescription]'s doses among [doses] (other prescriptions'
  /// doses are ignored) as of [now]. [treatmentActive] is whether the
  /// prescription's treatment is still running.
  factory IntakeCount.of(
    Prescription prescription,
    Iterable<DoseLog> doses, {
    required DateTime now,
    required bool treatmentActive,
  }) {
    final mine = doses.where((d) => d.prescriptionId == prescription.id);
    final taken = mine.where((d) => d.status == DoseStatus.taken).toList();
    if (prescription.scheduleType == 'as_needed') {
      final times = [for (final d in taken) d.takenTime ?? d.scheduledTime]
        ..sort();
      return IntakeCount._(
        asNeeded: true,
        taken: taken.length,
        due: 0,
        firstTaken: times.firstOrNull,
        lastTaken: times.lastOrNull,
      );
    }
    final expecting = prescription.isActive && treatmentActive;
    final due = mine.where(
      (d) => switch (d.status) {
        DoseStatus.taken || DoseStatus.skipped || DoseStatus.missed => true,
        DoseStatus.pending => expecting && !d.scheduledTime.isAfter(now),
      },
    );
    return IntakeCount._(asNeeded: false, taken: taken.length, due: due.length);
  }

  /// True for an as-needed prescription.
  final bool asNeeded;

  /// Doses taken.
  final int taken;

  /// Doses whose time has come (see the class comment). Zero when the
  /// schedule has not begun, and always zero for an as-needed prescription.
  final int due;

  /// When the first and the last as-needed dose were taken; null for a
  /// scheduled prescription or when none was taken.
  final DateTime? firstTaken;
  final DateTime? lastTaken;
}
