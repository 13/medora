/// Medora - Treatment Detail Screen
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:medora/core/extensions.dart';
import 'package:medora/core/platform_capabilities.dart';
import 'package:medora/core/theme_extensions.dart';
import 'package:medora/domain/entities/intake_count.dart';
import 'package:medora/domain/entities/medication.dart';
import 'package:medora/domain/entities/prescription.dart';
import 'package:medora/domain/entities/treatment.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/presentation/formatters.dart';
import 'package:medora/presentation/providers/dose_providers.dart';
import 'package:medora/presentation/providers/medication_providers.dart';
import 'package:medora/presentation/providers/now_provider.dart';
import 'package:medora/presentation/providers/prescription_providers.dart';
import 'package:medora/presentation/providers/settings_providers.dart';
import 'package:medora/presentation/providers/treatment_providers.dart';
import 'package:medora/presentation/screens/treatment/end_treatment_dialog.dart';
import 'package:medora/presentation/screens/treatment/prescription_sheet.dart';
import 'package:medora/presentation/screens/treatment/widgets/prescription_card.dart';
import 'package:medora/presentation/widgets/async_value_view.dart';
import 'package:medora/presentation/widgets/shared_widgets.dart';
import 'package:medora/services/export_service.dart';
import 'package:share_plus/share_plus.dart';

class TreatmentDetailScreen extends ConsumerStatefulWidget {
  const TreatmentDetailScreen({super.key, required this.treatmentId});

  final String treatmentId;

  @override
  ConsumerState<TreatmentDetailScreen> createState() =>
      _TreatmentDetailScreenState();
}

class _TreatmentDetailScreenState extends ConsumerState<TreatmentDetailScreen> {
  /// Prescriptions whose "Log dose" is being saved. A second tap meanwhile
  /// would record a second intake and take the stock down twice.
  final Set<String> _logging = {};

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final now = ref.watch(nowProvider)();
    final treatmentsAsync = ref.watch(treatmentListProvider);
    final prescriptionsAsync = ref.watch(
      prescriptionsByTreatmentProvider(widget.treatmentId),
    );
    // Null while the doses load or when they cannot be read: no intake
    // line then, rather than a "Not taken" that is not known to be true.
    final dosesAsync = ref.watch(
      doseLogsByTreatmentProvider(widget.treatmentId),
    );
    final episodeDoses = dosesAsync.hasError ? null : dosesAsync.value;
    final grace = Duration(minutes: ref.watch(missedGraceMinutesProvider));
    final units = _unitsById(ref.watch(medicationListProvider).value);
    final intakeLabels = EpisodeLabels.fromL10n(l10n, keepDatesTogether: true);
    final canShare = ref.watch(platformCapabilitiesProvider).hasFileShare;
    final treatment = treatmentsAsync.value
        ?.where((t) => t.id == widget.treatmentId)
        .firstOrNull;

