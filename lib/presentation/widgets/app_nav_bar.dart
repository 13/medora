/// Medora - Shared Bottom Navigation Bar
///
/// Used on all four main screens: Home, Medications, Treatments, Doses.
library;

import 'package:flutter/material.dart';
import 'package:medora/l10n/generated/app_localizations.dart';

class AppNavBar extends StatelessWidget {
  const AppNavBar({super.key, required this.currentIndex, this.onTap});

  final int currentIndex;
  final ValueChanged<int>? onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return NavigationBar(
      selectedIndex: currentIndex,
      onDestinationSelected: onTap,
      destinations: [
        NavigationDestination(
          icon: const Icon(Icons.home_outlined),
          selectedIcon: const Icon(Icons.home),
          label: l10n.navHome,
        ),
        NavigationDestination(
          icon: const Icon(Icons.medication_outlined),
          selectedIcon: const Icon(Icons.medication),
          label: l10n.navMedications,
        ),
        NavigationDestination(
          icon: const Icon(Icons.healing_outlined),
          selectedIcon: const Icon(Icons.healing),
          label: l10n.navTreatments,
        ),
        NavigationDestination(
          icon: const Icon(Icons.schedule_outlined),
          selectedIcon: const Icon(Icons.schedule),
          label: l10n.navDoses,
        ),
      ],
    );
  }
}
