import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/core/result.dart';
import 'package:medora/domain/entities/rx.dart';
import 'package:medora/domain/entities/rx_dispensing.dart';
import 'package:medora/domain/repositories/rx_repository.dart';
import 'package:medora/domain/rx/rx_rules.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/presentation/providers/now_provider.dart';
import 'package:medora/presentation/providers/providers.dart';
import 'package:medora/presentation/providers/settings_providers.dart';
import 'package:medora/presentation/screens/rx/redeem_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../helpers/fake_reminder_port.dart';
import '../../../helpers/test_database.dart';

class _Repo implements RxRepository {
  final redeemed = <List<RxDispensing>>[];
  int stockFailures = 0;

  @override
  Future<Result<RedeemOutcome>> redeem(
    String rxId,
    List<RxDispensing> d,
  ) async {
    redeemed.add(d);
    return Result.success(RedeemOutcome(stockFailures: stockFailures));
  }

  @override
  Future<Result<Rx>> saveRx(Rx rx) async => Result.success(rx);
  @override
  Future<Result<List<RxWithDispensings>>> getAll() async =>
      const Result.success([]);
  @override
  Future<Result<RxWithDispensings>> getById(String id) async =>
      const Result.failure('none');
  @override
  Future<Result<List<RxWithDispensings>>> getForTreatment(String id) async =>
      const Result.success([]);
  @override
  Future<Result<void>> deleteRx(String id) async => const Result.success(null);
  @override
  Future<Result<void>> undoDispensing(String id) async =>
      const Result.success(null);
}

