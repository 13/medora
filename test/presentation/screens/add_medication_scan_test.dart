import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:medora/core/platform_capabilities.dart';
import 'package:medora/core/theme.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/presentation/providers/providers.dart';
import 'package:medora/presentation/providers/settings_providers.dart';
import 'package:medora/presentation/router/app_router.dart';
import 'package:medora/presentation/screens/medication/add_medication_screen.dart';
import 'package:medora/presentation/screens/scanner/scan_result.dart';
import 'package:medora/services/code_candidates.dart';
import 'package:medora/services/supplement_registry_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/fake_reminder_port.dart';
import '../../helpers/test_database.dart';

/// A register with fixed contents that never touches SQLite or the network.
class _FakeRegistry extends SupplementRegistryService {
  _FakeRegistry(this.entries, {this.cached = true});

  final List<SupplementEntry> entries;
  final bool cached;
  final lookups = <String>[];

  @override
  Future<bool> hasData() async => cached;

  @override
  Future<List<SupplementEntry>> findByCode(String code) async {
    lookups.add(code);
    return [
      for (final e in entries)
        if (SupplementRegistryService.codeKey(e.code) ==
            SupplementRegistryService.codeKey(code))
          e,
    ];
  }
}

const _zinco = SupplementEntry(
  code: '107018',
  product: 'ZINCO-C',
  company: 'SYGNUM SRL',
);

