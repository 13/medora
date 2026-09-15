/// Medora - Supabase Configuration
///
/// Never throws on access: when the build has no Supabase configuration,
/// [clientOrNull] is null and [isConfigured] is false.
library;

import 'package:flutter/foundation.dart';
import 'package:medora/core/app_config.dart';
import 'package:medora/core/errors.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide AuthException;

/// Where the credentials Supabase was initialized with came from.
enum CloudConfigSource {
  /// No usable credentials: the app is local-only.
  none,

  /// Baked into the build with `--dart-define`.
  defines,

  /// Entered in Settings and stored in `SharedPreferences`.
  settings,
}

class SupabaseConfig {
  SupabaseConfig._();

  static bool _initialized = false;
  static CloudConfigSource _source = CloudConfigSource.none;

  /// True after a successful [initialize] with usable credentials.
  static bool get isConfigured => _initialized;

  /// Where the running configuration came from.
  static CloudConfigSource get configuredFrom => _source;

  /// Set when credentials change after Supabase was already initialized:
  /// `Supabase.initialize` runs once per process, so the new values only take
  /// effect after a restart.
  static bool pendingRestart = false;

  /// The Supabase client, or null when cloud is not configured.
  static SupabaseClient? get clientOrNull =>
      _initialized ? Supabase.instance.client : null;

  /// The Supabase client; throws [AuthException] when not configured.
  static SupabaseClient requireClient() {
    final client = clientOrNull;
    if (client == null) {
      throw const AuthException('Cloud sync is not configured');
    }
    return client;
  }

  /// Picks the credentials to run with: complete Settings values win over the
  /// `--dart-define` values, which win over nothing at all.
  @visibleForTesting
  static ({CloudCredentials? credentials, CloudConfigSource source}) resolve(
    AppConfig config, {
    CloudCredentials? override,
  }) {
    if (override != null && override.isComplete) {
      return (
        credentials: override.normalized,
        source: CloudConfigSource.settings,
      );
    }
    if (config.isCloudAvailable) {
      return (
        credentials: CloudCredentials(
          url: config.supabaseUrl,
          anonKey: config.supabaseAnonKey,
        ).normalized,
        source: CloudConfigSource.defines,
      );
    }
    return (credentials: null, source: CloudConfigSource.none);
  }

  /// Initialize Supabase with the first usable credentials of [override] (from
  /// Settings) and [config] (from the build). Safe to call without either.
  static Future<void> initialize(
    AppConfig config, {
    CloudCredentials? override,
  }) async {
    if (_initialized) return;
    final resolved = resolve(config, override: override);
    final credentials = resolved.credentials;
    if (credentials == null) {
      debugPrint('ℹ Supabase not configured — local-only build');
      return;
    }
    await Supabase.initialize(
      url: credentials.normalizedUrl,
      publishableKey: credentials.normalizedKey,
    );
    _initialized = true;
    _source = resolved.source;
    debugPrint('✅ Supabase initialized (${resolved.source.name})');
  }

  /// Get the current authenticated user ID, or null.
  static String? get currentUserId => clientOrNull?.auth.currentUser?.id;

  /// Whether we have a valid Supabase session.
  static bool get isAuthenticated => clientOrNull?.auth.currentSession != null;

  /// Test-only: forget initialization state.
  @visibleForTesting
  static void resetForTest() {
    _initialized = false;
    _source = CloudConfigSource.none;
    pendingRestart = false;
  }
}
