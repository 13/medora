/// Medora - Dose Log Providers
library;

import 'dart:async';

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

/// Normalizes a [DateTime] to midnight (local), for use as a calendar-day
/// key.
DateTime dayKey(DateTime d) => DateTime(d.year, d.month, d.day);

/// Doses for the calendar day containing [day] (local). Queries the
/// repository by date range and re-fetches when [doseDataVersionProvider]
/// changes (also for today, so a fixed test clock works).
final dosesForDayProvider = FutureProvider.family<List<DoseLog>, DateTime>(
  (ref, day) async {
    ref.watch(doseDataVersionProvider);
    final key = dayKey(day);
    final repo = ref.watch(doseLogRepositoryProvider);
    final result = await repo.getDoseLogsByDateRange(
      key,
      key.add(const Duration(days: 1)),
    );
    return result.when(
      success: (data) => data,
      failure: (msg) => throw Exception(msg),
    );
  },
);

/// The next pending dose to act on: earliest pending dose today whose time
/// is <= now + 2h, else the earliest pending dose today, else null.
final nextDueDoseProvider = Provider<DoseLog?>((ref) {
  final doses = ref.watch(todaysDoseLogsProvider).value ?? [];
  final now = ref.watch(nowProvider)();

  final pending = doses.where((d) => d.status == DoseStatus.pending).toList()
    ..sort((a, b) => a.scheduledTime.compareTo(b.scheduledTime));
  if (pending.isEmpty) return null;

  final cutoff = now.add(const Duration(hours: 2));
  for (final dose in pending) {
    if (!dose.scheduledTime.isAfter(cutoff)) return dose;
  }
  return pending.first;
});

/// Single entry point for dose mutations from any screen.
final doseActionsProvider = Provider<DoseActions>((ref) => DoseActions(ref));

class DoseActions {
  DoseActions(this._ref);

  final Ref _ref;

  Future<void> take(String id) async {
    final repo = _ref.read(doseLogRepositoryProvider);
    await repo.markDoseTaken(id);
    await _autoDiminish(_ref, id);
    await _refresh();
  }

  Future<void> undoTake(String id) async {
    final repo = _ref.read(doseLogRepositoryProvider);
    await repo.markDosePending(id);
    await _autoDiminish(_ref, id, reverse: true);
    await _refresh();
  }

  Future<void> skip(String id) async {
    final repo = _ref.read(doseLogRepositoryProvider);
    await repo.markDoseSkipped(id);
    await _refresh();
  }

  Future<void> markMissed(String id) async {
    final repo = _ref.read(doseLogRepositoryProvider);
    await repo.markDoseMissed(id);
    await _refresh();
  }

  /// Undo a skip: mark pending again, without touching stock.
  Future<void> undoSkip(String id) async {
    final repo = _ref.read(doseLogRepositoryProvider);
    await repo.markDosePending(id);
    await _refresh();
  }

  /// Take each dose in turn; returns the number taken.
  Future<int> takeAllDue(List<String> ids) async {
    var count = 0;
    for (final id in ids) {
      await take(id);
      count++;
    }
    return count;
  }

  Future<void> _refresh() async {
    await _ref.read(todaysDoseLogsProvider.notifier).refresh();
    _ref.read(doseDataVersionProvider.notifier).bump();
    unawaited(_ref.read(reminderSchedulerProvider).reconcile());
  }
}

/// If the prescription has autoDiminish enabled, decrease medication stock.
Future<void> _autoDiminish(Ref ref, String doseLogId, {bool reverse = false}) async {
  try {
    final repo = ref.read(doseLogRepositoryProvider);
    final doseResult = await repo.getDoseLogById(doseLogId);
    final dose = doseResult.dataOrNull;
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
    await medNotifier.updateQuantity(prescription.medicationId, reverse ? amount : -amount);
  } catch (_) {
    // Non-critical: don't fail the dose marking
  }
}

/// Parse leading integer from dosage string. Falls back to 1.
int _parseDosageAmount(String dosage) {
  final match = RegExp(r'^(\d+)').firstMatch(dosage.trim());
  if (match != null) {
    return int.tryParse(match.group(1)!) ?? 1;
  }
  return 1;
}

