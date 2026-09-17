/// Medora - The settings gear of the four main tabs.
///
/// One widget so the four app bars cannot drift apart: same icon, same
/// tooltip (which is also the screen-reader label), same route. It belongs
/// at the end of `AppBar.actions` on Dashboard, Medications, Treatments and
/// Doses only. Forms, detail screens, sheets, dialogs and the scanner do not
/// get it: leaving a half-filled form for Settings would lose the input.
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/presentation/router/app_router.dart';

class SettingsAction extends StatefulWidget {
  const SettingsAction({super.key});

  /// The gear's own key, for tests.
  static const buttonKey = Key('settingsAction');

  @override
  State<SettingsAction> createState() => _SettingsActionState();
}

class _SettingsActionState extends State<SettingsAction> {
  /// True while the Settings route this gear pushed is open. A second tap
  /// in the same frame would otherwise stack a second Settings screen.
  bool _open = false;

  Future<void> _openSettings() async {
    if (_open) return;
    _open = true;
    try {
      await context.push<void>(AppRoutes.settings);
    } finally {
      _open = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return IconButton(
      key: SettingsAction.buttonKey,
      icon: const Icon(Icons.settings),
      tooltip: AppLocalizations.of(context).settings,
      onPressed: _openSettings,
    );
  }
}
