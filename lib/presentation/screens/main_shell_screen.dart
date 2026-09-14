/// Medora - Main Shell Screen
///
/// Provides navigation between the four main tabs:
/// Home, Medications, Treatments, Doses.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:medora/presentation/providers/onboarding_provider.dart';
import 'package:medora/presentation/providers/providers.dart';
import 'package:medora/presentation/screens/dose/dose_schedule_screen.dart';
import 'package:medora/presentation/screens/home/home_screen.dart';
import 'package:medora/presentation/screens/medication/medication_list_screen.dart';
import 'package:medora/presentation/screens/onboarding/onboarding_sheet.dart';
import 'package:medora/presentation/screens/treatment/treatment_list_screen.dart';
import 'package:medora/presentation/widgets/app_nav_bar.dart';

/// Provides access to the shell's tab switching from child widgets.
class MainShellScope extends InheritedWidget {
  const MainShellScope({
    super.key,
    required this.switchTab,
    required super.child,
  });

  final void Function(int index) switchTab;

  static MainShellScope? of(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<MainShellScope>();
  }

  @override
  bool updateShouldNotify(MainShellScope oldWidget) => false;
}

class MainShellScreen extends ConsumerStatefulWidget {
  const MainShellScreen({super.key, this.initialIndex = 0});

  final int initialIndex;

  @override
  ConsumerState<MainShellScreen> createState() => _MainShellScreenState();
}

class _MainShellScreenState extends ConsumerState<MainShellScreen> with WidgetsBindingObserver {
  late int _currentIndex;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(ref.read(appStartupTasksProvider).run());
      unawaited(_maybeShowOnboarding());
    });
  }

  /// On the very first launch, show the onboarding sheet. Any dismissal —
  /// Done, Skip or a drag-down — completes the sheet's future and marks it
  /// seen, so it appears exactly once.
  Future<void> _maybeShowOnboarding() async {
    if (ref.read(onboardingSeenProvider)) return;
    await showOnboardingSheet(context);
    if (!mounted) return;
    await ref.read(onboardingSeenProvider.notifier).markSeen();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) {
      unawaited(ref.read(appStartupTasksProvider).run());
    }
  }

  void _onNavTapped(int index) {
    if (_currentIndex == index) return;
    setState(() => _currentIndex = index);
  }

  @override
  Widget build(BuildContext context) {
    return MainShellScope(
      switchTab: _onNavTapped,
      child: Scaffold(
        // Use a simple switcher that only builds the active tab
        // This prevents loading all 4 screens' data simultaneously on startup
        body: [
          const HomeScreen(),
          const MedicationListScreen(),
          const TreatmentListScreen(),
          const DoseScheduleScreen(),
        ][_currentIndex],
        bottomNavigationBar: AppNavBar(
          currentIndex: _currentIndex,
          onTap: _onNavTapped,
        ),
      ),
    );
  }
}