    return Scaffold(
      appBar: AppBar(
        title: Text(treatment?.name ?? l10n.treatment),
        actions: treatment == null
            ? null
            : [
                // Edit button
                IconButton(
                  icon: const Icon(Icons.edit),
                  onPressed: () =>
                      context.push('/treatments/${treatment.id}/edit'),
                ),
                PopupMenuButton<String>(
                  onSelected: (value) async {
                    switch (value) {
                      case 'share':
                        await _shareEpisode(treatment);
                      case 'end':
                        await confirmAndEndTreatment(context, ref, treatment);
                      case 'delete':
                        final confirm = await showDialog<bool>(
                          context: context,
                          builder: (ctx) => AlertDialog(
                            title: Text(l10n.deleteTreatment),
                            content: Text(
                              l10n.deleteTreatmentConfirm(treatment.name),
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(ctx, false),
                                child: Text(l10n.cancel),
                              ),
                              TextButton(
                                onPressed: () => Navigator.pop(ctx, true),
                                child: Text(
                                  l10n.delete,
                                  style: TextStyle(color: context.colors.error),
                                ),
                              ),
                            ],
                          ),
                        );
                        if (confirm == true && context.mounted) {
                          // Fire and forget: pop immediately, the list
                          // provider refreshes itself when the write lands.
                          unawaited(
                            ref
                                .read(treatmentListProvider.notifier)
                                .deleteTreatment(treatment.id),
                          );
                          if (context.mounted) context.pop();
                        }
                    }
                  },
                  itemBuilder: (ctx) => [
                    if (canShare)
                      PopupMenuItem(
                        value: 'share',
                        child: ListTile(
                          leading: const Icon(Icons.share),
                          title: Text(l10n.shareEpisode),
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
                    if (treatment.isActive)
                      PopupMenuItem(
                        value: 'end',
                        child: ListTile(
                          leading: Icon(
                            Icons.stop_circle,
                            color: context.medora.warning,
                          ),
                          title: Text(l10n.endTreatment),
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
                    PopupMenuItem(
                      value: 'delete',
                      child: ListTile(
                        leading: Icon(
                          Icons.delete,
                          color: context.colors.error,
                        ),
                        title: Text(l10n.deleteTreatment),
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                  ],
                ),
              ],
      ),
      body: AsyncValueView<List<Treatment>>(
        value: treatmentsAsync,
        data: (treatments) {
          final treatment = treatments
              .where((t) => t.id == widget.treatmentId)
              .firstOrNull;
          if (treatment == null) {
            return EmptyStateWidget(
              icon: Icons.error_outline,
              title: l10n.treatmentNotFound,
            );
          }

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              // Status card
              Card(
                color: treatment.isActive
                    ? context.medora.successContainer
                    : context.colors.surfaceContainerHighest,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            treatment.isActive
                                ? Icons.healing
                                : Icons.healing_outlined,
                            color: treatment.isActive
                                ? context.medora.onSuccessContainer
                                : context.colors.onSurfaceVariant,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            treatment.isActive ? l10n.active : l10n.ended,
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: treatment.isActive
                                  ? context.medora.onSuccessContainer
                                  : context.colors.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      if (treatment.patientTags.isNotEmpty) ...[
                        Text(
                          l10n.treatmentPatientTags,
                          style: TextStyle(
                            color: context.colors.onSurfaceVariant,
                            fontSize: 12,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Wrap(
                          spacing: 6,
                          runSpacing: 4,
                          children: treatment.patientTags.map((t) {
                            return TagChip(
                              label: t,
                              icon: Icons.person,
                              fontSize: 12,
                            );
                          }).toList(),
                        ),
                        const SizedBox(height: 12),
                      ],
                      if (treatment.symptomTags.isNotEmpty) ...[
                        Text(
                          l10n.treatmentSymptomTags,
                          style: TextStyle(
                            color: context.colors.onSurfaceVariant,
                            fontSize: 12,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Wrap(
                          spacing: 6,
                          runSpacing: 4,
                          children: treatment.symptomTags.map((s) {
                            return TagChip(label: s, fontSize: 12);
                          }).toList(),
                        ),
                        const SizedBox(height: 12),
                      ],
                      Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  l10n.startDate,
                                  style: TextStyle(
                                    color: context.colors.onSurfaceVariant,
                                    fontSize: 12,
                                  ),
                                ),
                                Text(treatment.startDate.formatted),
                              ],
                            ),
                          ),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  l10n.endDate,
                                  style: TextStyle(
                                    color: context.colors.onSurfaceVariant,
                                    fontSize: 12,
                                  ),
                                ),
                                Text(
                                  treatment.endDate.formattedOr(l10n.ongoing),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      if (treatment.notes != null &&
                          treatment.notes!.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        Text(
                          l10n.notes,
                          style: TextStyle(
                            color: context.colors.onSurfaceVariant,
                            fontSize: 12,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(treatment.notes!),
                      ],
                    ],
                  ),
                ),
              ),
              if (_SickLeaveBlock.hasContent(treatment)) ...[
                const SizedBox(height: 12),
                _SickLeaveBlock(treatment: treatment, now: now),
              ],
              const SizedBox(height: 20),

              // Prescriptions section. A Wrap, not a Row: in German at a
              // 1.6x text scale "Verschreibungen" and "Hinzufügen" overflow
              // 328 dp by 52 dp, so the button moves to its own line.
              Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    l10n.prescriptions,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (treatment.isActive)
                    TextButton.icon(
                      onPressed: () => showPrescriptionSheet(
                        context,
                        ref,
                        treatmentId: widget.treatmentId,
                      ),
                      icon: const Icon(Icons.add, size: 18),
                      label: Text(l10n.add),
                    ),
                ],
              ),
              const SizedBox(height: 8),

              AsyncValueView<List<Prescription>>(
                value: prescriptionsAsync,
                compact: true,
                onRetry: () async => ref.invalidate(
                  prescriptionsByTreatmentProvider(widget.treatmentId),
                ),
                emptyWhen: (prescriptions) => prescriptions.isEmpty,
                empty: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      children: [
                        Icon(
                          Icons.medication_outlined,
                          size: 48,
                          color: context.colors.outline,
                        ),
                        const SizedBox(height: 8),
                        Text(l10n.noPrescriptionsYet),
                        if (treatment.isActive) ...[
                          const SizedBox(height: 8),
                          TextButton(
                            onPressed: () => showPrescriptionSheet(
                              context,
                              ref,
                              treatmentId: widget.treatmentId,
                            ),
                            child: Text(l10n.addPrescription),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                data: (prescriptions) {
                  return Column(
                    children: prescriptions.map((p) {
                      // A line may break after the dash of the date
                      // range, never before it.
                      final intake = episodeDoses == null
                          ? null
                          : intakeText(
                              IntakeCount.of(
                                p,
                                episodeDoses,
                                now: now,
                                treatmentActive: treatment.isActive,
                                grace: grace,
                              ),
                              intakeLabels,
                            )?.replaceAll(' – ', '\u00A0– ');
                      return PrescriptionCard(
                        prescription: p,
                        treatmentId: widget.treatmentId,
                        treatmentActive: treatment.isActive,
                        unit: units[p.medicationId],
                        intake: intake,
                        logging: _logging.contains(p.id),
                        onLogDose: () => _logAsNeededDose(p),
                      );
                    }).toList(),
                  );
                },
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _logAsNeededDose(Prescription p) async {
    // Checked here too: a second tap can arrive before the disabled button
    // has been built.
    if (!_logging.add(p.id)) return;
    setState(() {});
    final l10n = AppLocalizations.of(context);
    final actions = ref.read(doseActionsProvider);
    String? logged;
    try {
      logged = await actions.logAsNeededDose(p.id);
    } finally {
      if (mounted) setState(() => _logging.remove(p.id));
    }
    final id = logged;
    if (!mounted || id == null) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(l10n.doseLogged),
        // A tap by mistake has already moved the stock; this takes both back.
        action: SnackBarAction(
          label: l10n.undo,
          onPressed: () => unawaited(actions.undoTake(id)),
        ),
      ),
    );
  }

  /// Each medication's quantity unit, by id: a prescription that uses the
  /// medication's own unit stores no unit of its own.
  static Map<String, String?> _unitsById(List<Medication>? medications) => {
    for (final m in medications ?? const <Medication>[]) m.id: m.quantityUnit,
  };

  /// Shares this episode, and nothing else, as plain text.
  Future<void> _shareEpisode(Treatment treatment) async {
    final l10n = AppLocalizations.of(context);
    final String text;
    final String subject;
    try {
      // Read fresh: the list on screen may still be loading.
      final prescriptions = await ref.read(
        prescriptionsByTreatmentProvider(widget.treatmentId).future,
      );
      final doses = await ref.read(
        doseLogsByTreatmentProvider(widget.treatmentId).future,
      );
      // Only for the units, and the stored unit key is the fallback, so a
      // failed read here does not stop the share.
      final units = _unitsById(
        await ref
            .read(medicationListProvider.future)
            .then<List<Medication>?>((m) => m, onError: (_) => null),
      );
      final labels = EpisodeLabels.fromL10n(l10n);
      text = buildEpisodeSummary(
        treatment: treatment,
        prescriptions: prescriptions,
        doses: doses,
        labels: labels,
        now: ref.read(nowProvider)(),
        grace: Duration(minutes: ref.read(missedGraceMinutesProvider)),
        dosageText: (p) => prescriptionDosageLabel(
          l10n,
          p,
          medicationUnit: units[p.medicationId],
        ),
      );
      subject = episodeShareSubject(treatment, labels);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(l10n.genericError)));
      }
      return;
    }
    if (!mounted) return;
    // An iPad anchors its share sheet to a rectangle; the screen will do.
    final box = context.findRenderObject() as RenderBox?;
    await SharePlus.instance.share(
      ShareParams(
        text: text,
        // Not the treatment's name: a subject shows in mail lists and
        // notifications, and the name is usually the diagnosis.
        subject: subject,
        sharePositionOrigin: box == null
            ? null
            : box.localToGlobal(Offset.zero) & box.size,
      ),
    );
  }
}

/// The Krankenstand card: the leave's range, its length, the certificate
/// number and the doctor, each row only when it has a value. It shows when
/// any of the four fields is set, since the form saves each one on its own
/// (a certificate number often arrives before the dates are known).
///
/// The rows are [_SickLeaveRow]s, not the shared `DetailRow`: that one puts
/// "label: value" on one line with only the value flexible, so at 360 dp and
/// a 1.6x text scale the value was left 23 dp ("1234567890" one digit per
/// line) and Italian "In malattia fino al: " overflowed the card by 52 dp.
class _SickLeaveBlock extends StatelessWidget {
  const _SickLeaveBlock({required this.treatment, required this.now});

  final Treatment treatment;
  final DateTime now;

  static bool hasContent(Treatment t) => _hasLeaveData(t) || t.doctor != null;

  /// Anything that belongs to the leave itself, as opposed to the doctor.
  static bool _hasLeaveData(Treatment t) =>
      t.sickLeaveFrom != null ||
      t.sickLeaveTo != null ||
      t.sickLeaveRef != null;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final from = treatment.sickLeaveFrom;
    final to = treatment.sickLeaveTo;
    // Null for a leave that has not started or ends before it starts: the
    // row is left out rather than showing a count that is not true.
    final days = treatment.sickLeaveDaysAt(now);
    return Card(
      key: const Key('sickLeaveBlock'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // A doctor alone is not a sick leave, so the card does not claim
            // one with the heading.
            if (_hasLeaveData(treatment)) ...[
              Row(
                children: [
                  Icon(Icons.work_off, color: context.colors.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    // "Assenza per malattia" in Italian, where "Malattia"
                    // alone names the illness.
                    child: Text(
                      l10n.sickLeavePeriod,
                      style: context.text.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
            ],
            if (from != null)
              _SickLeaveRow(
                icon: Icons.event_busy,
                label: l10n.sickLeaveFrom,
                value: from.formatted,
              ),
            // An open leave reads "Ongoing"; an end date with no start (only
            // from a synced or restored row) still shows its date.
            if (from != null || to != null)
              _SickLeaveRow(
                icon: Icons.event_available,
                label: l10n.sickLeaveTo,
                value: to.formattedOr(l10n.ongoing),
              ),
            if (days != null)
              _SickLeaveRow(
                icon: Icons.today,
                label: l10n.sickLeaveDuration,
                value: l10n.sickLeaveDays(days),
              ),
            if (treatment.sickLeaveRef != null)
              _SickLeaveRow(
                icon: Icons.confirmation_number,
                label: l10n.sickLeaveRef,
                value: treatment.sickLeaveRef!,
              ),
            if (treatment.doctor != null)
              _SickLeaveRow(
                icon: Icons.medical_services,
                label: l10n.doctorLabel,
                value: treatment.doctor!,
              ),
          ],
        ),
      ),
    );
  }
}

/// An icon beside a small label with its value underneath. Stacked rather
/// than side by side, so a long label never squeezes the value.
class _SickLeaveRow extends StatelessWidget {
  const _SickLeaveRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: context.colors.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    color: context.colors.onSurfaceVariant,
                    fontSize: 12,
                  ),
                ),
                Text(value),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
