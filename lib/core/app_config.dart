/// Medora - Build-time configuration.
///
/// Values come from `--dart-define` (or `--dart-define-from-file`).
/// When absent, the app runs in local-only mode and cloud sync is unavailable.
library;

import 'package:shared_preferences/shared_preferences.dart';

class AppConfig {
  const AppConfig({
    required this.supabaseUrl,
    required this.supabaseAnonKey,
    required this.updateRepo,
    required this.buildDate,
    required this.gitSha,
    required this.buildChannel,
  });

  /// Read from compile-time environment. Supabase defaults to empty strings.
  factory AppConfig.fromEnvironment() {
    return const AppConfig(
      supabaseUrl: String.fromEnvironment('SUPABASE_URL'),
      supabaseAnonKey: String.fromEnvironment('SUPABASE_ANON_KEY'),
      updateRepo: String.fromEnvironment(
        'UPDATE_REPO',
        defaultValue: defaultUpdateRepo,
      ),
      buildDate: String.fromEnvironment('BUILD_DATE'),
      gitSha: String.fromEnvironment('GIT_SHA'),
      buildChannel: String.fromEnvironment(
        'BUILD_CHANNEL',
        defaultValue: defaultBuildChannel,
      ),
    );
  }

  /// Where in-app updates come from unless `--dart-define=UPDATE_REPO` says
  /// otherwise. A Play Store build must pass an empty value: Play forbids
  /// apps that update themselves.
  static const defaultUpdateRepo = '13/medora';

  /// Build channel unless `--dart-define=BUILD_CHANNEL` says otherwise: any
  /// build not produced by a workflow (a local `flutter build` / `flutter
  /// run`) is a development build.
  static const defaultBuildChannel = 'dev';

  final String supabaseUrl;
  final String supabaseAnonKey;

  /// `<owner>/<name>` of the GitHub repository that publishes the releases.
  final String updateRepo;

  /// ISO-8601 UTC timestamp set by CI/release workflows, or `''` for a local
  /// build.
  final String buildDate;

  /// The short (7+ char) commit SHA the build was made from, or `''` for a
  /// local build.
  final String gitSha;

  /// `'release'`, `'ci'`, or `'dev'` (the default for a local build).
  final String buildChannel;

  /// True when the build carries a complete Supabase configuration.
  bool get isCloudAvailable =>
      supabaseUrl.trim().isNotEmpty && supabaseAnonKey.trim().isNotEmpty;

  /// True when this build may look for updates on GitHub.
  bool get hasInAppUpdates => updateRepo.trim().isNotEmpty;
}

/// Supabase credentials entered in Settings and kept in `SharedPreferences`.
///
/// The anon/publishable key is public by design, but it still never leaves the
/// device and is never logged.
class CloudCredentials {
  const CloudCredentials({required this.url, required this.anonKey});

  /// Reads the pair stored by Settings, or null when either half is missing.
  static CloudCredentials? fromPrefs(SharedPreferences prefs) {
    final url = prefs.getString(prefsUrlKey)?.trim() ?? '';
    final key = prefs.getString(prefsKeyKey)?.trim() ?? '';
    if (url.isEmpty || key.isEmpty) return null;
    return CloudCredentials(url: url, anonKey: key);
  }

  /// `SharedPreferences` key holding the project URL.
  static const prefsUrlKey = 'cloud.supabase_url';

  /// `SharedPreferences` key holding the anon/publishable key.
  static const prefsKeyKey = 'cloud.supabase_anon_key';

  /// True for an https URL with a host: `https://<ref>.supabase.co` for a
  /// hosted project, any https host for a self-hosted one.
  static bool isValidUrl(String url) {
    final parsed = Uri.tryParse(url.trim());
    return parsed != null && parsed.scheme == 'https' && parsed.host.isNotEmpty;
  }

  final String url;
  final String anonKey;

  /// The URL as Supabase wants it: trimmed, without a trailing slash.
  String get normalizedUrl {
    final trimmed = url.trim();
    return trimmed.endsWith('/')
        ? trimmed.substring(0, trimmed.length - 1)
        : trimmed;
  }

  /// The key as stored: trimmed, never logged or displayed.
  String get normalizedKey => anonKey.trim();

  /// True when both halves are present and the URL is usable.
  bool get isComplete => isValidUrl(url) && normalizedKey.isNotEmpty;

  /// A copy with both halves normalized.
  CloudCredentials get normalized =>
      CloudCredentials(url: normalizedUrl, anonKey: normalizedKey);

  @override
  bool operator ==(Object other) =>
      other is CloudCredentials && other.url == url && other.anonKey == anonKey;

  @override
  int get hashCode => Object.hash(url, anonKey);

  /// Deliberately omits the key.
  @override
  String toString() => 'CloudCredentials($normalizedUrl)';
}
