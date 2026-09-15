/// Medora - Settings Providers
///
/// Persisted providers for theme mode, locale, and security preferences.
library;

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:medora/core/app_config.dart';
import 'package:medora/core/cloud_credentials_prefs.dart';
import 'package:medora/core/supabase_config.dart';
import 'package:medora/presentation/providers/app_config_provider.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ── Keys ──────────────────────────────────────────────────────
const _kThemeMode = 'theme_mode';
const _kLocale = 'locale';
const _kColorScheme = 'color_scheme';
const _kBiometricsEnabled = 'biometrics_enabled';
const _kRemindersEnabled = 'reminders_enabled';

// ── SharedPreferences provider ───────────────────────────────
final sharedPreferencesProvider = Provider<SharedPreferences>(
  (ref) => throw UnimplementedError(
    'sharedPreferencesProvider must be overridden in main()',
  ),
);

// ── Theme Mode ───────────────────────────────────────────────
final themeModeProvider = NotifierProvider<ThemeModeNotifier, ThemeMode>(
  ThemeModeNotifier.new,
);

class ThemeModeNotifier extends Notifier<ThemeMode> {
  @override
  ThemeMode build() {
    final prefs = ref.watch(sharedPreferencesProvider);
    final stored = prefs.getString(_kThemeMode);
    return switch (stored) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
  }

  Future<void> set(ThemeMode mode) async {
    state = mode;
    final prefs = ref.read(sharedPreferencesProvider);
    await prefs.setString(_kThemeMode, mode.name);
  }
}

// ── Locale ───────────────────────────────────────────────────
final localeProvider = NotifierProvider<LocaleNotifier, Locale?>(
  LocaleNotifier.new,
);

class LocaleNotifier extends Notifier<Locale?> {
  @override
  Locale? build() {
    final prefs = ref.watch(sharedPreferencesProvider);
    final stored = prefs.getString(_kLocale);
    if (stored == null) return null; // system default
    return Locale(stored);
  }

  Future<void> set(Locale? locale) async {
    state = locale;
    final prefs = ref.read(sharedPreferencesProvider);
    if (locale == null) {
      await prefs.remove(_kLocale);
    } else {
      await prefs.setString(_kLocale, locale.languageCode);
    }
  }
}

// ── Color Scheme ─────────────────────────────────────────────

/// Available color scheme options.
enum AppColorScheme {
  teal(Color(0xFF2E7D6F)),
  blue(Color(0xFF1976D2)),
  indigo(Color(0xFF3F51B5)),
  purple(Color(0xFF7B1FA2)),
  pink(Color(0xFFE91E63)),
  red(Color(0xFFE53935)),
  orange(Color(0xFFF57C00)),
  green(Color(0xFF388E3C));

  const AppColorScheme(this.color);
  final Color color;
}

final colorSchemeProvider =
    NotifierProvider<ColorSchemeNotifier, AppColorScheme>(
      ColorSchemeNotifier.new,
    );

class ColorSchemeNotifier extends Notifier<AppColorScheme> {
  @override
  AppColorScheme build() {
    final prefs = ref.watch(sharedPreferencesProvider);
    final stored = prefs.getString(_kColorScheme);
    if (stored == null) return AppColorScheme.teal;
    return AppColorScheme.values.firstWhere(
      (e) => e.name == stored,
      orElse: () => AppColorScheme.teal,
    );
  }

  Future<void> set(AppColorScheme scheme) async {
    state = scheme;
    final prefs = ref.read(sharedPreferencesProvider);
    await prefs.setString(_kColorScheme, scheme.name);
  }
}

// ── Biometrics Setting ───────────────────────────────────────
final biometricsEnabledProvider =
    NotifierProvider<BiometricsEnabledNotifier, bool>(
      BiometricsEnabledNotifier.new,
    );

class BiometricsEnabledNotifier extends Notifier<bool> {
  @override
  bool build() {
    final prefs = ref.watch(sharedPreferencesProvider);
    // Default is OFF per user request
    return prefs.getBool(_kBiometricsEnabled) ?? false;
  }

  Future<void> set(bool enabled) async {
    state = enabled;
    final prefs = ref.read(sharedPreferencesProvider);
    await prefs.setBool(_kBiometricsEnabled, enabled);
  }
}

// ── Reminders Setting ────────────────────────────────────────
final remindersEnabledProvider =
    NotifierProvider<RemindersEnabledNotifier, bool>(
      RemindersEnabledNotifier.new,
    );

class RemindersEnabledNotifier extends Notifier<bool> {
  @override
  bool build() {
    final prefs = ref.watch(sharedPreferencesProvider);
    // Default is ON
    return prefs.getBool(_kRemindersEnabled) ?? true;
  }

