import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/core/platform_capabilities.dart';
import 'package:medora/domain/entities/medication.dart';
import 'package:medora/presentation/providers/medication_providers.dart';
import 'package:medora/presentation/providers/providers.dart';
import 'package:medora/presentation/providers/settings_providers.dart';
import 'package:medora/presentation/screens/medication/medication_detail_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/fake_reminder_port.dart';
import '../../helpers/pump_app.dart';

class _Failing extends MedicationListNotifier {
  @override
  Future<List<Medication>> build() async => throw StateError('db down');
}

void main() {
  testWidgets(
    'medication detail screen keeps AppBar when medications fail to load',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final overrides = <Override>[
        sharedPreferencesProvider.overrideWithValue(prefs),
        syncStartupDelayProvider.overrideWithValue(Duration.zero),
        reminderPortProvider.overrideWithValue(FakePort()),
        platformCapabilitiesProvider.overrideWithValue(
          PlatformCapabilities.mobile,
        ),
        medicationListProvider.overrideWith(_Failing.new),
      ];

      await pumpMedoraApp(
        tester,
        const MedicationDetailScreen(medicationId: 'x'),
        overrides: overrides,
      );
      await tester.pump();

      expect(find.byType(AppBar), findsOneWidget);
      expect(find.text('Something went wrong'), findsOneWidget);
    },
  );
}
