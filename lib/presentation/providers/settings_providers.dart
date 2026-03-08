/// Medora - Settings Providers
///
/// Persisted providers for theme mode, locale, and security preferences.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ── Keys ──────────────────────────────────────────────────────
const _kThemeMode = 'theme_mode';
const _kLocale = 'locale';
const _kColorScheme = 'color_scheme';
const _kBiometricsEnabled = 'biometrics_enabled';

// ── SharedPreferences provider ───────────────────────────────
final sharedPreferencesProvider = Provider<SharedPreferences>(
  (ref) => throw UnimplementedError(
    'sharedPreferencesProvider must be overridden in main()',
  ),
);

// ── Theme Mode ───────────────────────────────────────────────
final themeModeProvider =
    NotifierProvider<ThemeModeNotifier, ThemeMode>(ThemeModeNotifier.new);

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
final localeProvider =
    NotifierProvider<LocaleNotifier, Locale?>(LocaleNotifier.new);

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
    NotifierProvider<ColorSchemeNotifier, AppColorScheme>(ColorSchemeNotifier.new);

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
    NotifierProvider<BiometricsEnabledNotifier, bool>(BiometricsEnabledNotifier.new);

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

// ── App Version ─────────────────────────────────────────────
final appVersionProvider = FutureProvider<String>((ref) async {
  final packageInfo = await PackageInfo.fromPlatform();
  return packageInfo.version;
});