void main() {
  setUp(() async {
    await setUpTestDatabase();
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(tearDownTestDatabase);

  /// Pumps Add Medication with a fake scanner route that pops [result];
  /// returns the pushed scanner URIs.
  Future<List<Uri>> pumpWithFakeScanner(
    WidgetTester tester,
    ScanResult result, {
    List<Override> overrides = const [],
  }) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final pushed = <Uri>[];
    final router = GoRouter(
      initialLocation: AppRoutes.addMedication,
      routes: [
        GoRoute(
          path: AppRoutes.addMedication,
          builder: (_, _) => const AddMedicationScreen(),
        ),
        GoRoute(
          path: AppRoutes.scanner,
          builder: (context, state) {
            pushed.add(state.uri);
            return Scaffold(
              body: TextButton(
                onPressed: () => context.pop(result),
                child: const Text('fake scan'),
              ),
            );
          },
        ),
      ],
    );
    addTearDown(router.dispose);
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          syncStartupDelayProvider.overrideWithValue(Duration.zero),
          reminderPortProvider.overrideWithValue(FakePort()),
          platformCapabilitiesProvider.overrideWithValue(
            PlatformCapabilities.mobile,
          ),
          ...overrides,
        ],
        child: MaterialApp.router(
          theme: AppTheme.lightThemeFrom(const Color(0xFF2E7D6F)),
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          routerConfig: router,
        ),
      ),
    );
    await tester.pumpAndSettle();
    return pushed;
  }

  Future<void> scanWithChip(WidgetTester tester) async {
    await tester.tap(find.byType(ActionChip).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('fake scan'));
    await tester.pumpAndSettle();
  }

  Finder field(String text) => find.descendant(
    of: find.byType(TextFormField),
    matching: find.text(text),
  );

  testWidgets(
    'the scan chip opens the scanner in return-only mode and fills an EAN',
    (tester) async {
      final pushed = await pumpWithFakeScanner(
        tester,
        const ScanResult('8057737141836', CodeKind.ean),
      );

      await tester.tap(find.byType(ActionChip).first);
      await tester.pumpAndSettle();
      expect(pushed.single.path, AppRoutes.scanner);
      expect(pushed.single.queryParameters['returnOnly'], 'true');

      await tester.tap(find.text('fake scan'));
      await tester.pumpAndSettle();

      expect(find.byType(AddMedicationScreen), findsOneWidget);
      expect(field('8057737141836'), findsOneWidget);
    },
  );

  testWidgets(
    'an EAN from the barcode field scanner is filled in without a lookup',
    (tester) async {
      final registry = _FakeRegistry(const [_zinco]);
      await pumpWithFakeScanner(
        tester,
        const ScanResult('8057737141836', CodeKind.ean),
        overrides: [
          supplementRegistryServiceProvider.overrideWithValue(registry),
        ],
      );
      // The barcode field is in the collapsed Stock section: open it.
      await tester.tap(find.text('Stock & storage'));
      await tester.pumpAndSettle();
      final fieldScanner = find.descendant(
        of: find.byType(TextFormField),
        matching: find.byIcon(Icons.qr_code_scanner),
      );
      await tester.ensureVisible(fieldScanner);
      await tester.tap(fieldScanner);
      await tester.pumpAndSettle();
      await tester.tap(find.text('fake scan'));
      await tester.pump();

      expect(field('8057737141836'), findsOneWidget);
      expect(find.byType(SnackBar), findsNothing);
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsNothing);
      expect(registry.lookups, isEmpty);
    },
  );

  testWidgets('a scanned supplement code prefills from the register', (
    tester,
  ) async {
    final registry = _FakeRegistry(const [_zinco]);
    await pumpWithFakeScanner(
      tester,
      const ScanResult('107018', CodeKind.supplement),
      overrides: [
        supplementRegistryServiceProvider.overrideWithValue(registry),
      ],
    );

    await scanWithChip(tester);

    expect(registry.lookups, ['107018']);
    expect(field('ZINCO-C'), findsOneWidget);
    expect(field('SYGNUM SRL'), findsOneWidget);
    expect(field('107018'), findsOneWidget);
    expect(find.text('Supplement'), findsOneWidget); // category
    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    expect(find.text(l10n.barcodeNotFound), findsNothing);
  });

  testWidgets(
    'a supplement code missing from the register keeps the code and says so',
    (tester) async {
      final registry = _FakeRegistry(const [_zinco]);
      await pumpWithFakeScanner(
        tester,
        const ScanResult('54321', CodeKind.supplement),
        overrides: [
          supplementRegistryServiceProvider.overrideWithValue(registry),
        ],
      );

      await scanWithChip(tester);

      final l10n = await AppLocalizations.delegate.load(const Locale('en'));
      expect(field('54321'), findsOneWidget);
      expect(find.text(l10n.supplementNotFound), findsOneWidget);
      expect(find.text(l10n.barcodeNotFound), findsNothing);
    },
  );

  testWidgets('a supplement code missing from the register asks before using a '
      'matching alternative', (tester) async {
    final registry = _FakeRegistry(const [_zinco]);
    await pumpWithFakeScanner(
      tester,
      const ScanResult('707018', CodeKind.supplement, alternatives: ['107018']),
      overrides: [
        supplementRegistryServiceProvider.overrideWithValue(registry),
      ],
    );

    await scanWithChip(tester);

    // Review I1: nothing is prefilled before the user confirms.
    expect(registry.lookups, ['707018', '107018']);
    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    expect(
      find.text(
        l10n.scanAlternativeCodeConfirm(
          '707018',
          '107018',
          'ZINCO-C',
          'SYGNUM SRL',
        ),
      ),
      findsOneWidget,
    );
    expect(field('ZINCO-C'), findsNothing);
    expect(field('707018'), findsOneWidget);

    await tester.tap(find.text(l10n.scanAlternativeCodeUse));
    await tester.pumpAndSettle();

    expect(field('ZINCO-C'), findsOneWidget);
    expect(field('107018'), findsOneWidget);
    expect(field('707018'), findsNothing);
    expect(find.text(l10n.supplementNotFound), findsNothing);
  });

  testWidgets(
    'cancelling the alternative keeps the code as read and says not found',
    (tester) async {
      final registry = _FakeRegistry(const [_zinco]);
      await pumpWithFakeScanner(
        tester,
        const ScanResult(
          '707018',
          CodeKind.supplement,
          alternatives: ['107018'],
        ),
        overrides: [
          supplementRegistryServiceProvider.overrideWithValue(registry),
        ],
      );

      await scanWithChip(tester);
      final l10n = await AppLocalizations.delegate.load(const Locale('en'));
      await tester.tap(find.text(l10n.cancel));
      await tester.pumpAndSettle();

      expect(field('707018'), findsOneWidget);
      expect(field('107018'), findsNothing);
      expect(field('ZINCO-C'), findsNothing);
      expect(find.text(l10n.supplementNotFound), findsOneWidget);
    },
  );

  testWidgets(
    'cancelling the picker for an alternative keeps the code as read',
    (tester) async {
      // Review M6: the field held the unconfirmed alternative.
      const forte = SupplementEntry(
        code: '107018',
        product: 'ZINCO-C FORTE',
        company: 'SYGNUM SRL',
      );
      final registry = _FakeRegistry(const [_zinco, forte]);
      await pumpWithFakeScanner(
        tester,
        const ScanResult(
          '707018',
          CodeKind.supplement,
          alternatives: ['107018'],
        ),
        overrides: [
          supplementRegistryServiceProvider.overrideWithValue(registry),
        ],
      );

      await scanWithChip(tester);
      final l10n = await AppLocalizations.delegate.load(const Locale('en'));
      expect(find.text(l10n.supplementSelectProduct), findsOneWidget);
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();

      expect(find.text(l10n.supplementSelectProduct), findsNothing);
      expect(field('707018'), findsOneWidget);
      expect(field('107018'), findsNothing);
      expect(field('ZINCO-C'), findsNothing);
    },
  );

  testWidgets('a product picked for an alternative is confirmed before use', (
    tester,
  ) async {
    const forte = SupplementEntry(
      code: '107018',
      product: 'ZINCO-C FORTE',
      company: 'SYGNUM SRL',
    );
    final registry = _FakeRegistry(const [_zinco, forte]);
    await pumpWithFakeScanner(
      tester,
      const ScanResult('707018', CodeKind.supplement, alternatives: ['107018']),
      overrides: [
        supplementRegistryServiceProvider.overrideWithValue(registry),
      ],
    );

    await scanWithChip(tester);
    await tester.tap(find.text('ZINCO-C FORTE'));
    await tester.pumpAndSettle();

    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    expect(
      find.text(
        l10n.scanAlternativeCodeConfirm(
          '707018',
          '107018',
          'ZINCO-C FORTE',
          'SYGNUM SRL',
        ),
      ),
      findsOneWidget,
    );
    expect(field('707018'), findsOneWidget);
    await tester.tap(find.text(l10n.scanAlternativeCodeUse));
    await tester.pumpAndSettle();
    expect(field('ZINCO-C FORTE'), findsOneWidget);
    expect(field('107018'), findsOneWidget);
  });

  testWidgets('no matching alternative keeps the primary code and says so', (
    tester,
  ) async {
    final registry = _FakeRegistry(const [_zinco]);
    await pumpWithFakeScanner(
      tester,
      const ScanResult('707018', CodeKind.supplement, alternatives: ['101018']),
      overrides: [
        supplementRegistryServiceProvider.overrideWithValue(registry),
      ],
    );

    await scanWithChip(tester);

    expect(registry.lookups, ['707018', '101018']);
    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    expect(field('707018'), findsOneWidget);
    expect(find.text(l10n.supplementNotFound), findsOneWidget);
  });

  test('ScanResult equality includes alternatives', () {
    const plain = ScanResult('707018', CodeKind.supplement);
    expect(plain.alternatives, isEmpty);
    expect(
      const ScanResult('707018', CodeKind.supplement, alternatives: ['107018']),
      isNot(plain),
    );
    // Separate list instances: equality compares contents.
    final first = ['107018'];
    final second = ['107018'];
    expect(
      ScanResult('707018', CodeKind.supplement, alternatives: first),
      ScanResult('707018', CodeKind.supplement, alternatives: second),
    );
  });

  testWidgets('an empty register cache offers the download first', (
    tester,
  ) async {
    final registry = _FakeRegistry(const [_zinco], cached: false);
    await pumpWithFakeScanner(
      tester,
      const ScanResult('107018', CodeKind.supplement),
      overrides: [
        supplementRegistryServiceProvider.overrideWithValue(registry),
      ],
    );

    await scanWithChip(tester);

    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    expect(find.text(l10n.supplementRegisterDownloadPrompt), findsOneWidget);
    await tester.tap(find.text(l10n.cancel));
    await tester.pumpAndSettle();
    expect(registry.lookups, isEmpty);
    expect(field('107018'), findsOneWidget);
  });

  test('every scanner push from Add Medication is return-only', () {
    final source = File(
      'lib/presentation/screens/medication/add_medication_screen.dart',
    ).readAsStringSync();
    final pushes = RegExp(
      r'push<ScanResult>\(\s*([^,)]+)',
    ).allMatches(source).map((m) => m.group(1)!.trim()).toList();
    expect(pushes, isNotEmpty);
    expect(pushes, everyElement('AppRoutes.scannerReturnOnly'));
    expect(source, isNot(contains('push<String>')));
    expect(source, isNot(contains('AppRoutes.scanner)')));
    expect(source, isNot(contains('returnOnly=true')));
  });
}
