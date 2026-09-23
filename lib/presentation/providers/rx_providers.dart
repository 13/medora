/// Medora - What the screens show of persons and prescriptions.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:medora/domain/entities/person.dart';
import 'package:medora/domain/repositories/rx_repository.dart';
import 'package:medora/presentation/providers/attachment_providers.dart';
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

/// Refetches every prescription and person view.
///
/// These providers are not auto-dispose, so after anything that writes
/// underneath them — a sync pull, a wipe, a restore — they keep serving
/// what they first read until they are invalidated. Call this wherever the
/// medication and treatment lists are refreshed for the same reason.
extension RxDataRefresh on Ref {
  void invalidateRxData() {
    invalidate(personsProvider);
    invalidate(rxListProvider);
    invalidate(rxByIdProvider);
    invalidate(rxForTreatmentProvider);
    invalidate(attachmentsForOwnerProvider);
    invalidate(attachmentCountsProvider);
  }
}

/// Widget-side twin of [RxDataRefresh.invalidateRxData].
extension WidgetRxDataRefresh on WidgetRef {
  void invalidateRxData() {
    invalidate(personsProvider);
    invalidate(rxListProvider);
    invalidate(rxByIdProvider);
    invalidate(rxForTreatmentProvider);
    invalidate(attachmentsForOwnerProvider);
    invalidate(attachmentCountsProvider);
  }
}

/// Refresh everything that shows prescriptions, after a write.
///
/// Also re-plans the stock scheduler's prescription-expiry alerts:
/// [StockReminderScheduler] reads `RxRepository.getAll()` itself on every
/// reconcile, but only on launch, resume or a sync pull — a write made here,
/// in this session, would otherwise sit unplanned until one of those next
/// happens.
void invalidateRx(WidgetRef ref) {
  ref.invalidate(rxListProvider);
  ref.invalidate(rxByIdProvider);
  ref.invalidate(rxForTreatmentProvider);
  unawaited(ref.read(stockReminderSchedulerProvider).reconcile());
}

/// Refresh the prescription lists after a delete, but not
/// `rxByIdProvider`: the detail route is still mounted during its pop
/// animation, and invalidating the just-deleted prescription's own
/// provider would refetch it there and flash the error view before the
/// route is gone.
///
/// See [invalidateRx]: a delete changes what the scheduler should plan too.
void invalidateRxLists(WidgetRef ref) {
  ref.invalidate(rxListProvider);
  ref.invalidate(rxForTreatmentProvider);
  unawaited(ref.read(stockReminderSchedulerProvider).reconcile());
}
