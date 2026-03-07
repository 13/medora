/// Medora - App Router Configuration
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
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

/// Route paths as constants.
class AppRoutes {
  AppRoutes._();

  static const home = '/';
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
    // Main shell with swipeable tabs
    GoRoute(
      path: AppRoutes.home,
      builder: (context, state) => const MainShellScreen(initialIndex: 0),
    ),
    GoRoute(
      path: AppRoutes.medications,
      builder: (context, state) => const MainShellScreen(initialIndex: 1),
    ),
    GoRoute(
      path: AppRoutes.treatments,
      builder: (context, state) => const MainShellScreen(initialIndex: 2),
    ),
    GoRoute(
      path: AppRoutes.doses,
      builder: (context, state) => const MainShellScreen(initialIndex: 3),
    ),

    // Medication detail routes
    GoRoute(
      path: AppRoutes.addMedication,
      builder: (context, state) {
        final barcode = state.uri.queryParameters['barcode'];
        return AddMedicationScreen(
          initialBarcode: barcode,
          lookupResult: state.extra,
        );
      },
    ),
    GoRoute(
      path: AppRoutes.editMedication,
      builder: (context, state) {
        final id = state.pathParameters['id']!;
        return AddMedicationScreen(medicationId: id);
      },
    ),
    GoRoute(
      path: AppRoutes.medicationDetail,
      builder: (context, state) {
        final id = state.pathParameters['id']!;
        return MedicationDetailScreen(medicationId: id);
      },
    ),

    // Treatment detail routes
    GoRoute(
      path: AppRoutes.addTreatment,
      builder: (context, state) => const AddTreatmentScreen(),
    ),
    GoRoute(
      path: '${AppRoutes.treatments}/:id/edit',
      builder: (context, state) {
        final id = state.pathParameters['id']!;
        return AddTreatmentScreen(treatmentId: id);
      },
    ),
    GoRoute(
      path: AppRoutes.treatmentDetail,
      builder: (context, state) {
        final id = state.pathParameters['id']!;
        return TreatmentDetailScreen(treatmentId: id);
      },
    ),

    // Dose history
    GoRoute(
      path: AppRoutes.doseHistory,
      builder: (context, state) => const DoseHistoryScreen(),
    ),

    // Barcode scanner
    GoRoute(
      path: AppRoutes.scanner,
      builder: (context, state) {
        final returnOnly =
            state.uri.queryParameters['returnOnly'] == 'true';
        return BarcodeScannerScreen(returnBarcodeOnly: returnOnly);
      },
    ),

    // Settings
    GoRoute(
      path: AppRoutes.settings,
      builder: (context, state) => const SettingsScreen(),
    ),

    // Family sharing
    GoRoute(
      path: AppRoutes.family,
      builder: (context, state) => const FamilyScreen(),
    ),

    // Export data
    GoRoute(
      path: AppRoutes.export,
      builder: (context, state) => const ExportScreen(),
    ),
  ],
  errorBuilder: (context, state) => Scaffold(
    body: Center(
      child: Text('Page not found: ${state.uri.path}'),
    ),
  ),
);

