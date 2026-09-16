/// The sick-leave badge on the dashboard's active treatments card: only an
/// open leave shows, and it never squeezes the treatment's name.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/core/platform_capabilities.dart';
import 'package:medora/data/datasources/treatment_local_datasource.dart';
import 'package:medora/data/models/treatment_model.dart';
import 'package:medora/presentation/providers/now_provider.dart';
import 'package:medora/presentation/providers/providers.dart';
import 'package:medora/presentation/providers/settings_providers.dart';
import 'package:medora/presentation/screens/home/home_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/fake_reminder_port.dart';
import '../../helpers/fonts.dart';
import '../../helpers/pump_app.dart';
import '../../helpers/test_database.dart';
import '../../helpers/text_fit.dart';

void main() {
  final now = DateTime(2026, 3, 5, 12);

  setUp(() async {
    await setUpTestDatabase();
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(tearDownTestDatabase);

  Future<List<Override>> overrides() async => [
    sharedPreferencesProvider.overrideWithValue(
      await SharedPreferences.getInstance(),
    ),
    syncStartupDelayProvider.overrideWithValue(Duration.zero),
    reminderPortProvider.overrideWithValue(FakePort()),
    platformCapabilitiesProvider.overrideWithValue(
      PlatformCapabilities.desktop,
    ),
    nowProvider.overrideWithValue(() => now),
  ];

  Future<void> seed(
    String id,
    String name, {
    DateTime? from,
    DateTime? to,
    List<String> patientTags = const [],
  }) => TreatmentLocalDatasource().upsert(
    TreatmentModel(
      id: id,
      name: name,
      startDate: DateTime(2026, 3, 3),
      sickLeaveFrom: from,
      sickLeaveTo: to,
      patientTags: patientTags,
    ),
    syncStatus: 'synced',
  );

  Future<void> pump(
    WidgetTester tester, {
    Locale locale = const Locale('en'),
    double scale = 1.0,
    Size size = const Size(800, 2400),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await pumpMedoraApp(
      tester,
      withTextScale(scale, const HomeScreen()),
      overrides: await overrides(),
      locale: locale,
    );
    await tester.pumpAndSettle();
  }

  Finder badgeOf(String name) => find.descendant(
    of: find.ancestor(of: find.text(name), matching: find.byType(ListTile)),
    matching: find.byKey(const Key('sickLeaveBadge')),
  );

  Finder badgeTextOf(String name) =>
      find.descendant(of: badgeOf(name), matching: find.byType(Text));

  testWidgets('an open leave shows its day; closed or absent shows nothing', (
    tester,
  ) async {
    await seed('t1', 'Sinusitis', from: DateTime(2026, 3, 3));
    await seed(
      't2',
      'Bronchitis',
      from: DateTime(2026, 2, 3),
      to: DateTime(2026, 3, 4),
    );
    await seed('t3', 'Influenza');
    await pump(tester);

    expect(
      tester.widget<Text>(badgeTextOf('Sinusitis')).data,
      'Sick leave · Day 3',
    );
    expect(find.text('Bronchitis'), findsOneWidget);
    expect(badgeOf('Bronchitis'), findsNothing);
    expect(find.text('Influenza'), findsOneWidget);
    expect(badgeOf('Influenza'), findsNothing);
  });

  testWidgets('a leave that has not started yet shows no badge', (
    tester,
  ) async {
    // The dashboard is about today: a leave planned for next week would
    // read as if the user were off work now. The list still shows it.
    await seed('t1', 'OP-Nachsorge', from: DateTime(2026, 3, 10));
    await pump(tester);
    expect(tester.takeException(), isNull);
    expect(find.text('OP-Nachsorge'), findsOneWidget);
    expect(badgeOf('OP-Nachsorge'), findsNothing);
  });

  testWidgets('a leave that starts today shows day 1', (tester) async {
    await seed('t1', 'OP-Nachsorge', from: DateTime(2026, 3, 5));
    await pump(tester);
    expect(
      tester.widget<Text>(badgeTextOf('OP-Nachsorge')).data,
      'Sick leave · Day 1',
    );
  });

  group('layout at 360 dp', () {
    setUpAll(loadAppFonts);

    for (final locale in const ['de', 'it', 'en']) {
      testWidgets('name and badge stay whole in $locale at 1.6x', (
        tester,
      ) async {
        await seed(
          't1',
          'Sinusitis',
          from: DateTime(2026, 2, 3),
          patientTags: const ['Ben'],
        );
        await pump(
          tester,
          locale: Locale(locale),
          scale: 1.6,
          size: const Size(360, 2400),
        );

        final title = measureText(tester, find.text('Sinusitis'));
        final badge = measureText(tester, badgeTextOf('Sinusitis'));
        printOnFailure('title $title; badge $badge');
        expect(
          title.minIntrinsic,
          lessThanOrEqualTo(title.maxWidth + 0.5),
          reason: 'the name is broken mid-word: $title',
        );
        expect(
          badge.minIntrinsic,
          lessThanOrEqualTo(badge.maxWidth + 0.5),
          reason: 'the badge is broken mid-word: $badge',
        );
        expect(badge.exceeded, isFalse, reason: 'the badge is cut off: $badge');
      });
    }
  });
}
