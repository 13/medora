import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

const _uuid = Uuid();

class SeededPrescription {
  const SeededPrescription({
    required this.medicationId,
    required this.treatmentId,
    required this.prescriptionId,
  });
  final String medicationId;
  final String treatmentId;
  final String prescriptionId;
}

/// Inserts one medication, one treatment and one prescription, fixed-interval
/// unless [scheduleType] says otherwise.
Future<SeededPrescription> seedPrescription(
  Database db, {
  DateTime? startTime,
  int intervalHours = 8,
  int durationDays = 2,
  String medicationName = 'Tachipirina',
  String scheduleType = 'fixed_interval',
}) async {
  final medId = _uuid.v4();
  final treatId = _uuid.v4();
  final prescId = _uuid.v4();
  final start = startTime ?? DateTime(2026, 3, 1, 8);
  final now = DateTime.now().toIso8601String();

  await db.insert('medications', {
    'id': medId,
    'name': medicationName,
    'quantity': 10,
    'quantity_unit': 'tablets',
    'minimum_stock_level': 0,
    'created_at': now,
    'updated_at': now,
    'sync_status': 'synced',
  });
  await db.insert('treatments', {
    'id': treatId,
    'name': 'Flu',
    'start_date': start.toIso8601String().split('T').first,
    'is_active': 1,
    'created_at': now,
    'updated_at': now,
    'sync_status': 'synced',
  });
  await db.insert('prescriptions', {
    'id': prescId,
    'treatment_id': treatId,
    'medication_id': medId,
    'dosage': '1 tablet',
    'dosage_amount': 1.0,
    'interval_hours': intervalHours,
    'duration_days': durationDays,
    'start_time': start.toIso8601String(),
    'is_active': 1,
    'auto_diminish': 0,
    'created_at': now,
    'updated_at': now,
    'schedule_type': scheduleType,
    'sync_status': 'synced',
  });
  return SeededPrescription(
    medicationId: medId,
    treatmentId: treatId,
    prescriptionId: prescId,
  );
}

/// Inserts one dose log and returns its id.
Future<String> seedDoseLog(
  Database db,
  String prescriptionId,
  DateTime scheduledTime, {
  String status = 'pending',
  String? id,
  DateTime? takenTime,
}) async {
  final doseId = id ?? _uuid.v4();
  final now = DateTime.now().toIso8601String();
  await db.insert('dose_logs', {
    'id': doseId,
    'prescription_id': prescriptionId,
    'scheduled_time': scheduledTime.toIso8601String(),
    'taken_time': takenTime?.toIso8601String(),
    'status': status,
    'created_at': now,
    'updated_at': now,
    'sync_status': 'synced',
  });
  return doseId;
}

/// A time on the same calendar day as [now], at most [minutes] before it
/// (never crossing midnight) — stays inside the 2 h missed-dose grace window
/// whatever the wall-clock hour, so maintenance never marks it missed.
///
/// The clamp is start-of-day, not 00:01: within the first [minutes] of a day
/// it is the only value that is both still today and not *after* [now], and
/// a seed in the future is not overdue — which is what a caller asking for a
/// recent time is invariably about to assert. Pinned by `seed_test.dart`.
DateTime recentToday(DateTime now, {int minutes = 30}) {
  final candidate = now.subtract(Duration(minutes: minutes));
  return candidate.day == now.day
      ? candidate
      : DateTime(now.year, now.month, now.day);
}

/// A time on the same calendar day as [now], at least [minutes] after it
/// (never crossing midnight) — for seeds that must land later today
/// relative to the real clock, whatever the wall-clock hour.
///
/// The clamp is the last instant of the day for the mirror of the reason
/// above: 23:59 is already in the past at 23:59:30, which would seed an
/// upcoming dose as an overdue one. Pinned by `seed_test.dart`.
DateTime laterToday(DateTime now, {int minutes = 60}) {
  final candidate = now.add(Duration(minutes: minutes));
  return candidate.day == now.day
      ? candidate
      : DateTime(now.year, now.month, now.day, 23, 59, 59, 999);
}
