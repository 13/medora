/// Medora - Prescription Sheet
///
/// Add/edit prescription bottom sheet, extracted from
/// [TreatmentDetailScreen] so its form logic is independently testable.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:medora/core/constants.dart';
import 'package:medora/core/extensions.dart';
import 'package:medora/core/theme_extensions.dart';
import 'package:medora/domain/entities/medication.dart';
import 'package:medora/domain/entities/prescription.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/presentation/providers/dose_providers.dart';
import 'package:medora/presentation/providers/medication_providers.dart';
import 'package:medora/presentation/providers/prescription_providers.dart';
import 'package:medora/presentation/providers/providers.dart';
import 'package:medora/presentation/widgets/forms/unit_dropdown.dart';
import 'package:uuid/uuid.dart';

const _kPresetTimes = ['08:00', '12:00', '18:00', '22:00'];

/// Opens the add/edit prescription bottom sheet.
///
/// Pass [existing] to edit a prescription in place; omit it to add a new
/// one for [treatmentId]. [pickTime] is used to obtain a custom time for
/// the times-per-day chip picker — it defaults to [showTimePicker] and is
/// overridden in widget tests to avoid driving the time-picker dial.
Future<void> showPrescriptionSheet(
  BuildContext context,
  WidgetRef ref, {
  required String treatmentId,
  Prescription? existing,
  Future<TimeOfDay?> Function(BuildContext, TimeOfDay)? pickTime,
}) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) => _PrescriptionSheet(
      treatmentId: treatmentId,
      existing: existing,
      pickTime:
          pickTime ??
          (c, initial) => showTimePicker(context: c, initialTime: initial),
    ),
  );
}

class _PrescriptionSheet extends ConsumerStatefulWidget {
  const _PrescriptionSheet({
    required this.treatmentId,
    required this.pickTime,
    this.existing,
  });

  final String treatmentId;
  final Prescription? existing;
  final Future<TimeOfDay?> Function(BuildContext, TimeOfDay) pickTime;

  @override
  ConsumerState<_PrescriptionSheet> createState() => _PrescriptionSheetState();
}

class _PrescriptionSheetState extends ConsumerState<_PrescriptionSheet> {
  final _formKey = GlobalKey<FormState>();

  late final TextEditingController _dosageAmountController;
  late final TextEditingController _dosageFreeController;
  late final TextEditingController _intervalController;
  late final TextEditingController _durationController;
  late final TextEditingController _notesController;

  String? _selectedMedicationId;
  String? _dosageUnitOverride;
  String _scheduleType = 'fixed_interval';
  List<String> _selectedTimes = [];
  bool _autoDiminish = false;

  /// "Now", rounded down to the minute — used as the preview/start time for
  /// a new prescription so the fixed-interval preview stays stable across
  /// rebuilds triggered by keystrokes.
  late final DateTime _roundedNow;

  bool get _isEdit => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    final now = DateTime.now();
    _roundedNow = DateTime(now.year, now.month, now.day, now.hour, now.minute);

    _dosageAmountController = TextEditingController(
      text: existing?.dosageAmount != null
          ? (existing!.dosageAmount! % 1 == 0
                ? existing.dosageAmount!.toInt().toString()
                : existing.dosageAmount.toString())
          : '',
    );
    _dosageFreeController = TextEditingController(text: existing?.dosage ?? '');
    _intervalController = TextEditingController(
      text: (existing?.intervalHours ?? 8).toString(),
    );
    _durationController = TextEditingController(
      text: (existing?.durationDays ?? 7).toString(),
    );
    _notesController = TextEditingController(text: existing?.notes ?? '');

    _selectedMedicationId = existing?.medicationId;
    _dosageUnitOverride = existing?.dosageUnit;
    _scheduleType = existing?.scheduleType ?? 'fixed_interval';
    _selectedTimes = List.of(existing?.scheduleTimes ?? []);
    _autoDiminish = existing?.autoDiminish ?? false;

