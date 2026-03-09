/// Medora - Home / Dashboard Screen
library;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:medora/core/constants.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:medora/core/extensions.dart';
import 'package:medora/core/theme.dart';
import 'package:medora/domain/entities/dose_log.dart';
import 'package:medora/domain/entities/treatment.dart';
import 'package:medora/presentation/providers/auth_providers.dart';
import 'package:medora/presentation/providers/dose_providers.dart';
import 'package:medora/presentation/providers/medication_providers.dart';
import 'package:medora/presentation/providers/prescription_providers.dart';
import 'package:medora/presentation/providers/treatment_providers.dart';
import 'package:medora/presentation/router/app_router.dart';
import 'package:medora/presentation/screens/main_shell_screen.dart';
import 'package:medora/presentation/widgets/sync_icon_button.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Dashboard'),
        actions: [
          IconButton(
            icon: const Icon(Icons.qr_code_scanner),
            tooltip: l10n.scanBarcodeTooltip,
            onPressed: () => context.push(AppRoutes.scanner),
          ),
          const SyncIconButton(),
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () => context.push(AppRoutes.settings),
          ),
          if (kIsWeb)
            IconButton(
              icon: const Icon(Icons.logout),
              tooltip: l10n.signOut,
              onPressed: () => ref.read(authControllerProvider.notifier).signOut(),
            ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(expiringSoonProvider);
          ref.invalidate(lowStockProvider);
          ref.invalidate(activeTreatmentsProvider);
          ref.invalidate(todaysDoseLogsProvider);
        },
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // Today's Doses Summary (on top)
            _TodaysDosesSummaryCard(),
            const SizedBox(height: 16),

            // Active Treatments
            _SectionHeader(
              title: l10n.activeTreatments,
              onSeeAll: () => MainShellScope.of(context)?.switchTab(2),
            ),
            _ActiveTreatmentsCard(),
            const SizedBox(height: 16),

            // Expiring Soon
            _SectionHeader(
              title: l10n.expiringSoon,
              onSeeAll: () => MainShellScope.of(context)?.switchTab(1),
            ),
            _ExpiringSoonCard(),
            const SizedBox(height: 16),

            // Low Stock
            _SectionHeader(
              title: l10n.lowStock,
              onSeeAll: () => MainShellScope.of(context)?.switchTab(1),
            ),
            _LowStockCard(),
          ],
        ),
      ),
    );
  }
}

class _TodaysDosesSummaryCard extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final dosesAsync = ref.watch(todaysDoseLogsProvider);

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [AppTheme.primaryColor, AppTheme.primaryDark],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: InkWell(
          onTap: () {
            // Switch to Doses tab (index 3) without pushing a new route
            MainShellScope.of(context)?.switchTab(3);
          },
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: dosesAsync.when(
              data: (doses) {
                final total = doses.length;
                final taken =
                    doses.where((d) => d.status == DoseStatus.taken).length;
                final pending =
                    doses.where((d) => d.status == DoseStatus.pending).length;

                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.todaysDoses,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 12),
                    if (total == 0)
                      Text(
                        l10n.noDosesScheduled,
                        style: const TextStyle(color: Colors.white70),
                      )
                    else ...[
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: LinearProgressIndicator(
                          value: total > 0 ? taken / total : 0,
                          backgroundColor: Colors.white24,
                          valueColor:
                              const AlwaysStoppedAnimation<Color>(Colors.white),
                          minHeight: 8,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        l10n.dosesProgress(taken, total, pending),
                        style: const TextStyle(color: Colors.white70),
                      ),
                    ],
                  ],
                );
              },
              loading: () => const SizedBox(
                height: 60,
                child: Center(
                  child: CircularProgressIndicator(color: Colors.white),
                ),
              ),
              error: (error, stack) => Text(
                l10n.unableToLoadDoses,
                style: const TextStyle(color: Colors.white70),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, this.onSeeAll});

  final String title;
  final VoidCallback? onSeeAll;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          title,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
        ),
        if (onSeeAll != null)
          TextButton(
            onPressed: onSeeAll,
            child: Text(l10n.seeAll),
          ),
      ],
    );
  }
}

