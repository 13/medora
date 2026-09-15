import 'package:flutter_test/flutter_test.dart';
import 'package:medora/core/app_config.dart';

void main() {
  group('AppConfig', () {
    test('isCloudAvailable is false when either value is empty', () {
      expect(
        const AppConfig(
          supabaseUrl: '',
          supabaseAnonKey: '',
          updateRepo: '',
        ).isCloudAvailable,
        isFalse,
      );
      expect(
        const AppConfig(
          supabaseUrl: 'https://x.supabase.co',
          supabaseAnonKey: '',
          updateRepo: '',
        ).isCloudAvailable,
        isFalse,
      );
      expect(
        const AppConfig(
          supabaseUrl: '',
          supabaseAnonKey: 'key',
          updateRepo: '',
        ).isCloudAvailable,
        isFalse,
      );
    });

    test('isCloudAvailable is true when both values are set', () {
      const config = AppConfig(
        supabaseUrl: 'https://x.supabase.co',
        supabaseAnonKey: 'key',
        updateRepo: '',
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
        ).hasInAppUpdates,
        isFalse,
      );
      expect(
        const AppConfig(
          supabaseUrl: '',
          supabaseAnonKey: '',
          updateRepo: '   ',
        ).hasInAppUpdates,
        isFalse,
      );
    });
  });
}
