/// Medora - Dose Log Providers
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:medora/domain/entities/dose_log.dart';
import 'package:medora/presentation/providers/medication_providers.dart';
import 'package:medora/presentation/providers/providers.dart';
import 'package:medora/services/reminder_service.dart';

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
      // We don't await this to keep app startup snappy
      _ensureDoseLogsExistInBackground();
    }
    final doses = await _fetchTodaysDoses();
    _scheduleUpcomingReminders(doses);
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

  /// Schedule reminders for all pending doses.
  void _scheduleUpcomingReminders(List<DoseLog> doses) {
    if (kIsWeb) return;
    
    final pending = doses.where((d) => d.status == DoseStatus.pending).toList();
    // Use a background future to avoid blocking the main build process
    Future(() async {
      for (final dose in pending) {
        // We pass cancelFirst: false here because we're doing a bulk schedule 
        // and assuming it's fresh. Individual updates still use cancelFirst: true.
        await ReminderService.instance.scheduleRemindersForDose(
          dose: dose,
          medicationName: dose.medicationName ?? 'Medication',
          cancelFirst: false, 
        );
      }
    });
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

      for (final p in prescriptions) {
        // Skip prescriptions that ended before today
        if (p.endTime.isBefore(today)) continue;

        // Check how many doses SHOULD exist today
        final scheduledToday = p.scheduledDoseTimes.where((t) =>
            !t.isBefore(today) && t.isBefore(tomorrow)).toList();

        if (scheduledToday.isEmpty) continue;

        // Filter logs for THIS prescription
        final todayLogs = allTodayLogs.where((l) => l.prescriptionId == p.id).toList();

        if (todayLogs.length < scheduledToday.length) {
          debugPrint('⚠ Missing dose logs for prescription ${p.id} '
              '(${p.medicationName ?? "unknown"}): '
              'has ${todayLogs.length}, expected ${scheduledToday.length}. Generating missing...');
          await doseRepo.generateDoseLogsForPrescription(p.id);
        }
      }
      
      // If we generated anything, refresh the state
      if (_startupCheckDone) {
        state = await AsyncValue.guard(_fetchTodaysDoses);
      }
    } catch (e) {
      debugPrint('⚠ _ensureDoseLogsExist error: $e');
    }
  }

  Future<void> refresh() async {
    state = await AsyncValue.guard(_fetchTodaysDoses);
    if (state.hasValue) {
      _scheduleUpcomingReminders(state.value!);
    }
  }

  Future<void> markTaken(String id) async {
    // Optimistic update: immediately reflect in UI
    _updateDoseStatus(id, DoseStatus.taken, takenTime: DateTime.now());

    // Cancel pending reminders for this dose
    if (!kIsWeb) {
      await ReminderService.instance.cancelRemindersForDose(id);
    }

    final repo = ref.read(doseLogRepositoryProvider);
    await repo.markDoseTaken(id);

    // Auto-diminish: find the dose, look up its prescription
    await _autoDiminish(id);

    // Refresh from DB to get canonical state + invalidate history cache
    await _refreshAndInvalidateHistory();
  }

  Future<void> undoTaken(String id) async {
    // Optimistic update: back to pending
    _updateDoseStatus(id, DoseStatus.pending, clearTakenTime: true);

    final repo = ref.read(doseLogRepositoryProvider);
    await repo.markDosePending(id);
    
    await _autoDiminish(id, reverse: true);

    await _refreshAndInvalidateHistory();
    
    // Reschedule reminders for this dose as it's now pending again
    if (!kIsWeb && state.hasValue) {
      final dose = state.value!.where((d) => d.id == id).firstOrNull;
      if (dose != null) {
        await ReminderService.instance.scheduleRemindersForDose(
          dose: dose,
          medicationName: dose.medicationName ?? 'Medication',
        );
      }
    }
  }

  Future<void> markSkipped(String id) async {
    _updateDoseStatus(id, DoseStatus.skipped);

    if (!kIsWeb) {
      await ReminderService.instance.cancelRemindersForDose(id);
    }

    final repo = ref.read(doseLogRepositoryProvider);
    await repo.markDoseSkipped(id); 
    await _refreshAndInvalidateHistory();
  }

  Future<void> markMissed(String id) async {
    _updateDoseStatus(id, DoseStatus.missed);

    if (!kIsWeb) {
      await ReminderService.instance.cancelRemindersForDose(id);
    }

    final repo = ref.read(doseLogRepositoryProvider);
    await repo.markDoseMissed(id);
    await _refreshAndInvalidateHistory();
  }

  /// Optimistic UI update: change a dose's status in the current state
  /// without waiting for the DB roundtrip.
  void _updateDoseStatus(String id, DoseStatus newStatus, {DateTime? takenTime, bool clearTakenTime = false}) {
    final current = state.value;
    if (current == null) return;

    final updated = current.map((dose) {
      if (dose.id == id) {
        return dose.copyWith(
          status: newStatus, 
          takenTime: clearTakenTime ? null : (takenTime ?? dose.takenTime),
        );
      }
      return dose;
    }).toList();

    state = AsyncData(updated);
  }

  /// Refresh from DB and bump the dose data version so all dependent
  /// providers (like dose history) refetch automatically.
  Future<void> _refreshAndInvalidateHistory() async {
    final doses = await _fetchTodaysDoses();
    state = AsyncData(doses);
    _scheduleUpcomingReminders(doses);
    // Bump version to trigger dose history and other dependent providers
    ref.read(doseDataVersionProvider.notifier).bump();
  }

  /// If the prescription has autoDiminish enabled, decrease medication stock.
  Future<void> _autoDiminish(String doseLogId, {bool reverse = false}) async {
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
      await medNotifier.updateQuantity(prescription.medicationId, reverse ? amount : -amount);
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
    final result = await repo.getTodaysDoseLogs();
    return result.when(
      success: (data) => data.where((d) => d.prescriptionId == prescriptionId).toList(),
      failure: (msg) => throw Exception(msg),
    );
  },
);
