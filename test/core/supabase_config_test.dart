import 'package:flutter_test/flutter_test.dart';
import 'package:medora/core/app_config.dart';
import 'package:medora/core/errors.dart';
import 'package:medora/core/supabase_config.dart';

const _noConfig = AppConfig(
  supabaseUrl: '',
  supabaseAnonKey: '',
  updateRepo: '',
  buildDate: '',
  gitSha: '',
  buildChannel: 'dev',
);

const _definesConfig = AppConfig(
  supabaseUrl: 'https://defines.supabase.co',
  supabaseAnonKey: 'defines-key',
  updateRepo: '',
  buildDate: '',
  gitSha: '',
  buildChannel: 'dev',
);

void main() {
  setUp(SupabaseConfig.resetForTest);

  test(
    'initialize without config leaves Supabase unconfigured and never throws',
    () async {
      await SupabaseConfig.initialize(_noConfig);
      expect(SupabaseConfig.isConfigured, isFalse);
      expect(SupabaseConfig.configuredFrom, CloudConfigSource.none);
      expect(SupabaseConfig.clientOrNull, isNull);
      expect(SupabaseConfig.currentUserId, isNull);
      expect(SupabaseConfig.isAuthenticated, isFalse);
      expect(SupabaseConfig.requireClient, throwsA(isA<AuthException>()));
    },
  );

  test('initialize with an incomplete override stays unconfigured', () async {
    await SupabaseConfig.initialize(
      _noConfig,
      override: const CloudCredentials(
        url: 'https://a.supabase.co',
        anonKey: '',
      ),
    );
    expect(SupabaseConfig.isConfigured, isFalse);
    expect(SupabaseConfig.configuredFrom, CloudConfigSource.none);
  });

  group('resolve', () {
    test('settings credentials win over the dart-defines', () {
      final resolved = SupabaseConfig.resolve(
        _definesConfig,
        override: const CloudCredentials(
          url: 'https://settings.supabase.co/',
          anonKey: ' settings-key ',
        ),
      );
      expect(resolved.source, CloudConfigSource.settings);
      expect(
        resolved.credentials?.normalizedUrl,
        'https://settings.supabase.co',
      );
      expect(resolved.credentials?.normalizedKey, 'settings-key');
    });

    test('an incomplete or absent override falls back to the defines', () {
      for (final override in <CloudCredentials?>[
        null,
        const CloudCredentials(
          url: 'https://settings.supabase.co',
          anonKey: '',
        ),
        const CloudCredentials(url: 'nonsense', anonKey: 'settings-key'),
      ]) {
        final resolved = SupabaseConfig.resolve(
          _definesConfig,
          override: override,
        );
        expect(resolved.source, CloudConfigSource.defines);
        expect(
          resolved.credentials?.normalizedUrl,
          'https://defines.supabase.co',
        );
      }
    });

    test('nothing configured resolves to none', () {
      final resolved = SupabaseConfig.resolve(_noConfig);
      expect(resolved.source, CloudConfigSource.none);
      expect(resolved.credentials, isNull);
    });
  });

  test('resetForTest clears the restart flag', () {
    SupabaseConfig.pendingRestart = true;
    SupabaseConfig.resetForTest();
    expect(SupabaseConfig.pendingRestart, isFalse);
    expect(SupabaseConfig.configuredFrom, CloudConfigSource.none);
  });

  group('debugSetConfiguredForTest', () {
    tearDown(SupabaseConfig.resetForTest);

    test('reports configured without ever reaching for a client', () {
      SupabaseConfig.debugSetConfiguredForTest(true);

      expect(SupabaseConfig.isConfigured, isTrue);
      expect(SupabaseConfig.configuredFrom, CloudConfigSource.settings);
      // `Supabase.instance` throws when initialize never ran, so the getters
      // that would touch it must answer without it.
      expect(SupabaseConfig.clientOrNull, isNull);
      expect(SupabaseConfig.currentUserId, isNull);
      expect(SupabaseConfig.isAuthenticated, isFalse);
      expect(SupabaseConfig.requireClient, throwsA(isA<Exception>()));
    });

    test('false, and resetForTest, put it back', () {
      SupabaseConfig.debugSetConfiguredForTest(true);
      SupabaseConfig.debugSetConfiguredForTest(false);

      expect(SupabaseConfig.isConfigured, isFalse);
      expect(SupabaseConfig.clientOrNull, isNull);
    });
  });
}
