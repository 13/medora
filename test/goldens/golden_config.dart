import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:medora/core/platform_capabilities.dart';
import 'package:medora/core/theme.dart';
import 'package:medora/domain/entities/dose_log.dart';
import 'package:medora/domain/entities/medication.dart';
import 'package:medora/domain/entities/treatment.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/presentation/providers/dose_providers.dart';
import 'package:medora/presentation/providers/medication_providers.dart';
import 'package:medora/presentation/providers/providers.dart';
import 'package:medora/presentation/providers/settings_providers.dart';
import 'package:medora/presentation/providers/treatment_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fake_reminder_port.dart';

final goldenNow = DateTime(2026, 3, 4, 15); // Wednesday
final goldenToday = DateTime(2026, 3, 4);

final goldenMedications = <Medication>[
  Medication(
    id: 'm1',
    name: 'Tachipirina 1000',
    quantity: 12,
    quantityUnit: 'tablets',
    expiryDate: DateTime(2026, 3, 20),
    category: 'painkiller',
  ),
  Medication(
    id: 'm2',
    name: 'Moment 200',
    quantity: 1,
    quantityUnit: 'tablets',
    minimumStockLevel: 3,
    // Far future on purpose: Medication.isExpiringSoon/isExpired read the
    // real DateTime.now() (they bypass nowProvider), so a near-future date
    // would flip the Home golden's Expiring Soon card to a populated,
    // daily-changing state once "today" caught up. These goldens only cover
    // the empty Expiring Soon state.
    expiryDate: DateTime(2099),
    category: 'painkiller',
  ),
  Medication(
    id: 'm3',
    name: 'Bentelan',
    quantity: 8,
    quantityUnit: 'tablets',
    expiryDate: DateTime(2025, 12),
    category: 'other',
  ),
];

final goldenTreatments = <Treatment>[
  Treatment(
    id: 't1',
    name: 'Influenza',
    patientTags: const ['Ben'],
    symptomTags: const ['fever', 'cough'],
    startDate: DateTime(2026, 3, 2),
  ),
];

List<DoseLog> goldenDoses() => [
  DoseLog(
    id: 'd1',
    prescriptionId: 'p1',
    scheduledTime: goldenToday.add(const Duration(hours: 8)),
    status: DoseStatus.taken,
    takenTime: goldenToday.add(const Duration(hours: 8, minutes: 5)),
    medicationName: 'Tachipirina 1000',
    dosageAmount: 1,
    medicationUnit: 'tablets',
    treatmentName: 'Influenza',
    patientTags: const ['Ben'],
  ),
  DoseLog(
    id: 'd2',
    prescriptionId: 'p1',
    scheduledTime: goldenToday.add(const Duration(hours: 14)),
    medicationName: 'Tachipirina 1000',
    dosageAmount: 1,
    medicationUnit: 'tablets',
    treatmentName: 'Influenza',
    patientTags: const ['Ben'],
  ),
  DoseLog(
    id: 'd3',
    prescriptionId: 'p1',
    scheduledTime: goldenToday.add(const Duration(hours: 20)),
    medicationName: 'Tachipirina 1000',
    dosageAmount: 1,
    medicationUnit: 'tablets',
    treatmentName: 'Influenza',
    patientTags: const ['Ben'],
  ),
];

/// Pumps [home] at 412×915 @1x with fixed data and clock. Golden files live
/// next to the test.
Future<void> pumpGolden(
  WidgetTester tester,
  Widget home, {
  required Brightness brightness,
}) async {
  tester.view.physicalSize = const Size(412, 915);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  Intl.defaultLocale = 'en';
  SharedPreferences.setMockInitialValues({'onboarding_seen': true});
  final prefs = await SharedPreferences.getInstance();

  final overrides = <Override>[
    sharedPreferencesProvider.overrideWithValue(prefs),
    syncStartupDelayProvider.overrideWithValue(Duration.zero),
    reminderPortProvider.overrideWithValue(FakePort()),
    platformCapabilitiesProvider.overrideWithValue(PlatformCapabilities.mobile),
    nowProvider.overrideWithValue(() => goldenNow),
    medicationListProvider.overrideWith(_FixedMedications.new),
    treatmentListProvider.overrideWith(_FixedTreatments.new),
    todaysDoseLogsProvider.overrideWith(_FixedTodaysDoses.new),
    dosesForDayProvider.overrideWith(
      (ref, day) async => day == goldenToday ? goldenDoses() : <DoseLog>[],
    ),
  ];

  await tester.pumpWidget(
    ProviderScope(
      overrides: overrides,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.lightThemeFrom(const Color(0xFF2E7D6F)),
        darkTheme: AppTheme.darkThemeFrom(const Color(0xFF2E7D6F)),
        themeMode: brightness == Brightness.dark
            ? ThemeMode.dark
            : ThemeMode.light,
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: home,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

class _FixedMedications extends MedicationListNotifier {
  @override
  Future<List<Medication>> build() async => goldenMedications;
}

class _FixedTreatments extends TreatmentListNotifier {
  @override
  Future<List<Treatment>> build() async => goldenTreatments;
}

class _FixedTodaysDoses extends TodaysDoseLogsNotifier {
  @override
  Future<List<DoseLog>> build() async => goldenDoses();
}
