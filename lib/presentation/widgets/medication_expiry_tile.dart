/// Medora - One medication row on the expiry axis.
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:medora/core/extensions.dart';
import 'package:medora/core/theme_extensions.dart';
import 'package:medora/domain/entities/medication.dart';
import 'package:medora/presentation/widgets/shared_widgets.dart';

/// A medication seen from the expiry axis: red and `error_outline` once it
/// has expired, amber and `warning_amber_rounded` while it is only expiring,
/// with the [ExpiryBadge] the medication list and the detail screen show.
///
/// The dashboard's card and the screen its "See All" opens both build their
/// rows from this, so the two cannot drift into two ways of drawing the same
/// medication.
class MedicationExpiryTile extends StatelessWidget {
  const MedicationExpiryTile({super.key, required this.med, required this.now});

  final Medication med;

  /// "Now" injected by the nearest consumer (`ref.watch(nowProvider)()`).
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final expired = med.expiredAt(now);
    return ListTile(
      leading: Icon(
        expired ? Icons.error_outline : Icons.warning_amber_rounded,
        color: expired ? context.medora.danger : context.medora.warning,
      ),
      title: Text(med.name),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (med.expiryDate != null)
            Text(
              med.expiryDate!.formatted,
              style: const TextStyle(fontSize: 12),
            ),
          if (med.patientTags.isNotEmpty) ...[
            const SizedBox(height: 2),
            Wrap(
              spacing: 4,
              runSpacing: 4,
              children: med.patientTags
                  .map((t) => TagChip(label: t, fontSize: 10))
                  .toList(),
            ),
          ],
        ],
      ),
      trailing: ExpiryBadge(expiryDate: med.expiryDate, now: now),
      dense: true,
      onTap: () => context.push('/medications/${med.id}'),
    );
  }
}
