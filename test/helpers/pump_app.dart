import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:medora/core/provider_retry.dart';
import 'package:medora/core/theme.dart';
import 'package:medora/l10n/generated/app_localizations.dart';

/// Pumps [home] inside a ProviderScope + MaterialApp configured like main.dart
/// (Inter theme with MedoraColors, l10n delegates). Returns the container.
///
/// [locale] drives both the MaterialApp locale and `Intl.defaultLocale`, so
/// date/number formatting matches the l10n strings.
///
/// [retry] is the container's retry policy, and defaults to [medoraRetry] —
/// the one main.dart installs — so a test sees the same wait before an error
/// shell that a user does. A test that wants no automatic retry at all (to
/// prove that only the Retry button cleared an error, say) passes
/// `(_, _) => null`; passing `null` restores Riverpod's own default.
Future<ProviderContainer> pumpMedoraApp(
  WidgetTester tester,
  Widget home, {
  List<Override> overrides = const [],
  Brightness brightness = Brightness.light,
  Locale locale = const Locale('en'),
  Duration? Function(int retryCount, Object error)? retry = medoraRetry,
}) async {
  final previousLocale = Intl.defaultLocale;
  Intl.defaultLocale = locale.languageCode;
  addTearDown(() => Intl.defaultLocale = previousLocale);
  final container = ProviderContainer(overrides: overrides, retry: retry);
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: AppTheme.lightThemeFrom(const Color(0xFF2E7D6F)),
        darkTheme: AppTheme.darkThemeFrom(const Color(0xFF2E7D6F)),
        themeMode: brightness == Brightness.dark
            ? ThemeMode.dark
            : ThemeMode.light,
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: home,
      ),
    ),
  );
  await tester.pump();
  return container;
}
