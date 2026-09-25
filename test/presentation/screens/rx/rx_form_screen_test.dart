import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/core/result.dart';
import 'package:medora/domain/entities/person.dart';
import 'package:medora/domain/entities/rx.dart';
import 'package:medora/domain/entities/rx_dispensing.dart';
import 'package:medora/domain/repositories/rx_repository.dart';
import 'package:medora/domain/rx/rx_draft.dart';
import 'package:medora/domain/rx/rx_rules.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/presentation/providers/now_provider.dart';
import 'package:medora/presentation/providers/providers.dart';
import 'package:medora/presentation/providers/rx_providers.dart';
import 'package:medora/presentation/providers/settings_providers.dart';
import 'package:medora/presentation/screens/rx/rx_form_screen.dart';
import 'package:medora/presentation/widgets/forms/date_picker_field.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../helpers/fake_reminder_port.dart';
import '../../../helpers/test_database.dart';

class _Repo implements RxRepository {
  _Repo({this.refuse, this.byId, this.byIdCompleter, this.throwOnSave = false});
  final String? refuse;

  /// What `getById` resolves to. Ignored when [byIdCompleter] is set.
  final Result<RxWithDispensings>? byId;

  /// When set, `getById` returns this future instead of resolving right
  /// away, so a test can hold the load open.
  final Completer<Result<RxWithDispensings>>? byIdCompleter;

  /// `saveRx` throws instead of returning, so a test can check that
  /// `_saving` is still reset (via `finally`) when the save flow blows up.
  final bool throwOnSave;
  final saved = <Rx>[];

  @override
  Future<Result<Rx>> saveRx(Rx rx) async {
    if (throwOnSave) throw StateError('disk gone');
    if (refuse != null) return Result.failure('$duplicateNrePrefix$refuse');
    saved.add(rx);
    return Result.success(rx);
  }

