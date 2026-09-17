/// Medora - Keeps each prescription's dose rows in line with its schedule.
///
/// Every device generates the doses of a schedule with the same ids (see
/// `dose_slot.dart`); the sync cycle pulls the copies other devices sent
/// and inserts a generated dose only where the server lacks it. This
/// service is what makes a device generate what it still lacks:
///
/// - [applyPulled] when a pull brings a prescription that is new here, or
///   whose schedule changed on another device;
/// - [ensureScheduled] on start, on resume and after every sync, for any
///   prescription whose stored doses do not match its schedule. It also
///   moves a dose an older build stored hours off back to its slot's time
///   (`DoseLogRepository.correctDoseTimes`).
library;

import 'package:flutter/foundation.dart';
import 'package:medora/domain/entities/dose_log.dart';
import 'package:medora/domain/entities/dose_slot.dart';
import 'package:medora/domain/entities/prescription.dart';
import 'package:medora/domain/repositories/dose_log_repository.dart';
import 'package:medora/domain/repositories/prescription_repository.dart';

/// The prescriptions one pull stored: [added] were not on this device
/// before, [changed] were, and their schedule or active state changed.
class PulledPrescriptions {
  PulledPrescriptions({Set<String>? added, Set<String>? changed})
    : added = added ?? <String>{},
      changed = changed ?? <String>{};

  final Set<String> added;
  final Set<String> changed;

  bool get isEmpty => added.isEmpty && changed.isEmpty;
}

class DoseScheduleService {
  DoseScheduleService({
    required this._prescriptions,
    required this._doses,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final PrescriptionRepository _prescriptions;
  final DoseLogRepository _doses;
  final DateTime Function() _now;

  /// Dose ids [ensureScheduled] already acted on in this process, per
  /// prescription. A slot that keeps disappearing (the server holds a
  /// tombstone for its id, so the sync deletes it again) is then not
  /// generated again after every sync, which would never end.
  final Map<String, Set<String>> _attempted = {};

  Future<int>? _running;

  /// Brings the doses of the prescriptions a pull stored in line with them,
  /// as the device that made the change did: a changed schedule is
  /// regenerated (the pending doses it no longer has are dropped here), a
  /// new prescription is generated. A paused prescription, or one of an
  /// ended treatment, gets nothing. Returns how many prescriptions were
  /// handled.
  Future<int> applyPulled(PulledPrescriptions pulled) async {
    if (pulled.isEmpty) return 0;
    final running = {
      for (final p
          in (await _prescriptions.getActivePrescriptions()).dataOrNull ??
              const <Prescription>[])
        p.id,
    };
    var handled = 0;
    for (final id in {...pulled.changed, ...pulled.added}) {
      if (!running.contains(id)) continue;
      final result = pulled.changed.contains(id)
          ? await _doses.regenerateDoseLogsForPrescription(id)
          : await _doses.generateDoseLogsForPrescription(id);
      if (result.isSuccess) handled++;
    }
    return handled;
  }

  /// Regenerates every running prescription (active, in a treatment that
  /// has not ended) whose schedule has not run out and whose
  /// stored doses differ from its schedule: a scheduled time with no dose,
  /// or a pending dose at a time the schedule does not have. Compares times,
  /// not counts, so a schedule moved to other times of day is caught too.
  /// Returns how many prescriptions were regenerated.
  ///
  /// Calls made while one runs share its result.
  Future<int> ensureScheduled() => _running ??= _ensure().whenComplete(() {
    _running = null;
  });

  Future<int> _ensure() async {
    var regenerated = 0;
    try {
      final prescriptions =
          (await _prescriptions.getActivePrescriptions()).dataOrNull ??
          const <Prescription>[];
      final now = _now();
      final today = DateTime(now.year, now.month, now.day);
      for (final p in prescriptions) {
        if (p.scheduleType == 'as_needed' || p.endTime.isBefore(today)) {
          continue;
        }
        final times = p.scheduledDoseTimes;
        if (times.isEmpty) continue;
        final stored = (await _doses.getDoseLogsByPrescription(
          p.id,
        )).dataOrNull;
        if (stored == null) continue;
        final shifted = _shiftedSlots(p.id, times, stored);
        if (shifted.isNotEmpty) await _doses.correctDoseTimes(shifted);
        final off = _offSchedule(p.id, times, stored);
        final attempted = _attempted.putIfAbsent(p.id, () => <String>{});
        if (attempted.containsAll(off)) continue;
        attempted.addAll(off);
        debugPrint(
          'Doses: ${off.length} dose(s) of prescription ${p.id} do not match '
          'its schedule; regenerating',
        );
        final result = await _doses.regenerateDoseLogsForPrescription(p.id);
        if (result.isSuccess) regenerated++;
      }
    } catch (e) {
      debugPrint('⚠ Doses: checking the schedules failed: $e');
    }
    return regenerated;
  }

  /// The pending doses stored under a slot's own id at another time, with
  /// the time that slot has: dose id → slot time. A slot another dose
  /// already sits at is left out: moving the dose there would make two.
  static Map<String, DateTime> _shiftedSlots(
    String prescriptionId,
    List<DateTime> times,
    List<DoseLog> stored,
  ) {
    final byId = {for (final d in stored) d.id: d};
    final storedKeys = {for (final d in stored) doseSlotKey(d.scheduledTime)};
    final shifted = <String, DateTime>{};
    for (final t in times) {
      if (storedKeys.contains(doseSlotKey(t))) continue;
      final dose = byId[scheduledDoseId(prescriptionId, t)];
      if (dose == null || dose.status != DoseStatus.pending) continue;
      if (doseSlotKey(dose.scheduledTime) != doseSlotKey(t)) {
        shifted[dose.id] = t;
      }
    }
    return shifted;
  }

  /// The ids of the scheduled doses [stored] lacks, and of the pending
  /// doses in [stored] the schedule does not have.
  ///
  /// A dose stored under a slot's id counts as that slot even at another
  /// time: an older build wrote some slots hours off, and generating them
  /// again would only bring the same row back.
  static Set<String> _offSchedule(
    String prescriptionId,
    List<DateTime> times,
    List<DoseLog> stored,
  ) {
    final storedKeys = {for (final d in stored) doseSlotKey(d.scheduledTime)};
    final storedIds = {for (final d in stored) d.id};
    final scheduledKeys = {for (final t in times) doseSlotKey(t)};
    final unmatchedIds = <String>{};
    final off = <String>{};
    for (final t in times) {
      if (storedKeys.contains(doseSlotKey(t))) continue;
      final id = scheduledDoseId(prescriptionId, t);
      unmatchedIds.add(id);
      if (!storedIds.contains(id)) off.add(id);
    }
    for (final d in stored) {
      if (d.status != DoseStatus.pending) continue;
      if (scheduledKeys.contains(doseSlotKey(d.scheduledTime))) continue;
      if (unmatchedIds.contains(d.id)) continue;
      off.add(d.id);
    }
    return off;
  }
}
