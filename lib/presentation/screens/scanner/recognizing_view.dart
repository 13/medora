/// Medora - Scanner: the "recognizing" stage.
library;

import 'package:flutter/material.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/presentation/screens/scanner/capture_view.dart';

/// The stage between the shutter and the review: the photo under a scrim,
/// with a spinner. [photo] is null while the capture is still being written.
class RecognizingView extends StatelessWidget {
  const RecognizingView({super.key, required this.photo});

  final ImageProvider? photo;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return ColoredBox(
      color: Colors.black, // scrim
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (photo != null)
            Image(
              image: photo!,
              fit: BoxFit.contain,
              errorBuilder: (_, _, _) => const SizedBox.shrink(),
            ),
          ColoredBox(color: Colors.black.withValues(alpha: 0.54)), // scrim
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircularProgressIndicator(color: kOnScrim),
                const SizedBox(height: 16),
                Text(
                  l10n.scanRecognizing,
                  style: const TextStyle(color: kOnScrim, fontSize: 15),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
