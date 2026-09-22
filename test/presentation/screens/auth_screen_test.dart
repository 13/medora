import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/core/supabase_config.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/presentation/providers/app_mode_provider.dart';
import 'package:medora/presentation/providers/auth_providers.dart';
import 'package:medora/presentation/providers/now_provider.dart';
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

/// A sign-up whose outcome the test chooses, and which counts the resends.
class _SignUpController extends AuthController {
  _SignUpController(this.outcome, {this.signUpError});

  final SignUpOutcome outcome;
  final Object? signUpError;
  int resends = 0;

  @override
  Future<SignUpOutcome> signUpWithEmail(String email, String password) async {
    if (signUpError != null) {
      state = AsyncError(signUpError!, StackTrace.empty);
      return SignUpOutcome.failed;
    }
    state = const AsyncData(null);
    return outcome;
  }

  @override
  Future<void> resendConfirmation(String email) async {
    resends++;
    state = const AsyncData(null);
  }
}

/// A clock the test winds forward, so the resend cooldown can be waited out
/// without the test waiting a minute.
DateTime _now = DateTime.utc(2026, 9, 22, 9);

/// Fills the form and presses the button named [button].
Future<void> _submitForm(WidgetTester tester, String button) async {
  await tester.enterText(find.byType(TextFormField).first, 'new@example.test');
  await tester.enterText(find.byType(TextFormField).last, 'hunter22');
  await tester.tap(find.text(button));
  await tester.pumpAndSettle();
}

/// Pumps the cloud form with [controller] behind it.
Future<void> _pumpCloudForm(
  WidgetTester tester,
  AuthController Function() controller, {
  User? user,
}) async {
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
      authControllerProvider.overrideWith(controller),
      nowProvider.overrideWithValue(() => _now),
      if (user != null) currentUserProvider.overrideWithValue(user),
    ],
  );
  await tester.pumpAndSettle();
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

  group('registering says what happened', () {
    testWidgets('a sign-up with no session says to check the e-mail', (
      tester,
    ) async {
      // What e-mail confirmation does: the account exists, there is no
      // session yet. Before this, the screen showed nothing at all.
      await _pumpCloudForm(
        tester,
        () => _SignUpController(SignUpOutcome.confirmationRequired),
      );

      await tester.tap(find.text("Don't have an account? Sign Up"));
      await tester.pumpAndSettle();
      await _submitForm(tester, 'Sign Up');

      expect(find.text('Check your e-mail'), findsOneWidget);
      expect(find.textContaining('new@example.test'), findsOneWidget);
      expect(find.text('Send it again'), findsOneWidget);
      // The form is gone: there is nothing useful to do with it now.
      expect(find.byType(TextFormField), findsNothing);
    });

    testWidgets('a sign-up that signs the user in claims the local rows', (
      tester,
    ) async {
      await _pumpCloudForm(
        tester,
        () => _SignUpController(SignUpOutcome.signedIn),
        user: _signedInUser,
      );

      await tester.tap(find.text("Don't have an account? Sign Up"));
      await tester.pumpAndSettle();
      await _submitForm(tester, 'Sign Up');

      // No "check your e-mail" detour when there is a session.
      expect(find.text('Check your e-mail'), findsNothing);
    });

    testWidgets('a resend inside the cooldown never reaches the server', (
      tester,
    ) async {
      _now = DateTime.utc(2026, 9, 22, 9);
      final controller = _SignUpController(SignUpOutcome.confirmationRequired);
      await _pumpCloudForm(tester, () => controller);

      await tester.tap(find.text("Don't have an account? Sign Up"));
      await tester.pumpAndSettle();
      await _submitForm(tester, 'Sign Up');

      // The sign-up already sent one, so the cooldown is running: pressing
      // now is refused here rather than spending the attempt on a request
      // Supabase would rate-limit anyway.
      await tester.tap(find.text('Send it again'));
      await tester.pumpAndSettle();
      expect(controller.resends, 0, reason: 'the cooldown did not hold');
      expect(find.textContaining('You can ask for another in'), findsOneWidget);

      // A minute later it goes through. The refusal's snackbar has to be let
      // go first: ScaffoldMessenger shows one at a time and queues the rest,
      // so the next one would not be on screen to find.
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      _now = _now.add(const Duration(seconds: 61));
      await tester.tap(find.text('Send it again'));
      await tester.pumpAndSettle();
      expect(controller.resends, 1);
      expect(find.text('Confirmation e-mail sent again'), findsOneWidget);
    });

    testWidgets('a taken e-mail reads as a sentence, not an exception', (
      tester,
    ) async {
      await _pumpCloudForm(
        tester,
        () => _SignUpController(
          SignUpOutcome.failed,
          signUpError: const AuthApiException(
            'User already registered',
            statusCode: '400',
          ),
        ),
      );

      await tester.tap(find.text("Don't have an account? Sign Up"));
      await tester.pumpAndSettle();
      await _submitForm(tester, 'Sign Up');

      expect(
        find.text('That e-mail already has an account. Sign in instead.'),
        findsOneWidget,
      );
      expect(find.textContaining('AuthApiException'), findsNothing);
    });

    testWidgets('being offline says so', (tester) async {
      await _pumpCloudForm(
        tester,
        () => _SignUpController(
          SignUpOutcome.failed,
          signUpError: const SocketException('failed host lookup'),
        ),
      );

      await tester.tap(find.text("Don't have an account? Sign Up"));
      await tester.pumpAndSettle();
      await _submitForm(tester, 'Sign Up');

      expect(
        find.text('No connection. Check your network and try again.'),
        findsOneWidget,
      );
    });
  });
}
