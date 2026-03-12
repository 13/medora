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
import 'package:medora/data/local/db_setup.dart' if (dart.library.html) 'package:medora/data/local/db_setup_web.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/presentation/providers/settings_providers.dart';
import 'package:medora/presentation/router/app_router.dart';
import 'package:medora/services/connectivity_service.dart';
import 'package:medora/services/reminder_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> main() async {
  // 1. Ensure Flutter is ready as soon as possible
  WidgetsFlutterBinding.ensureInitialized();

  // 2. Setup database factory (fast)
  setupDatabaseFactory();

  // 3. Initialize essential configuration in parallel
  // We only await things that are absolutely required for the first frame or app stability
  final results = await Future.wait([
    SharedPreferences.getInstance(),
    dotenv.load(fileName: '.env').catchError((e) {
      debugPrint('⚠ Failed to load .env: $e');
      return null;
    }),
  ]);

  final prefs = results[0] as SharedPreferences;

  // 4. Initialize Supabase. 
  // We await this because the AuthGuard depends on the client being available.
  // However, we don't await network-dependent tasks inside Supabase.initialize.
  await _initSafe('Supabase', () => SupabaseConfig.initialize());

  // 5. Defer non-critical services to background
  // This removes the largest bottlenecks from app startup (Connectivity checks, Timezone loading)
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
  unawaited(ConnectivityService.instance.initialize());
  
  // Notification/Timezone initialization is heavy, run in background
  unawaited(ReminderService.instance.initialize());
  
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
      routerConfig: appRouter,
      builder: (context, child) {
        // Set navigation context for notification handling
        ReminderService.setNavigationContext(context);
        return child ?? const SizedBox.shrink();
      },
    );
  }
}
