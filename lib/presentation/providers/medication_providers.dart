/// Medora - Medication Providers
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:medora/domain/entities/medication.dart';
import 'package:medora/presentation/providers/providers.dart';

/// Provider for the full medication list.
final medicationListProvider =
    AsyncNotifierProvider<MedicationListNotifier, List<Medication>>(
  MedicationListNotifier.new,
);

class MedicationListNotifier extends AsyncNotifier<List<Medication>> {
  @override
  Future<List<Medication>> build() async {
    return _fetchMedications();
  }

  Future<List<Medication>> _fetchMedications() async {
    final repo = ref.read(medicationRepositoryProvider);
    final result = await repo.getMedications();
    return result.when(
      success: (data) => data,
      failure: (msg) => throw Exception(msg),
    );
  }

  Future<void> refresh() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(_fetchMedications);
  }

  Future<void> addMedication(Medication medication) async {
    final repo = ref.read(medicationRepositoryProvider);
    final result = await repo.addMedication(medication);
    result.when(
      success: (_) => refresh(),
      failure: (msg) => throw Exception(msg),
    );
  }

  Future<void> updateMedication(Medication medication) async {
    final repo = ref.read(medicationRepositoryProvider);
    final result = await repo.updateMedication(medication);
    result.when(
      success: (_) => refresh(),
      failure: (msg) => throw Exception(msg),
    );
  }

  Future<void> deleteMedication(String id) async {
    final repo = ref.read(medicationRepositoryProvider);
    final result = await repo.deleteMedication(id);
    result.when(
      success: (_) => refresh(),
      failure: (msg) => throw Exception(msg),
    );
  }

  Future<void> updateQuantity(String id, int delta) async {
    final repo = ref.read(medicationRepositoryProvider);
    final result = await repo.updateQuantity(id, delta);
    result.when(
      success: (_) => refresh(),
      failure: (msg) => throw Exception(msg),
    );
  }

  Future<void> archiveMedication(String id) async {
    final repo = ref.read(medicationRepositoryProvider);
    final result = await repo.archiveMedication(id);
    result.when(
      success: (_) {
        refresh();
        ref.invalidate(archivedMedicationsProvider);
      },
      failure: (msg) => throw Exception(msg),
    );
  }

  Future<void> unarchiveMedication(String id) async {
    final repo = ref.read(medicationRepositoryProvider);
    final result = await repo.unarchiveMedication(id);
    result.when(
      success: (_) {
        refresh();
        ref.invalidate(archivedMedicationsProvider);
      },
      failure: (msg) => throw Exception(msg),
    );
  }
}

/// Provider for archived medications.
final archivedMedicationsProvider =
    FutureProvider<List<Medication>>((ref) async {
  final repo = ref.watch(medicationRepositoryProvider);
  final result = await repo.getArchivedMedications();
  return result.when(
    success: (data) => data,
    failure: (msg) => throw Exception(msg),
  );
});

/// Provider for medications expiring soon.
final expiringSoonProvider = FutureProvider<List<Medication>>((ref) async {
  final repo = ref.watch(medicationRepositoryProvider);
  final result = await repo.getExpiringSoon(days: 30);
  return result.when(
    success: (data) => data,
    failure: (msg) => throw Exception(msg),
  );
});

/// Provider for low stock medications.
final lowStockProvider = FutureProvider<List<Medication>>((ref) async {
  final repo = ref.watch(medicationRepositoryProvider);
  final result = await repo.getLowStock();
  return result.when(
    success: (data) => data,
    failure: (msg) => throw Exception(msg),
  );
});

/// Provider for medication search query.
final medicationSearchQueryProvider =
    NotifierProvider<MedicationSearchQueryNotifier, String>(
  MedicationSearchQueryNotifier.new,
);

class MedicationSearchQueryNotifier extends Notifier<String> {
  @override
  String build() => '';

  void set(String value) {
    state = value;
  }
}

final medicationSearchProvider = FutureProvider<List<Medication>>((ref) async {
  final query = ref.watch(medicationSearchQueryProvider);
  if (query.isEmpty) {
    return ref.watch(medicationListProvider.future);
  }
  final repo = ref.watch(medicationRepositoryProvider);
  final result = await repo.searchMedications(query);
  return result.when(
    success: (data) => data,
    failure: (msg) => throw Exception(msg),
  );
});

