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
      // Cap the badge, do not let it take the row. A ListTile hands its
      // trailing slot loose constraints, so the badge claimed its natural
      // width and the title got whatever was left: at 360 dp, German, 1.6x
      // that is 128 dp for "Abgelaufen" and 210 dp for "Laeuft in 16 Tagen
      // ab" out of the 208 dp the title and the badge share - so "Bentelan"
      // broke mid-word and "Moment 200" was laid out in a 0 dp box, one
      // glyph per line. Nothing overflowed and nothing left the viewport,
      // which is why this survived every earlier test.
      //
      // The badge may take 42.5% of the slot, so the name always keeps the
      // other 57.5%, and BoxFit.scaleDown only ever shrinks: while the badge
      // fits, this paints exactly what it painted before, flush right and
      // unscaled. The same shrink-to-fit the Low Stock row's trailing column
      // already uses. The name is the row's subject and the date is repeated
      // in the subtitle, so the badge is what gives way.
      //
      // The fraction is bounded on both sides, which is why it is 0.425 and
      // not a round number. It must stay above 0.405: at 412 dp the slot is
      // 316 dp and English "Expires in 16 days" wants 128.0 dp, and a cap
      // below that scales a badge the Home goldens photograph. It must stay
      // below 0.448: at 360 dp / 1.6x the slot is 264 dp, the title and the
      // badge share 208 dp of it, and "Bentelan" needs 89.7 dp of that or it
      // breaks mid-word again. 0.425 sits in the middle with about 6 dp of
      // room on each side.
      trailing: LayoutBuilder(
        builder: (context, constraints) => ConstrainedBox(
          constraints: BoxConstraints(maxWidth: constraints.maxWidth * 0.425),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerRight,
            child: ExpiryBadge(expiryDate: med.expiryDate, now: now),
          ),
        ),
      ),
      dense: true,
      onTap: () => context.push('/medications/${med.id}'),
    );
  }
}