class _ExpiringSoonCard extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final expiringAsync = ref.watch(expiringSoonProvider);

    return expiringAsync.when(
      data: (meds) {
        if (meds.isEmpty) {
          return Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Icon(Icons.check_circle, color: AppTheme.inStockColor),
                  const SizedBox(width: 12),
                  Text(l10n.allMedicationsWithinDate),
                ],
              ),
            ),
          );
        }
        return Card(
          child: Column(
            children: meds.take(3).map((med) {
              final days = med.expiryDate?.difference(DateTime.now()).inDays;
              return ListTile(
                leading: const Icon(
                  Icons.warning_amber_rounded,
                  color: AppTheme.expiringSoonColor,
                ),
                title: Text(med.name),
                subtitle: Row(
                  children: [
                    if (med.expiryDate != null)
                      Text(med.expiryDate!.formatted, style: const TextStyle(fontSize: 12)),
                    if (med.patientTags.isNotEmpty) ...[
                      const SizedBox(width: 8),
                      const Icon(Icons.person, size: 14, color: Colors.grey),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          med.patientTags.join(', '),
                          style: const TextStyle(fontSize: 12),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ],
                ),
                trailing: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      '${days ?? 0}',
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                        color: AppTheme.expiringSoonColor,
                      ),
                    ),
                    Text(
                      l10n.daysLabel,
                      style: const TextStyle(fontSize: 10, color: Colors.grey),
                    ),
                  ],
                ),
                dense: true,
                onTap: () => context.push('/medications/${med.id}'),
              );
            }).toList(),
          ),
        );
      },
      loading: () => const Card(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Center(child: CircularProgressIndicator()),
        ),
      ),
      error: (error, stack) => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text('Error: $error'),
        ),
      ),
    );
  }
}

class _LowStockCard extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final lowStockAsync = ref.watch(lowStockProvider);

    return lowStockAsync.when(
      data: (meds) {
        if (meds.isEmpty) {
          return Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Icon(Icons.check_circle, color: AppTheme.inStockColor),
                  const SizedBox(width: 12),
                  Text(l10n.allMedicationsWellStocked),
                ],
              ),
            ),
          );
        }
        return Card(
          child: Column(
            children: meds.take(3).map((med) {
              return ListTile(
                leading: const Icon(
                  Icons.inventory_2_outlined,
                  color: AppTheme.lowStockColor,
                ),
                title: Text(med.name),
                subtitle: Row(
                  children: [
                    if (med.category != null)
                      Text(AppConstants.categoryLabel(l10n, med.category!), style: const TextStyle(fontSize: 12)),
                    if (med.patientTags.isNotEmpty) ...[
                      const SizedBox(width: 8),
                      const Icon(Icons.person, size: 14, color: Colors.grey),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          med.patientTags.join(', '),
                          style: const TextStyle(fontSize: 12),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ],
                ),
                trailing: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      '${med.quantity}',
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                        color: AppTheme.lowStockColor,
                      ),
                    ),
                    Text(
                      l10n.leftLabel,
                      style: const TextStyle(fontSize: 10, color: Colors.grey),
                    ),
                  ],
                ),
                dense: true,
                onTap: () => context.push('/medications/${med.id}'),
              );
            }).toList(),
          ),
        );
      },
      loading: () => const Card(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Center(child: CircularProgressIndicator()),
        ),
      ),
      error: (error, stack) => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text('Error: $error'),
        ),
      ),
    );
  }
}

class _ActiveTreatmentsCard extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final treatmentsAsync = ref.watch(activeTreatmentsProvider);

    return treatmentsAsync.when(
      data: (treatments) {
        if (treatments.isEmpty) {
          return Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Icon(Icons.check_circle, color: AppTheme.inStockColor),
                  const SizedBox(width: 12),
                  Text(l10n.noActiveTreatments),
                ],
              ),
            ),
          );
        }
        return Card(
          child: Column(
            children: treatments.take(3).map((t) {
              return _ActiveTreatmentTile(treatment: t);
            }).toList(),
          ),
        );
      },
      loading: () => const Card(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Center(child: CircularProgressIndicator()),
        ),
      ),
      error: (error, stack) => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text('Error: $error'),
        ),
      ),
    );
  }
}

class _ActiveTreatmentTile extends ConsumerWidget {
  const _ActiveTreatmentTile({required this.treatment});
  final Treatment treatment;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final prescriptionsAsync = ref.watch(prescriptionsByTreatmentProvider(treatment.id));

    return ListTile(
      leading: const Icon(Icons.healing, color: AppTheme.primaryColor),
      title: Text(treatment.name, style: const TextStyle(fontWeight: FontWeight.bold)),
      subtitle: Row(
        children: [
          Text(l10n.startedOn(treatment.startDate.formatted), style: const TextStyle(fontSize: 12)),
          if (treatment.patientName != null) ...[
            const SizedBox(width: 8),
            const Icon(Icons.person, size: 14, color: Colors.grey),
            const SizedBox(width: 4),
            Text(
              treatment.patientName!,
              style: const TextStyle(fontSize: 12),
            ),
          ],
        ],
      ),
      trailing: prescriptionsAsync.when(
        data: (prescriptions) => Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              '${prescriptions.length}',
              style: const TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 16,
                color: AppTheme.primaryColor,
              ),
            ),
            Text(
              l10n.prescriptions,
              style: const TextStyle(fontSize: 10, color: Colors.grey),
            ),
          ],
        ),
        loading: () => const SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        error: (error, stack) => const Icon(Icons.error_outline, size: 16),
      ),
      dense: true,
      onTap: () => context.push('/treatments/${treatment.id}'),
    );
  }
}