  Future<void> set(bool enabled) async {
    state = enabled;
    final prefs = ref.read(sharedPreferencesProvider);
    await prefs.setBool(_kRemindersEnabled, enabled);
  }
}

// ── Missed-dose grace period ─────────────────────────────────
const _kMissedGraceMinutes = 'missed_grace_minutes';
const kMissedGraceOptions = [30, 60, 120, 240];

final missedGraceMinutesProvider =
    NotifierProvider<MissedGraceMinutesNotifier, int>(
      MissedGraceMinutesNotifier.new,
    );

class MissedGraceMinutesNotifier extends Notifier<int> {
  @override
  int build() {
    final prefs = ref.watch(sharedPreferencesProvider);
    return prefs.getInt(_kMissedGraceMinutes) ?? 120;
  }

  Future<void> set(int minutes) async {
    state = minutes;
    await ref
        .read(sharedPreferencesProvider)
        .setInt(_kMissedGraceMinutes, minutes);
  }
}

// ── App Version ─────────────────────────────────────────────
final appVersionProvider = FutureProvider<String>((ref) async {
  final packageInfo = await PackageInfo.fromPlatform();
  return packageInfo.version;
});

// ── Build info (About section) ────────────────────────────────

/// Everything the About screen shows: the package version alongside the
/// build metadata baked in via `--dart-define` (empty/`'dev'` for a local
/// build — see [AppConfig]).
class BuildInfo {
  const BuildInfo({
    required this.version,
    required this.buildNumber,
    required this.buildDate,
    required this.gitSha,
    required this.channel,
    required this.dartVersion,
  });

  final String version;
  final String buildNumber;
  final String buildDate;
  final String gitSha;
  final String channel;
  final String dartVersion;
}

final buildInfoProvider = FutureProvider<BuildInfo>((ref) async {
  final packageInfo = await PackageInfo.fromPlatform();
  final config = ref.watch(appConfigProvider);
  return BuildInfo(
    version: packageInfo.version,
    buildNumber: packageInfo.buildNumber,
    buildDate: config.buildDate,
    gitSha: config.gitSha,
    channel: config.buildChannel,
    dartVersion: kIsWeb ? 'web' : Platform.version.split(' ').first,
  );
});

// ── Runtime cloud configuration ───────────────────────────────

/// The Supabase credentials entered in Settings, or null when this device has
/// none (the build's `--dart-define` values, if any, are then used instead).
final cloudCredentialsProvider =
    NotifierProvider<CloudCredentialsNotifier, CloudCredentials?>(
      CloudCredentialsNotifier.new,
    );

class CloudCredentialsNotifier extends Notifier<CloudCredentials?> {
  @override
  CloudCredentials? build() =>
      readCloudCredentials(ref.watch(sharedPreferencesProvider));

  /// Stores [credentials] on this device. The key is never logged.
  Future<void> save(CloudCredentials credentials) async {
    final normalized = credentials.normalized;
    final prefs = ref.read(sharedPreferencesProvider);
    await prefs.setString(CloudCredentials.prefsUrlKey, normalized.url);
    await prefs.setString(CloudCredentials.prefsKeyKey, normalized.anonKey);
    state = normalized;
  }

  /// Forgets the credentials stored on this device.
  Future<void> clear() async {
    final prefs = ref.read(sharedPreferencesProvider);
    await prefs.remove(CloudCredentials.prefsUrlKey);
    await prefs.remove(CloudCredentials.prefsKeyKey);
    state = null;
  }
}

/// The client the "Test connection" button uses; overridden in tests.
final cloudHttpClientProvider = Provider<http.Client>((ref) {
  final client = http.Client();
  ref.onDispose(client.close);
  return client;
});

/// Applies freshly saved credentials to the running app.
///
/// Returns true when cloud sync is usable right away, false when Supabase was
/// already initialized and the change needs a restart. Overridden in tests so
/// they never touch `Supabase.initialize`.
final cloudActivatorProvider =
    Provider<Future<bool> Function(CloudCredentials)>((ref) {
      final config = ref.watch(appConfigProvider);
      return (credentials) async {
        if (SupabaseConfig.isConfigured) {
          SupabaseConfig.pendingRestart = true;
          return false;
        }
        await SupabaseConfig.initialize(config, override: credentials);
        return SupabaseConfig.isConfigured;
      };
    });

/// Asks a Supabase project whether it answers for these credentials.
Future<bool> probeCloudCredentials(
  http.Client client,
  CloudCredentials credentials,
) async {
  final response = await client.get(
    Uri.parse('${credentials.normalizedUrl}/auth/v1/settings'),
    headers: {'apikey': credentials.normalizedKey},
  );
  return response.statusCode == 200;
}
