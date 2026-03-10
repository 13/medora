/// Medora - Main Shell Screen
///
/// Provides swipeable navigation between the four main tabs:
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
  late final PageController _pageController;
  late int _currentIndex;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    _pageController = PageController(
      initialPage: _currentIndex,
      keepPage: true,
    );

    // Automatically trigger sync when the app shell is first loaded
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(syncServiceProvider).syncAll();
    });
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _onPageChanged(int index) {
    setState(() => _currentIndex = index);
  }

  void _onNavTapped(int index) {
    _pageController.animateToPage(
      index,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    return MainShellScope(
      switchTab: _onNavTapped,
      child: Scaffold(
        body: PageView(
          controller: _pageController,
          onPageChanged: _onPageChanged,
          children: const [
            HomeScreen(),
            MedicationListScreen(),
            TreatmentListScreen(),
            DoseScheduleScreen(),
          ],
        ),
        bottomNavigationBar: AppNavBar(
          currentIndex: _currentIndex,
          onTap: _onNavTapped,
        ),
      ),
    );
  }
}
