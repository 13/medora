/// Medora - Home Medicine Cabinet Manager
///
/// Core constants used throughout the application.
library;

import 'package:medora/l10n/generated/app_localizations.dart';

class AppConstants {
  AppConstants._();

  // App Info
  static const String appName = 'Medora';
  static const String appVersion = '1.0.0';

  // Supabase Table Names
  static const String usersTable = 'users';
  static const String medicationsTable = 'medications';
  static const String treatmentsTable = 'treatments';
  static const String prescriptionsTable = 'prescriptions';
  static const String doseLogsTable = 'dose_logs';

  // Default Values
  static const int defaultMinimumStock = 0;
  static const int expiryWarningDays = 30;
  static const int lowStockThreshold = 1;

  // Medication Categories (keys — translated via l10n)
  static const List<String> medicationCategoryKeys = [
    'painkiller',
    'antibiotic',
    'antihistamine',
    'vitamin',
    'supplement',
    'cold_flu',
    'digestive',
    'skin_care',
    'eye_care',
    'first_aid',
    'other',
  ];

  /// Get the localized name for a category key.
  static String categoryLabel(AppLocalizations l10n, String key) {
    switch (key) {
      case 'painkiller':
        return l10n.catPainkiller;
      case 'antibiotic':
        return l10n.catAntibiotic;
      case 'antihistamine':
        return l10n.catAntihistamine;
      case 'vitamin':
        return l10n.catVitamin;
      case 'supplement':
        return l10n.catSupplement;
      case 'cold_flu':
        return l10n.catColdFlu;
      case 'digestive':
        return l10n.catDigestive;
      case 'skin_care':
        return l10n.catSkinCare;
      case 'eye_care':
        return l10n.catEyeCare;
      case 'first_aid':
        return l10n.catFirstAid;
      case 'other':
        return l10n.catOther;
      default:
        return key;
    }
  }

  // Storage Locations (keys — translated via l10n)
  static const List<String> storageLocationKeys = [
    'medicine_cabinet',
    'bathroom',
    'kitchen',
    'bedroom',
    'refrigerator',
    'first_aid_kit',
    'other',
  ];

  /// Get the localized name for a storage location key.
  static String storageLabel(AppLocalizations l10n, String key) {
    switch (key) {
      case 'medicine_cabinet':
        return l10n.locMedicineCabinet;
      case 'bathroom':
        return l10n.locBathroom;
      case 'kitchen':
        return l10n.locKitchen;
      case 'bedroom':
        return l10n.locBedroom;
      case 'refrigerator':
        return l10n.locRefrigerator;
      case 'first_aid_kit':
        return l10n.locFirstAidKit;
      case 'other':
        return l10n.locOther;
      default:
        return key;
    }
  }
}
