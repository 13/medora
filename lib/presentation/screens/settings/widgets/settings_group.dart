/// Medora - Settings: the group card and the small pieces its tiles share.
library;

import 'package:flutter/material.dart';
import 'package:medora/core/theme_extensions.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/services/register_freshness.dart';

class SettingsGroup extends StatelessWidget {
  const SettingsGroup({required this.title, required this.children, super.key});
  final String title;
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      SectionTitle(title),
      Card(
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Column(children: children),
      ),
    ],
  );
}

class SectionTitle extends StatelessWidget {
  const SectionTitle(this.title, {super.key});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        title,
        style: TextStyle(
          color: Theme.of(context).colorScheme.primary,
          fontWeight: FontWeight.w600,
          fontSize: 14,
        ),
      ),
    );
  }
}

class ColorDot extends StatelessWidget {
  const ColorDot(this.color, {super.key});
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 24,
      height: 24,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: Theme.of(context).dividerColor),
      ),
    );
  }
}

class LanguageOption {
  const LanguageOption(this.locale, this.label);
  final Locale? locale;
  final String label;
}

/// "Last updated N days ago" under a register tile's status line, shown
/// once the register is [registerStaleDays] old or older.
class RegisterStaleWarning extends StatelessWidget {
  const RegisterStaleWarning(this.freshness, {super.key});

  final RegisterFreshness freshness;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final days = freshness.days;
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.warning_amber_rounded,
            color: context.colors.error,
            size: 18,
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              days == null
                  ? l10n.registerStaleUnknown
                  : l10n.registerStale(days),
              style: TextStyle(color: context.colors.error),
            ),
          ),
        ],
      ),
    );
  }
}
