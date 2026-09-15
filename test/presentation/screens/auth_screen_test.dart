import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/core/supabase_config.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/presentation/providers/app_mode_provider.dart';
import 'package:medora/presentation/providers/auth_providers.dart';
import 'package:medora/presentation/providers/settings_providers.dart';
import 'package:medora/presentation/providers/sync_providers.dart';
import 'package:medora/presentation/screens/auth/auth_screen.dart';
import 'package:medora/services/local_upload_marker.dart';
import 'package:medora/services/sync_cursor_store.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../helpers/fonts.dart';
import '../../helpers/pump_app.dart';

/// A sign-in that always succeeds, so the test never needs a Supabase client.
class _StubAuthController extends AuthController {
  @override
  Future<void> signInWithEmail(String email, String password) async {
    state = const AsyncData(null);
  }
}

/// A marker whose database is unreachable: claiming the local rows throws.
class _FailingMarker extends LocalUploadMarker {
  _FailingMarker(SharedPreferences prefs)
    : super(
        database: AppDatabase.instance,
        cursors: SyncCursorStore(prefs),
        prefs: prefs,
      );

  @override
  Future<bool> hasDataFromAnotherAccount(String userId) async => false;

  @override
  Future<int> markAllForUpload(String userId) async =>
      throw StateError('database is locked');
}

const _signedInUser = User(
  id: 'user-1',
  appMetadata: {},
  userMetadata: {},
  aud: 'authenticated',
  createdAt: '2026-03-04T15:00:00Z',
);

void main() {
  testWidgets(
    'unconfigured build shows only the local-only path and selecting it sets AppMode.localOnly',
    (tester) async {
      SupabaseConfig.resetForTest();
      SharedPreferences.setMockInitialValues({'app_mode': 'cloud'});
      final prefs = await SharedPreferences.getInstance();

      final container = await pumpMedoraApp(
        tester,
        const AuthScreen(),
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      );
      await tester.pumpAndSettle();

      expect(container.read(appModeProvider), AppMode.cloud);
      expect(find.text('Use Medora on this device'), findsOneWidget);
      expect(
        find.byType(TextFormField),
        findsNothing,
      ); // no cloud form without config

      await tester.tap(find.text('Use Medora on this device'));
      await tester.pumpAndSettle();

      expect(container.read(appModeProvider), AppMode.localOnly);
      expect(prefs.getString('app_mode'), 'localOnly');
    },
  );

  group('the "or sign in" divider', () {
    const label = 'Or sign in to sync across devices';

    // Measured, not drawn: without the real face every glyph is a 1-em box
    // and the label is three times the width it has on a device.
    setUpAll(loadAppFonts);

    /// The cloud form on a 412 px phone, at [scale] text size.
    Future<void> pumpAt(WidgetTester tester, double scale) async {
      tester.view.physicalSize = const Size(412, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      SupabaseConfig.debugSetConfiguredForTest(true);
      addTearDown(SupabaseConfig.resetForTest);
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();

      await pumpMedoraApp(
        tester,
        Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: const AuthScreen(),
          ),
        ),
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      );
      await tester.pumpAndSettle();
    }

    testWidgets('fits on one line at normal text size', (tester) async {
      await pumpAt(tester, 1);

      // One line: the laid-out paragraph is no taller than a single line of
      // its own text.
      final paragraph = tester.renderObject<RenderParagraph>(find.text(label));
      expect(
        paragraph.size.height,
        lessThan(paragraph.preferredLineHeight * 1.5),
        reason: 'the divider label wrapped',
      );
    });

    testWidgets('gives way instead of overflowing at 2x', (tester) async {
      await pumpAt(tester, 2);

      expect(find.text(label), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('a sign-in that cannot claim the local rows says so', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SupabaseConfig.debugSetConfiguredForTest(true);
    addTearDown(SupabaseConfig.resetForTest);
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();

    await pumpMedoraApp(
      tester,
      const AuthScreen(),
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        authControllerProvider.overrideWith(_StubAuthController.new),
        currentUserProvider.overrideWithValue(_signedInUser),
        localUploadMarkerProvider.overrideWithValue(_FailingMarker(prefs)),
      ],
    );
    await tester.pumpAndSettle();

    // A configured build offers the cloud form alongside the local path.
    expect(find.byType(TextFormField), findsNWidgets(2));
    await tester.enterText(find.byType(TextFormField).first, 'a@example.test');
    await tester.enterText(find.byType(TextFormField).last, 'hunter22');
    await tester.tap(find.text('Sign In'));
    await tester.pumpAndSettle();

    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.textContaining('database is locked'), findsOneWidget);
  });
}