  @override
  Future<Result<List<RxWithDispensings>>> getAll() async =>
      const Result.success([]);
  @override
  Future<Result<RxWithDispensings>> getById(String id) {
    final completer = byIdCompleter;
    if (completer != null) return completer.future;
    return Future.value(byId ?? const Result.failure('none'));
  }

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

void main() {
  setUp(() async {
    await setUpTestDatabase();
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(tearDownTestDatabase);

  Future<_Repo> pump(
    WidgetTester tester, {
    String? refuse,
    _Repo? repo,
    String? rxId,
    RxDraft? draft,
    bool settle = true,
  }) async {
    final theRepo = repo ?? _Repo(refuse: refuse);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          rxRepositoryProvider.overrideWithValue(theRepo),
          personsProvider.overrideWith(
            (ref) async => const [Person(id: 'p1', name: 'Ben')],
          ),
          nowProvider.overrideWithValue(() => DateTime(2026, 9, 23, 10)),
          // `_save` invalidates the rx providers, which now also re-plans the
          // stock scheduler (Task 11): it needs real prefs and a fake
          // notification port rather than the platform plugin.
          sharedPreferencesProvider.overrideWithValue(
            await SharedPreferences.getInstance(),
          ),
          reminderPortProvider.overrideWithValue(FakePort()),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: RxFormScreen(rxId: rxId, draft: draft),
        ),
      ),
    );
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
    }
    return theRepo;
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
    await tester.enterText(find.byKey(const Key('rx_nre')), '041A00012345678');
    await save(tester);
    final rx = repo.saved.single;
    expect(rx.issuedOn, DateTime(2026, 9, 23));
    expect(rx.validUntil, DateTime(2026, 10, 23));
    expect(rx.nre, '041A00012345678');
  });

  testWidgets('a malformed NRE is refused', (tester) async {
    final repo = await pump(tester);
    await tester.enterText(find.byKey(const Key('rx_nre')), '12345');
    await save(tester);
    expect(find.text('15 letters or digits'), findsOneWidget);
    expect(repo.saved, isEmpty);
  });

  testWidgets('an SSN/referral prescription shows no PIN field', (
    tester,
  ) async {
    await pump(tester);
    expect(find.byKey(const Key('rx_pin')), findsNothing);
  });

  Future<void> selectWhiteKind(WidgetTester tester) async {
    await tester.tap(find.byType(DropdownButtonFormField<RxKind>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Private (white)').last);
    await tester.pumpAndSettle();
  }

  testWidgets('a white prescription shows the NRBE label and a PIN field', (
    tester,
  ) async {
    await pump(tester);
    await selectWhiteKind(tester);
    expect(find.text('Prescription number (NRBE)'), findsOneWidget);
    expect(find.byKey(const Key('rx_pin')), findsOneWidget);
  });

  testWidgets('a paper white prescription (no NRBE, no PIN) saves fine', (
    tester,
  ) async {
    final repo = await pump(tester);
    await selectWhiteKind(tester);
    await save(tester);
    final rx = repo.saved.single;
    expect(rx.nre, isNull);
    expect(rx.pin, isNull);
  });

  // save() drags the Save button into view, which can scroll a field-level
  // error above it out of the lazily-built ListView; drag back to it, as
  // the pre-existing valid-until-before-issue-date test does.
  Future<void> expectErrorVisible(WidgetTester tester, String text) async {
    await tester.dragUntilVisible(
      find.text(text),
      find.byType(ListView),
      const Offset(0, 200),
    );
    expect(find.text(text), findsOneWidget);
  }

  testWidgets('a malformed NRBE is refused', (tester) async {
    final repo = await pump(tester);
    await selectWhiteKind(tester);
    await tester.enterText(find.byKey(const Key('rx_nre')), '12345');
    await save(tester);
    await expectErrorVisible(tester, '12 characters: a letter and 11 digits');
    expect(repo.saved, isEmpty);
  });

  testWidgets('an NRBE without a PIN is refused', (tester) async {
    final repo = await pump(tester);
    await selectWhiteKind(tester);
    await tester.enterText(find.byKey(const Key('rx_nre')), 'G00001234567');
    await save(tester);
    await expectErrorVisible(tester, 'Required');
    expect(repo.saved, isEmpty);
  });

  testWidgets('a malformed PIN is refused', (tester) async {
    final repo = await pump(tester);
    await selectWhiteKind(tester);
    await tester.enterText(find.byKey(const Key('rx_nre')), 'G00001234567');
    await tester.enterText(find.byKey(const Key('rx_pin')), '7XQ2');
    await save(tester);
    await expectErrorVisible(tester, '5 letters or digits');
    expect(repo.saved, isEmpty);
  });

  testWidgets('a valid NRBE and PIN are saved together', (tester) async {
    final repo = await pump(tester);
    await selectWhiteKind(tester);
    await tester.enterText(find.byKey(const Key('rx_nre')), 'G00001234567');
    await tester.enterText(find.byKey(const Key('rx_pin')), '7xq2k');
    await save(tester);
    final rx = repo.saved.single;
    expect(rx.nre, 'G00001234567');
    expect(rx.pin, '7XQ2K');
  });

  testWidgets('a duplicate NRE shows a message with a link', (tester) async {
    await pump(tester, refuse: 'r0');
    await tester.enterText(find.byKey(const Key('rx_nre')), '041A00012345678');
    await save(tester);
    expect(
      find.text('This prescription number is already saved'),
      findsOneWidget,
    );
    expect(find.text('Open'), findsOneWidget);
    // A field-level hint stays after the SnackBar is gone, worded
    // differently so it does not collide with the SnackBar's own text
    // above.
    expect(find.text('Already saved'), findsOneWidget);
  });

  testWidgets(
    'a save that throws still resets _saving, so the form is usable again',
    (tester) async {
      await pump(tester, repo: _Repo(throwOnSave: true));
      await tester.enterText(
        find.byKey(const Key('rx_nre')),
        '041A00012345678',
      );
      // The throw happens in an async gap `save()` never awaits directly
      // (the tap's onPressed fires it and moves on), so it surfaces on the
      // zone, not as a normal `expect`/`takeException` failure; caught here
      // so the rest of the test can check the cleanup that matters: with no
      // try/finally, `_saving` would be stuck true and the button disabled.
      Object? caught;
      await runZonedGuarded(() async {
        await save(tester);
      }, (error, stack) => caught = error);
      expect(caught, isA<StateError>());
      final button = tester.widget<FilledButton>(
        find.byKey(const Key('rx_save')),
      );
      expect(button.onPressed, isNotNull);
    },
  );

  testWidgets('an item can be added with packs', (tester) async {
    final repo = await pump(tester);
    await tester.enterText(find.byKey(const Key('rx_nre')), '041A00012345678');
    await tester.tap(find.byKey(const Key('rx_add_item')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('rx_item_description_0')),
      'Brufen 400',
    );
    await tester.enterText(find.byKey(const Key('rx_item_packs_0')), '2');
    await tester.enterText(
      find.byKey(const Key('rx_item_posology_0')),
      '1x3 bei Bedarf',
    );
    await save(tester);
    expect(repo.saved.single.items.single.description, 'Brufen 400');
    expect(repo.saved.single.items.single.packs, 2);
    expect(repo.saved.single.items.single.posology, '1x3 bei Bedarf');
  });

  testWidgets(
    'edit mode shows a loading indicator with no Save button until the '
    'load resolves',
    (tester) async {
      final completer = Completer<Result<RxWithDispensings>>();
      await pump(
        tester,
        repo: _Repo(byIdCompleter: completer),
        rxId: 'rx1',
        settle: false,
      );
      expect(find.byKey(const Key('rx_save')), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      // Let the load resolve so nothing is left pending past the test.
      completer.complete(const Result.failure('gone'));
      await tester.pumpAndSettle();
    },
  );

  testWidgets('a failed load shows the generic error and never calls save', (
    tester,
  ) async {
    final repo = await pump(
      tester,
      repo: _Repo(byId: const Result.failure('missing')),
      rxId: 'rx1',
    );
    expect(find.text('Something went wrong'), findsOneWidget);
    expect(find.byKey(const Key('rx_save')), findsNothing);
    expect(repo.saved, isEmpty);
  });

  testWidgets(
    'editing an existing prescription keeps its id, items and createdAt',
    (tester) async {
      final createdAt = DateTime(2026);
      final existing = Rx(
        id: 'rx1',
        personId: 'p1',
        kind: RxKind.ssn,
        nre: '041A00012345678',
        issuedOn: DateTime(2026, 9),
        validUntil: DateTime(2026, 10),
        items: const [RxItem(id: 'i1', description: 'Brufen 400', packs: 2)],
        createdAt: createdAt,
      );
      final repo = await pump(
        tester,
        repo: _Repo(
          byId: Result.success(RxWithDispensings(existing, const [])),
        ),
        rxId: 'rx1',
      );
      await save(tester);
      final saved = repo.saved.single;
      expect(saved.id, 'rx1');
      expect(saved.createdAt, createdAt);
      expect(saved.items.single.description, 'Brufen 400');
      expect(saved.items.single.packs, 2);
    },
  );

  Future<_Repo> pumpExisting(WidgetTester tester, Rx existing) => pump(
    tester,
    repo: _Repo(byId: Result.success(RxWithDispensings(existing, const []))),
    rxId: 'rx1',
  );

  testWidgets('an unchanged stored number of an older shape still saves', (
    tester,
  ) async {
    final repo = await pumpExisting(
      tester,
      Rx(
        id: 'rx1',
        kind: RxKind.ssn,
        nre: '0410A1234567890',
        issuedOn: DateTime(2026, 9),
      ),
    );
    await save(tester);
    expect(repo.saved.single.nre, '0410A1234567890');
  });

  testWidgets('an unchanged older white number saves without a PIN', (
    tester,
  ) async {
    final repo = await pumpExisting(
      tester,
      Rx(
        id: 'rx1',
        kind: RxKind.white,
        nre: 'W123',
        issuedOn: DateTime(2026, 9),
      ),
    );
    await save(tester);
    expect(repo.saved.single.nre, 'W123');
    expect(repo.saved.single.pin, isNull);
  });

  testWidgets('a changed older number must match the new shape', (
    tester,
  ) async {
    final repo = await pumpExisting(
      tester,
      Rx(
        id: 'rx1',
        kind: RxKind.ssn,
        nre: '0410A1234567890',
        issuedOn: DateTime(2026, 9),
      ),
    );
    await tester.enterText(find.byKey(const Key('rx_nre')), '0410A1234567891');
    await save(tester);
    expect(repo.saved, isEmpty);
  });

  testWidgets(
    'a kind change requires an untouched older number to match the new shape',
    (tester) async {
      final repo = await pumpExisting(
        tester,
        Rx(
          id: 'rx1',
          kind: RxKind.ssn,
          nre: '0410A1234567890',
          issuedOn: DateTime(2026, 9),
        ),
      );
      await selectWhiteKind(tester);
      await save(tester);
      await expectErrorVisible(tester, '12 characters: a letter and 11 digits');
      expect(repo.saved, isEmpty);
    },
  );

  testWidgets('a valid-until before the issue date is refused on save', (
    tester,
  ) async {
    final existing = Rx(
      id: 'rx1',
      kind: RxKind.ssn,
      issuedOn: DateTime(2026, 9, 20),
      validUntil: DateTime(2026, 9, 10),
    );
    final repo = await pump(
      tester,
      repo: _Repo(byId: Result.success(RxWithDispensings(existing, const []))),
      rxId: 'rx1',
    );
    await save(tester);
    expect(repo.saved, isEmpty);
    await tester.dragUntilVisible(
      find.text('Valid-until is before the issue date'),
      find.byType(ListView),
      const Offset(0, 200),
    );
    expect(find.text('Valid-until is before the issue date'), findsOneWidget);
  });

  testWidgets('a picked valid-until date is kept when the kind changes', (
    tester,
  ) async {
    await pump(tester);

    // SSN issued today (2026-09-23) defaults to 30 days out.
    expect(find.text('Oct 23, 2026'), findsOneWidget);

    // "Pick" that same default by opening the picker and confirming it.
    await tester.tap(find.byType(DatePickerField).at(1));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();

    // Switching kind no longer resets a date the user has picked.
    await tester.tap(find.byType(DropdownButtonFormField<RxKind>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Private, repeatable').last);
    await tester.pumpAndSettle();
    expect(find.text('Oct 23, 2026'), findsOneWidget);
  });

  testWidgets(
    'an unpicked valid-until date follows the kind to its new default',
    (tester) async {
      await pump(tester);
      expect(find.text('Oct 23, 2026'), findsOneWidget);

      await tester.tap(find.byType(DropdownButtonFormField<RxKind>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Private, repeatable').last);
      await tester.pumpAndSettle();

      // Repeatable defaults to 6 months out: 2026-09-23 + 6 months.
      expect(find.text('Mar 23, 2027'), findsOneWidget);
    },
  );

  Future<void> pickIssueDay(WidgetTester tester, String day) async {
    await tester.tap(find.byType(DatePickerField).first);
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(DatePickerDialog),
        matching: find.text(day),
      ),
    );
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
  }

  testWidgets('a scanned "valid for n days" follows an issue-date edit', (
    tester,
  ) async {
    await pump(
      tester,
      draft: RxDraft(
        kind: RxKind.ssn,
        issuedOn: DateTime(2026, 3, 3),
        validUntil: DateTime(2026, 4, 2),
        validDays: 30,
      ),
    );
    expect(find.text('Apr 2, 2026'), findsOneWidget);
    await pickIssueDay(tester, '10');
    expect(find.text('Mar 10, 2026'), findsOneWidget);
    expect(find.text('Apr 9, 2026'), findsOneWidget);
  });

  testWidgets('a printed validity date stays put on an issue-date edit', (
    tester,
  ) async {
    await pump(
      tester,
      draft: RxDraft(
        kind: RxKind.whiteRepeatable,
        issuedOn: DateTime(2026, 3, 3),
        validUntil: DateTime(2026, 9, 3),
      ),
    );
    await pickIssueDay(tester, '10');
    expect(find.text('Mar 10, 2026'), findsOneWidget);
    expect(find.text('Sep 3, 2026'), findsOneWidget);
  });
}
