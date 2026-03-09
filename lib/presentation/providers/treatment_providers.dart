/// Medora - Treatment Providers
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:medora/domain/entities/treatment.dart';
import 'package:medora/presentation/providers/providers.dart';

/// Provider for the full treatment list.
final treatmentListProvider =
    AsyncNotifierProvider<TreatmentListNotifier, List<Treatment>>(
  TreatmentListNotifier.new,
);

class TreatmentListNotifier extends AsyncNotifier<List<Treatment>> {
  @override
  Future<List<Treatment>> build() async {
    return _fetchTreatments();
  }

  Future<List<Treatment>> _fetchTreatments() async {
    final repo = ref.read(treatmentRepositoryProvider);
    final result = await repo.getTreatments();
    return result.when(
      success: (data) => data,
      failure: (msg) => throw Exception(msg),
    );
  }

  Future<void> refresh() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(_fetchTreatments);
    // After refreshing the full list, invalidate dependent providers
    ref.invalidate(activeTreatmentsProvider);
  }

  Future<void> addTreatment(Treatment treatment) async {
    final repo = ref.read(treatmentRepositoryProvider);
    final result = await repo.addTreatment(treatment);
    result.when(
      success: (_) => refresh(),
      failure: (msg) => throw Exception(msg),
    );
  }

  Future<void> updateTreatment(Treatment treatment) async {
    final repo = ref.read(treatmentRepositoryProvider);
    final result = await repo.updateTreatment(treatment);
    result.when(
      success: (_) => refresh(),
      failure: (msg) => throw Exception(msg),
    );
  }

  Future<void> deleteTreatment(String id) async {
    final repo = ref.read(treatmentRepositoryProvider);
    final result = await repo.deleteTreatment(id);
    result.when(
      success: (_) => refresh(),
      failure: (msg) => throw Exception(msg),
    );
  }

  Future<void> endTreatment(String id) async {
    final repo = ref.read(treatmentRepositoryProvider);
    final result = await repo.endTreatment(id);
    result.when(
      success: (_) => refresh(),
      failure: (msg) => throw Exception(msg),
    );
  }
}

/// Provider for active treatments only.
final activeTreatmentsProvider = FutureProvider<List<Treatment>>((ref) async {
  // Watch the full treatment list
  final allTreatments = await ref.watch(treatmentListProvider.future);
  // Filter for active treatments
  return allTreatments.where((t) => t.isActive).toList();
});
