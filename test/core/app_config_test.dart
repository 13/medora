import 'package:flutter_test/flutter_test.dart';
import 'package:medora/core/app_config.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AppConfig', () {
    test('isCloudAvailable is false when either value is empty', () {
      expect(
        const AppConfig(
          supabaseUrl: '',
          supabaseAnonKey: '',
          updateRepo: '',
          buildDate: '',
          gitSha: '',
          buildChannel: 'dev',
        ).isCloudAvailable,
        isFalse,
      );
      expect(
        const AppConfig(
          supabaseUrl: 'https://x.supabase.co',
          supabaseAnonKey: '',
          updateRepo: '',
          buildDate: '',
          gitSha: '',
          buildChannel: 'dev',
        ).isCloudAvailable,
        isFalse,
      );
      expect(
        const AppConfig(
          supabaseUrl: '',
          supabaseAnonKey: 'key',
          updateRepo: '',
          buildDate: '',
          gitSha: '',
          buildChannel: 'dev',
        ).isCloudAvailable,
        isFalse,
      );
    });

    test('isCloudAvailable is true when both values are set', () {
      const config = AppConfig(
        supabaseUrl: 'https://x.supabase.co',
        supabaseAnonKey: 'key',
        updateRepo: '',
        buildDate: '',
        gitSha: '',
        buildChannel: 'dev',
      );
      expect(config.isCloudAvailable, isTrue);
    });

    test(
      'fromEnvironment defaults to empty strings when no dart-defines are given',
      () {
        final config = AppConfig.fromEnvironment();
        expect(config.supabaseUrl, '');
        expect(config.supabaseAnonKey, '');
        expect(config.isCloudAvailable, isFalse);
      },
    );

    test('updateRepo defaults to the project repository', () {
      expect(AppConfig.fromEnvironment().updateRepo, '13/medora');
      expect(AppConfig.fromEnvironment().hasInAppUpdates, isTrue);
    });

    test('hasInAppUpdates is false when UPDATE_REPO is blanked out', () {
      expect(
        const AppConfig(
          supabaseUrl: '',
          supabaseAnonKey: '',
          updateRepo: '',
          buildDate: '',
          gitSha: '',
          buildChannel: 'dev',
        ).hasInAppUpdates,
        isFalse,
      );
      expect(
        const AppConfig(
          supabaseUrl: '',
          supabaseAnonKey: '',
          updateRepo: '   ',
          buildDate: '',
          gitSha: '',
          buildChannel: 'dev',
        ).hasInAppUpdates,
        isFalse,
      );
    });

    test('buildDate, gitSha and buildChannel default to a local dev build when '
        'no dart-defines are given', () {
      final config = AppConfig.fromEnvironment();
      expect(config.buildDate, '');
      expect(config.gitSha, '');
      expect(config.buildChannel, 'dev');
    });

    test('buildDate, gitSha and buildChannel are stored verbatim', () {
      const config = AppConfig(
        supabaseUrl: '',
        supabaseAnonKey: '',
        updateRepo: '',
        buildDate: '2026-09-15T20:14:00Z',
        gitSha: 'abc1234',
        buildChannel: 'release',
      );
      expect(config.buildDate, '2026-09-15T20:14:00Z');
      expect(config.gitSha, 'abc1234');
      expect(config.buildChannel, 'release');
    });
  });

  group('CloudCredentials', () {
    test('isComplete needs an https URL with a host and a non-empty key', () {
      expect(
        const CloudCredentials(
          url: 'https://abc.supabase.co',
          anonKey: 'key',
        ).isComplete,
        isTrue,
      );
      // Self-hosted hosts are allowed, plain http is not.
      expect(
        const CloudCredentials(
          url: 'https://supabase.example.org',
          anonKey: 'key',
        ).isComplete,
        isTrue,
      );
      expect(
        const CloudCredentials(
          url: 'http://abc.supabase.co',
          anonKey: 'key',
        ).isComplete,
        isFalse,
      );
      expect(
        const CloudCredentials(url: 'https://', anonKey: 'key').isComplete,
        isFalse,
      );
      expect(
        const CloudCredentials(url: 'not a url', anonKey: 'key').isComplete,
        isFalse,
      );
      expect(
        const CloudCredentials(
          url: 'https://abc.supabase.co',
          anonKey: '   ',
        ).isComplete,
        isFalse,
      );
      expect(const CloudCredentials(url: '', anonKey: '').isComplete, isFalse);
    });

    test('normalized values are trimmed and lose a trailing slash', () {
      const creds = CloudCredentials(
        url: '  https://abc.supabase.co/  ',
        anonKey: '  key  ',
      );
      expect(creds.isComplete, isTrue);
      expect(creds.normalizedUrl, 'https://abc.supabase.co');
      expect(creds.normalizedKey, 'key');
    });
  });
}
