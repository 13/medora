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
  static Future<void> initialize() async {
    final url = dotenv.env['SUPABASE_URL'] ?? '';
    final anonKey = dotenv.env['SUPABASE_ANON_KEY'] ?? '';
    if (url.isEmpty || anonKey.isEmpty) {
      debugPrint('⚠ Supabase URL or anon key not set — running offline only');
      return;
    }

    await Supabase.initialize(url: url, anonKey: anonKey);
    debugPrint('✅ Supabase initialized');
  }

  /// Get the current authenticated user ID, or null.
  static String? get currentUserId => client.auth.currentUser?.id;

  /// Whether we have a valid Supabase session.
  static bool get isAuthenticated => client.auth.currentSession != null;
}
