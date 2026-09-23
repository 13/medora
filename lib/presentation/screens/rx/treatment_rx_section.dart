/// Medora - Treatment detail's prescriptions (rx) section, its own widget
/// so `TreatmentDetailScreen` doesn't carry every section inline.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:medora/domain/entities/treatment.dart';
import 'package:medora/domain/repositories/rx_repository.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/presentation/providers/now_provider.dart';
import 'package:medora/presentation/providers/rx_providers.dart';
import 'package:medora/presentation/router/app_router.dart';
import 'package:medora/presentation/screens/rx/rx_labels.dart';
import 'package:medora/presentation/widgets/async_value_view.dart';

class TreatmentRxSection extends ConsumerWidget {
  const TreatmentRxSection({super.key, required this.treatment});

  final Treatment treatment;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final now = ref.watch(nowProvider)();
    final persons = ref.watch(personsProvider).value ?? const [];
    final rxAsync = ref.watch(rxForTreatmentProvider(treatment.id));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Prescriptions (rx) section header, same Wrap pattern as the
        // prescriptions-document section in treatment_detail_screen.dart: a
        // Row would overflow at a 1.6x text scale in German.
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              l10n.rxSectionTitle,
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
            TextButton.icon(
              onPressed: () {
                final matching = persons
                    .where((p) => treatment.patientTags.any(p.matchesTag))
                    .toList();
                final personId = matching.length == 1
                    ? matching.single.id
                    : null;
                var location = '${AppRoutes.addRx}?treatmentId=${treatment.id}';
                if (personId != null) {
                  location = '$location&personId=$personId';
                }
                context.push(location);
              },
              icon: const Icon(Icons.add, size: 18),
              label: Text(l10n.add),
            ),
          ],
        ),
        const SizedBox(height: 8),

        AsyncValueView<List<RxWithDispensings>>(
          value: rxAsync,
          compact: true,
          onRetry: () async =>
              ref.invalidate(rxForTreatmentProvider(treatment.id)),
          emptyWhen: (rx) => rx.isEmpty,
          empty: Card(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(l10n.rxNoneYet),
            ),
          ),
          data: (entries) {
            return Column(
              children: entries.map((entry) {
                final rx = entry.rx;
                final title = rx.items.isEmpty
                    ? rxKindShort(l10n, rx.kind)
                    : rx.items.map((i) => i.description).join(', ');
                return Card(
                  child: ListTile(
                    title: Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      [
                        rxKindShort(l10n, rx.kind),
                        rxStatusLabel(l10n, entry.statusAt(now)),
                      ].join(' · '),
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => context.push(
                      AppRoutes.rxDetail.replaceFirst(':id', rx.id),
                    ),
                  ),
                );
              }).toList(),
            );
          },
        ),
      ],
    );
  }
}
