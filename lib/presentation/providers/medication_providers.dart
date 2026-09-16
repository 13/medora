/// Medora - Medication Providers
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:medora/domain/entities/medication.dart';
import 'package:medora/presentation/providers/dose_providers.dart';
import 'package:medora/presentation/providers/now_provider.dart';
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
    state = await AsyncValue.guard(_fetchMedications);
  }

  /// Re-plans the stock and expiry notifications after a mutation.
  ///
  /// They are planned from the cabinet itself, so every write here changes
  /// them: without this, taking the last dose books no low-stock alert until
  /// the next cold start, and a deleted medication keeps announcing itself
  /// for the rest of the session.
  void _reconcileStockAlerts() =>
      unawaited(ref.read(stockReminderSchedulerProvider).reconcile());

  Future<void> addMedication(Medication medication) async {
    final repo = ref.read(medicationRepositoryProvider);
    final result = await repo.addMedication(medication);
    await result.when(
      success: (_) async {
        await refresh();
        _reconcileStockAlerts();
      },
      failure: (msg) => throw Exception(msg),
    );
  }

  Future<void> updateMedication(Medication medication) async {
    final repo = ref.read(medicationRepositoryProvider);
    final result = await repo.updateMedication(medication);
    await result.when(
      success: (_) async {
        await refresh();
        _reconcileStockAlerts();
      },
      failure: (msg) => throw Exception(msg),
    );
  }

  Future<void> deleteMedication(String id) async {
    final repo = ref.read(medicationRepositoryProvider);
    final result = await repo.deleteMedication(id);
    await result.when(
      success: (_) async {
        await refresh();
        _reconcileStockAlerts();
      },
      failure: (msg) => throw Exception(msg),
    );
  }

  Future<void> updateQuantity(String id, int delta) async {
    final repo = ref.read(medicationRepositoryProvider);
    final result = await repo.updateQuantity(id, delta);
    await result.when(
      success: (_) async {
        await refresh();
        // Also refresh today's doses as they might show stock warnings
        ref.invalidateDoseData();
        _reconcileStockAlerts();
      },
      failure: (msg) => throw Exception(msg),
    );
  }

  Future<void> archiveMedication(String id) async {
    final repo = ref.read(medicationRepositoryProvider);
    final result = await repo.archiveMedication(id);
    await result.when(
      success: (_) async {
        await refresh();
        ref.invalidate(archivedMedicationsProvider);
        // Dose lists hide pending doses of archived medications, so they
        // have to be refetched too.
        ref.invalidateDoseData();
        _reconcileStockAlerts();
      },
      failure: (msg) => throw Exception(msg),
    );
  }

  Future<void> unarchiveMedication(String id) async {
    final repo = ref.read(medicationRepositoryProvider);
    final result = await repo.unarchiveMedication(id);
    await result.when(
      success: (_) async {
        await refresh();
        ref.invalidate(archivedMedicationsProvider);
        ref.invalidateDoseData();
        _reconcileStockAlerts();
      },
      failure: (msg) => throw Exception(msg),
    );
  }
}

/// Provider for archived medications.
final archivedMedicationsProvider = FutureProvider<List<Medication>>((
  ref,
) async {
  final repo = ref.watch(medicationRepositoryProvider);
  final result = await repo.getArchivedMedications();
  return result.when(
    success: (data) => data,
    failure: (msg) => throw Exception(msg),
  );
});

/// Provider for medications expiring soon.
final expiringSoonProvider = FutureProvider<List<Medication>>((ref) async {
  // Watch the medication list to trigger updates
  final meds = await ref.watch(medicationListProvider.future);

  final now = ref.watch(nowProvider)();

  return meds
      .where(
        (m) => !m.isArchived && m.isExpiringSoon(now: now) && !m.expiredAt(now),
      )
      .toList();
});

/// Provider for low stock medications.
final lowStockProvider = FutureProvider<List<Medication>>((ref) async {
  // Watch the medication list to trigger updates
  final meds = await ref.watch(medicationListProvider.future);

  return meds
      .where((m) => !m.isArchived && m.quantity <= m.minimumStockLevel)
      .toList();
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
