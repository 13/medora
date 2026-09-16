/// The Krankenstand block on the treatment detail screen.
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
import 'package:medora/presentation/screens/treatment/treatment_detail_screen.dart';
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

  Future<void> seedAndPump(
    WidgetTester tester, {
    DateTime? from,
    DateTime? to,
    String? ref,
    String? doctor,
    Locale locale = const Locale('en'),
    double scale = 1.0,
  }) async {
    await TreatmentLocalDatasource().upsert(
      TreatmentModel(
        id: 't1',
        name: 'Sinusitis',
        startDate: DateTime(2026, 3, 3),
        sickLeaveFrom: from,
        sickLeaveTo: to,
        sickLeaveRef: ref,
        doctor: doctor,
      ),
      syncStatus: 'synced',
    );
    await pumpMedoraApp(
      tester,
      withTextScale(scale, const TreatmentDetailScreen(treatmentId: 't1')),
      overrides: await overrides(),
      locale: locale,
    );
    await tester.pumpAndSettle();
  }

  Finder inBlock(Finder f) =>
      find.descendant(of: find.byKey(const Key('sickLeaveBlock')), matching: f);

  testWidgets('a closed sick leave shows its range, length, certificate and '
      'doctor', (tester) async {
    await seedAndPump(
      tester,
      from: DateTime(2026, 3, 3),
      to: DateTime(2026, 3, 9),
      ref: '1234567890',
      doctor: 'Dr. Rossi, Bozen',
    );

    expect(find.byKey(const Key('sickLeaveBlock')), findsOneWidget);
    expect(inBlock(find.text('Sick leave')), findsOneWidget);
    expect(inBlock(find.text('Mar 3, 2026')), findsOneWidget);
    expect(inBlock(find.text('Mar 9, 2026')), findsOneWidget);
    expect(inBlock(find.text('7 days')), findsOneWidget);
    expect(inBlock(find.text('1234567890')), findsOneWidget);
    expect(inBlock(find.text('Dr. Rossi, Bozen')), findsOneWidget);
  });

  testWidgets('an open sick leave counts up to today and reads "Ongoing"', (
    tester,
  ) async {
    await seedAndPump(tester, from: DateTime(2026, 3, 3));
    expect(inBlock(find.text('Ongoing')), findsOneWidget);
    expect(inBlock(find.text('3 days')), findsOneWidget);
  });

  testWidgets('a one-day leave reads "1 day"', (tester) async {
    await seedAndPump(
      tester,
      from: DateTime(2026, 3, 4),
      to: DateTime(2026, 3, 4),
    );
    expect(inBlock(find.text('1 day')), findsOneWidget);
  });

  testWidgets('an open leave that has not started shows no length', (
    tester,
  ) async {
    await seedAndPump(tester, from: DateTime(2026, 3, 10));
    expect(tester.takeException(), isNull);
    expect(inBlock(find.text('Mar 10, 2026')), findsOneWidget);
    expect(inBlock(find.text('Duration')), findsNothing);
  });

  testWidgets('a leave that ends before it starts shows no length', (
    tester,
  ) async {
    await seedAndPump(
      tester,
      from: DateTime(2026, 3, 9),
      to: DateTime(2026, 3, 3),
    );
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('sickLeaveBlock')), findsOneWidget);
    expect(inBlock(find.text('Duration')), findsNothing);
  });

  testWidgets('a doctor alone shows the block without sick-leave rows', (
    tester,
  ) async {
    await seedAndPump(tester, doctor: 'Dr. Rossi');
    expect(inBlock(find.text('Dr. Rossi')), findsOneWidget);
    expect(inBlock(find.text('Unable to work from')), findsNothing);
  });

  testWidgets('a treatment without sick leave or doctor has no block', (
    tester,
  ) async {
    await seedAndPump(tester);
    expect(find.text('Sinusitis'), findsWidgets);
    expect(find.byKey(const Key('sickLeaveBlock')), findsNothing);
  });

  group('layout at 360 dp', () {
    setUpAll(loadAppFonts);

    for (final locale in const ['de', 'it', 'en']) {
      testWidgets('every row of the block stays whole in $locale at 1.6x', (
        tester,
      ) async {
        usePhone(tester);
        await seedAndPump(
          tester,
          from: DateTime(2026, 3, 3),
          to: DateTime(2026, 3, 29),
          ref: '1234567890',
          doctor: 'Dr. Rossi, Bozen',
          locale: Locale(locale),
          scale: 1.6,
        );
        await tester.scrollUntilVisible(
          find.byKey(const Key('sickLeaveBlock')),
          100,
        );

        final texts = inBlock(find.byType(Text));
        final count = texts.evaluate().length;
        expect(count, greaterThanOrEqualTo(11));
        for (var i = 0; i < count; i++) {
          final text = texts.at(i);
          final data = tester.widget<Text>(text).data;
          final fit = measureText(tester, text);
          expect(
            fit.minIntrinsic,
            lessThanOrEqualTo(fit.maxWidth + 0.5),
            reason: '"$data" is broken mid-word: $fit',
          );
        }
      });
    }
  });
}
