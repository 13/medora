import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/presentation/router/app_router.dart';
import 'package:medora/presentation/widgets/settings_action.dart';

void main() {
  late int settingsBuilds;

  Future<void> pump(WidgetTester tester, {Locale locale = const Locale('en')}) {
    settingsBuilds = 0;
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => Scaffold(
            appBar: AppBar(
              title: const Text('Tab'),
              actions: const [SettingsAction()],
            ),
          ),
        ),
        GoRoute(
          path: AppRoutes.settings,
          builder: (_, _) {
            settingsBuilds++;
            return Scaffold(appBar: AppBar(title: const Text('settings page')));
          },
        ),
      ],
    );
    addTearDown(router.dispose);
    return tester.pumpWidget(
      MaterialApp.router(
        routerConfig: router,
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
      ),
    );
  }

  testWidgets('opens Settings', (tester) async {
    await pump(tester);
    await tester.tap(find.byKey(SettingsAction.buttonKey));
    await tester.pumpAndSettle();
    expect(find.text('settings page'), findsOneWidget);
  });

  testWidgets('a double tap opens Settings once', (tester) async {
    await pump(tester);
    await tester.tap(find.byKey(SettingsAction.buttonKey));
    await tester.tap(find.byKey(SettingsAction.buttonKey), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(find.text('settings page'), findsOneWidget);
    // Back lands on the tab, not on a second Settings.
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('settings page'), findsNothing);
    expect(find.text('Tab'), findsOneWidget);
  });

  testWidgets('can be used again after Settings was closed', (tester) async {
    await pump(tester);
    await tester.tap(find.byKey(SettingsAction.buttonKey));
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(SettingsAction.buttonKey));
    await tester.pumpAndSettle();
    expect(find.text('settings page'), findsOneWidget);
    expect(settingsBuilds, greaterThanOrEqualTo(2));
  });

  for (final (locale, label) in const [
    ('en', 'Settings'),
    ('de', 'Einstellungen'),
    ('it', 'Impostazioni'),
  ]) {
    testWidgets('is labelled "$label" for screen readers ($locale)', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      await pump(tester, locale: Locale(locale));
      expect(
        tester.getSemantics(find.byKey(SettingsAction.buttonKey)),
        isSemantics(tooltip: label, isButton: true, hasTapAction: true),
      );
      expect(find.byTooltip(label), findsOneWidget);
      semantics.dispose();
    });
  }

  testWidgets('keeps a 48 dp touch target and the settings icon', (
    tester,
  ) async {
    await pump(tester);
    final size = tester.getSize(find.byKey(SettingsAction.buttonKey));
    expect(size.width, greaterThanOrEqualTo(48));
    expect(size.height, greaterThanOrEqualTo(48));
    expect(
      find.descendant(
        of: find.byKey(SettingsAction.buttonKey),
        matching: find.byIcon(Icons.settings),
      ),
      findsOneWidget,
    );
  });
}
