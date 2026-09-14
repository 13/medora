import 'package:flutter_test/flutter_test.dart';
import 'package:medora/core/app_config.dart';
import 'package:medora/core/errors.dart';
import 'package:medora/core/supabase_config.dart';

void main() {
  setUp(SupabaseConfig.resetForTest);

  test(
    'initialize without config leaves Supabase unconfigured and never throws',
    () async {
      await SupabaseConfig.initialize(
        const AppConfig(supabaseUrl: '', supabaseAnonKey: ''),
      );
      expect(SupabaseConfig.isConfigured, isFalse);
      expect(SupabaseConfig.clientOrNull, isNull);
      expect(SupabaseConfig.currentUserId, isNull);
      expect(SupabaseConfig.isAuthenticated, isFalse);
      expect(
        () => SupabaseConfig.requireClient(),
        throwsA(isA<AuthException>()),
      );
    },
  );
}
