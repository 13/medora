/// Medora - Expired & Expiring Medications Screen
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:medora/domain/entities/medication.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/presentation/providers/medication_providers.dart';
import 'package:medora/presentation/providers/now_provider.dart';
import 'package:medora/presentation/widgets/async_value_view.dart';
import 'package:medora/presentation/widgets/medication_expiry_tile.dart';
import 'package:medora/presentation/widgets/shared_widgets.dart';

/// The whole of what the dashboard's expiry card shows three of.
///
/// It reads `expiringSoonProvider`, the card's own source, so the set and
/// the order are the card's by construction - expired first, longest expired
/// at the top - instead of the alphabetical, unfiltered cabinet the tab
/// switch used to land on.
class ExpiringMedicationsScreen extends ConsumerWidget {
  const ExpiringMedicationsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final expiringAsync = ref.watch(expiringSoonProvider);
    final now = ref.watch(nowProvider)();

    return Scaffold(
      appBar: AppBar(title: Text(l10n.expiringOrExpired)),
      body: AsyncValueView<List<Medication>>(
        value: expiringAsync,
        // The source list is the only place a cabinet read can fail, so a
        // retry that re-awaited the derived provider alone could not recover.
        onRetry: () async {
          ref.invalidate(medicationListProvider);
          ref.invalidate(expiringSoonProvider);
        },
        emptyWhen: (meds) => meds.isEmpty,
        empty: EmptyStateWidget(
          icon: Icons.check_circle,
          title: l10n.allMedicationsWithinDate,
        ),
        data: (meds) => ListView(
          children: [
            for (final med in meds) MedicationExpiryTile(med: med, now: now),
          ],
        ),
        loading: LoadingWidget(message: l10n.loadingMedications),
      ),
    );
  }
}
