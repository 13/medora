import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/core/platform_capabilities.dart';
import 'package:medora/core/supabase_config.dart';
import 'package:medora/presentation/providers/providers.dart';
import 'package:medora/presentation/providers/settings_providers.dart';
import 'package:medora/presentation/screens/settings/settings_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/fake_reminder_port.dart';
import '../../helpers/pump_app.dart';
import '../../helpers/test_database.dart';

void main() {
  setUp(() async {
    SupabaseConfig.resetForTest();
    await setUpTestDatabase();
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(tearDownTestDatabase);

  testWidgets(
    'local-only desktop shows the grouped sections without Security or Advanced',
    (tester) async {
      await pumpMedoraApp(
        tester,
        const SettingsScreen(),
        overrides: [
          sharedPreferencesProvider.overrideWithValue(
            await SharedPreferences.getInstance(),
          ),
          syncStartupDelayProvider.overrideWithValue(Duration.zero),
          reminderPortProvider.overrideWithValue(FakePort()),
          platformCapabilitiesProvider.overrideWithValue(
            PlatformCapabilities.desktop,
          ),
        ],
      );
      await tester.pumpAndSettle();

      for (final title in [
        'Appearance',
        'Notifications',
        'Data',
        'Cloud sync',
        'Danger Zone',
        'About',
      ]) {
        await tester.scrollUntilVisible(
          find.text(title),
          200,
          scrollable: find.byType(Scrollable).first,
        );
        expect(find.text(title), findsOneWidget, reason: title);
      }
      expect(find.text('Security'), findsNothing);
      expect(find.text('Advanced'), findsNothing);
    },
  );
}
