/// Medora - Scanner: the live camera stage.
library;

import 'package:flutter/material.dart';
import 'package:medora/core/theme_extensions.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/presentation/screens/scanner/barcode_scanner_screen.dart';
import 'package:medora/services/scanner_ports.dart';

/// White text and icons on the black camera scrim.
const Color kOnScrim = Color(0xFFFFFFFF); // on scrim

/// The camera stage: the cover-fitted preview with tap-to-focus, the capture
/// hint, and the gallery / shutter / manual-entry row.
///
/// The camera itself stays with [BarcodeScannerScreen]: this view only draws
/// the [camera] port it is handed and reports the taps back.
class CaptureView extends StatelessWidget {
  const CaptureView({
    super.key,
    required this.camera,
    required this.cameraReady,
    required this.cameraFailed,
    required this.busy,
    required this.canShoot,
    required this.searching,
    required this.onShutter,
    required this.onGallery,
    required this.onManualEntry,
    required this.onFocus,
  });

  final CameraPort camera;

  /// Whether the preview can be drawn; [cameraFailed] tells a camera that
  /// never came up from one still starting.
  final bool cameraReady;
  final bool cameraFailed;

  /// Any in-flight work that the buttons must not start twice.
  final bool busy;
  final bool canShoot;

  /// Whether a lookup is running, which the hint says instead of the prompt.
  final bool searching;

  final VoidCallback onShutter;
  final VoidCallback onGallery;
  final VoidCallback onManualEntry;
  final void Function(Offset local, Size viewport, Orientation orientation)
  onFocus;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final previewSize = camera.previewSize;
    return ColoredBox(
      color: Colors.black, // scrim
      child: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                if (cameraReady && previewSize != null)
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final orientation = MediaQuery.orientationOf(context);
                      final child = BarcodeScannerScreen.previewChildSize(
                        previewSize,
                        orientation,
                      );
                      return GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTapUp: (details) => onFocus(
                          details.localPosition,
                          constraints.biggest,
                          orientation,
                        ),
                        child: SizedBox.expand(
                          child: ClipRect(
                            child: FittedBox(
                              fit: BoxFit.cover,
                              child: SizedBox(
                                width: child.width,
                                height: child.height,
                                child: camera.buildPreview(context),
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  )
                else if (!cameraFailed)
                  const Center(
                    child: CircularProgressIndicator(color: kOnScrim),
                  ),
                Positioned(
                  bottom: 12,
                  left: 16,
                  right: 16,
                  child: Center(
                    child: ScrimLabel(
                      child: searching
                          ? Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: kOnScrim,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  l10n.lookingUpBarcode,
                                  style: const TextStyle(
                                    color: kOnScrim,
                                    fontSize: 13,
                                  ),
                                ),
                              ],
                            )
                          : Text(
                              l10n.scanCaptureHint,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: kOnScrim,
                                fontSize: 13,
                              ),
                            ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  IconButton(
                    iconSize: 28,
                    color: kOnScrim,
                    tooltip: l10n.scanFromGallery,
                    onPressed: busy ? null : onGallery,
                    icon: const Icon(Icons.photo_library_outlined),
                  ),
                  Tooltip(
                    message: l10n.scanTakePhoto,
                    child: FilledButton(
                      onPressed: canShoot ? onShutter : null,
                      style: FilledButton.styleFrom(
                        shape: const CircleBorder(),
                        fixedSize: const Size(72, 72),
                        padding: EdgeInsets.zero,
                        disabledBackgroundColor: context.colors.onSurface
                            .withValues(alpha: 0.38),
                      ),
                      child: Icon(
                        Icons.camera_alt,
                        size: 32,
                        semanticLabel: l10n.scanTakePhoto,
                      ),
                    ),
                  ),
                  IconButton(
                    iconSize: 28,
                    color: kOnScrim,
                    tooltip: l10n.enterBarcodeManually,
                    onPressed: busy ? null : onManualEntry,
                    icon: const Icon(Icons.keyboard),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class ScrimLabel extends StatelessWidget {
  const ScrimLabel({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.54), // scrim
        borderRadius: BorderRadius.circular(20),
      ),
      child: child,
    );
  }
}
