/// Notification handling no longer stores a BuildContext: taps navigate
/// through the app's GoRouter and strings resolve through a locale seam.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:medora/presentation/router/app_router.dart';
import 'package:medora/services/reminder_service.dart';

void main() {
  tearDown(() {
    ReminderService.router = null;
    ReminderService.localeResolver = null;
  });

  testWidgets('a notification tap routes to /doses through the router', (
    tester,
  ) async {
    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(path: '/', builder: (_, _) => const Text('home')),
        GoRoute(path: '/doses', builder: (_, _) => const Text('doses')),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    expect(find.text('home'), findsOneWidget);

    ReminderService.router = router;
    ReminderService.instance.handleNotificationTap('dose-1');
    await tester.pumpAndSettle();

    expect(router.routerDelegate.currentConfiguration.uri.path, '/doses');
    expect(find.text('doses'), findsOneWidget);
  });

  testWidgets('a prescription alert opens that prescription', (tester) async {
    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(path: '/', builder: (_, _) => const Text('home')),
        GoRoute(path: '/doses', builder: (_, _) => const Text('doses')),
        GoRoute(
          path: AppRoutes.rxDetail,
          builder: (_, state) => Text('rx ${state.pathParameters['id']}'),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));

    ReminderService.router = router;
    ReminderService.instance.handleNotificationTap('rx:r1');
    await tester.pumpAndSettle();

    // A pushed route's `uri` still reads as its base location (`go_router`
    // doesn't rewrite the address for an imperative push), so the pushed
    // screen is asserted through the widget tree instead.
    expect(find.text('rx r1'), findsOneWidget);

    // Home sits under the pushed detail (Task 1): the rx detail route is a
    // leaf inside the shell, so landing there directly via `go` would leave
    // it as the only page — no way back, and nowhere for a delete to pop
    // to. Back must return to home.
    expect(router.canPop(), isTrue);
    router.pop();
    await tester.pumpAndSettle();
    expect(router.routerDelegate.currentConfiguration.uri.path, '/');
    expect(find.text('home'), findsOneWidget);

    // Other payloads still open the doses, as before.
    ReminderService.instance.handleNotificationTap('medication:m1');
    await tester.pumpAndSettle();
    expect(router.routerDelegate.currentConfiguration.uri.path, '/doses');
  });

  test('a tap without a router assigned is a no-op', () {
    ReminderService.router = null;
    expect(
      () => ReminderService.instance.handleNotificationTap('dose-1'),
      returnsNormally,
    );
  });

  testWidgets(
    'a tap before the router is assigned routes once the router arrives',
    (tester) async {
      final router = GoRouter(
        initialLocation: '/',
        routes: [
          GoRoute(path: '/', builder: (_, _) => const Text('home')),
          GoRoute(path: '/doses', builder: (_, _) => const Text('doses')),
        ],
      );
      addTearDown(router.dispose);

      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      expect(find.text('home'), findsOneWidget);

      ReminderService.router = null;
      ReminderService.instance.handleNotificationTap('dose-1');
      expect(
        router.routerDelegate.currentConfiguration.uri.path,
        '/',
        reason: 'no router yet — the route is only remembered',
      );

      ReminderService.router = router;
      await tester.pumpAndSettle();

      expect(router.routerDelegate.currentConfiguration.uri.path, '/doses');
      expect(find.text('doses'), findsOneWidget);
    },
  );

  testWidgets(
    'a prescription alert tapped before the router is assigned still lands '
    'on home under the detail once the router arrives',
    (tester) async {
      final router = GoRouter(
        initialLocation: '/',
        routes: [
          GoRoute(path: '/', builder: (_, _) => const Text('home')),
          GoRoute(path: '/doses', builder: (_, _) => const Text('doses')),
          GoRoute(
            path: AppRoutes.rxDetail,
            builder: (_, state) => Text('rx ${state.pathParameters['id']}'),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(MaterialApp.router(routerConfig: router));

      ReminderService.router = null;
      ReminderService.instance.handleNotificationTap('rx:r1');
      expect(
        router.routerDelegate.currentConfiguration.uri.path,
        '/',
        reason: 'no router yet — the navigation is only remembered',
      );

      ReminderService.router = router;
      await tester.pumpAndSettle();

      expect(find.text('rx r1'), findsOneWidget);
      expect(router.canPop(), isTrue);
      router.pop();
      await tester.pumpAndSettle();
      expect(router.routerDelegate.currentConfiguration.uri.path, '/');
    },
  );

  test('notification titles use the locale from the seam', () {
    ReminderService.localeResolver = () => const Locale('it');
    expect(
      ReminderService.reminderTitle(
        medicationName: 'Moment 200',
        minutesBefore: 0,
      ),
      'È ora di assumere Moment 200',
    );
    expect(
      ReminderService.reminderTitle(
        medicationName: 'Moment 200',
        minutesBefore: 60,
      ),
      'Promemoria: Moment 200 tra 60 min',
    );

    ReminderService.localeResolver = () => const Locale('de');
    expect(
      ReminderService.reminderTitle(
        medicationName: 'Moment 200',
        minutesBefore: 0,
      ),
      'Zeit für Moment 200',
    );
  });

  test('an unsupported locale falls back to the English strings', () {
    ReminderService.localeResolver = () => const Locale('fr');
    expect(
      ReminderService.reminderTitle(
        medicationName: 'Moment 200',
        minutesBefore: 0,
      ),
      'Time for Moment 200',
    );
  });
}
