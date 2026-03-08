/// Medora - Dose Log Providers
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:medora/domain/entities/dose_log.dart';
import 'package:medora/presentation/providers/medication_providers.dart';
import 'package:medora/presentation/providers/providers.dart';

/// Counter that is incremented whenever dose statuses change.
/// Providers that depend on this (e.g. dose history) will auto-refetch.
final doseDataVersionProvider =
    NotifierProvider<DoseDataVersionNotifier, int>(
  DoseDataVersionNotifier.new,
);

class DoseDataVersionNotifier extends Notifier<int> {
  @override
  int build() => 0;

  void bump() => state++;
}

/// Provider for today's dose logs.
final todaysDoseLogsProvider =
    AsyncNotifierProvider<TodaysDoseLogsNotifier, List<DoseLog>>(
  TodaysDoseLogsNotifier.new,
);

class TodaysDoseLogsNotifier extends AsyncNotifier<List<DoseLog>> {
  /// Track whether the one-time startup check has already run.
  static bool _startupCheckDone = false;

  @override
  Future<List<DoseLog>> build() async {
    // One-time startup check: ensure dose logs exist for all active
    // prescriptions. Only runs once per app session to avoid
    // interfering with already-taken doses on subsequent invalidations.
    if (!_startupCheckDone) {
      _startupCheckDone = true;
      await _ensureDoseLogsExist();
    }
    return _fetchTodaysDoses();
  }

  Future<List<DoseLog>> _fetchTodaysDoses() async {
    final repo = ref.read(doseLogRepositoryProvider);
    final result = await repo.getTodaysDoseLogs();
    return result.when(
      success: (data) => data,
      failure: (msg) => throw Exception(msg),
    );
  }

  /// Ensure dose logs exist for all active prescriptions.
  /// Only runs once at app startup to fill in any missing dose logs
  /// (e.g. new day, or generation failed previously).
  Future<void> _ensureDoseLogsExist() async {
    try {
      final prescRepo = ref.read(prescriptionRepositoryProvider);
      final doseRepo = ref.read(doseLogRepositoryProvider);

      final prescResult = await prescRepo.getActivePrescriptions();
      final prescriptions = prescResult.dataOrNull ?? [];

      if (prescriptions.isEmpty) return;

      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      final tomorrow = today.add(const Duration(days: 1));

      for (final p in prescriptions) {
        // Skip prescriptions that ended before today
        if (p.endTime.isBefore(today)) continue;

        // Check how many doses SHOULD exist today
        final scheduledToday = p.scheduledDoseTimes.where((t) =>
            !t.isBefore(today) && t.isBefore(tomorrow)).toList();

        if (scheduledToday.isEmpty) continue;

        // Check if dose logs exist for today for this prescription
        final logsResult =
            await doseRepo.getDoseLogsByPrescription(p.id);
        final logs = logsResult.dataOrNull ?? [];

        final todayLogs = logs.where((l) =>
            !l.scheduledTime.isBefore(today) &&
            l.scheduledTime.isBefore(tomorrow)).toList();

        if (todayLogs.length < scheduledToday.length) {
          debugPrint('⚠ Missing dose logs for prescription ${p.id} '
              '(${p.medicationName ?? "unknown"}): '
              'has ${todayLogs.length}, expected ${scheduledToday.length}. Generating missing...');
          // generateDoseLogsForPrescription is idempotent — it checks
          // existing times before creating and never overwrites existing logs.
          await doseRepo.generateDoseLogsForPrescription(p.id);
        }
      }
    } catch (e) {
      debugPrint('⚠ _ensureDoseLogsExist error (non-fatal): $e');
    }
  }

  Future<void> refresh() async {
    state = await AsyncValue.guard(_fetchTodaysDoses);
  }

  Future<void> markTaken(String id) async {
    // Optimistic update: immediately reflect in UI
    _updateDoseStatus(id, DoseStatus.taken, takenTime: DateTime.now());

    final repo = ref.read(doseLogRepositoryProvider);
    await repo.markDoseTaken(id);

    // Auto-diminish: find the dose, look up its prescription
    await _autoDiminish(id);

    // Refresh from DB to get canonical state + invalidate history cache
    await _refreshAndInvalidateHistory();
  }

  Future<void> markSkipped(String id) async {
    _updateDoseStatus(id, DoseStatus.skipped);

    final repo = ref.read(doseLogRepositoryProvider);
    await repo.markDoseSkipped(id);
    await _refreshAndInvalidateHistory();
  }

  Future<void> markMissed(String id) async {
    _updateDoseStatus(id, DoseStatus.missed);

    final repo = ref.read(doseLogRepositoryProvider);
    await repo.markDoseMissed(id);
    await _refreshAndInvalidateHistory();
  }

  /// Optimistic UI update: change a dose's status in the current state
  /// without waiting for the DB roundtrip.
  void _updateDoseStatus(String id, DoseStatus newStatus, {DateTime? takenTime}) {
    final current = state.value;
    if (current == null) return;

    final updated = current.map((dose) {
      if (dose.id == id) {
        return dose.copyWith(status: newStatus, takenTime: takenTime);
      }
      return dose;
    }).toList();

    state = AsyncData(updated);
  }

  /// Refresh from DB and bump the dose data version so all dependent
  /// providers (like dose history) refetch automatically.
  Future<void> _refreshAndInvalidateHistory() async {
    state = await AsyncValue.guard(_fetchTodaysDoses);
    // Bump version to trigger dose history and other dependent providers
    ref.read(doseDataVersionProvider.notifier).bump();
  }

  /// If the prescription has autoDiminish enabled, decrease medication stock.
  Future<void> _autoDiminish(String doseLogId) async {
    try {
      // Find the dose log to get prescriptionId
      final doses = state.value ?? [];
      final dose = doses.where((d) => d.id == doseLogId).firstOrNull;
      if (dose == null) return;

      final prescRepo = ref.read(prescriptionRepositoryProvider);
      final prescResult =
          await prescRepo.getPrescriptionById(dose.prescriptionId);
      final prescription = prescResult.dataOrNull;
      if (prescription == null || !prescription.autoDiminish) return;

      // Parse numeric amount from dosageAmount or dosage text
      final amount = prescription.dosageAmount?.round() ??
          _parseDosageAmount(prescription.dosage);
      if (amount <= 0) return;

      final medNotifier = ref.read(medicationListProvider.notifier);
      await medNotifier.updateQuantity(prescription.medicationId, -amount);
    } catch (_) {
      // Non-critical: don't fail the dose marking
    }
  }

  /// Parse leading integer from dosage string. Falls back to 1.
  static int _parseDosageAmount(String dosage) {
    final match = RegExp(r'^(\d+)').firstMatch(dosage.trim());
    if (match != null) {
      return int.tryParse(match.group(1)!) ?? 1;
    }
    return 1;
  }
}

/// Provider for dose logs by prescription.
final doseLogsByPrescriptionProvider =
    FutureProvider.family<List<DoseLog>, String>(
  (ref, prescriptionId) async {
    final repo = ref.watch(doseLogRepositoryProvider);
    final result = await repo.getDoseLogsByPrescription(prescriptionId);
    return result.when(
      success: (data) => data,
      failure: (msg) => throw Exception(msg),
    );
  },
);

