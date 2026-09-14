/// Medora - Supabase Configuration
///
/// Never throws on access: when the build has no Supabase configuration,
/// [clientOrNull] is null and [isConfigured] is false.
library;

import 'package:flutter/foundation.dart';
import 'package:medora/core/app_config.dart';
import 'package:medora/core/errors.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide AuthException;

class SupabaseConfig {
  SupabaseConfig._();

  static bool _initialized = false;

  /// True after a successful [initialize] with a complete [AppConfig].
  static bool get isConfigured => _initialized;

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

  /// Initialize Supabase if [config] is complete. Safe to call without config.
  static Future<void> initialize(AppConfig config) async {
    if (_initialized) return;
    if (!config.isCloudAvailable) {
      debugPrint('ℹ Supabase not configured — local-only build');
      return;
    }
    await Supabase.initialize(
      url: config.supabaseUrl,
      // ignore: deprecated_member_use
      anonKey: config.supabaseAnonKey,
    );
    _initialized = true;
    debugPrint('✅ Supabase initialized');
  }

  /// Get the current authenticated user ID, or null.
  static String? get currentUserId => clientOrNull?.auth.currentUser?.id;

  /// Whether we have a valid Supabase session.
  static bool get isAuthenticated => clientOrNull?.auth.currentSession != null;

  /// Test-only: forget initialization state.
  @visibleForTesting
  static void resetForTest() => _initialized = false;
}
