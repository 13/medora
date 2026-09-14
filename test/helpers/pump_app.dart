import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/core/theme.dart';
import 'package:medora/l10n/generated/app_localizations.dart';

/// Pumps [home] inside a ProviderScope + MaterialApp configured like main.dart
/// (Inter theme with MedoraColors, l10n delegates). Returns the container.
Future<ProviderContainer> pumpMedoraApp(WidgetTester tester, Widget home, {List<Override> overrides = const [], Brightness brightness = Brightness.light}) async {
  final container = ProviderContainer(overrides: overrides);
  addTearDown(container.dispose);
  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      theme: AppTheme.lightThemeFrom(const Color(0xFF2E7D6F)),
      darkTheme: AppTheme.darkThemeFrom(const Color(0xFF2E7D6F)),
      themeMode: brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: home,
    ),
  ));
  await tester.pump();
  return container;
}
