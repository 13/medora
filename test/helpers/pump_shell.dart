/// The whole app through the real router, local-only, for tests that open
/// the four main tabs from the bottom bar.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:medora/core/platform_capabilities.dart';
import 'package:medora/core/provider_retry.dart';
import 'package:medora/core/theme.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/presentation/providers/providers.dart';
import 'package:medora/presentation/providers/settings_providers.dart';
import 'package:medora/presentation/router/app_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_reminder_port.dart';
import 'fake_scanner_ports.dart';

/// The four main tabs, in bottom-bar order.
const mainTabs = ['Dashboard', 'Medications', 'Treatments', 'Doses'];

/// Pumps the app shell at [size] with [locale] and [textScale] applied to
/// every route, and settles. Needs `setUpTestDatabase()` and
/// `SupabaseConfig.resetForTest()` in the caller's `setUp`.
Future<ProviderContainer> pumpShell(
  WidgetTester tester, {
  Size size = const Size(412, 915),
  Locale locale = const Locale('en'),
  double textScale = 1.0,
  PlatformCapabilities caps = PlatformCapabilities.mobile,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final previousLocale = Intl.defaultLocale;
  Intl.defaultLocale = locale.languageCode;
  addTearDown(() => Intl.defaultLocale = previousLocale);
  SharedPreferences.setMockInitialValues({
    'app_mode': 'localOnly',
    'onboarding_seen': true,
    'biometrics_enabled': false,
  });
  final container = ProviderContainer(
    retry: medoraRetry,
    overrides: [
      sharedPreferencesProvider.overrideWithValue(
        await SharedPreferences.getInstance(),
      ),
      syncStartupDelayProvider.overrideWithValue(Duration.zero),
      reminderPortProvider.overrideWithValue(FakePort()),
      platformCapabilitiesProvider.overrideWithValue(caps),
      ...scannerOverrides(camera: FakeCamera(opens: false)),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: Consumer(
        builder: (context, ref, _) => MaterialApp.router(
          theme: AppTheme.lightThemeFrom(const Color(0xFF2E7D6F)),
          locale: locale,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          routerConfig: ref.watch(appRouterProvider),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

/// Taps the bottom-bar destination at [index] and settles.
Future<void> openTab(WidgetTester tester, int index) async {
  await tester.tap(find.byType(NavigationDestination).at(index));
  await tester.pumpAndSettle();
}

/// Runs [body] with Flutter errors collected instead of failing the test,
/// for layouts whose page body is known to overflow at a large text scale.
/// Returns each error's summary and context.
Future<List<String>> collectFlutterErrors(Future<void> Function() body) async {
  final errors = <String>[];
  final previous = FlutterError.onError;
  FlutterError.onError = (details) => errors.add(
    details.toStringShort() +
        (details.informationCollector?.call() ?? const [])
            .map((n) => n.toString())
            .join('\n'),
  );
  try {
    await body();
  } finally {
    FlutterError.onError = previous;
  }
  return errors;
}
