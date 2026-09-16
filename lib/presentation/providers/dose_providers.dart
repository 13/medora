/// Medora - Dose Log Providers
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:medora/domain/entities/dose_log.dart';
import 'package:medora/domain/entities/prescription.dart';
import 'package:medora/presentation/providers/medication_providers.dart';
import 'package:medora/presentation/providers/now_provider.dart';
import 'package:medora/presentation/providers/providers.dart';
import 'package:uuid/uuid.dart';

/// Counter that is incremented whenever dose statuses change.
/// Providers that depend on this (e.g. dose history) will auto-refetch.
final doseDataVersionProvider = NotifierProvider<DoseDataVersionNotifier, int>(
  DoseDataVersionNotifier.new,
);

class DoseDataVersionNotifier extends Notifier<int> {
  @override
  int build() => 0;

  void bump() => state++;
}

/// Refetches every dose-derived provider.
///
/// [DoseActions] does this itself after each mutation, but plenty of writes
/// happen elsewhere (saving a prescription, ending a treatment, archiving a
/// medication, wiping local data). Those must call this, otherwise
/// [dosesForDayProvider] keeps serving its cached list — Riverpod 3
/// providers are not auto-dispose, so nothing re-runs on its own.
extension DoseDataRefresh on Ref {
  void invalidateDoseData() {
    invalidate(todaysDoseLogsProvider);
    read(doseDataVersionProvider.notifier).bump();
  }
}

/// Widget-side twin of [DoseDataRefresh.invalidateDoseData].
extension WidgetDoseDataRefresh on WidgetRef {
  void invalidateDoseData() {
    invalidate(todaysDoseLogsProvider);
    read(doseDataVersionProvider.notifier).bump();
  }
}

/// Normalizes a [DateTime] to midnight (local), for use as a calendar-day
/// key.
DateTime dayKey(DateTime d) => DateTime(d.year, d.month, d.day);

/// Doses for the calendar day containing [day] (local). Queries the
/// repository by date range and re-fetches when [doseDataVersionProvider]
/// changes (also for today, so a fixed test clock works).
final dosesForDayProvider = FutureProvider.family<List<DoseLog>, DateTime>((
  ref,
  day,
) async {
  ref.watch(doseDataVersionProvider);
  final key = dayKey(day);
  final repo = ref.watch(doseLogRepositoryProvider);
  final result = await repo.getDoseLogsByDateRange(
    key,
    DateTime(key.year, key.month, key.day + 1),
  );
  return result.when(
    success: (data) => data,
    failure: (msg) => throw Exception(msg),
  );
});

/// The next pending dose to act on: the earliest pending dose today, else
/// null. "Earliest pending" already covers the old "<= now + 2h" case — if
/// the earliest pending dose is more than 2h out, there is by definition no
/// pending dose within the next 2h, so returning it (or null) is the same
/// result either way.
final nextDueDoseProvider = Provider<DoseLog?>((ref) {
  final doses = ref.watch(todaysDoseLogsProvider).value ?? [];
  final pending = doses.where((d) => d.status == DoseStatus.pending).toList()
    ..sort((a, b) => a.scheduledTime.compareTo(b.scheduledTime));
  return pending.isEmpty ? null : pending.first;
});

/// Single entry point for dose mutations from any screen.
final doseActionsProvider = Provider<DoseActions>(DoseActions.new);

class DoseActions {
  DoseActions(this._ref);

  final Ref _ref;

  Future<bool> take(String id) async {
    final ok = await _take(id);
    await _refresh();
    return ok;
  }

  /// Marks one dose taken without refreshing — [takeAllDue] refreshes once
  /// for the whole batch instead of once per dose.
  Future<bool> _take(String id) async {
    final repo = _ref.read(doseLogRepositoryProvider);
    final result = await repo.markDoseTaken(id);
    // Stock only moves when the dose actually changed status; a failed
    // write must not diminish (or, on undo, restore) the medication.
    if (result.isSuccess) await _autoDiminish(_ref, id);
    return result.isSuccess;
  }

