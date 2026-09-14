import 'package:flutter_test/flutter_test.dart';
import 'package:medora/domain/entities/dose_log.dart';

void main() {
  final now = DateTime(2026, 3, 4, 15);

  DoseLog dose(DoseStatus status, DateTime scheduled) => DoseLog(
    id: 'd1',
    prescriptionId: 'p1',
    scheduledTime: scheduled,
    status: status,
  );

  test('isOverdueAt uses the injected clock', () {
    expect(
      dose(DoseStatus.pending, DateTime(2026, 3, 4, 14)).isOverdueAt(now),
      isTrue,
    );
    expect(
      dose(DoseStatus.pending, DateTime(2026, 3, 4, 16)).isOverdueAt(now),
      isFalse,
    );
    expect(
      dose(DoseStatus.taken, DateTime(2026, 3, 4, 14)).isOverdueAt(now),
      isFalse,
    );
  });

  test('isOverdue getter delegates to the system clock', () {
    expect(dose(DoseStatus.pending, DateTime(2000)).isOverdue, isTrue);
    expect(dose(DoseStatus.pending, DateTime(2099)).isOverdue, isFalse);
  });
}
