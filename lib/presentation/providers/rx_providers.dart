/// Medora - What the screens show of persons and prescriptions.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:medora/domain/entities/person.dart';
import 'package:medora/domain/repositories/rx_repository.dart';
import 'package:medora/presentation/providers/providers.dart';

final personsProvider = FutureProvider<List<Person>>((ref) async {
  final result = await ref.watch(personRepositoryProvider).getPersons();
  return result.when(success: (p) => p, failure: (m) => throw Exception(m));
});

final rxListProvider = FutureProvider<List<RxWithDispensings>>((ref) async {
  final result = await ref.watch(rxRepositoryProvider).getAll();
  return result.when(success: (r) => r, failure: (m) => throw Exception(m));
});

final rxByIdProvider = FutureProvider.family<RxWithDispensings, String>((
  ref,
  id,
) async {
  final result = await ref.watch(rxRepositoryProvider).getById(id);
  return result.when(success: (r) => r, failure: (m) => throw Exception(m));
});

final rxForTreatmentProvider =
    FutureProvider.family<List<RxWithDispensings>, String>((ref, id) async {
      final result = await ref.watch(rxRepositoryProvider).getForTreatment(id);
      return result.when(success: (r) => r, failure: (m) => throw Exception(m));
    });

/// Refresh everything that shows prescriptions, after a write.
void invalidateRx(WidgetRef ref) {
  ref.invalidate(rxListProvider);
  ref.invalidate(rxByIdProvider);
  ref.invalidate(rxForTreatmentProvider);
}
