import 'package:flutter_test/flutter_test.dart';
import 'package:medora/data/models/dose_log_model.dart';

void main() {
  test('fromJson converts offset timestamps to local time', () {
    final m = DoseLogModel.fromJson({
      'id': 'd1',
      'prescription_id': 'p1',
      'scheduled_time': '2026-03-01T07:00:00+00:00',
      'status': 'pending',
    });
    expect(m.scheduledTime.isUtc, isFalse);
    expect(m.scheduledTime.toUtc(), DateTime.utc(2026, 3, 1, 7));
  });

  test('fromLocalMap keeps naive local strings as local', () {
    final m = DoseLogModel.fromLocalMap({
      'id': 'd1',
      'prescription_id': 'p1',
      'scheduled_time': '2026-03-01T08:00:00.000',
      'status': 'pending',
    });
    expect(m.scheduledTime, DateTime(2026, 3, 1, 8));
  });

  test('fromLocalMap converts legacy Z strings to local', () {
    final m = DoseLogModel.fromLocalMap({
      'id': 'd1',
      'prescription_id': 'p1',
      'scheduled_time': '2026-03-01T07:00:00.000Z',
      'status': 'pending',
    });
    expect(m.scheduledTime.isUtc, isFalse);
    expect(m.scheduledTime.toUtc(), DateTime.utc(2026, 3, 1, 7));
  });
}