  /// Undo a take: the dose is pending again and its stock comes back.
  ///
  /// A dose of an as-needed prescription was only ever a record of an
  /// intake, so undoing it deletes it instead: back to pending it would be
  /// a dose nobody is due to take.
  ///
  /// Only a dose that is still taken can be undone. Two undo buttons can
  /// hold the same dose (the dose sheet and the snackbar); the second one
  /// returns false and gives no stock back.
  Future<bool> undoTake(String id) async {
    final repo = _ref.read(doseLogRepositoryProvider);
    final dose = (await repo.getDoseLogById(id)).dataOrNull;
    if (dose == null || dose.status != DoseStatus.taken) return false;
    final prescription =
        (await _ref
                .read(prescriptionRepositoryProvider)
                .getPrescriptionById(dose.prescriptionId))
            .dataOrNull;
    final bool ok;
    if (prescription?.scheduleType == 'as_needed') {
      ok = (await repo.deleteDoseLog(id)).isSuccess;
      // By the prescription already loaded, not by the deleted dose's id.
      if (ok) await _diminishFor(_ref, prescription!, reverse: true);
    } else {
      ok = (await repo.markDosePending(id)).isSuccess;
      if (ok) await _autoDiminish(_ref, id, reverse: true);
    }
    await _refresh();
    return ok;
  }

  Future<bool> skip(String id) async {
    final repo = _ref.read(doseLogRepositoryProvider);
    final result = await repo.markDoseSkipped(id);
    await _refresh();
    return result.isSuccess;
  }

  Future<bool> markMissed(String id) async {
    final repo = _ref.read(doseLogRepositoryProvider);
    final result = await repo.markDoseMissed(id);
    await _refresh();
    return result.isSuccess;
  }

  /// Undo a skip: mark pending again, without touching stock.
  Future<bool> undoSkip(String id) async {
    final repo = _ref.read(doseLogRepositoryProvider);
    final result = await repo.markDosePending(id);
    await _refresh();
    return result.isSuccess;
  }

  /// Take each dose in turn; returns the ids actually taken (ids that
  /// aren't currently pending — e.g. already taken — are skipped and not
  /// included).
  Future<List<String>> takeAllDue(List<String> ids) async {
    final repo = _ref.read(doseLogRepositoryProvider);
    final taken = <String>[];
    for (final id in ids) {
      final doseResult = await repo.getDoseLogById(id);
      final dose = doseResult.dataOrNull;
      if (dose == null || dose.status != DoseStatus.pending) continue;
      if (await _take(id)) taken.add(id);
    }
    // One refresh/bump/reconcile for the whole batch, not one per dose.
    await _refresh();
    return taken;
  }

  /// Records one dose of an as-needed prescription, taken right now.
  ///
  /// An 'as_needed' prescription generates no doses, so there is nothing to
  /// tick off: this inserts the dose that just happened, with
  /// `scheduledTime == takenTime ==` [nowProvider], and then runs the same
  /// auto-diminish and refresh a tapped dose does. Returns the new dose's
  /// id, or null when the write failed (and then stock is left alone).
  Future<String?> logAsNeededDose(String prescriptionId) async {
    final now = _ref.read(nowProvider)();
    final dose = DoseLog(
      id: const Uuid().v4(),
      prescriptionId: prescriptionId,
      scheduledTime: now,
      takenTime: now,
      status: DoseStatus.taken,
      createdAt: now,
      updatedAt: now,
    );
    final repo = _ref.read(doseLogRepositoryProvider);
    final result = await repo.addDoseLog(dose);
    if (result.isSuccess) await _autoDiminish(_ref, dose.id);
    await _refresh();
    return result.isSuccess ? dose.id : null;
  }

  Future<void> _refresh() async {
    await _ref.read(todaysDoseLogsProvider.notifier).refresh(reconcile: false);
    _ref.read(doseDataVersionProvider.notifier).bump();
    unawaited(_ref.read(reminderSchedulerProvider).reconcile());
    // A taken dose can empty a pack (auto-diminish), which changes what the
    // stock alerts should say.
    unawaited(_ref.read(stockReminderSchedulerProvider).reconcile());
  }
}

/// If the prescription has autoDiminish enabled, decrease medication stock.
Future<void> _autoDiminish(
  Ref ref,
  String doseLogId, {
  bool reverse = false,
}) async {
  try {
    final repo = ref.read(doseLogRepositoryProvider);
    final doseResult = await repo.getDoseLogById(doseLogId);
    final dose = doseResult.dataOrNull;
    if (dose == null) return;

    final prescRepo = ref.read(prescriptionRepositoryProvider);
    final prescResult = await prescRepo.getPrescriptionById(
      dose.prescriptionId,
    );
    final prescription = prescResult.dataOrNull;
    if (prescription == null) return;
    await _diminishFor(ref, prescription, reverse: reverse);
  } catch (_) {
    // Non-critical: don't fail the dose marking
  }
}

