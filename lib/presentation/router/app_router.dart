/// Medora - App Router Configuration
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:medora/presentation/providers/auth_providers.dart';
import 'package:medora/presentation/providers/settings_providers.dart';
import 'package:medora/presentation/screens/auth/auth_screen.dart';
import 'package:medora/presentation/screens/main_shell_screen.dart';
import 'package:medora/presentation/screens/medication/add_medication_screen.dart';
import 'package:medora/presentation/screens/medication/medication_detail_screen.dart';
import 'package:medora/presentation/screens/treatment/add_treatment_screen.dart';
import 'package:medora/presentation/screens/treatment/treatment_detail_screen.dart';
import 'package:medora/presentation/screens/dose/dose_history_screen.dart';
import 'package:medora/presentation/screens/scanner/barcode_scanner_screen.dart';
import 'package:medora/presentation/screens/settings/settings_screen.dart';
import 'package:medora/presentation/screens/family/family_screen.dart';
import 'package:medora/presentation/screens/export/export_screen.dart';
import 'package:medora/services/security_service.dart';

/// Route paths as constants.
class AppRoutes {
  AppRoutes._();

  static const home = '/';
  static const auth = '/auth';
  static const medications = '/medications';
  static const medicationDetail = '/medications/:id';
  static const addMedication = '/medications/add';
  static const editMedication = '/medications/:id/edit';
  static const treatments = '/treatments';
  static const treatmentDetail = '/treatments/:id';
  static const addTreatment = '/treatments/add';
  static const doses = '/doses';
  static const doseHistory = '/doses/history';
  static const scanner = '/scanner';
  static const settings = '/settings';
  static const family = '/family';
  static const export = '/export';
}

/// GoRouter configuration.
final appRouter = GoRouter(
  initialLocation: AppRoutes.home,
  routes: [
    // Auth Screen
    GoRoute(
      path: AppRoutes.auth,
      builder: (context, state) => const AuthScreen(),
    ),

    // Main shell with swipeable tabs
    GoRoute(
      path: AppRoutes.home,
      builder: (context, state) => const _AuthGuard(
        child: MainShellScreen(initialIndex: 0),
      ),
    ),
    GoRoute(
      path: AppRoutes.medications,
      builder: (context, state) => const _AuthGuard(
        child: MainShellScreen(initialIndex: 1),
      ),
    ),
    GoRoute(
      path: AppRoutes.treatments,
      builder: (context, state) => const _AuthGuard(
        child: MainShellScreen(initialIndex: 2),
      ),
    ),
    GoRoute(
      path: AppRoutes.doses,
      builder: (context, state) => const _AuthGuard(
        child: MainShellScreen(initialIndex: 3),
      ),
    ),

    // Medication detail routes
    GoRoute(
      path: AppRoutes.addMedication,
      builder: (context, state) => _AuthGuard(
        child: AddMedicationScreen(
          initialBarcode: state.uri.queryParameters['barcode'],
          lookupResult: state.extra,
        ),
      ),
    ),
    GoRoute(
      path: AppRoutes.editMedication,
      builder: (context, state) => _AuthGuard(
        child: AddMedicationScreen(medicationId: state.pathParameters['id']),
      ),
    ),
    GoRoute(
      path: AppRoutes.medicationDetail,
      builder: (context, state) => _AuthGuard(
        child: MedicationDetailScreen(medicationId: state.pathParameters['id']!),
      ),
    ),

    // Treatment detail routes
    GoRoute(
      path: AppRoutes.addTreatment,
      builder: (context, state) => const _AuthGuard(
        child: AddTreatmentScreen(),
      ),
    ),
    GoRoute(
      path: '${AppRoutes.treatments}/:id/edit',
      builder: (context, state) => _AuthGuard(
        child: AddTreatmentScreen(treatmentId: state.pathParameters['id']),
      ),
    ),
    GoRoute(
      path: AppRoutes.treatmentDetail,
      builder: (context, state) => _AuthGuard(
        child: TreatmentDetailScreen(treatmentId: state.pathParameters['id']!),
      ),
    ),

    // Dose history
    GoRoute(
      path: AppRoutes.doseHistory,
      builder: (context, state) => const _AuthGuard(
        child: DoseHistoryScreen(),
      ),
    ),

    // Barcode scanner
    GoRoute(
      path: AppRoutes.scanner,
      builder: (context, state) {
        final returnOnly =
            state.uri.queryParameters['returnOnly'] == 'true';
        return _AuthGuard(child: BarcodeScannerScreen(returnBarcodeOnly: returnOnly));
      },
    ),

    // Settings
    GoRoute(
      path: AppRoutes.settings,
      builder: (context, state) => const _AuthGuard(child: SettingsScreen()),
    ),

    // Family sharing
    GoRoute(
      path: AppRoutes.family,
      builder: (context, state) => const _AuthGuard(child: FamilyScreen()),
    ),

    // Export data
    GoRoute(
      path: AppRoutes.export,
      builder: (context, state) => const _AuthGuard(child: ExportScreen()),
    ),
  ],
);

