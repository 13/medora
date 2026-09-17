/// Medora - Shared "end treatment" confirmation.
///
/// Both the detail screen's overflow menu and the list row's slide action
/// end a treatment, and both must offer to close an open sick leave on the
/// same day, so the dialog lives here rather than twice.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:medora/core/extensions.dart';
import 'package:medora/domain/entities/treatment.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/presentation/providers/now_provider.dart';
import 'package:medora/presentation/providers/treatment_providers.dart';

/// Confirms, then ends [treatment]. Returns true when it was ended.
///
/// When the sick leave can be ended today ([Treatment.sickLeaveEndAt]), the
/// dialog carries one extra checkbox naming the end date it would store
/// (inclusive, so today still counts). It starts unticked: a leave closed by
/// mistake changes the record silently, while one left open stays visible
/// because its badge keeps counting. A treatment with no leave, a closed
/// leave or a leave that has not started yet gets the plain dialog.
Future<bool> confirmAndEndTreatment(
  BuildContext context,
  WidgetRef ref,
  Treatment treatment,
) async {
  final l10n = AppLocalizations.of(context);
  final sickLeaveEnd = treatment.sickLeaveEndAt(ref.read(nowProvider)());
  var endSickLeave = false;

  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        title: Text(l10n.endTreatment),
        // Scrolls rather than overflows at large text scales.
        scrollable: true,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.endTreatmentConfirm(treatment.name)),
            if (sickLeaveEnd != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: CheckboxListTile(
                  key: const Key('endSickLeaveCheckbox'),
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: endSickLeave,
                  onChanged: (v) => setState(() => endSickLeave = v ?? false),
                  title: Text(l10n.sickLeaveEndToday(sickLeaveEnd.formatted)),
                ),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l10n.endTreatment),
          ),
        ],
      ),
    ),
  );

  if (confirmed != true || !context.mounted) return false;
  final messenger = ScaffoldMessenger.of(context);
  try {
    await ref
        .read(treatmentListProvider.notifier)
        .endTreatment(treatment.id, endSickLeave: endSickLeave);
  } catch (e) {
    debugPrint('⚠ Ending treatment ${treatment.id} failed: $e');
    messenger.showSnackBar(SnackBar(content: Text(l10n.endTreatmentFailed)));
    return false;
  }
  return true;
}
