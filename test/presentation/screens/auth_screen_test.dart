import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/core/supabase_config.dart';
import 'package:medora/presentation/providers/app_mode_provider.dart';
import 'package:medora/presentation/providers/settings_providers.dart';
import 'package:medora/presentation/screens/auth/auth_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/pump_app.dart';

void main() {
  testWidgets('unconfigured build shows only the local-only path and selecting it sets AppMode.localOnly',
      (tester) async {
    SupabaseConfig.resetForTest();
    SharedPreferences.setMockInitialValues({'app_mode': 'cloud'});
    final prefs = await SharedPreferences.getInstance();

    final container = await pumpMedoraApp(
      tester,
      const AuthScreen(),
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
    );
    await tester.pumpAndSettle();

    expect(container.read(appModeProvider), AppMode.cloud);
    expect(find.text('Use Medora on this device'), findsOneWidget);
    expect(find.byType(TextFormField), findsNothing); // no cloud form without config

    await tester.tap(find.text('Use Medora on this device'));
    await tester.pumpAndSettle();

    expect(container.read(appModeProvider), AppMode.localOnly);
    expect(prefs.getString('app_mode'), 'localOnly');
  });
}
