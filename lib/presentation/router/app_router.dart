/// Medora - App Router Configuration
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:medora/core/platform_capabilities.dart';
import 'package:medora/core/supabase_config.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/presentation/providers/app_mode_provider.dart';
import 'package:medora/presentation/providers/auth_providers.dart';
import 'package:medora/presentation/screens/auth/auth_screen.dart';
import 'package:medora/presentation/screens/dose/dose_history_screen.dart';
import 'package:medora/presentation/screens/export/export_screen.dart';
import 'package:medora/presentation/screens/family/family_screen.dart';
import 'package:medora/presentation/screens/main_shell_screen.dart';
import 'package:medora/presentation/screens/medication/add_medication_screen.dart';
import 'package:medora/presentation/screens/medication/medication_detail_screen.dart';
import 'package:medora/presentation/screens/scanner/barcode_scanner_screen.dart';
import 'package:medora/presentation/screens/settings/settings_screen.dart';
import 'package:medora/presentation/screens/treatment/add_treatment_screen.dart';
import 'package:medora/presentation/screens/treatment/treatment_detail_screen.dart';
import 'package:medora/presentation/widgets/biometric_gate.dart';

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
  static const editTreatment = '/treatments/:id/edit';
  static const doses = '/doses';
  static const doseHistory = '/doses/history';
  static const scanner = '/scanner';
  static const settings = '/settings';
  static const family = '/family';
  static const export = '/export';
}

/// Pure redirect rule (unit-tested).
/// Returns the location to go to, or null to stay.
String? computeRedirect({
  required AppMode mode,
  required bool hasSession,
  required String location,
}) {
  final onAuth = location == AppRoutes.auth;
  if (mode == AppMode.localOnly) return onAuth ? AppRoutes.home : null;
  if (!hasSession) return onAuth ? null : AppRoutes.auth;
  return onAuth ? AppRoutes.home : null;
}

/// Notifies GoRouter when app mode or auth session changes.
class _RouterRefresh extends ChangeNotifier {
  _RouterRefresh(Ref ref) {
    ref.listen(appModeProvider, (_, _) => notifyListeners());
    ref.listen(authStateProvider, (_, _) => notifyListeners());
  }
}

final appRouterProvider = Provider<GoRouter>((ref) {
  final refresh = _RouterRefresh(ref);
  ref.onDispose(refresh.dispose);

  return GoRouter(
    initialLocation: AppRoutes.home,
    refreshListenable: refresh,
    redirect: (context, state) {
      final mode = ref.read(appModeProvider);
      final hasSession = ref.read(authStateProvider).value?.session != null ||
          SupabaseConfig.isAuthenticated;
      return computeRedirect(
        mode: mode,
        hasSession: hasSession,
        location: state.matchedLocation,
      );
    },
    routes: [
      GoRoute(
        path: AppRoutes.auth,
        builder: (context, state) => const AuthScreen(),
      ),
      ShellRoute(
        builder: (context, state, child) => BiometricGate(child: child),
        routes: [
          GoRoute(path: AppRoutes.home, builder: (_, _) => const MainShellScreen(initialIndex: 0)),
          GoRoute(path: AppRoutes.medications, builder: (_, _) => const MainShellScreen(initialIndex: 1)),
          GoRoute(path: AppRoutes.treatments, builder: (_, _) => const MainShellScreen(initialIndex: 2)),
          GoRoute(path: AppRoutes.doses, builder: (_, _) => const MainShellScreen(initialIndex: 3)),
          GoRoute(
            path: AppRoutes.addMedication,
            builder: (_, state) => AddMedicationScreen(
              initialBarcode: state.uri.queryParameters['barcode'],
              lookupResult: state.extra,
            ),
          ),
          GoRoute(
            path: AppRoutes.editMedication,
            builder: (_, state) => AddMedicationScreen(medicationId: state.pathParameters['id']),
          ),
          GoRoute(
            path: AppRoutes.medicationDetail,
            builder: (_, state) => MedicationDetailScreen(medicationId: state.pathParameters['id']!),
          ),
          GoRoute(path: AppRoutes.addTreatment, builder: (_, _) => const AddTreatmentScreen()),
          GoRoute(
            path: AppRoutes.editTreatment,
            builder: (_, state) => AddTreatmentScreen(treatmentId: state.pathParameters['id']),
          ),
          GoRoute(
            path: AppRoutes.treatmentDetail,
            builder: (_, state) => TreatmentDetailScreen(treatmentId: state.pathParameters['id']!),
          ),
          GoRoute(path: AppRoutes.doseHistory, builder: (_, _) => const DoseHistoryScreen()),
          GoRoute(
            path: AppRoutes.scanner,
            builder: (context, state) {
              final caps = ProviderScope.containerOf(context).read(platformCapabilitiesProvider);
              if (!caps.hasCamera) return const _UnavailableScreen();
              return BarcodeScannerScreen(
                returnBarcodeOnly: state.uri.queryParameters['returnOnly'] == 'true',
              );
            },
          ),
          GoRoute(path: AppRoutes.settings, builder: (_, _) => const SettingsScreen()),
          GoRoute(path: AppRoutes.family, builder: (_, _) => const FamilyScreen()),
          GoRoute(
            path: AppRoutes.export,
            builder: (context, state) {
              final caps = ProviderScope.containerOf(context).read(platformCapabilitiesProvider);
              if (!caps.hasFileShare) return const _UnavailableScreen();
              return const ExportScreen();
            },
          ),
        ],
      ),
    ],
  );
});

/// Shown in place of a route whose screen needs a platform capability
/// (camera, file share) the current platform doesn't provide.
class _UnavailableScreen extends StatelessWidget {
  const _UnavailableScreen();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            AppLocalizations.of(context).featureUnavailableOnPlatform,
            textAlign: TextAlign.center,
          ),
        ),
      ),
    );
  }
}
