/// Medora - Build-time configuration.
///
/// Values come from `--dart-define` (or `--dart-define-from-file`).
/// When absent, the app runs in local-only mode and cloud sync is unavailable.
library;

class AppConfig {
  const AppConfig({
    required this.supabaseUrl,
    required this.supabaseAnonKey,
    required this.updateRepo,
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
    );
  }

  /// Where in-app updates come from unless `--dart-define=UPDATE_REPO` says
  /// otherwise. A Play Store build must pass an empty value: Play forbids
  /// apps that update themselves.
  static const defaultUpdateRepo = '13/medora';

  final String supabaseUrl;
  final String supabaseAnonKey;

  /// `<owner>/<name>` of the GitHub repository that publishes the releases.
  final String updateRepo;

  /// True when the build carries a complete Supabase configuration.
  bool get isCloudAvailable =>
      supabaseUrl.trim().isNotEmpty && supabaseAnonKey.trim().isNotEmpty;

  /// True when this build may look for updates on GitHub.
  bool get hasInAppUpdates => updateRepo.trim().isNotEmpty;
}
