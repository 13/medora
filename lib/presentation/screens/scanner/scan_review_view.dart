/// Medora - scan review: the photo with numbered code markers and a list
///
/// Shows the captured photo with every detected code outlined and numbered,
/// plus the same candidates grouped by kind (AIC, supplement, EAN, other).
/// Tapping a marker or a row selects that code.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/services/code_candidates.dart';

class ScanReviewView extends StatelessWidget {
  const ScanReviewView({
    super.key,
    required this.image,
    required this.imageSize,
    required this.candidates,
    required this.onSelected,
    required this.onRetake,
    required this.onManualEntry,
    this.busy = false,
  });

  final ImageProvider image;
  final Size imageSize;
  final List<CodeCandidate> candidates;
  final ValueChanged<CodeCandidate> onSelected;
  final VoidCallback onRetake;
  final VoidCallback onManualEntry;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxPhotoHeight = constraints.maxHeight.isFinite
            ? constraints.maxHeight * 0.45
            : 360.0;
        final aspectRatio = imageSize.width > 0 && imageSize.height > 0
            ? imageSize.width / imageSize.height
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
                    image: image,
                    imageSize: imageSize,
                    candidates: candidates,
                    onSelected: busy ? null : onSelected,
                  ),
                ),
              ),
            ),
            if (busy) const LinearProgressIndicator(),
            Expanded(
              child: candidates.isEmpty
                  ? _EmptyState(message: l10n.scanNoCodeFound)
                  : _CandidateList(
                      candidates: candidates,
                      onSelected: busy ? null : onSelected,
                    ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: busy ? null : onRetake,
                      icon: const Icon(Icons.photo_camera_outlined),
                      label: Text(l10n.scanRetake),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextButton.icon(
                      onPressed: busy ? null : onManualEntry,
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

class _Photo extends StatelessWidget {
  const _Photo({
    required this.image,
    required this.imageSize,
    required this.candidates,
    required this.onSelected,
  });

  static const double _tapTarget = 40;

  final ImageProvider image;
  final Size imageSize;
  final List<CodeCandidate> candidates;
  final ValueChanged<CodeCandidate>? onSelected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ClipRect(
      child: InteractiveViewer(
        maxScale: 5,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Image(
              image: image,
              fit: BoxFit.contain,
              errorBuilder: (_, _, _) => const SizedBox.shrink(),
            ),
            LayoutBuilder(
              builder: (context, constraints) {
                final width = constraints.maxWidth;
                final height = constraints.maxHeight;
                final sx = imageSize.width > 0 ? width / imageSize.width : 1.0;
                final sy = imageSize.height > 0
                    ? height / imageSize.height
                    : 1.0;
                return Stack(
                  children: [
                    for (var i = 0; i < candidates.length; i++)
                      ..._marker(scheme, i, width, height, sx, sy),
                  ],
                );
              },
            ),
          ],
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
    final candidate = candidates[index];
    final colors = _kindColors(scheme, candidate.kind);
    final box = candidate.box;
    final rect = Rect.fromLTRB(
      box.left * sx,
      box.top * sy,
      box.right * sx,
      box.bottom * sy,
    );
    final chipLeft = math.max(0.0, math.min(rect.left, width - _tapTarget));
    final chipTop = math.max(
      0.0,
      math.min(rect.top - _tapTarget / 2, height - _tapTarget),
    );
    final select = onSelected;
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
        width: _tapTarget,
        height: _tapTarget,
        child: Semantics(
          button: true,
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
    return ListTile(
      key: ValueKey('scanRow${index + 1}'),
      enabled: select != null,
      tileColor: tinted ? colors.fill : null,
      textColor: tinted ? colors.onFill : null,
      iconColor: tinted ? colors.onFill : null,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: tinted ? BorderSide.none : BorderSide(color: colors.border),
      ),
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
