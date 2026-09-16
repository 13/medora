import 'package:flutter_test/flutter_test.dart';
import 'package:medora/domain/entities/dose_log.dart';
import 'package:medora/domain/entities/intake_count.dart';
import 'package:medora/domain/entities/prescription.dart';

void main() {
  final now = DateTime(2026, 3, 5, 12);

  Prescription prescription({
    String id = 'p1',
    String scheduleType = 'times_per_day',
    bool isActive = true,
  }) => Prescription(
    id: id,
    treatmentId: 't1',
    medicationId: 'm1',
    dosage: '1 tablet',
    durationDays: 5,
    startTime: DateTime(2026, 3, 3, 8),
    scheduleType: scheduleType,
    scheduleTimes: const ['08:00', '14:00', '20:00'],
    isActive: isActive,
  );

  var seq = 0;
  DoseLog dose(
    DateTime at,
    DoseStatus status, {
    String prescriptionId = 'p1',
    DateTime? takenTime,
  }) => DoseLog(
    id: 'd${seq++}',
    prescriptionId: prescriptionId,
    scheduledTime: at,
    status: status,
    takenTime: takenTime,
  );

  group('a scheduled prescription', () {
    test('counts taken doses out of the doses recorded as due', () {
      final doses = [
        for (var i = 0; i < 14; i++)
          dose(
            DateTime(2026, 2, 20, 8).add(Duration(hours: 8 * i)),
            DoseStatus.taken,
          ),
        dose(DateTime(2026, 2, 25, 8), DoseStatus.missed),
      ];
      final c = IntakeCount.of(
        prescription(),
        doses,
        now: now,
        treatmentActive: true,
      );
      expect(c.asNeeded, isFalse);
      expect(c.taken, 14);
      expect(c.due, 15);
    });

    test('a pending dose counts once its time has come, a later one does '
        'not', () {
      final doses = [
        dose(DateTime(2026, 3, 5, 8), DoseStatus.taken),
        // Overdue: due and not taken.
        dose(DateTime(2026, 3, 5, 11), DoseStatus.pending),
        // Exactly now: due.
        dose(now, DoseStatus.pending),
        // Later today and tomorrow: not due yet.
        dose(DateTime(2026, 3, 5, 20), DoseStatus.pending),
        dose(DateTime(2026, 3, 6, 8), DoseStatus.pending),
      ];
      final c = IntakeCount.of(
        prescription(),
        doses,
        now: now,
        treatmentActive: true,
      );
      expect(c.taken, 1);
      expect(c.due, 3);
    });

    test('skipped and missed doses were due and not taken', () {
      final doses = [
        dose(DateTime(2026, 3, 4, 8), DoseStatus.taken),
        dose(DateTime(2026, 3, 4, 14), DoseStatus.skipped),
        dose(DateTime(2026, 3, 4, 20), DoseStatus.missed),
      ];
      final c = IntakeCount.of(
        prescription(),
        doses,
        now: now,
        treatmentActive: true,
      );
      expect(c.taken, 1);
      expect(c.due, 3);
    });

    test('a dose taken or skipped ahead of its time counts', () {
      final doses = [
        dose(DateTime(2026, 3, 5, 14), DoseStatus.taken),
        dose(DateTime(2026, 3, 5, 20), DoseStatus.skipped),
        dose(DateTime(2026, 3, 6, 8), DoseStatus.pending),
      ];
      final c = IntakeCount.of(
        prescription(),
        doses,
        now: now,
        treatmentActive: true,
      );
      expect(c.taken, 1);
      expect(c.due, 2);
    });

    test('once paused, its leftover pending doses are not due', () {
      final doses = [
        dose(DateTime(2026, 3, 4, 8), DoseStatus.taken),
        dose(DateTime(2026, 3, 4, 14), DoseStatus.missed),
        dose(DateTime(2026, 3, 4, 20), DoseStatus.pending),
      ];
      final c = IntakeCount.of(
        prescription(isActive: false),
        doses,
        now: now,
        treatmentActive: true,
      );
      expect(c.taken, 1);
      expect(c.due, 2);
    });

    test('once the treatment has ended, its leftover pending doses are not '
        'due', () {
      final doses = [
        dose(DateTime(2026, 3, 4, 8), DoseStatus.taken),
        dose(DateTime(2026, 3, 4, 14), DoseStatus.pending),
      ];
      final c = IntakeCount.of(
        prescription(),
        doses,
        now: now,
        treatmentActive: false,
      );
      expect(c.taken, 1);
      expect(c.due, 1);
    });

    test("another prescription's doses are not counted", () {
      final doses = [
        dose(DateTime(2026, 3, 4, 8), DoseStatus.taken),
        dose(DateTime(2026, 3, 4, 8), DoseStatus.taken, prescriptionId: 'p2'),
        dose(DateTime(2026, 3, 4, 9), DoseStatus.missed, prescriptionId: 'p2'),
      ];
      final c = IntakeCount.of(
        prescription(),
        doses,
        now: now,
        treatmentActive: true,
      );
      expect(c.taken, 1);
      expect(c.due, 1);
    });

    test('has no dates', () {
      final c = IntakeCount.of(
        prescription(),
        [dose(DateTime(2026, 3, 4, 8), DoseStatus.taken)],
        now: now,
        treatmentActive: true,
      );
      expect(c.firstTaken, isNull);
      expect(c.lastTaken, isNull);
    });
  });

  group('an as-needed prescription', () {
    test('counts the logged doses and when they were taken', () {
      final doses = [
        dose(
          DateTime(2026, 3, 4, 15),
          DoseStatus.taken,
          takenTime: DateTime(2026, 3, 4, 15, 5),
        ),
        dose(DateTime(2026, 3, 2, 22), DoseStatus.taken),
        dose(
          DateTime(2026, 3, 3, 9),
          DoseStatus.taken,
          takenTime: DateTime(2026, 3, 3, 9),
        ),
      ];
      final c = IntakeCount.of(
        prescription(scheduleType: 'as_needed'),
        doses,
        now: now,
        treatmentActive: true,
      );
      expect(c.asNeeded, isTrue);
      expect(c.taken, 3);
      expect(c.due, 0);
      // The one without a taken time falls back to its scheduled time.
      expect(c.firstTaken, DateTime(2026, 3, 2, 22));
      expect(c.lastTaken, DateTime(2026, 3, 4, 15, 5));
    });

    test('ignores doses that were never taken', () {
      // Only an older build or a switched schedule leaves these behind.
      final doses = [
        dose(DateTime(2026, 3, 4, 8), DoseStatus.pending),
        dose(DateTime(2026, 3, 4, 9), DoseStatus.missed),
        dose(DateTime(2026, 3, 4, 10), DoseStatus.skipped),
      ];
      final c = IntakeCount.of(
        prescription(scheduleType: 'as_needed'),
        doses,
        now: now,
        treatmentActive: true,
      );
      expect(c.taken, 0);
      expect(c.due, 0);
      expect(c.firstTaken, isNull);
      expect(c.lastTaken, isNull);
    });
  });
}
