import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/core/result.dart';
import 'package:medora/domain/entities/medication.dart';
import 'package:medora/domain/entities/person.dart';
import 'package:medora/domain/entities/rx.dart';
import 'package:medora/domain/entities/rx_dispensing.dart';
import 'package:medora/domain/repositories/rx_repository.dart';
import 'package:medora/domain/rx/rx_rules.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/l10n/generated/app_localizations_en.dart';
import 'package:medora/presentation/providers/medication_providers.dart';
import 'package:medora/presentation/providers/now_provider.dart';
import 'package:medora/presentation/providers/providers.dart';
import 'package:medora/presentation/providers/rx_providers.dart';
import 'package:medora/presentation/providers/settings_providers.dart';
import 'package:medora/presentation/screens/rx/rx_detail_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../helpers/fake_reminder_port.dart';
import '../../../helpers/test_database.dart';

class _Repo implements RxRepository {
  _Repo({this.byId});
  final Result<RxWithDispensings>? byId;

  @override
  Future<Result<RxWithDispensings>> getById(String id) async =>
      byId ?? const Result.failure('gone');
  @override
  Future<Result<Rx>> saveRx(Rx rx) async => Result.success(rx);
  @override
  Future<Result<List<RxWithDispensings>>> getAll() async =>
      const Result.success([]);
  @override
  Future<Result<List<RxWithDispensings>>> getForTreatment(String id) async =>
      const Result.success([]);
  @override
  Future<Result<void>> deleteRx(String id) async => const Result.success(null);
  @override
  Future<Result<RedeemOutcome>> redeem(String id, List<RxDispensing> d) async =>
      const Result.success(RedeemOutcome());
  @override
  Future<Result<void>> undoDispensing(String id) async =>
      const Result.success(null);
}

/// Always empty, so `_linkMedication` sees a load that resolves but has
/// nothing to offer.
class _EmptyMeds extends MedicationListNotifier {
  @override
  Future<List<Medication>> build() async => const [];
}

/// Always throws, so `_linkMedication` sees a failing load.
class _FailingMeds extends MedicationListNotifier {
  @override
  Future<List<Medication>> build() async => throw StateError('db down');
}

void main() {
  setUp(() async {
    await setUpTestDatabase();
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(tearDownTestDatabase);

  final l10n = AppLocalizationsEn();

  test('share text includes the tax code when there is one on file', () {
    expect(
      rxShareMessage(l10n, '0410A1234567890', 'RSSMRA85T10A562S'),
      'Prescription 0410A1234567890\nTax code RSSMRA85T10A562S',
    );
  });

  test('share text falls back to NRE-only with no tax code on file', () {
    expect(
      rxShareMessage(l10n, '0410A1234567890', null),
      'Prescription 0410A1234567890',
    );
    expect(
      rxShareMessage(l10n, '0410A1234567890', ''),
      'Prescription 0410A1234567890',
    );
  });

  final rx = Rx(
    id: 'rx1',
    personId: 'p1',
    kind: RxKind.ssn,
    nre: '0410A1234567890',
    issuedOn: DateTime(2026, 9),
    items: const [RxItem(id: 'i1', description: 'Brufen 400', packs: 2)],
    createdAt: DateTime(2026, 9),
  );

  Future<void> pump(
    WidgetTester tester, {
    required _Repo repo,
    MedicationListNotifier Function()? meds,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          rxRepositoryProvider.overrideWithValue(repo),
          personsProvider.overrideWith(
            (ref) async => const [Person(id: 'p1', name: 'Ben')],
          ),
          nowProvider.overrideWithValue(() => DateTime(2026, 9, 23)),
          if (meds != null) medicationListProvider.overrideWith(meds),
          // Closing, collecting or deleting invalidates the rx providers,
          // which now also re-plans the stock scheduler (Task 11): it needs
          // real prefs and a fake notification port rather than the
          // platform plugin.
          sharedPreferencesProvider.overrideWithValue(
            await SharedPreferences.getInstance(),
          ),
          reminderPortProvider.overrideWithValue(FakePort()),
        ],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: Locale('en'),
          home: RxDetailScreen(rxId: 'rx1'),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'a failed load renders inside a Scaffold with an AppBar/back button '
    'and raises no exception',
    (tester) async {
      await pump(tester, repo: _Repo(byId: const Result.failure('boom')));
      expect(find.byType(Scaffold), findsOneWidget);
      expect(find.byType(AppBar), findsOneWidget);
      expect(find.text('Something went wrong'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a loaded prescription shows its own AppBar with actions', (
    tester,
  ) async {
    await pump(
      tester,
      repo: _Repo(byId: Result.success(RxWithDispensings(rx, const []))),
      meds: _EmptyMeds.new,
    );
    expect(find.byType(AppBar), findsOneWidget);
    expect(find.text('Brufen 400'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('linking with an empty medication list opens no dialog', (
    tester,
  ) async {
    await pump(
      tester,
      repo: _Repo(byId: Result.success(RxWithDispensings(rx, const []))),
      meds: _EmptyMeds.new,
    );
    await tester.tap(find.byIcon(Icons.link));
    await tester.pumpAndSettle();
    expect(find.byType(SimpleDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('linking when the medication list fails shows a generic error', (
    tester,
  ) async {
    await pump(
      tester,
      repo: _Repo(byId: Result.success(RxWithDispensings(rx, const []))),
      meds: _FailingMeds.new,
    );
    await tester.tap(find.byIcon(Icons.link));
    await tester.pumpAndSettle();
    expect(find.byType(SimpleDialog), findsNothing);
    expect(find.text('Something went wrong'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
