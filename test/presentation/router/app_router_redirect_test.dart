import 'package:flutter_test/flutter_test.dart';
import 'package:medora/presentation/providers/app_mode_provider.dart';
import 'package:medora/presentation/router/app_router.dart';

void main() {
  group('computeRedirect', () {
    test('local-only never goes to /auth and leaves /auth for home', () {
      expect(
        computeRedirect(
          mode: AppMode.localOnly,
          hasSession: false,
          location: '/',
        ),
        isNull,
      );
      expect(
        computeRedirect(
          mode: AppMode.localOnly,
          hasSession: false,
          location: '/medications/add',
        ),
        isNull,
      );
      expect(
        computeRedirect(
          mode: AppMode.localOnly,
          hasSession: false,
          location: '/auth',
        ),
        '/',
      );
    });

    test('cloud without session goes to /auth', () {
      expect(
        computeRedirect(mode: AppMode.cloud, hasSession: false, location: '/'),
        '/auth',
      );
      expect(
        computeRedirect(
          mode: AppMode.cloud,
          hasSession: false,
          location: '/settings',
        ),
        '/auth',
      );
      expect(
        computeRedirect(
          mode: AppMode.cloud,
          hasSession: false,
          location: '/auth',
        ),
        isNull,
      );
    });

    test('cloud with session stays, and leaves /auth for home', () {
      expect(
        computeRedirect(
          mode: AppMode.cloud,
          hasSession: true,
          location: '/doses',
        ),
        isNull,
      );
      expect(
        computeRedirect(
          mode: AppMode.cloud,
          hasSession: true,
          location: '/auth',
        ),
        '/',
      );
    });
  });
}
