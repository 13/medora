/// Medora - Main Shell Screen
///
/// Provides navigation between the four main tabs:
/// Home, Medications, Treatments, Doses.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:medora/presentation/providers/providers.dart';
import 'package:medora/presentation/screens/dose/dose_schedule_screen.dart';
import 'package:medora/presentation/screens/home/home_screen.dart';
import 'package:medora/presentation/screens/medication/medication_list_screen.dart';
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

class _MainShellScreenState extends ConsumerState<MainShellScreen> {
  late int _currentIndex;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;

    // Automatically trigger sync when the app shell is first loaded
    // Delay sync significantly to allow UI to fully render and settle
    // The initial frame drop is caused by provider loading, not sync itself
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Future.delayed(const Duration(seconds: 2), () {
        if (mounted) {
          ref.read(syncServiceProvider).syncAll();
        }
      });
    });
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
