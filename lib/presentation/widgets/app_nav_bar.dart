/// Medora - Shared Bottom Navigation Bar
///
/// Used on all four main screens: Home, Medications, Treatments, Doses.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:medora/l10n/generated/app_localizations.dart';

class AppNavBar extends StatelessWidget {
  const AppNavBar({super.key, required this.currentIndex, this.onTap});

  final int currentIndex;
  final ValueChanged<int>? onTap;

  /// Flutter's own cap on navigation-bar label scaling
  /// (`_kMaxLabelTextScaleFactor` in navigation_bar.dart).
  static const maxLabelScale = 1.3;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final labels = [
      l10n.navHome,
      l10n.navMedications,
      l10n.navTreatments,
      l10n.navDoses,
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        // Each destination is an equal share of the bar inside its safe area,
        // and the label may use all of it.
        final slot =
            (constraints.maxWidth - MediaQuery.paddingOf(context).horizontal) /
            labels.length;
        return NavigationBar(
          selectedIndex: currentIndex,
          onDestinationSelected: onTap,
          labelTextStyle: _fittingLabelStyle(context, labels, slot),
          destinations: [
            NavigationDestination(
              icon: const Icon(Icons.home_outlined),
              selectedIcon: const Icon(Icons.home),
              label: labels[0],
            ),
            NavigationDestination(
              icon: const Icon(Icons.medication_outlined),
              selectedIcon: const Icon(Icons.medication),
              label: labels[1],
            ),
            NavigationDestination(
              icon: const Icon(Icons.healing_outlined),
              selectedIcon: const Icon(Icons.healing),
              label: labels[2],
            ),
            NavigationDestination(
              icon: const Icon(Icons.schedule_outlined),
              selectedIcon: const Icon(Icons.schedule),
              label: labels[3],
            ),
          ],
        );
      },
    );
  }

  /// The label style that keeps every label whole on one line.
  ///
  /// Material 3 keeps navigation-bar labels on one line, neither wrapped nor
  /// truncated, with the full name in the long-press tooltip and in
  /// semantics (both of which `NavigationBar` provides). The label `Text`
  /// has no `maxLines`, so a label wider than its slot was broken inside the
  /// word: "Behandlungen" is 88.8 dp at 1.0x in a 90 dp slot on a 360 dp
  /// phone, and split from about 1.02x.
  ///
  /// Returns null (Flutter's own style) when every label fits at the size the
  /// bar would give it. Otherwise all labels get the largest size at which
  /// the widest one fits, so they still read as a set, but never a smaller
  /// one than at 1.0x (or at the user's own smaller setting). The long-press
  /// tooltip keeps the user's full text size. Measured with the bar's own
  /// clamped scaler, so a non-linear system scaler is handled too.
  static WidgetStateProperty<TextStyle?>? _fittingLabelStyle(
    BuildContext context,
    List<String> labels,
    double slot,
  ) {
    final theme = Theme.of(context);
    final themed = NavigationBarTheme.of(context).labelTextStyle;
    final colors = theme.colorScheme;
    // Material 3's default label style (navigation_bar.dart,
    // _NavigationBarDefaultsM3.labelTextStyle), unless the theme sets one.
    TextStyle? styleFor(Set<WidgetState> states) =>
        themed?.resolve(states) ??
        theme.textTheme.labelMedium?.apply(
          color: states.contains(WidgetState.disabled)
              ? colors.onSurfaceVariant.withValues(alpha: 0.38)
              : states.contains(WidgetState.selected)
              ? colors.onSurface
              : colors.onSurfaceVariant,
        );

    final measured = styleFor(const {WidgetState.selected});
    final baseSize = measured?.fontSize;
    if (measured == null || baseSize == null || !slot.isFinite) return null;
    final scaler = MediaQuery.textScalerOf(
      context,
    ).clamp(maxScaleFactor: maxLabelScale);
    final direction = Directionality.of(context);
    final locale = Localizations.maybeLocaleOf(context);

    bool fits(double fontSize) {
      final style = measured.copyWith(fontSize: fontSize);
      for (final label in labels) {
        final painter = TextPainter(
          text: TextSpan(text: label, style: style),
          textDirection: direction,
          textScaler: scaler,
          locale: locale,
        )..layout();
        // The whole label on one line, as the paragraph will measure it.
        final width = painter.maxIntrinsicWidth;
        painter.dispose();
        // A hair of margin, so rounding in the paragraph's own layout can
        // never push a label that just fits onto a second line.
        if (width > slot - 0.05) return false;
      }
      return true;
    }

    if (fits(baseSize)) return null;

    // The smallest font size that still renders at the 1.0x size.
    final floorPx = math.min(baseSize, scaler.scale(baseSize));
    var lo = 0.0;
    var hi = baseSize;
    for (var i = 0; i < 20; i++) {
      final mid = (lo + hi) / 2;
      if (scaler.scale(mid) >= floorPx) {
        hi = mid;
      } else {
        lo = mid;
      }
    }
    final floor = hi;

    // The largest font size between that floor and the unscaled size at
    // which every label fits. If none does, the floor wins: a label is
    // never made smaller than it is at 1.0x.
    var fitting = floor;
    if (fits(floor)) {
      lo = floor;
      hi = baseSize;
      for (var i = 0; i < 20; i++) {
        final mid = (lo + hi) / 2;
        if (fits(mid)) {
          lo = mid;
        } else {
          hi = mid;
        }
      }
      fitting = lo;
    }

    return WidgetStateProperty.resolveWith(
      (states) => styleFor(states)?.copyWith(fontSize: fitting),
    );
  }
}
