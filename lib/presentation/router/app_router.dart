/// Medora - App Router Configuration
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:medora/core/platform_capabilities.dart';
import 'package:medora/core/route_paths.dart';
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
import 'package:medora/presentation/screens/medication/expiring_medications_screen.dart';
import 'package:medora/presentation/screens/medication/medication_detail_screen.dart';
import 'package:medora/presentation/screens/persons/person_form_screen.dart';
import 'package:medora/presentation/screens/persons/person_list_screen.dart';
import 'package:medora/presentation/screens/rx/rx_detail_screen.dart';
import 'package:medora/presentation/screens/rx/rx_form_screen.dart';
import 'package:medora/presentation/screens/rx/rx_scan_sheet.dart';
import 'package:medora/presentation/screens/scanner/barcode_scanner_screen.dart';
import 'package:medora/presentation/screens/settings/settings_screen.dart';
import 'package:medora/presentation/screens/stats/stats_screen.dart';
import 'package:medora/presentation/screens/treatment/add_treatment_screen.dart';
import 'package:medora/presentation/screens/treatment/treatment_detail_screen.dart';
import 'package:medora/presentation/widgets/biometric_gate.dart';

/// Route paths as constants.
class AppRoutes {
  AppRoutes._();

  // `home`, `doses` and `rxDetail` are shared with [RoutePaths] (`lib/core`)
  // so `ReminderService` can build these three routes without importing
  // presentation code; the constants are declared there and just used here,
  // so the two cannot drift.
  static const home = RoutePaths.home;
  static const auth = '/auth';
  static const medications = '/medications';
  static const medicationDetail = '/medications/:id';
  static const addMedication = '/medications/add';

  /// The dashboard's expiry card in full. Declared before
  /// [medicationDetail] so it is not read as a medication id.
  static const expiringMedications = '/medications/expiring';
  static const editMedication = '/medications/:id/edit';
  static const treatments = '/treatments';
  static const treatmentDetail = '/treatments/:id';
  static const addTreatment = '/treatments/add';
  static const editTreatment = '/treatments/:id/edit';
  static const doses = RoutePaths.doses;
  static const doseHistory = '/doses/history';
  static const scanner = '/scanner';

  /// The scanner in return-only mode: pops with the chosen code and its kind
  /// (`ScanResult`).
  static const scannerReturnOnly = '$scanner?returnOnly=true';
  static const settings = '/settings';
  static const family = '/family';
  static const export = '/export';
  static const stats = '/stats';
  static const persons = '/persons';
  static const addPerson = '/persons/add';
  static const editPerson = '/persons/:id/edit';
  static const addRx = '/rx/add';
  static const rxDetail = RoutePaths.rxDetail;
  static const editRx = '/rx/:id/edit';
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
      final hasSession =
          ref.read(authStateProvider).value?.session != null ||
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
          GoRoute(
            path: AppRoutes.home,
            builder: (_, _) => const MainShellScreen(),
          ),
          GoRoute(
            path: AppRoutes.medications,
            builder: (_, _) => const MainShellScreen(initialIndex: 1),
          ),
          GoRoute(
            path: AppRoutes.treatments,
            builder: (_, _) => const MainShellScreen(initialIndex: 2),
          ),
          GoRoute(
            path: AppRoutes.doses,
            builder: (_, _) => const MainShellScreen(initialIndex: 3),
          ),
          GoRoute(
            path: AppRoutes.addMedication,
            builder: (_, state) => AddMedicationScreen(
              initialBarcode: state.uri.queryParameters['barcode'],
              initialEan: state.uri.queryParameters['ean'],
              lookupResult: state.extra,
            ),
          ),
          GoRoute(
            path: AppRoutes.stats,
            builder: (_, _) => const StatsScreen(),
          ),
          GoRoute(
            path: AppRoutes.expiringMedications,
            builder: (_, _) => const ExpiringMedicationsScreen(),
          ),
          GoRoute(
            path: AppRoutes.editMedication,
            builder: (_, state) =>
                AddMedicationScreen(medicationId: state.pathParameters['id']),
          ),
          GoRoute(
            path: AppRoutes.medicationDetail,
            builder: (_, state) => MedicationDetailScreen(
              medicationId: state.pathParameters['id']!,
            ),
          ),
          GoRoute(
            path: AppRoutes.addTreatment,
            builder: (_, _) => const AddTreatmentScreen(),
          ),
          GoRoute(
            path: AppRoutes.editTreatment,
            builder: (_, state) =>
                AddTreatmentScreen(treatmentId: state.pathParameters['id']),
          ),
          GoRoute(
            path: AppRoutes.treatmentDetail,
            builder: (_, state) =>
                TreatmentDetailScreen(treatmentId: state.pathParameters['id']!),
          ),
          GoRoute(
            path: AppRoutes.doseHistory,
            builder: (_, _) => const DoseHistoryScreen(),
          ),
          GoRoute(
            path: AppRoutes.scanner,
            builder: (context, state) {
              final caps = ProviderScope.containerOf(
                context,
              ).read(platformCapabilitiesProvider);
              if (!caps.hasCamera) return const _UnavailableScreen();
              return BarcodeScannerScreen(
                returnBarcodeOnly:
                    state.uri.queryParameters['returnOnly'] == 'true',
              );
            },
          ),
          GoRoute(
            path: AppRoutes.settings,
            builder: (_, _) => const SettingsScreen(),
          ),
          GoRoute(
            path: AppRoutes.family,
            builder: (_, _) => const FamilyScreen(),
          ),
          GoRoute(
            path: AppRoutes.persons,
            builder: (_, _) => const PersonListScreen(),
          ),
          GoRoute(
            path: AppRoutes.addPerson,
            builder: (_, _) => const PersonFormScreen(),
          ),
          GoRoute(
            path: AppRoutes.editPerson,
            builder: (_, state) =>
                PersonFormScreen(personId: state.pathParameters['id']),
          ),
          // addRx before rxDetail (Task 10) so '/rx/add' is not read as an id.
          GoRoute(
            path: AppRoutes.addRx,
            builder: (_, state) {
              // Set when the prescription was scanned (rx_scan_sheet.dart).
              final scan = state.extra is RxScanPrefill
                  ? state.extra! as RxScanPrefill
                  : null;
              return RxFormScreen(
                treatmentId: state.uri.queryParameters['treatmentId'],
                personId: state.uri.queryParameters['personId'],
                draft: scan?.draft,
                originalPath: scan?.originalPath,
                originalName: scan?.originalName,
              );
            },
          ),
          GoRoute(
            path: AppRoutes.editRx,
            builder: (_, state) =>
                RxFormScreen(rxId: state.pathParameters['id']),
          ),
          GoRoute(
            path: AppRoutes.rxDetail,
            builder: (_, state) =>
                RxDetailScreen(rxId: state.pathParameters['id']!),
          ),
          GoRoute(
            path: AppRoutes.export,
            builder: (context, state) {
              final caps = ProviderScope.containerOf(
                context,
              ).read(platformCapabilitiesProvider);
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
