/// Medora - scan review: the photo with numbered code markers and a list
///
/// Shows the captured photo with every detected code outlined and numbered,
/// plus the same candidates grouped by kind (AIC, supplement, EAN, other).
/// Tapping a marker or a row selects that code.
///
/// When the caller offers a rescan ([ScanReviewView.onRescanArea]), the user
/// can switch to selection mode and drag a rectangle over the photo; the
/// rectangle is reported in fractions (0..1) of the photo so the caller can
/// crop the original file. Pinch-zoom keeps working while selecting - only
/// panning is off, so a one-finger drag draws instead of moving the photo.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/services/code_candidates.dart';

class ScanReviewView extends StatefulWidget {
  const ScanReviewView({
    super.key,
    required this.image,
    required this.imageSize,
    required this.candidates,
    required this.onSelected,
    required this.onRetake,
    required this.onManualEntry,
    this.busy = false,
    this.onRescanArea,
    this.selecting = false,
    this.onToggleSelecting,
  });

  final ImageProvider image;
  final Size imageSize;
  final List<CodeCandidate> candidates;
  final ValueChanged<CodeCandidate> onSelected;
  final VoidCallback onRetake;
  final VoidCallback onManualEntry;
  final bool busy;

  /// Called with the rectangle the user drew, in fractions (0..1) of the
  /// photo. Null hides the whole area-selection affordance.
  final ValueChanged<Rect>? onRescanArea;

  /// Whether the photo is in area-selection mode (owned by the caller, so a
  /// finished rescan can leave it).
  final bool selecting;
  final VoidCallback? onToggleSelecting;

  @override
  State<ScanReviewView> createState() => _ScanReviewViewState();
}

class _ScanReviewViewState extends State<ScanReviewView> {
  /// Shared with [_Photo] so pinch-zoom survives a rebuild while drawing.
  final TransformationController _zoom = TransformationController();

  /// The rectangle drawn on the photo, in fractions (0..1) of it.
  Rect? _selection;

  @override
  void didUpdateWidget(ScanReviewView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Leaving selection mode drops the rectangle, so coming back starts clean
    // (and a finished rescan does not leave a stale box on the photo).
    if (oldWidget.selecting && !widget.selecting) _selection = null;
  }

