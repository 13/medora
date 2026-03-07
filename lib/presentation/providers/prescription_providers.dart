/// Medora - Prescription Providers
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:medora/domain/entities/prescription.dart';
import 'package:medora/presentation/providers/providers.dart';

/// Provider for prescriptions by treatment ID.
final prescriptionsByTreatmentProvider =
    FutureProvider.family<List<Prescription>, String>(
  (ref, treatmentId) async {
    final repo = ref.watch(prescriptionRepositoryProvider);
    final result = await repo.getPrescriptionsByTreatment(treatmentId);
    return result.when(
      success: (data) => data,
      failure: (msg) => throw Exception(msg),
    );
  },
);

/// Provider for all active prescriptions.
final activePrescriptionsProvider =
    FutureProvider<List<Prescription>>((ref) async {
  final repo = ref.watch(prescriptionRepositoryProvider);
  final result = await repo.getActivePrescriptions();
  return result.when(
    success: (data) => data,
    failure: (msg) => throw Exception(msg),
  );
});