/// Provider for today's dose logs.
final todaysDoseLogsProvider =
    AsyncNotifierProvider<TodaysDoseLogsNotifier, List<DoseLog>>(
  TodaysDoseLogsNotifier.new,
);

class TodaysDoseLogsNotifier extends AsyncNotifier<List<DoseLog>> {
  @override
  Future<List<DoseLog>> build() async {
    // We don't await this to keep app startup snappy. It's idempotent —
    // it only generates dose logs that are missing.
    unawaited(_ensureDoseLogsExistInBackground());
    final doses = await _fetchTodaysDoses();
    unawaited(ref.read(reminderSchedulerProvider).reconcile());
    return doses;
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
  /// Runs in background to avoid blocking app startup.
  Future<void> _ensureDoseLogsExistInBackground() async {
    try {
      final prescRepo = ref.read(prescriptionRepositoryProvider);
      final doseRepo = ref.read(doseLogRepositoryProvider);

      final prescResult = await prescRepo.getActivePrescriptions();
      final prescriptions = prescResult.dataOrNull ?? [];

      if (prescriptions.isEmpty) return;

      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      final tomorrow = today.add(const Duration(days: 1));

      // Get ALL dose logs for today in one query instead of looping
      final logsResult = await doseRepo.getTodaysDoseLogs();
      final allTodayLogs = logsResult.dataOrNull ?? [];

      // Build a map for O(1) lookup instead of filtering repeatedly
      final logsByPrescription = <String, List<dynamic>>{};
      for (final log in allTodayLogs) {
        logsByPrescription.putIfAbsent(log.prescriptionId, () => []).add(log);
      }

      // Collect prescriptions that need dose generation
      final needsGeneration = <String>[];

      for (final p in prescriptions) {
        // Skip prescriptions that ended before today
        if (p.endTime.isBefore(today)) continue;

        // Check how many doses SHOULD exist today
        final scheduledToday = p.scheduledDoseTimes.where((t) =>
            !t.isBefore(today) && t.isBefore(tomorrow)).toList();

        if (scheduledToday.isEmpty) continue;

        // O(1) lookup using map
        final todayLogs = logsByPrescription[p.id] ?? [];

        if (todayLogs.length < scheduledToday.length) {
          debugPrint('⚠ Missing dose logs for prescription ${p.id} '
              '(${p.medicationName ?? "unknown"}): '
              'has ${todayLogs.length}, expected ${scheduledToday.length}. Generating missing...');
          needsGeneration.add(p.id);
        }
      }

      // Generate all missing dose logs in parallel
      if (needsGeneration.isNotEmpty) {
        await Future.wait(
          needsGeneration.map((id) => doseRepo.generateDoseLogsForPrescription(id))
        );

        // Refresh the state after generation
        state = await AsyncValue.guard(_fetchTodaysDoses);
        unawaited(ref.read(reminderSchedulerProvider).reconcile());
      }
    } catch (e) {
      debugPrint('⚠ _ensureDoseLogsExist error: $e');
    }
  }

  Future<void> refresh() async {
    state = await AsyncValue.guard(_fetchTodaysDoses);
    unawaited(ref.read(reminderSchedulerProvider).reconcile());
  }

  // Thin wrappers kept so existing call sites compile unchanged.
  // The actual mutation logic lives in [DoseActions].
  Future<void> markTaken(String id) => ref.read(doseActionsProvider).take(id);

  Future<void> undoTaken(String id) =>
      ref.read(doseActionsProvider).undoTake(id);

  Future<void> markSkipped(String id) => ref.read(doseActionsProvider).skip(id);

  Future<void> markMissed(String id) =>
      ref.read(doseActionsProvider).markMissed(id);
}

/// Provider for dose logs by prescription.
final doseLogsByPrescriptionProvider =
    FutureProvider.family<List<DoseLog>, String>(
  (ref, prescriptionId) async {
    final repo = ref.watch(doseLogRepositoryProvider);
    final result = await repo.getTodaysDoseLogs();
    return result.when(
      success: (data) => data.where((d) => d.prescriptionId == prescriptionId).toList(),
      failure: (msg) => throw Exception(msg),
    );
  },
);