  @override
  void dispose() {
    _zoom.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final rescan = widget.onRescanArea;
    final selection = _selection;
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxPhotoHeight = constraints.maxHeight.isFinite
            ? constraints.maxHeight * 0.45
            : 360.0;
        final aspectRatio =
            widget.imageSize.width > 0 && widget.imageSize.height > 0
            ? widget.imageSize.width / widget.imageSize.height
            : 1.0;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: maxPhotoHeight),
              child: Align(
                heightFactor: 1,
                child: AspectRatio(
                  aspectRatio: aspectRatio,
                  child: _Photo(
                    key: const ValueKey('scanPhoto'),
                    image: widget.image,
                    imageSize: widget.imageSize,
                    candidates: widget.candidates,
                    onSelected: widget.busy ? null : widget.onSelected,
                    zoom: _zoom,
                    selecting: rescan != null && widget.selecting,
                    selection: selection,
                    onSelectionChanged: (area) =>
                        setState(() => _selection = area),
                  ),
                ),
              ),
            ),
            if (widget.busy) const LinearProgressIndicator(),
            if (rescan != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        TextButton.icon(
                          key: const ValueKey('scanSelectArea'),
                          onPressed: widget.busy
                              ? null
                              : widget.onToggleSelecting,
                          icon: const Icon(Icons.crop),
                          label: Text(l10n.scanSelectArea),
                        ),
                        if (widget.selecting && selection != null)
                          FilledButton.icon(
                            key: const ValueKey('scanRescanArea'),
                            onPressed: widget.busy
                                ? null
                                : () => rescan(selection),
                            icon: const Icon(Icons.search),
                            label: Text(l10n.scanRescanArea),
                          ),
                      ],
                    ),
                    if (widget.selecting)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          l10n.scanSelectAreaHint,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            Expanded(
              child: widget.candidates.isEmpty
                  ? _EmptyState(message: l10n.scanNoCodeFound)
                  : _CandidateList(
                      candidates: widget.candidates,
                      onSelected: widget.busy ? null : widget.onSelected,
                    ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: widget.busy ? null : widget.onRetake,
                      icon: const Icon(Icons.photo_camera_outlined),
                      label: Text(l10n.scanRetake),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextButton.icon(
                      onPressed: widget.busy ? null : widget.onManualEntry,
                      icon: const Icon(Icons.keyboard_outlined),
                      label: Text(l10n.enterBarcodeManually),
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Fill, border and on-fill colours for a candidate kind.
({Color fill, Color border, Color onFill}) _kindColors(
  ColorScheme scheme,
  CodeKind kind,
) => switch (kind) {
  CodeKind.aic => (
    fill: scheme.primaryContainer,
    border: scheme.primary,
    onFill: scheme.onPrimaryContainer,
  ),
  CodeKind.supplement => (
    fill: scheme.tertiaryContainer,
    border: scheme.tertiary,
    onFill: scheme.onTertiaryContainer,
  ),
  CodeKind.ean => (
    fill: scheme.secondaryContainer,
    border: scheme.secondary,
    onFill: scheme.onSecondaryContainer,
  ),
  CodeKind.other => (
    fill: scheme.surface,
    border: scheme.outline,
    onFill: scheme.onSurface,
  ),
};

class _Photo extends StatefulWidget {
  const _Photo({
    super.key,
    required this.image,
    required this.imageSize,
    required this.candidates,
    required this.onSelected,
    required this.zoom,
    required this.selecting,
    required this.selection,
    required this.onSelectionChanged,
  });

  static const double _tapTarget = 40;

  final ImageProvider image;
  final Size imageSize;
  final List<CodeCandidate> candidates;
  final ValueChanged<CodeCandidate>? onSelected;
  final TransformationController zoom;
  final bool selecting;

  /// The drawn rectangle in fractions (0..1) of the photo.
  final Rect? selection;
  final ValueChanged<Rect> onSelectionChanged;

  @override
  State<_Photo> createState() => _PhotoState();
}

class _PhotoState extends State<_Photo> {
  /// Where the current drag started, in photo-box pixels.
  Offset? _dragStart;

  /// The drag positions arrive in the photo's own coordinates: the gesture
  /// detector sits inside [InteractiveViewer]'s transform, so the zoom is
  /// already undone for us.
  void _extendSelection(Offset local, Size size) {
    final start = _dragStart;
    if (start == null || size.isEmpty) return;
    final rect = Rect.fromPoints(start, local);
    double fx(double v) => (v / size.width).clamp(0.0, 1.0);
    double fy(double v) => (v / size.height).clamp(0.0, 1.0);
    widget.onSelectionChanged(
      Rect.fromLTRB(
        fx(rect.left),
        fy(rect.top),
        fx(rect.right),
        fy(rect.bottom),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ClipRect(
      child: InteractiveViewer(
        maxScale: 5,
        // A one-finger drag draws the rectangle instead of moving the photo;
        // pinch-zoom stays on so the user can zoom in before drawing.
        panEnabled: !widget.selecting,
        transformationController: widget.zoom,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            final height = constraints.maxHeight;
            final sx = widget.imageSize.width > 0
                ? width / widget.imageSize.width
                : 1.0;
            final sy = widget.imageSize.height > 0
                ? height / widget.imageSize.height
                : 1.0;
            final selection = widget.selection;
            final stack = Stack(
              fit: StackFit.expand,
              children: [
                Image(
                  image: widget.image,
                  fit: BoxFit.contain,
                  errorBuilder: (_, _, _) => const SizedBox.shrink(),
                ),
                for (var i = 0; i < widget.candidates.length; i++)
                  ..._marker(scheme, i, width, height, sx, sy),
                if (widget.selecting && selection != null)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: CustomPaint(
                        painter: _SelectionPainter(
                          selection: selection,
                          color: scheme.primary,
                        ),
                      ),
                    ),
                  ),
              ],
            );
            if (!widget.selecting) return stack;
            final size = Size(width, height);
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              // onDown, not onStart: a pan is only recognised once the
              // finger has travelled the touch slop, and the rectangle has
              // to start where the finger actually landed.
              onPanDown: (details) => _dragStart = details.localPosition,
              onPanUpdate: (details) =>
                  _extendSelection(details.localPosition, size),
              onPanEnd: (_) => _dragStart = null,
              onPanCancel: () => _dragStart = null,
              child: stack,
            );
          },
        ),
      ),
    );
  }

  List<Widget> _marker(
    ColorScheme scheme,
    int index,
    double width,
    double height,
    double sx,
    double sy,
  ) {
    const tapTarget = _Photo._tapTarget;
    final candidate = widget.candidates[index];
    final colors = _kindColors(scheme, candidate.kind);
    final box = candidate.box;
    final rect = Rect.fromLTRB(
      box.left * sx,
      box.top * sy,
      box.right * sx,
      box.bottom * sy,
    );
    final chipLeft = math.max(0.0, math.min(rect.left, width - tapTarget));
    final chipTop = math.max(
      0.0,
      math.min(rect.top - tapTarget / 2, height - tapTarget),
    );
    final select = widget.onSelected;
    return [
      Positioned.fromRect(
        rect: rect,
        child: IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border.all(color: colors.border, width: 2),
              borderRadius: BorderRadius.circular(4),
            ),
          ),
        ),
      ),
      Positioned(
        left: chipLeft,
        top: chipTop,
        width: tapTarget,
        height: tapTarget,
        child: Semantics(
          button: true,
          enabled: select != null,
          label: '${index + 1}: ${candidate.code}',
          excludeSemantics: true,
          onTap: select == null ? null : () => select(candidate),
          child: GestureDetector(
            key: ValueKey('scanMarker${index + 1}'),
            behavior: HitTestBehavior.opaque,
            onTap: select == null ? null : () => select(candidate),
            child: Center(
              child: _NumberBadge(
                number: index + 1,
                fill: colors.fill,
                border: colors.border,
                onFill: colors.onFill,
              ),
            ),
          ),
        ),
      ),
    ];
  }
}

