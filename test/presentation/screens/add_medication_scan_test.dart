import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:medora/core/platform_capabilities.dart';
import 'package:medora/core/theme.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/presentation/providers/providers.dart';
import 'package:medora/presentation/providers/settings_providers.dart';
import 'package:medora/presentation/router/app_router.dart';
import 'package:medora/presentation/screens/medication/add_medication_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/fake_reminder_port.dart';
import '../../helpers/test_database.dart';

void main() {
  setUp(() async {
    await setUpTestDatabase();
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(tearDownTestDatabase);

  testWidgets(
    'the scan chip opens the scanner in return-only mode and fills the barcode',
    (tester) async {
      final pushed = <Uri>[];
      final router = GoRouter(
        initialLocation: AppRoutes.addMedication,
        routes: [
          GoRoute(
            path: AppRoutes.addMedication,
            builder: (_, _) => const AddMedicationScreen(),
          ),
          GoRoute(
            path: AppRoutes.scanner,
            builder: (context, state) {
              pushed.add(state.uri);
              return Scaffold(
                body: TextButton(
                  onPressed: () => context.pop('8057737141836'),
                  child: const Text('fake scan'),
                ),
              );
            },
          ),
        ],
      );
      addTearDown(router.dispose);
      final prefs = await SharedPreferences.getInstance();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(prefs),
            syncStartupDelayProvider.overrideWithValue(Duration.zero),
            reminderPortProvider.overrideWithValue(FakePort()),
            platformCapabilitiesProvider.overrideWithValue(
              PlatformCapabilities.mobile,
            ),
          ],
          child: MaterialApp.router(
            theme: AppTheme.lightThemeFrom(const Color(0xFF2E7D6F)),
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            routerConfig: router,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byType(ActionChip).first);
      await tester.pumpAndSettle();
      expect(pushed.single.path, AppRoutes.scanner);
      expect(pushed.single.queryParameters['returnOnly'], 'true');

      await tester.tap(find.text('fake scan'));
      await tester.pumpAndSettle();

      expect(find.byType(AddMedicationScreen), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(TextFormField),
          matching: find.text('8057737141836'),
        ),
        findsOneWidget,
      );
    },
  );

  test('every scanner push from Add Medication is return-only', () {
    final source = File(
      'lib/presentation/screens/medication/add_medication_screen.dart',
    ).readAsStringSync();
    final pushes = RegExp(
      r'push<String>\(\s*([^,)]+)',
    ).allMatches(source).map((m) => m.group(1)!.trim()).toList();
    expect(pushes, hasLength(2));
    expect(pushes, everyElement('AppRoutes.scannerReturnOnly'));
    expect(source, isNot(contains('AppRoutes.scanner)')));
    expect(source, isNot(contains('returnOnly=true')));
  });
}
