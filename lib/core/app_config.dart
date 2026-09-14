/// Medora - Build-time configuration.
///
/// Values come from `--dart-define` (or `--dart-define-from-file`).
/// When absent, the app runs in local-only mode and cloud sync is unavailable.
library;

class AppConfig {
  const AppConfig({required this.supabaseUrl, required this.supabaseAnonKey});

  /// Read from compile-time environment. Both default to empty strings.
  factory AppConfig.fromEnvironment() {
    return const AppConfig(
      supabaseUrl: String.fromEnvironment('SUPABASE_URL'),
      supabaseAnonKey: String.fromEnvironment('SUPABASE_ANON_KEY'),
    );
  }

  final String supabaseUrl;
  final String supabaseAnonKey;

  /// True when the build carries a complete Supabase configuration.
  bool get isCloudAvailable =>
      supabaseUrl.trim().isNotEmpty && supabaseAnonKey.trim().isNotEmpty;
}
