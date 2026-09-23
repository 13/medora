/// Medora - The persons prescriptions are written for.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:medora/domain/entities/person.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/presentation/providers/providers.dart';
import 'package:medora/presentation/providers/rx_providers.dart';
import 'package:medora/presentation/router/app_router.dart';
import 'package:medora/presentation/widgets/async_value_view.dart';
import 'package:medora/presentation/widgets/shared_widgets.dart';

class PersonListScreen extends ConsumerWidget {
  const PersonListScreen({super.key});

  Future<void> _delete(BuildContext context, WidgetRef ref, Person p) async {
    final l10n = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.personDelete),
        content: Text(l10n.personDeleteConfirm(p.name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.delete),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(personRepositoryProvider).deletePerson(p.id);
    ref.invalidate(personsProvider);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.persons)),
      body: AsyncValueView<List<Person>>(
        value: ref.watch(personsProvider),
        onRetry: () async => ref.invalidate(personsProvider),
        emptyWhen: (p) => p.isEmpty,
        empty: EmptyStateWidget(
          icon: Icons.badge_outlined,
          title: l10n.personNoneYet,
          subtitle: l10n.personsHint,
          actionLabel: l10n.personNew,
          onAction: () => context.push(AppRoutes.addPerson),
        ),
        data: (persons) => ListView(
          children: [
            for (final p in persons)
              ListTile(
                leading: const Icon(Icons.person_outline),
                title: Text(p.name),
                subtitle: p.taxCode == null && p.exemptions.isEmpty
                    ? null
                    : Text(
                        [
                          ?p.taxCode,
                          if (p.exemptions.isNotEmpty) p.exemptions.join(', '),
                        ].join(' · '),
                      ),
                onTap: () => context.push(
                  AppRoutes.editPerson.replaceFirst(':id', p.id),
                ),
                trailing: IconButton(
                  icon: const Icon(Icons.delete_outline),
                  tooltip: l10n.personDelete,
                  onPressed: () => _delete(context, ref, p),
                ),
              ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        tooltip: l10n.personNew,
        onPressed: () => context.push(AppRoutes.addPerson),
        child: const Icon(Icons.add),
      ),
    );
  }
}