/// Paints the drawn rectangle ([selection] in fractions of the photo).
class _SelectionPainter extends CustomPainter {
  const _SelectionPainter({required this.selection, required this.color});

  final Rect selection;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTRB(
      selection.left * size.width,
      selection.top * size.height,
      selection.right * size.width,
      selection.bottom * size.height,
    );
    canvas.drawRect(rect, Paint()..color = color.withValues(alpha: 0.12));
    canvas.drawRect(
      rect,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(_SelectionPainter oldDelegate) =>
      oldDelegate.selection != selection || oldDelegate.color != color;
}

class _NumberBadge extends StatelessWidget {
  const _NumberBadge({
    required this.number,
    required this.fill,
    required this.border,
    required this.onFill,
  });

  final int number;
  final Color fill;
  final Color border;
  final Color onFill;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(
        color: fill,
        border: Border.all(color: border, width: 2),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Center(
        widthFactor: 1,
        heightFactor: 1,
        child: Text(
          '$number',
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
            color: onFill,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

class _CandidateList extends StatelessWidget {
  const _CandidateList({required this.candidates, required this.onSelected});

  final List<CodeCandidate> candidates;
  final ValueChanged<CodeCandidate>? onSelected;

  String _title(AppLocalizations l10n, CodeKind kind) => switch (kind) {
    CodeKind.aic => l10n.scanAicCodes,
    CodeKind.supplement => l10n.scanSupplementCodes,
    CodeKind.ean => l10n.scanBarcodes,
    CodeKind.other => l10n.scanOtherNumbers,
  };

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final select = onSelected;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      children: [
        Text(
          l10n.scanChooseCode,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        for (final kind in CodeKind.values)
          if (candidates.any((c) => c.kind == kind)) ...[
            Padding(
              padding: const EdgeInsets.only(top: 16, bottom: 8),
              child: Text(
                _title(l10n, kind),
                style: theme.textTheme.titleSmall,
              ),
            ),
            for (var i = 0; i < candidates.length; i++)
              if (candidates[i].kind == kind)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: _row(scheme, i, select),
                ),
          ],
      ],
    );
  }

  Widget _row(
    ColorScheme scheme,
    int index,
    ValueChanged<CodeCandidate>? select,
  ) {
    final candidate = candidates[index];
    final colors = _kindColors(scheme, candidate.kind);
    final tinted = candidate.kind != CodeKind.other;
    const radius = BorderRadius.all(Radius.circular(12));
    // The row's own Material paints and clips the tint (and the ink splash),
    // so it scrolls with the list instead of painting on the Scaffold.
    return Material(
      type: tinted ? MaterialType.canvas : MaterialType.transparency,
      color: tinted ? colors.fill : null,
      shape: RoundedRectangleBorder(
        borderRadius: radius,
        side: tinted ? BorderSide.none : BorderSide(color: colors.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        key: ValueKey('scanRow${index + 1}'),
        enabled: select != null,
        textColor: tinted ? colors.onFill : null,
        iconColor: tinted ? colors.onFill : null,
        shape: const RoundedRectangleBorder(borderRadius: radius),
        leading: _NumberBadge(
          number: index + 1,
          fill: colors.fill,
          border: colors.border,
          onFill: colors.onFill,
        ),
        title: Text(candidate.code),
        subtitle: Text(
          candidate.sourceText,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: select == null ? null : () => select(candidate),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          Icon(
            Icons.search_off,
            size: 40,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 12),
          Text(
            message,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyLarge,
          ),
        ],
      ),
    );
  }
}