/// Moves [prescription]'s medication stock by one dose, if it auto-diminishes.
Future<void> _diminishFor(
  Ref ref,
  Prescription prescription, {
  bool reverse = false,
}) async {
  try {
    if (!prescription.autoDiminish) return;

    final medication =
        (await ref
                .read(medicationRepositoryProvider)
                .getMedicationById(prescription.medicationId))
            .dataOrNull;
    final amount = prescription.unitsPerDose(
      medicationUnit: medication?.quantityUnit,
    );
    if (amount <= 0) return;

    final medNotifier = ref.read(medicationListProvider.notifier);
    await medNotifier.updateQuantity(
      prescription.medicationId,
      reverse ? amount : -amount,
    );
  } catch (_) {
    // Non-critical: don't fail the dose marking
  }
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

  /// Generates the doses any active prescription lacks (see
  /// [DoseScheduleService.ensureScheduled]) and, if it did, refetches.
  /// Runs in the background to keep app startup snappy.
  Future<void> _ensureDoseLogsExistInBackground() async {
    try {
      final regenerated = await ref
          .read(doseScheduleServiceProvider)
          .ensureScheduled();
      if (regenerated == 0 || !ref.mounted) return;
      state = await AsyncValue.guard(_fetchTodaysDoses);
      unawaited(ref.read(reminderSchedulerProvider).reconcile());
    } catch (e) {
      debugPrint('⚠ _ensureDoseLogsExist error: $e');
    }
  }

  /// Refetch today's doses. Reconciling reminders is normally the caller's
  /// job (see [DoseActions], which owns a single reconcile per mutation) —
  /// pass [reconcile] false when the caller will reconcile itself.
  Future<void> refresh({bool reconcile = true}) async {
    state = await AsyncValue.guard(_fetchTodaysDoses);
    if (reconcile) {
      unawaited(ref.read(reminderSchedulerProvider).reconcile());
    }
  }
}

/// The day currently selected on the Doses tab (midnight-normalized).
/// Defaults to today (per [nowProvider]).
final selectedDoseDayProvider = NotifierProvider<SelectedDoseDay, DateTime>(
  SelectedDoseDay.new,
);

class SelectedDoseDay extends Notifier<DateTime> {
  @override
  DateTime build() => dayKey(ref.read(nowProvider)());

  void set(DateTime day) => state = dayKey(day);

  /// Shifts the selected day by [days], using calendar (not 24h-duration)
  /// arithmetic so it stays correct across DST transitions, clamped to
  /// today ± 3 days (the range shown by [_DateStrip]).
  void shift(int days) {
    final today = dayKey(ref.read(nowProvider)());
    final shifted = dayKey(DateTime(state.year, state.month, state.day + days));
    final min = dayKey(DateTime(today.year, today.month, today.day - 3));
    final max = dayKey(DateTime(today.year, today.month, today.day + 3));
    if (shifted.isBefore(min)) {
      state = min;
    } else if (shifted.isAfter(max)) {
      state = max;
    } else {
      state = shifted;
    }
  }
}

/// Every dose logged under a treatment, oldest first: the episode's intake
/// record. Re-fetches when [doseDataVersionProvider] changes, so logging,
/// taking or undoing a dose updates the counts without a manual invalidate.
final doseLogsByTreatmentProvider =
    FutureProvider.family<List<DoseLog>, String>((ref, treatmentId) async {
      ref.watch(doseDataVersionProvider);
      final repo = ref.watch(doseLogRepositoryProvider);
      final result = await repo.getDoseLogsByTreatment(treatmentId);
      return result.when(
        success: (data) => data,
        failure: (msg) => throw Exception(msg),
      );
    });

/// Provider for dose logs by prescription.
final doseLogsByPrescriptionProvider =
    FutureProvider.family<List<DoseLog>, String>((ref, prescriptionId) async {
      final repo = ref.watch(doseLogRepositoryProvider);
      final result = await repo.getTodaysDoseLogs();
      return result.when(
        success: (data) =>
            data.where((d) => d.prescriptionId == prescriptionId).toList(),
        failure: (msg) => throw Exception(msg),
      );
    });
