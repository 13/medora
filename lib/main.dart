/// Medora - Home Medicine Cabinet Manager
///
/// Main entry point for the application.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:medora/core/app_config.dart';
import 'package:medora/core/supabase_config.dart';
import 'package:medora/core/theme.dart';
import 'package:medora/data/local/db_setup.dart' if (dart.library.html) 'package:medora/data/local/db_setup_web.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/presentation/providers/settings_providers.dart';
import 'package:medora/presentation/router/app_router.dart';
import 'package:medora/services/connectivity_service.dart';
import 'package:medora/services/reminder_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  setupDatabaseFactory();

  final prefs = await SharedPreferences.getInstance();

  // Cloud is optional: this is a no-op when no dart-defines are present.
  await _initSafe('Supabase', () => SupabaseConfig.initialize(AppConfig.fromEnvironment()));

  _initServicesInBackground();

  runApp(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
      ],
      child: const MedoraApp(),
    ),
  );
}

/// Start non-critical services without blocking the initial UI render.
void _initServicesInBackground() {
  // Connectivity check can be slow on some devices, so we run it in background
  unawaited(_initSafe('Connectivity', ConnectivityService.instance.initialize));

  // Notification/Timezone initialization is heavy, run in background
  unawaited(_initSafe('Reminders', ReminderService.instance.initialize));

  // Note: Database opening is now lazy and will happen when the first data provider needs it.
}

/// Safe initialization helper — catches and logs errors.
Future<void> _initSafe(String name, Future<dynamic> Function() init) async {
  try {
    await init();
  } catch (e) {
    debugPrint('⚠ Failed to initialize $name: $e');
  }
}

/// Root application widget.
class MedoraApp extends ConsumerWidget {
  const MedoraApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeModeProvider);
    final locale = ref.watch(localeProvider);
    final colorScheme = ref.watch(colorSchemeProvider);

    return MaterialApp.router(
      title: 'Medora',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightThemeFrom(colorScheme.color),
      darkTheme: AppTheme.darkThemeFrom(colorScheme.color),
      themeMode: themeMode,
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      localeResolutionCallback: (device, supported) {
        final resolved = locale ??
            supported.firstWhere((s) => s.languageCode == device?.languageCode, orElse: () => supported.first);
        Intl.defaultLocale = resolved.toLanguageTag();
        return resolved;
      },
      routerConfig: ref.watch(appRouterProvider),
      builder: (context, child) {
        // Set navigation context for notification handling
        ReminderService.setNavigationContext(context);
        return child ?? const SizedBox.shrink();
      },
    );
  }
}