/// Simple widget to guard routes and redirect to Auth if not signed in.
/// Also handles biometric authentication when the app is foregrounded.
class _AuthGuard extends ConsumerStatefulWidget {
  const _AuthGuard({required this.child});
  final Widget child;

  @override
  ConsumerState<_AuthGuard> createState() => _AuthGuardState();
}

class _AuthGuardState extends ConsumerState<_AuthGuard> with WidgetsBindingObserver {
  bool _isAuthenticating = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Initial check on launch
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkBiometrics());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final biometricsEnabled = ref.read(biometricsEnabledProvider);
    if (!biometricsEnabled) return;

    if (state == AppLifecycleState.paused) {
      ref.read(isBiometricLockedProvider.notifier).setLocked(true);
    } 
    else if (state == AppLifecycleState.resumed) {
      _checkBiometrics();
    }
  }

  Future<void> _checkBiometrics() async {
    final biometricsEnabled = ref.read(biometricsEnabledProvider);
    if (!biometricsEnabled) {
      ref.read(isBiometricLockedProvider.notifier).setLocked(false);
      return;
    }

    final isLocked = ref.read(isBiometricLockedProvider);
    if (!isLocked || _isAuthenticating) return;

    _isAuthenticating = true;
    try {
      final canAuth = await SecurityService.instance.canAuthenticate();
      if (!canAuth) {
        if (mounted) ref.read(isBiometricLockedProvider.notifier).setLocked(false);
        return;
      }

      final authenticated = await SecurityService.instance.authenticate();
      if (authenticated && mounted) {
        ref.read(isBiometricLockedProvider.notifier).setLocked(false);
      }
    } finally {
      _isAuthenticating = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authStateProvider);
    final isOffline = ref.watch(isOfflineModeProvider);
    final isLocked = ref.watch(isBiometricLockedProvider);
    final biometricsEnabled = ref.watch(biometricsEnabledProvider);

    // If biometric is locked AND enabled, show the unlock screen
    if (isLocked && biometricsEnabled) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Image.asset(
                'assets/icon/medora_icon.png',
                height: 120,
                errorBuilder: (ctx, err, st) => const Icon(Icons.lock_outline, size: 80, color: Colors.teal),
              ),
              const SizedBox(height: 32),
              ElevatedButton.icon(
                onPressed: _checkBiometrics,
                icon: const Icon(Icons.fingerprint),
                label: const Text("Unlock Medora"),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 12),
                ),
              ),
            ],
          ),
        ),
      );
    }

    // Auth logic
    if (isOffline) return widget.child;

    return authState.when(
      data: (state) {
        if (state.session == null) {
          return const AuthScreen();
        }
        return widget.child;
      },
      loading: () => const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => const AuthScreen(),
    );
  }
}
