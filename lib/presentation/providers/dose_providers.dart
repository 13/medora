/// Medora - Dose Log Providers
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:medora/domain/entities/dose_log.dart';
import 'package:medora/presentation/providers/medication_providers.dart';
import 'package:medora/presentation/providers/providers.dart';

/// Provider for today's dose logs.
final todaysDoseLogsProvider =
    AsyncNotifierProvider<TodaysDoseLogsNotifier, List<DoseLog>>(
  TodaysDoseLogsNotifier.new,
);

class TodaysDoseLogsNotifier extends AsyncNotifier<List<DoseLog>> {
  @override
  Future<List<DoseLog>> build() async {
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

  Future<void> refresh() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(_fetchTodaysDoses);
  }

  Future<void> markTaken(String id) async {
    final repo = ref.read(doseLogRepositoryProvider);
    await repo.markDoseTaken(id);

    // Auto-diminish: find the dose, look up its prescription
    await _autoDiminish(id);

    await refresh();
  }

  Future<void> markSkipped(String id) async {
    final repo = ref.read(doseLogRepositoryProvider);
    await repo.markDoseSkipped(id);
    await refresh();
  }

  Future<void> markMissed(String id) async {
    final repo = ref.read(doseLogRepositoryProvider);
    await repo.markDoseMissed(id);
    await refresh();
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