    _intervalController.addListener(_onScheduleInputChanged);
    _durationController.addListener(_onScheduleInputChanged);
  }

  void _onScheduleInputChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _dosageAmountController.dispose();
    _dosageFreeController.dispose();
    _intervalController.removeListener(_onScheduleInputChanged);
    _intervalController.dispose();
    _durationController.removeListener(_onScheduleInputChanged);
    _durationController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  /// Format expiry date + unit for display in the medication dropdown.
  /// Both are locale-dependent: the date goes through the shared
  /// [DateTimeX.formatted] extension, the unit through the localized
  /// [AppConstants.unitLabel] rather than its raw storage key.
  String _medLabel(AppLocalizations l10n, Medication m) {
    final expiry = m.expiryDate;
    final unit = m.quantityUnit;
    final parts = <String>[m.name];
    if (expiry != null) {
      parts.add('(${expiry.formatted})');
    }
    if (unit != null && unit.isNotEmpty) {
      parts.add('· ${m.quantity} ${AppConstants.unitLabel(l10n, unit)}');
    }
    return parts.join(' ');
  }

  String? _selectedMedUnit(List<Medication> medications) {
    if (_selectedMedicationId == null) return null;
    return medications
        .where((m) => m.id == _selectedMedicationId)
        .firstOrNull
        ?.quantityUnit;
  }

  /// Compare two nullable string lists for equality.
  static bool _listEquals(List<String>? a, List<String>? b) {
    if (a == null && b == null) return true;
    if (a == null || b == null) return false;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  String _formatTimeOfDay(TimeOfDay t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  /// Builds a throwaway [Prescription] from the current fixed-interval
  /// inputs, purely to compute the first-day preview.
  Prescription _previewPrescription() {
    final interval = int.tryParse(_intervalController.text.trim()) ?? 8;
    final duration = int.tryParse(_durationController.text.trim()) ?? 7;
    return Prescription(
      id: 'preview',
      treatmentId: widget.treatmentId,
      medicationId: _selectedMedicationId ?? '',
      dosage: '',
      intervalHours: interval,
      durationDays: duration,
      startTime: widget.existing?.startTime ?? _roundedNow,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final medications = ref.watch(medicationListProvider).value ?? [];
    final medUnit = _selectedMedUnit(medications);

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: DraggableScrollableSheet(
        initialChildSize: 0.85,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        expand: false,
        builder: (ctx, scrollCtrl) => Column(
          children: [
            // Handle bar
            Container(
              margin: const EdgeInsets.only(top: 8),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: context.colors.outlineVariant,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            // Title
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _isEdit ? l10n.editPrescription : l10n.addPrescription,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            const Divider(),
            Expanded(
              child: Form(
                key: _formKey,
                // A SingleChildScrollView + Column keeps every field mounted
                // at all times (unlike a ListView, which lazily unmounts
                // off-screen children — deactivating their FormFieldState
                // and making Form.validate() silently skip them on a small
                // viewport / large text scale).
                child: SingleChildScrollView(
                  controller: scrollCtrl,
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _buildMedicationField(l10n, medications),
                      const SizedBox(height: 20),
                      _buildDosageFields(l10n, medUnit),
                      const SizedBox(height: 20),
                      _buildScheduleSection(l10n),
                      const SizedBox(height: 20),
                      _buildDurationField(l10n),
                      const SizedBox(height: 16),

                      // ── Auto-diminish toggle ──
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(l10n.autoDiminish),
                        subtitle: Text(
                          l10n.autoDiminishHint,
                          style: const TextStyle(fontSize: 12),
                        ),
                        value: _autoDiminish,
                        onChanged: (v) => setState(() => _autoDiminish = v),
                      ),
                      const SizedBox(height: 12),

                      // ── Notes ──
                      TextFormField(
                        controller: _notesController,
                        decoration: InputDecoration(
                          border: const OutlineInputBorder(),
                          labelText: l10n.notes,
                          prefixIcon: const Icon(Icons.notes),
                        ),
                        maxLines: 2,
                      ),
                      const SizedBox(height: 24),

                      // ── Save button ──
                      SizedBox(
                        width: double.infinity,
                        height: 50,
                        child: ElevatedButton.icon(
                          icon: Icon(_isEdit ? Icons.save : Icons.add),
                          label: Text(_isEdit ? l10n.update : l10n.add),
                          onPressed: () => _save(l10n, medications),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMedicationField(
    AppLocalizations l10n,
    List<Medication> medications,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          l10n.medicationLabel,
          style: TextStyle(
            fontWeight: FontWeight.w600,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
        const SizedBox(height: 8),
        DropdownButtonFormField<String>(
          key: const Key('medicationDropdown'),
          initialValue: _selectedMedicationId,
          isExpanded: true,
          decoration: InputDecoration(
            border: const OutlineInputBorder(),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 14,
            ),
            hintText: l10n.selectMedication,
          ),
          // Archived medications are not offered, but one already selected
          // (editing an old prescription) stays in the list — otherwise the
          // dropdown's initialValue has no matching item.
          items: medications
              .where((m) => !m.isArchived || m.id == _selectedMedicationId)
              .map((m) {
                return DropdownMenuItem(
                  value: m.id,
                  child: Text(
                    _medLabel(l10n, m),
                    overflow: TextOverflow.ellipsis,
                  ),
                );
              })
              .toList(),
          validator: (value) => value == null ? l10n.selectMedication : null,
          onChanged: (value) {
            setState(() {
              _selectedMedicationId = value;
              // Reset unit override so it inherits from new med.
              _dosageUnitOverride = null;
              // Only one of the two dosage inputs is rendered for a given
              // medication; clear the one that is about to disappear so a
              // value typed for the previous medication cannot be saved
              // (an amount with no unit used to save as "2 null").
              final unit = medications
                  .where((m) => m.id == value)
                  .firstOrNull
                  ?.quantityUnit;
              if (unit == null || unit.isEmpty) {
                _dosageAmountController.clear();
              } else {
                _dosageFreeController.clear();
              }
            });
          },
        ),
      ],
    );
  }

  Widget _buildDosageFields(AppLocalizations l10n, String? medUnit) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          l10n.dosageLabel,
          style: TextStyle(
            fontWeight: FontWeight.w600,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
        const SizedBox(height: 8),
        if (medUnit != null)
          Row(
            children: [
              Expanded(
                flex: 2,
                child: TextFormField(
                  key: const Key('dosageAmountField'),
                  controller: _dosageAmountController,
                  decoration: InputDecoration(
                    border: const OutlineInputBorder(),
                    labelText: l10n.dosageLabel,
                    prefixIcon: const Icon(Icons.medication),
                  ),
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  validator: (value) {
                    final amount = double.tryParse(
                      (value ?? '').trim().replaceAll(',', '.'),
                    );
                    if (amount == null || amount < 0.25) {
                      return l10n.invalidNumber;
                    }
                    return null;
                  },
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 3,
                child: UnitDropdown(
                  value: _dosageUnitOverride ?? medUnit,
                  decoration: InputDecoration(
                    border: const OutlineInputBorder(),
                    labelText: l10n.quantityUnit,
                  ),
                  onChanged: (v) => setState(() => _dosageUnitOverride = v),
                ),
              ),
            ],
          )
        else
          TextFormField(
            key: const Key('dosageFreeTextField'),
            controller: _dosageFreeController,
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              hintText: l10n.dosageHint,
              prefixIcon: const Icon(Icons.medication),
            ),
            validator: (v) => (v ?? '').trim().isEmpty ? l10n.required : null,
          ),
      ],
    );
  }

  Widget _buildScheduleSection(AppLocalizations l10n) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          l10n.scheduleType,
          style: TextStyle(
            fontWeight: FontWeight.w600,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
        const SizedBox(height: 8),
        SegmentedButton<String>(
          segments: [
            ButtonSegment(
              value: 'fixed_interval',
              label: Text(
                l10n.fixedInterval,
                style: const TextStyle(fontSize: 12),
              ),
              icon: const Icon(Icons.timer, size: 16),
            ),
            ButtonSegment(
              value: 'times_per_day',
              label: Text(
                l10n.timesPerDay,
                style: const TextStyle(fontSize: 12),
              ),
              icon: const Icon(Icons.schedule, size: 16),
            ),
          ],
          selected: {_scheduleType},
          onSelectionChanged: (s) => setState(() => _scheduleType = s.first),
        ),
        const SizedBox(height: 12),

        if (_scheduleType == 'fixed_interval') ...[
          TextFormField(
            key: const Key('intervalHoursField'),
            controller: _intervalController,
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              labelText: l10n.intervalHoursLabel,
              prefixIcon: const Icon(Icons.repeat),
            ),
            keyboardType: TextInputType.number,
            validator: (value) {
              final v = int.tryParse((value ?? '').trim());
              if (v == null || v < 1 || v > 48) {
                return l10n.intervalRange;
              }
              return null;
            },
          ),
          const SizedBox(height: 8),
          Text(
            l10n.doseTimesPreview(
              _previewPrescription()
                  .previewTimes()
                  .map((t) => t.timeFormatted)
                  .join(', '),
            ),
            style: TextStyle(
              fontSize: 12,
              color: context.colors.onSurfaceVariant,
            ),
          ),
        ],

        if (_scheduleType == 'times_per_day') _buildTimesPerDay(l10n),
      ],
    );
  }

  Widget _buildDurationField(AppLocalizations l10n) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          l10n.durationDaysLabel,
          style: TextStyle(
            fontWeight: FontWeight.w600,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
        const SizedBox(height: 8),
        TextFormField(
          key: const Key('durationDaysField'),
          controller: _durationController,
          decoration: InputDecoration(
            border: const OutlineInputBorder(),
            prefixIcon: const Icon(Icons.date_range),
            suffixText: l10n.durationDaysLabel,
          ),
          keyboardType: TextInputType.number,
          validator: (value) {
            final v = int.tryParse((value ?? '').trim());
            if (v == null || v < 1 || v > 365) {
              return l10n.durationRange;
            }
            return null;
          },
        ),
      ],
    );
  }

  Widget _buildTimesPerDay(AppLocalizations l10n) {
    final sorted = List<String>.from(_selectedTimes)..sort();
    return FormField<bool>(
      // Re-run the validator as soon as the user adds/removes a time so a
      // stale "Select at least one time" error clears immediately, rather
      // than waiting for the next full Form.validate() (e.g. on Save).
      autovalidateMode: AutovalidateMode.onUserInteraction,
      validator: (_) =>
          _selectedTimes.isEmpty ? l10n.selectAtLeastOneTime : null,
      builder: (state) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final t in sorted)
                  InputChip(
                    label: Text(t, style: const TextStyle(fontSize: 12)),
                    visualDensity: VisualDensity.compact,
                    onDeleted: () {
                      setState(() => _selectedTimes.remove(t));
                      state.didChange(null);
                    },
                  ),
                ActionChip(
                  label: const Icon(Icons.add, size: 18),
                  visualDensity: VisualDensity.compact,
                  onPressed: () async {
                    final picked = await widget.pickTime(
                      context,
                      TimeOfDay.now(),
                    );
                    if (picked == null) return;
                    final formatted = _formatTimeOfDay(picked);
                    setState(() {
                      if (!_selectedTimes.contains(formatted)) {
                        _selectedTimes.add(formatted);
                      }
                    });
                    state.didChange(null);
                  },
                ),
              ],
            ),
            if (_kPresetTimes.any((p) => !_selectedTimes.contains(p))) ...[
              const SizedBox(height: 4),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final preset in _kPresetTimes)
                    if (!_selectedTimes.contains(preset))
                      ActionChip(
                        label: Text(
                          preset,
                          style: const TextStyle(fontSize: 12),
                        ),
                        visualDensity: VisualDensity.compact,
                        onPressed: () {
                          setState(() => _selectedTimes.add(preset));
                          state.didChange(null);
                        },
                      ),
                ],
              ),
            ],
            if (state.hasError)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  state.errorText!,
                  style: TextStyle(fontSize: 12, color: context.colors.error),
                ),
              ),
          ],
        );
      },
    );
  }

  Future<void> _save(
    AppLocalizations l10n,
    List<Medication> medications,
  ) async {
    final valid = _formKey.currentState?.validate() ?? false;
    if (!valid) return;
    // Defensive: every field stays mounted for validate() now, but guard
    // anyway rather than null-asserting straight into the constructor.
    if (_selectedMedicationId == null) return;

    final existing = widget.existing;
    final medUnit = _selectedMedUnit(medications);
    final double? amount = double.tryParse(
      _dosageAmountController.text.trim().replaceAll(',', '.'),
    );
    final unit = _dosageUnitOverride ?? medUnit;
    final freeText = _dosageFreeController.text.trim();
    // `dosage` keeps the raw unit key (it is a display fallback, and a
    // label localized at save time would freeze that locale into the
    // record); rendering localizes it via `dosageLabel`. Never interpolate
    // a null unit — that is where "2 null" came from.
    final String dosageText;
    if (amount != null && unit != null && unit.isNotEmpty) {
      dosageText = '${amount % 1 == 0 ? amount.toInt() : amount} $unit';
    } else if (freeText.isNotEmpty) {
      dosageText = freeText;
    } else if (amount != null) {
      dosageText = '${amount % 1 == 0 ? amount.toInt() : amount}';
    } else {
      dosageText = '';
    }

    int interval = int.tryParse(_intervalController.text.trim()) ?? 8;
    if (_scheduleType == 'times_per_day' && _selectedTimes.isNotEmpty) {
      interval = (24 / _selectedTimes.length).round();
    }

    final prescription = Prescription(
      id: existing?.id ?? const Uuid().v4(),
      treatmentId: widget.treatmentId,
      medicationId: _selectedMedicationId!,
      dosage: dosageText,
      dosageAmount: amount,
      dosageUnit: _dosageUnitOverride,
      intervalHours: interval,
      durationDays: int.tryParse(_durationController.text.trim()) ?? 7,
      // New prescriptions use `_roundedNow`, captured when the sheet was
      // opened, so the fixed-interval preview above matches what is saved.
      startTime: existing?.startTime ?? _roundedNow,
      autoDiminish: _autoDiminish,
      notes: _notesController.text.trim().isEmpty
          ? null
          : _notesController.text.trim(),
      scheduleType: _scheduleType,
      scheduleTimes: _scheduleType == 'times_per_day' ? _selectedTimes : null,
    );

    final isEdit = existing != null;
    final medicationChanged =
        isEdit && _selectedMedicationId != existing.medicationId;

    if (medicationChanged) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          content: Text(l10n.changeMedicationConfirm),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(l10n.cancel),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(l10n.continueAction),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }

    final repo = ref.read(prescriptionRepositoryProvider);
    bool saved = false;

    if (isEdit) {
      final scheduleChanged =
          existing.intervalHours != prescription.intervalHours ||
          existing.durationDays != prescription.durationDays ||
          existing.scheduleType != prescription.scheduleType ||
          existing.startTime != prescription.startTime ||
          !_listEquals(existing.scheduleTimes, prescription.scheduleTimes);
      final needsRegeneration = scheduleChanged || medicationChanged;

      final result = await repo.updatePrescription(prescription);
      await result.when(
        success: (_) async {
          saved = true;
          if (needsRegeneration) {
            try {
              final doseLogRepo = ref.read(doseLogRepositoryProvider);
              final doseResult = await doseLogRepo
                  .regenerateDoseLogsForPrescription(prescription.id);
              doseResult.when(
                success: (doses) {
                  debugPrint(
                    '✅ Regenerated ${doses.length} doses for edited prescription',
                  );
                },
                failure: (msg) {
                  debugPrint('⚠ Failed to regenerate doses: $msg');
                },
              );
            } catch (e) {
              debugPrint('⚠ Dose regeneration error: $e');
            }
          }
          if (mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text(l10n.prescriptionUpdated)));
          }
        },
        failure: (msg) async {
          if (mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text(l10n.errorWithDetails(msg))));
          }
        },
      );
    } else {
      final result = await repo.addPrescription(prescription);
      await result.when(
        success: (p) async {
          saved = true;
          try {
            final doseLogRepo = ref.read(doseLogRepositoryProvider);
            final doseResult = await doseLogRepo
                .generateDoseLogsForPrescription(p.id);
            doseResult.when(
              success: (doses) {
                debugPrint(
                  '✅ Generated ${doses.length} doses for new prescription',
                );
              },
              failure: (msg) {
                debugPrint('⚠ Failed to generate doses: $msg');
              },
            );
          } catch (e) {
            debugPrint('⚠ Dose generation error: $e');
          }
        },
        failure: (msg) async {
          if (mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text(l10n.errorWithDetails(msg))));
          }
        },
      );
    }

    // The sheet can be dismissed (drag/X) while the write above is in
    // flight; `ref`/`context` on a disposed ConsumerState would throw.
    if (!mounted) return;

    if (saved) {
      ref.invalidate(prescriptionsByTreatmentProvider(widget.treatmentId));
      ref.invalidateDoseData();
      unawaited(ref.read(reminderSchedulerProvider).reconcile());
      ref.invalidate(activePrescriptionsProvider);
    }

    Navigator.pop(context);
  }
}
