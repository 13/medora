import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/core/result.dart';
import 'package:medora/domain/entities/person.dart';
import 'package:medora/domain/entities/rx.dart';
import 'package:medora/domain/entities/rx_dispensing.dart';
import 'package:medora/domain/repositories/rx_repository.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/presentation/providers/now_provider.dart';
import 'package:medora/presentation/providers/providers.dart';
import 'package:medora/presentation/providers/rx_providers.dart';
import 'package:medora/presentation/screens/rx/rx_form_screen.dart';

class _Repo implements RxRepository {
  _Repo({this.refuse});
  final String? refuse;
  final saved = <Rx>[];

  @override
  Future<Result<Rx>> saveRx(Rx rx) async {
    if (refuse != null) return Result.failure('$duplicateNrePrefix$refuse');
    saved.add(rx);
    return Result.success(rx);
  }

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
  Future<Result<void>> redeem(String id, List<RxDispensing> d) async =>
      const Result.success(null);
  @override
  Future<Result<void>> undoDispensing(String id) async =>
      const Result.success(null);
}

void main() {
  Future<_Repo> pump(WidgetTester tester, {String? refuse}) async {
    final repo = _Repo(refuse: refuse);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          rxRepositoryProvider.overrideWithValue(repo),
          personsProvider.overrideWith(
            (ref) async => const [Person(id: 'p1', name: 'Ben')],
          ),
          nowProvider.overrideWithValue(() => DateTime(2026, 9, 23, 10)),
        ],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: Locale('en'),
          home: RxFormScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return repo;
  }

  // The form has more fields than fit the test viewport, so the Save button
  // sits below the fold. A focused text field also makes the scrollable
  // snap back to keep it on screen, so focus is dropped first; only then is
  // scrolling the button into view reliable enough to tap.
  Future<void> save(WidgetTester tester) async {
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    await tester.dragUntilVisible(
      find.byKey(const Key('rx_save')),
      find.byType(ListView),
      const Offset(0, -200),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('rx_save')));
    await tester.pumpAndSettle();
  }

  testWidgets('an SSN prescription gets a 30-day validity by default', (
    tester,
  ) async {
    final repo = await pump(tester);
    await tester.enterText(find.byKey(const Key('rx_nre')), '0410A1234567890');
    await save(tester);
    final rx = repo.saved.single;
    expect(rx.issuedOn, DateTime(2026, 9, 23));
    expect(rx.validUntil, DateTime(2026, 10, 23));
    expect(rx.nre, '0410A1234567890');
  });

  testWidgets('a malformed NRE is refused', (tester) async {
    final repo = await pump(tester);
    await tester.enterText(find.byKey(const Key('rx_nre')), '12345');
    await save(tester);
    expect(find.text('15 letters or digits'), findsOneWidget);
    expect(repo.saved, isEmpty);
  });

  testWidgets('a duplicate NRE shows a message with a link', (tester) async {
    await pump(tester, refuse: 'r0');
    await tester.enterText(find.byKey(const Key('rx_nre')), '0410A1234567890');
    await save(tester);
    expect(
      find.text('This prescription number is already saved'),
      findsOneWidget,
    );
    expect(find.text('Open'), findsOneWidget);
  });

  testWidgets('an item can be added with packs', (tester) async {
    final repo = await pump(tester);
    await tester.enterText(find.byKey(const Key('rx_nre')), '0410A1234567890');
    await tester.tap(find.byKey(const Key('rx_add_item')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('rx_item_description_0')),
      'Brufen 400',
    );
    await tester.enterText(find.byKey(const Key('rx_item_packs_0')), '2');
    await save(tester);
    expect(repo.saved.single.items.single.description, 'Brufen 400');
    expect(repo.saved.single.items.single.packs, 2);
  });
}
