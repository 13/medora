/// Medora - The filter the Medications tab opens with.
///
/// Its own file, so the dashboard can ask for a filtered tab without
/// pulling in the list screen or the provider wiring.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Filter options for the medication list.
enum MedicationFilter { all, lowStock, needsAttention, archived }

/// A filter the next Medications tab should open with, or null for the
/// default ([MedicationFilter.all]).
///
/// The dashboard sets it right before it switches to the tab, so its
/// low-stock count and the list it opens agree. The tab is rebuilt on every
/// switch; it takes the request once, when it is built, and clears it, so a
/// later visit from the bottom bar opens unfiltered, as it always has.
final medicationListFilterProvider =
    NotifierProvider<MedicationListFilterNotifier, MedicationFilter?>(
      MedicationListFilterNotifier.new,
    );

class MedicationListFilterNotifier extends Notifier<MedicationFilter?> {
  @override
  MedicationFilter? build() => null;

  /// Asks the next Medications tab to open with [filter].
  void request(MedicationFilter filter) => state = filter;

  /// Called by the tab once it has taken the request.
  void clear() => state = null;
}
