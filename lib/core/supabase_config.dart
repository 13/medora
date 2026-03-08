/// Medora - Supabase Configuration
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Initialize and configure Supabase client.
class SupabaseConfig {
  SupabaseConfig._();

  static SupabaseClient get client => Supabase.instance.client;

  /// Initialize Supabase with environment variables.
  /// Also ensures the user is signed in (anonymously if needed).
  static Future<void> initialize() async {
    final url = dotenv.env['SUPABASE_URL'] ?? '';
    final anonKey = dotenv.env['SUPABASE_ANON_KEY'] ?? '';
    if (url.isEmpty || anonKey.isEmpty) {
      debugPrint('⚠ Supabase URL or anon key not set — running offline only');
      return;
    }

    await Supabase.initialize(url: url, anonKey: anonKey);

    // Ensure we have an authenticated session for RLS to work.
    // Uses anonymous sign-in: each device gets a persistent user_id
    // that stays across app restarts. Same account can be used
    // on multiple devices by later linking email/password.
    await _ensureAuthenticated();
  }

  /// Sign in anonymously if no session exists.
  /// Anonymous users get a stable UUID that persists in Supabase.
  static Future<void> _ensureAuthenticated() async {
    try {
      final session = client.auth.currentSession;
      if (session != null) {
        debugPrint('✅ Supabase: already signed in as ${session.user.id}');
        return;
      }

      final response = await client.auth.signInAnonymously();
      debugPrint('✅ Supabase: anonymous sign-in as ${response.user?.id}');
    } catch (e) {
      debugPrint('⚠ Supabase auth failed (running offline): $e');
    }
  }

  /// Get the current authenticated user ID, or null.
  static String? get currentUserId => client.auth.currentUser?.id;

  /// Whether we have a valid Supabase session.
  static bool get isAuthenticated => client.auth.currentSession != null;
}

