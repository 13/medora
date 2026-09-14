/// Medora - First-run onboarding sheet
///
/// A three-page modal bottom sheet shown once, on first launch, from
/// [MainShellScreen]. The caller persists `onboarding_seen` synchronously
/// right before opening the sheet (not on dismissal), so the sheet never
/// shows twice.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:medora/core/theme_extensions.dart';
import 'package:medora/l10n/generated/app_localizations.dart';

/// Shows the onboarding sheet. Completes when the sheet is closed, however
/// it was closed.
Future<void> showOnboardingSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => const OnboardingSheet(),
  );
}

class OnboardingSheet extends StatefulWidget {
  const OnboardingSheet({super.key});

  @override
  State<OnboardingSheet> createState() => _OnboardingSheetState();
}

class _OnboardingSheetState extends State<OnboardingSheet> {
  final _controller = PageController();
  int _page = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _next(int pageCount) {
    if (_page >= pageCount - 1) {
      Navigator.of(context).pop();
      return;
    }
    _controller.nextPage(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final pages = <_OnboardingPage>[
      _OnboardingPage(
        icon: Icons.inventory_2,
        title: l10n.onboardingCabinetTitle,
        body: l10n.onboardingCabinetBody,
      ),
      _OnboardingPage(
        icon: Icons.healing,
        title: l10n.onboardingTreatmentsTitle,
        body: l10n.onboardingTreatmentsBody,
      ),
      _OnboardingPage(
        icon: Icons.schedule,
        title: l10n.onboardingDosesTitle,
        body: l10n.onboardingDosesBody,
      ),
    ];
    final isLast = _page == pages.length - 1;
    // Capped at 300 (the usual portrait size) but shrinks further on a short
    // viewport (landscape phones), so the sheet stays scrollable-but-visible
    // instead of forcing a 300px PageView into e.g. a 360px-tall screen.
    final pageViewHeight =
        math.min(300.0, MediaQuery.sizeOf(context).height * 0.45);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: context.colors.onSurfaceVariant.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 300),
                child: SizedBox(
                  height: pageViewHeight,
                  child: PageView(
                    controller: _controller,
                    onPageChanged: (i) => setState(() => _page = i),
                    children: pages,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (var i = 0; i < pages.length; i++)
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      margin: const EdgeInsets.symmetric(horizontal: 4),
                      width: i == _page ? 20 : 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: i == _page
                            ? context.colors.primary
                            : context.colors.outlineVariant,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  if (!isLast)
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: Text(l10n.skip),
                    ),
                  const Spacer(),
                  FilledButton(
                    onPressed: () => _next(pages.length),
                    child: Text(isLast ? l10n.onboardingDone : l10n.onboardingNext),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _OnboardingPage extends StatelessWidget {
  const _OnboardingPage({
    required this.icon,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    // The PageView above gives this a fixed height; at a large text scale
    // (e.g. 2.0x) the title/body can outgrow it, so scroll this page's own
    // content instead of overflowing. LayoutBuilder + a min-height
    // ConstrainedBox keeps it centered when it fits.
    return LayoutBuilder(
      builder: (context, constraints) {
        return SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 88,
                  height: 88,
                  decoration: BoxDecoration(
                    color: context.colors.primaryContainer,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    icon,
                    size: 40,
                    color: context.colors.onPrimaryContainer,
                  ),
                ),
                const SizedBox(height: 24),
                Text(
                  title,
                  textAlign: TextAlign.center,
                  style: context.text.headlineSmall
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 12),
                Text(
                  body,
                  textAlign: TextAlign.center,
                  style: context.text.bodyMedium
                      ?.copyWith(color: context.colors.onSurfaceVariant),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