void main() {
  setUp(() async {
    await setUpTestDatabase();
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(tearDownTestDatabase);

  test('proposed units multiply packs by the pack size in the description', () {
    const item = RxItem(id: 'i', description: 'Tachipirina 20 compresse');
    expect(proposedUnits(item, 2), 40);
  });

  test('without a pack size the packs themselves are proposed', () {
    const item = RxItem(id: 'i', description: 'Sciroppo 150 ml');
    expect(proposedUnits(item, 2), 2);
  });

  Future<_Repo> pump(
    WidgetTester tester,
    RxWithDispensings entry, {
    Size size = const Size(360, 640),
    double viewInsetsBottom = 0,
    int stockFailures = 0,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    final repo = _Repo()..stockFailures = stockFailures;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          rxRepositoryProvider.overrideWithValue(repo),
          nowProvider.overrideWithValue(() => DateTime(2026, 9, 23)),
          // Confirming a redeem invalidates the rx providers, which now also
          // re-plans the stock scheduler (Task 11): it needs real prefs and
          // a fake notification port rather than the platform plugin.
          sharedPreferencesProvider.overrideWithValue(
            await SharedPreferences.getInstance(),
          ),
          reminderPortProvider.overrideWithValue(FakePort()),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: Consumer(
            builder: (context, ref, _) => Scaffold(
              body: Builder(
                builder: (context) => Center(
                  child: ElevatedButton(
                    onPressed: () => showRedeemSheet(context, ref, entry),
                    child: const Text('open'),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    // The keyboard opens once the sheet is already up, as it would when the
    // pharmacy field or a packs field gets focus.
    tester.view.viewInsets = FakeViewPadding(bottom: viewInsetsBottom);
    await tester.pumpAndSettle();
    return repo;
  }

  RxWithDispensings entryWith(int itemCount) => RxWithDispensings(
    Rx(
      id: 'rx1',
      kind: RxKind.ssn,
      issuedOn: DateTime(2026, 9),
      createdAt: DateTime(2026, 9),
      items: [
        for (var i = 0; i < itemCount; i++)
          RxItem(id: 'i$i', description: 'Item $i', packs: 2),
      ],
    ),
    const [],
  );

  testWidgets(
    'a small surface with the keyboard open does not overflow and Save '
    'is reachable',
    (tester) async {
      await pump(tester, entryWith(3), viewInsetsBottom: 300);
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.byKey(const Key('rx_redeem_save')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('rx_redeem_save')), findsOneWidget);
    },
  );

  testWidgets('Save starts enabled: the default packs is the full count', (
    tester,
  ) async {
    await pump(tester, entryWith(1));
    final save = tester.widget<FilledButton>(
      find.byKey(const Key('rx_redeem_save')),
    );
    expect(save.onPressed, isNotNull);
  });

  testWidgets('unchecking the only line disables Save', (tester) async {
    final repo = await pump(tester, entryWith(1));
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pumpAndSettle();
    final save = tester.widget<FilledButton>(
      find.byKey(const Key('rx_redeem_save')),
    );
    expect(save.onPressed, isNull);

    // Confirms the disabled button truly cannot be used to redeem.
    await tester.tap(
      find.byKey(const Key('rx_redeem_save')),
      warnIfMissed: false,
    );
    await tester.pumpAndSettle();
    expect(repo.redeemed, isEmpty);
  });

  testWidgets('a non-repeatable prescription flags more packs than remain and '
      'disables Save', (tester) async {
    await pump(tester, entryWith(1));
    await tester.enterText(find.byKey(const Key('rx_redeem_packs_0')), '3');
    await tester.pumpAndSettle();
    expect(find.text('More than prescribed'), findsOneWidget);
    final save = tester.widget<FilledButton>(
      find.byKey(const Key('rx_redeem_save')),
    );
    expect(save.onPressed, isNull);
  });

  testWidgets(
    'entering more than what remains after a partial collection flags it, '
    'entering exactly what remains does not',
    (tester) async {
      final entry = RxWithDispensings(
        Rx(
          id: 'rx1',
          kind: RxKind.ssn,
          issuedOn: DateTime(2026, 9),
          createdAt: DateTime(2026, 9),
          items: const [RxItem(id: 'i0', description: 'Item 0', packs: 3)],
        ),
        [
          RxDispensing(
            id: 'd0',
            rxId: 'rx1',
            itemId: 'i0',
            packs: 2,
            dispensedOn: DateTime(2026, 9, 10),
          ),
        ],
      );
      await pump(tester, entry);

      // 1 pack remains (3 prescribed, 2 already collected).
      await tester.enterText(find.byKey(const Key('rx_redeem_packs_0')), '2');
      await tester.pumpAndSettle();
      expect(find.text('More than prescribed'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('rx_redeem_save')))
            .onPressed,
        isNull,
      );

      await tester.enterText(find.byKey(const Key('rx_redeem_packs_0')), '1');
      await tester.pumpAndSettle();
      expect(find.text('More than prescribed'), findsNothing);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('rx_redeem_save')))
            .onPressed,
        isNotNull,
      );
    },
  );

  testWidgets('a repeatable prescription is not capped at what remains', (
    tester,
  ) async {
    final entry = RxWithDispensings(
      Rx(
        id: 'rx1',
        kind: RxKind.whiteRepeatable,
        issuedOn: DateTime(2026, 9),
        createdAt: DateTime(2026, 9),
        maxDispensings: 5,
        items: const [RxItem(id: 'i0', description: 'Item 0', packs: 2)],
      ),
      const [],
    );
    await pump(tester, entry);
    await tester.enterText(find.byKey(const Key('rx_redeem_packs_0')), '9');
    await tester.pumpAndSettle();
    expect(find.text('More than prescribed'), findsNothing);
    final save = tester.widget<FilledButton>(
      find.byKey(const Key('rx_redeem_save')),
    );
    expect(save.onPressed, isNotNull);
  });

  RxWithDispensings linked() => RxWithDispensings(
    Rx(
      id: 'rx1',
      kind: RxKind.ssn,
      issuedOn: DateTime(2026, 9),
      createdAt: DateTime(2026, 9),
      items: const [
        RxItem(id: 'i0', medicationId: 'm1', description: 'Item 0'),
      ],
    ),
    const [],
  );

  testWidgets('units to add are never negative: the server would refuse the '
      'row for ever', (tester) async {
    final repo = await pump(tester, linked());
    await tester.enterText(
      find.widgetWithText(TextField, 'Units to add'),
      '-5',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('rx_redeem_save')));
    await tester.pumpAndSettle();
    expect(repo.redeemed.single.single.unitsAdded, 5);
  });

  testWidgets('a collection whose stock change failed says so', (tester) async {
    await pump(tester, linked(), stockFailures: 1);
    await tester.tap(find.byKey(const Key('rx_redeem_save')));
    await tester.pumpAndSettle();
    expect(
      find.text('Collected, but the stock could not be updated'),
      findsOneWidget,
    );
  });
}
