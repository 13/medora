/// Medora - Home Medicine Cabinet Manager
///
/// Main entry point for the application.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:medora/core/supabase_config.dart';
import 'package:medora/core/theme.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/presentation/providers/settings_providers.dart';
import 'package:medora/presentation/router/app_router.dart';
import 'package:medora/services/connectivity_service.dart';
import 'package:medora/services/reminder_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize SharedPreferences first (needed by settings providers)
  final prefs = await SharedPreferences.getInstance();

  // Load env — needed before Supabase
  try {
    await dotenv.load(fileName: '.env');
  } catch (e) {
    debugPrint('⚠ Failed to load .env: $e');
  }

  // Initialize critical local services in parallel (fast)
  await Future.wait([
    _initSafe('local database', () => AppDatabase.instance.database),
    _initSafe('connectivity', () => ConnectivityService.instance.initialize()),
    _initSafe('notifications', () => ReminderService.instance.initialize()),
  ]);

  // Initialize Supabase in background — don't block app launch
  unawaited(_initSafe('Supabase', () => SupabaseConfig.initialize()));

  runApp(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
      ],
      child: const MedoraApp(),
    ),
  );
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
      routerConfig: appRouter,
    );
  }
}
