/// Screen-level tests for the scanner, which only became possible once the
/// camera and ML Kit moved behind ports (see `scanner_ports.dart`).
///
/// Each test writes a real PNG (so `readImageSize` and the crop passes work
/// on a real file), points the app's temporary directory at a real folder,
/// and drives the screen through the shutter of a fake camera. The screen
/// does real file I/O, which a widget test's fake clock never lets finish,
/// so [_settleWithIo] alternates real time (`runAsync`) with pumps.
library;

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:medora/core/platform_capabilities.dart';
import 'package:medora/core/result.dart';
import 'package:medora/core/theme.dart';
import 'package:medora/data/datasources/barcode_lookup_datasource.dart';
import 'package:medora/domain/entities/medication.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/presentation/providers/now_provider.dart';
import 'package:medora/presentation/providers/providers.dart';
import 'package:medora/presentation/router/app_router.dart';
import 'package:medora/presentation/screens/scanner/barcode_scanner_screen.dart';
import 'package:medora/presentation/screens/scanner/scan_result.dart';
import 'package:medora/services/code_candidates.dart';
import 'package:medora/services/scanner_ports.dart';
import 'package:medora/services/supplement_registry_service.dart';

import '../../helpers/failing_medication_repo.dart';
import '../../helpers/fake_scanner_ports.dart';
import '../../helpers/fake_supplement_registry.dart';

// ── Fixtures ─────────────────────────────────────────────────

const _zinco = SupplementEntry(
  code: '107018',
  product: 'ZINCO-C',
  company: 'SYGNUM SRL',
);

/// A register entry that matches nothing the tests scan.
const _other = SupplementEntry(
  code: '999999',
  product: 'ALTRO',
  company: 'ALTRA SRL',
);

const _tachipirina = AifaSearchResult(
  code: '134567891',
  groupCode: '134567',
  name: 'Tachipirina 500 Mg',
  description: '30 compresse',
  manufacturer: 'Angelini',
);

const _minsanBox = Rect.fromLTWH(20, 20, 160, 24);
const _eanBox = Rect.fromLTWH(20, 70, 160, 24);

OcrLine _minsan(String code) => OcrLine('COD MINSAN: $code', _minsanBox);

CodeCandidate _eanCandidate([Rect box = _eanBox]) =>
    CodeCandidate.eanFromBarcode('8057737141836', box)!;

/// The cabinet lookup every selection makes.
class _CabinetRepo extends FailingMedicationRepo {
  _CabinetRepo({this.match});

  final Medication? match;
  final lookups = <String>[];

  @override
  Future<Result<Medication?>> getMedicationByBarcode(String barcode) async {
    lookups.add(barcode);
    return Result.success(match);
  }
}

/// A camera whose shutter stays open until the test lets it close.
class _GatedCamera extends FakeCamera {
  _GatedCamera({super.photoPath});

  final gate = Completer<void>();
  bool _busy = false;

  @override
  bool get isTakingPicture => _busy;

  @override
  Future<String?> takePicture() async {
    takePictureCalls++;
    _busy = true;
    await gate.future;
    _busy = false;
    return photoPath;
  }
}

// ── Harness ──────────────────────────────────────────────────

/// Where the scanner went, and what it popped in return-only mode.
class _Harness {
  _Harness(this.pushed, this.popped);

  final List<String> pushed;
  final List<ScanResult?> popped;
}

/// Writes a real 240x160 PNG so the crop passes have pixels to work on.
///
/// Encoding goes through the engine, which only runs in real time, so this
/// has to happen inside `runAsync` like every other bit of I/O here.
Future<void> _writePhoto(WidgetTester tester, String path) =>
    tester.runAsync(() => _encodePhoto(path));

Future<void> _encodePhoto(String path) async {
  const width = 240;
  const height = 160;
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawRect(
    const Rect.fromLTWH(0, 0, 240, 160),
    ui.Paint()..color = const Color(0xFFFFFFFF),
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  picture.dispose();
  await File(path).writeAsBytes(png!.buffer.asUint8List(), flush: true);
}

/// Answers `getTemporaryDirectory()` with [path] (the crop passes create
/// their folders there); no plugin is registered in a widget test.
void _mockTemporaryDirectory(String path) {
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(
    channel,
    (call) async => call.method == 'getTemporaryDirectory' ? path : null,
  );
  addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
}

/// Real file I/O never completes under the test's fake clock, and widget
/// rebuilds never happen inside `runAsync`, so the two take turns.
///
/// [until] is what the caller is waiting for: the loop stops as soon as it
/// holds, so [rounds] is a ceiling for a slow disk rather than a budget
/// every test spends in full.
Future<void> _settleWithIo(
  WidgetTester tester, {
  int rounds = 40,
  bool Function()? until,
}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 2)),
    );
    await tester.pump();
    if (until != null && until()) return;
  }
}

/// [WidgetTester.pumpAndSettle] that gives up in seconds: a screen stuck on
/// a progress indicator would otherwise spin for ten minutes.
Future<void> _settle(WidgetTester tester) => tester.pumpAndSettle(
  const Duration(milliseconds: 100),
  EnginePhase.sendSemanticsUpdate,
  const Duration(seconds: 20),
);

Future<_Harness> _pumpScanner(
  WidgetTester tester, {
  List<Override> overrides = const [],
  bool returnBarcodeOnly = false,
}) async {
  tester.view.physicalSize = const Size(900, 1800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final pushed = <String>[];
  final popped = <ScanResult?>[];
  final router = GoRouter(
    initialLocation: returnBarcodeOnly ? AppRoutes.home : AppRoutes.scanner,
    routes: [
      GoRoute(
        path: AppRoutes.home,
        builder: (context, _) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () async => popped.add(
                await context.push<ScanResult>(AppRoutes.scannerReturnOnly),
              ),
              child: const Text('open scanner'),
            ),
          ),
        ),
      ),
      GoRoute(
        path: AppRoutes.scanner,
        builder: (_, state) => BarcodeScannerScreen(
          returnBarcodeOnly: state.uri.queryParameters['returnOnly'] == 'true',
        ),
      ),
      GoRoute(
        path: AppRoutes.addMedication,
        builder: (_, state) {
          pushed.add(state.uri.toString());
          return const Scaffold(body: Center(child: Text('add medication')));
        },
      ),
      GoRoute(
        path: AppRoutes.medicationDetail,
        builder: (_, state) {
          pushed.add(state.uri.toString());
          return const Scaffold(body: Center(child: Text('medication detail')));
        },
      ),
    ],
  );
  addTearDown(router.dispose);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
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
  await _settle(tester);
  return _Harness(pushed, popped);
}

/// Presses the shutter and waits for the whole recognition to land.
///
/// The review photo appearing is what "landed" means: every pass has run by
/// then. Waiting for it rather than for a fixed number of rounds keeps the
/// fast path fast and a loaded machine passing.
Future<void> _shoot(WidgetTester tester, {int rounds = 120}) async {
  await tester.tap(find.widgetWithIcon(FilledButton, Icons.camera_alt));
  await _settleWithIo(
    tester,
    rounds: rounds,
    until: () => find.byKey(const ValueKey('scanPhoto')).evaluate().isNotEmpty,
  );
  await _settle(tester);
}

/// Taps a review row and waits for what it triggered.
Future<void> _tapRow(WidgetTester tester, int number, {int rounds = 12}) async {
  await tester.tap(find.byKey(ValueKey('scanRow$number')));
  await _settleWithIo(tester, rounds: rounds);
  await _settle(tester);
}

void main() {
  late Directory temp;
  late String photo;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('scanner_screen_test_');
    photo = '${temp.path}/photo.png';
  });

  tearDown(() async {
    if (temp.existsSync()) await temp.delete(recursive: true);
  });

  /// The overrides every test shares: the four ports plus the register.
  List<Override> baseOverrides({
    required List<List<OcrLine>?> lines,
    List<List<CodeCandidate>?> barcodes = const [<CodeCandidate>[]],
    SupplementRegistryService? registry,
    CameraPort? camera,
    GalleryPort? gallery,
    _CabinetRepo? cabinet,
    List<Override> extra = const [],
  }) => [
    ...scannerOverrides(
      text: FakeTextRecognition(lines),
      barcodes: FakeBarcodeScan(barcodes),
      camera: camera ?? FakeCamera(photoPath: photo),
      gallery: gallery,
    ),
    supplementRegistryServiceProvider.overrideWithValue(
      registry ?? FakeSupplementRegistry(),
    ),
    // Every selection consults the cabinet first (review I4), so every test
    // needs one: an empty cabinet unless the test says otherwise.
    medicationRepositoryProvider.overrideWithValue(cabinet ?? _CabinetRepo()),
    ...extra,
  ];

  testWidgets('the review lists the codes the photo carried', (tester) async {
    await _writePhoto(tester, photo);
    _mockTemporaryDirectory(temp.path);

    await _pumpScanner(
      tester,
      overrides: baseOverrides(
        lines: [
          [_minsan('107018'), const OcrLine('8 057737 141836', _eanBox)],
          const <OcrLine>[],
        ],
      ),
    );
    await _shoot(tester);

    expect(find.text('Supplement codes (Ministry of Health)'), findsOneWidget);
    expect(find.text('Barcodes (EAN)'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('scanRow1')),
        matching: find.text('107018'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('scanRow2')),
        matching: find.text('8057737141836'),
      ),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('scanMarker1')), findsOneWidget);
    expect(find.byKey(const ValueKey('scanMarker2')), findsOneWidget);
  });

  testWidgets('a code found only as an alternative is confirmed first', (
    tester,
  ) async {
    await _writePhoto(tester, photo);
    _mockTemporaryDirectory(temp.path);

    // Nothing cached: the chip stays as read (707018) and the register is
    // downloaded when the user taps it.
    final registry = FakeSupplementRegistry(syncedEntries: const [_zinco]);
    final harness = await _pumpScanner(
      tester,
      overrides: baseOverrides(
        lines: [
          [_minsan('T07018')],
          const <OcrLine>[],
        ],
        registry: registry,
      ),
    );
    await _shoot(tester);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('scanRow1')),
        matching: find.text('707018'),
      ),
      findsOneWidget,
    );

    await _tapRow(tester, 1);
    expect(find.text('Food supplement register'), findsOneWidget);
    await tester.tap(find.text('Download'));
    await _settleWithIo(tester, rounds: 12);
    await _settle(tester);

    expect(registry.syncCalls, 1);
    expect(
      find.text(
        'Code 707018 was not found. Did you mean 107018: ZINCO-C '
        '(SYGNUM SRL)?',
      ),
      findsOneWidget,
    );

    await tester.tap(find.text('Use'));
    await _settle(tester);
    expect(harness.pushed, ['/medications/add?barcode=107018']);
    expect(find.text('Product found — fields auto-filled'), findsOneWidget);
  });

  testWidgets('declining the alternative keeps the code as read', (
    tester,
  ) async {
    await _writePhoto(tester, photo);
    _mockTemporaryDirectory(temp.path);

    final harness = await _pumpScanner(
      tester,
      overrides: baseOverrides(
        lines: [
          [_minsan('T07018')],
          const <OcrLine>[],
        ],
        registry: FakeSupplementRegistry(syncedEntries: const [_zinco]),
      ),
    );
    await _shoot(tester);
    await _tapRow(tester, 1);
    await tester.tap(find.text('Download'));
    await _settleWithIo(tester, rounds: 12);
    await _settle(tester);

    await tester.tap(find.text('Cancel'));
    await _settle(tester);
    expect(harness.pushed, ['/medications/add?barcode=707018']);
    expect(
      find.text(
        'Supplement not found in the register — enter details manually',
      ),
      findsOneWidget,
    );
  });

  testWidgets('a cached register resolves the chip before the review', (
    tester,
  ) async {
    await _writePhoto(tester, photo);
    _mockTemporaryDirectory(temp.path);

    final harness = await _pumpScanner(
      tester,
      overrides: baseOverrides(
        lines: [
          [_minsan('T07018')],
          const <OcrLine>[],
        ],
        registry: FakeSupplementRegistry(entries: const [_zinco]),
      ),
    );
    await _shoot(tester);

    expect(
      find.descendant(
        of: find.byKey(const ValueKey('scanRow1')),
        matching: find.text('107018'),
      ),
      findsOneWidget,
    );

    await _tapRow(tester, 1);
    // Already settled at review time: no confirmation, straight to the form.
    expect(find.text('Use'), findsNothing);
    expect(harness.pushed, ['/medications/add?barcode=107018']);
  });

  testWidgets('return-only mode pops the code, its kind and the pack EAN', (
    tester,
  ) async {
    await _writePhoto(tester, photo);
    _mockTemporaryDirectory(temp.path);

    final harness = await _pumpScanner(
      tester,
      returnBarcodeOnly: true,
      overrides: baseOverrides(
        lines: [
          [_minsan('T07018')],
        ],
        barcodes: [
          [_eanCandidate()],
        ],
      ),
    );
    await tester.tap(find.text('open scanner'));
    await _settle(tester);
    await _shoot(tester);
    await _tapRow(tester, 1);

    expect(harness.popped, const [
      ScanResult(
        '707018',
        CodeKind.supplement,
        alternatives: ['107018'],
        ean: '8057737141836',
      ),
    ]);
    expect(find.text('open scanner'), findsOneWidget);
  });

  testWidgets('a crop that cannot be written leaves the first pass standing', (
    tester,
  ) async {
    await _writePhoto(tester, photo);
    // No such directory: every crop pass fails at its first step.
    _mockTemporaryDirectory('${temp.path}/missing/deeper');

    await _pumpScanner(
      tester,
      overrides: baseOverrides(
        lines: [
          [_minsan('107018')],
          const <OcrLine>[],
        ],
      ),
    );
    await _shoot(tester);

    expect(
      find.descendant(
        of: find.byKey(const ValueKey('scanRow1')),
        matching: find.text('107018'),
      ),
      findsOneWidget,
    );
    expect(find.text('Something went wrong'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an AIC found only as an alternative is confirmed first', (
    tester,
  ) async {
    await _writePhoto(tester, photo);
    _mockTemporaryDirectory(temp.path);

    final asked = <String>[];
    final harness = await _pumpScanner(
      tester,
      overrides: baseOverrides(
        lines: [
          [const OcrLine('AIC n. T34567891', _minsanBox)],
          const <OcrLine>[],
        ],
        extra: [
          aifaSearchProvider.overrideWithValue((code) async {
            asked.add(code);
            return code == '134567891' ? const [_tachipirina] : const [];
          }),
        ],
      ),
    );
    await _shoot(tester);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('scanRow1')),
        matching: find.text('734567891'),
      ),
      findsOneWidget,
    );

    await _tapRow(tester, 1);
    expect(asked, ['734567891', '134567891']);
    expect(
      find.text(
        'Code 734567891 was not found. Did you mean 134567891: '
        'Tachipirina 500 Mg (Angelini)?',
      ),
      findsOneWidget,
    );

    await tester.tap(find.text('Use'));
    await _settle(tester);
    expect(harness.pushed, ['/medications/add?barcode=134567891']);
  });

  testWidgets('a scanned EAN already in the cabinet opens that medication', (
    tester,
  ) async {
    await _writePhoto(tester, photo);
    _mockTemporaryDirectory(temp.path);

    final repo = _CabinetRepo(
      match: const Medication(id: 'med-1', name: 'Tachipirina', quantity: 4),
    );
    final harness = await _pumpScanner(
      tester,
      overrides: baseOverrides(
        lines: [const <OcrLine>[]],
        barcodes: [
          [_eanCandidate()],
        ],
        cabinet: repo,
      ),
    );
    await _shoot(tester);
    await _tapRow(tester, 1);

    expect(repo.lookups, ['8057737141836']);
    expect(harness.pushed, ['/medications/med-1']);
    expect(find.text('Already in your cabinet'), findsOneWidget);
  });

  testWidgets('an EAN that is not in the cabinet opens Add Medication', (
    tester,
  ) async {
    await _writePhoto(tester, photo);
    _mockTemporaryDirectory(temp.path);

    final harness = await _pumpScanner(
      tester,
      overrides: baseOverrides(
        lines: [const <OcrLine>[]],
        barcodes: [
          [_eanCandidate()],
        ],
        cabinet: _CabinetRepo(),
      ),
    );
    await _shoot(tester);
    await _tapRow(tester, 1);

    expect(harness.pushed, ['/medications/add?barcode=8057737141836']);
    expect(find.text('Already in your cabinet'), findsNothing);
  });

  testWidgets('a supplement code already in the cabinet opens that '
      'medication', (tester) async {
    // Review I4: the cabinet remembers both the label code and the pack EAN
    // so a later scan of either finds the medication. Only the EAN chip used
    // to look, so rescanning a stored pack by its label code walked the user
    // into Add Medication and made a duplicate.
    await _writePhoto(tester, photo);
    _mockTemporaryDirectory(temp.path);

    final repo = _CabinetRepo(
      match: const Medication(id: 'med-1', name: 'Zinco-C', quantity: 4),
    );
    final registry = FakeSupplementRegistry(entries: const [_zinco]);
    final harness = await _pumpScanner(
      tester,
      overrides: baseOverrides(
        lines: [
          [_minsan('107018')],
        ],
        registry: registry,
        cabinet: repo,
      ),
    );
    await _shoot(tester);
    await _tapRow(tester, 1);

    expect(repo.lookups, ['107018']);
    expect(harness.pushed, ['/medications/med-1']);
    expect(find.text('Already in your cabinet'), findsOneWidget);
  });

  testWidgets('an AIC already in the cabinet opens it without asking AIFA', (
    tester,
  ) async {
    await _writePhoto(tester, photo);
    _mockTemporaryDirectory(temp.path);

    final asked = <String>[];
    final repo = _CabinetRepo(
      match: const Medication(id: 'med-2', name: 'Tachipirina', quantity: 2),
    );
    final harness = await _pumpScanner(
      tester,
      overrides: baseOverrides(
        lines: [
          [const OcrLine('AIC 034567891', _minsanBox)],
          const <OcrLine>[],
        ],
        cabinet: repo,
        extra: [
          aifaSearchProvider.overrideWithValue((code) async {
            asked.add(code);
            return const [_tachipirina];
          }),
        ],
      ),
    );
    await _shoot(tester);
    await _tapRow(tester, 1);

    expect(repo.lookups, ['034567891']);
    expect(asked, isEmpty);
    expect(harness.pushed, ['/medications/med-2']);
    expect(find.text('Already in your cabinet'), findsOneWidget);
  });

  testWidgets('an unknown code in the cabinet opens that medication', (
    tester,
  ) async {
    await _writePhoto(tester, photo);
    _mockTemporaryDirectory(temp.path);

    final repo = _CabinetRepo(
      match: const Medication(id: 'med-3', name: 'Vitamin D', quantity: 1),
    );
    final harness = await _pumpScanner(
      tester,
      overrides: baseOverrides(
        lines: [const <OcrLine>[]],
        barcodes: [
          [
            const CodeCandidate(
              code: 'X-12345',
              kind: CodeKind.other,
              sourceText: 'X-12345',
              box: Rect.fromLTWH(20, 20, 60, 20),
            ),
          ],
        ],
        cabinet: repo,
      ),
    );
    await _shoot(tester);
    await _tapRow(tester, 1);

    expect(repo.lookups, ['X-12345']);
    expect(harness.pushed, ['/medications/med-3']);
  });

  testWidgets('rescanning an area merges what it finds into the list', (
    tester,
  ) async {
    await _writePhoto(tester, photo);
    _mockTemporaryDirectory(temp.path);

    await _pumpScanner(
      tester,
      overrides: baseOverrides(
        lines: [
          [_minsan('107018')],
          [const OcrLine('AIC A023834118', Rect.fromLTWH(4, 4, 80, 16))],
        ],
        barcodes: [
          [_eanCandidate()],
          const <CodeCandidate>[],
        ],
      ),
    );
    await _shoot(tester);

    await tester.tap(find.byKey(const ValueKey('scanSelectArea')));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('scanSelectCentre')));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('scanRescanArea')));
    await _settleWithIo(tester);
    await _settle(tester);

    // The AIC read in the selection ranks first, above the two already found.
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('scanRow1')),
        matching: find.text('023834118'),
      ),
      findsOneWidget,
    );
    expect(find.text('No new code found in that area.'), findsNothing);
  });

  testWidgets('a rescan that finds nothing new says so', (tester) async {
    await _writePhoto(tester, photo);
    _mockTemporaryDirectory(temp.path);

    await _pumpScanner(
      tester,
      overrides: baseOverrides(
        lines: [
          [_minsan('107018')],
        ],
        barcodes: [
          [_eanCandidate()],
        ],
      ),
    );
    await _shoot(tester);

    await tester.tap(find.byKey(const ValueKey('scanSelectArea')));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('scanSelectCentre')));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('scanRescanArea')));
    await _settleWithIo(tester);
    await _settle(tester);

    expect(find.text('No new code found in that area.'), findsOneWidget);
  });

  testWidgets('a rescan whose crop fails reports the error', (tester) async {
    await _writePhoto(tester, photo);
    // The first pass needs no crop (a barcode decoded and the label paired),
    // so only the rescan hits the missing directory.
    _mockTemporaryDirectory('${temp.path}/missing/deeper');

    await _pumpScanner(
      tester,
      overrides: baseOverrides(
        lines: [
          [_minsan('107018')],
        ],
        barcodes: [
          [_eanCandidate()],
        ],
      ),
    );
    await _shoot(tester);

    await tester.tap(find.byKey(const ValueKey('scanSelectArea')));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('scanSelectCentre')));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('scanRescanArea')));
    await _settleWithIo(tester);
    await _settle(tester);

    expect(find.text('Something went wrong'), findsOneWidget);
    // Selection mode was left, so no stale rectangle sits over the error.
    expect(find.byKey(const ValueKey('scanRescanArea')), findsNothing);
  });

  testWidgets('a stale register is flagged, and updating it re-resolves the '
      'chips', (tester) async {
    await _writePhoto(tester, photo);
    _mockTemporaryDirectory(temp.path);

    final registry = FakeSupplementRegistry(
      entries: const [_other],
      sourceUpdatedAt: DateTime(2026),
      lastSyncAt: DateTime(2026),
      syncedEntries: const [_zinco],
    );
    await _pumpScanner(
      tester,
      overrides: baseOverrides(
        lines: [
          [_minsan('T07018')],
        ],
        barcodes: [
          [_eanCandidate()],
        ],
        registry: registry,
        extra: [nowProvider.overrideWithValue(() => DateTime(2026, 9, 16))],
      ),
    );
    await _shoot(tester);

    expect(find.text('Last updated 258 days ago'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('scanRow1')),
        matching: find.text('707018'),
      ),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('scanRegisterUpdate')));
    await _settle(tester);
    await tester.tap(find.text('Download'));
    await _settleWithIo(tester, rounds: 12);
    await _settle(tester);

    expect(registry.syncCalls, 1);
    // Downloaded on 2026-09-01: fresh again, and the chip now reads the
    // register code that matches it.
    expect(find.text('Last updated 258 days ago'), findsNothing);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('scanRow1')),
        matching: find.text('107018'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('the staleness banner can be dismissed for this photo', (
    tester,
  ) async {
    await _writePhoto(tester, photo);
    _mockTemporaryDirectory(temp.path);

    await _pumpScanner(
      tester,
      overrides: baseOverrides(
        lines: [
          [_minsan('107018')],
        ],
        barcodes: [
          [_eanCandidate()],
        ],
        registry: FakeSupplementRegistry(
          entries: const [_other],
          sourceUpdatedAt: DateTime(2026),
        ),
        extra: [nowProvider.overrideWithValue(() => DateTime(2026, 9, 16))],
      ),
    );
    await _shoot(tester);

    expect(find.text('Last updated 258 days ago'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('scanRegisterDismiss')));
    await _settle(tester);
    expect(find.text('Last updated 258 days ago'), findsNothing);
  });

  testWidgets('a torch that refuses to switch off keeps saying it is on', (
    tester,
  ) async {
    await _writePhoto(tester, photo);
    _mockTemporaryDirectory(temp.path);

    final camera = FakeCamera(photoPath: photo);
    await _pumpScanner(
      tester,
      overrides: baseOverrides(
        lines: [
          [_minsan('107018')],
          const <OcrLine>[],
        ],
        camera: camera,
      ),
    );

    await tester.tap(find.byIcon(Icons.flash_off));
    await _settle(tester);
    expect(camera.torchOn, isTrue);
    expect(find.byIcon(Icons.flash_on), findsOneWidget);

    // From here the device refuses to switch the light off, which is what
    // pausing the preview for the review asks it to do.
    camera.torchWorks = false;
    await _shoot(tester);
    expect(camera.torchOn, isTrue, reason: 'the light never went off');

    await tester.tap(find.text('Retake'));
    await _settleWithIo(tester, rounds: 12);
    await _settle(tester);
    // The indicator has to stay truthful: one reading "off" would make the
    // button ask for the light to come on, with no way left to kill it.
    expect(find.byIcon(Icons.flash_on), findsOneWidget);
  });

  // ── Camera lifecycle ──────────────────

  testWidgets('a device with no camera disables every way to take one', (
    tester,
  ) async {
    final camera = FakeCamera(opens: false);
    await _pumpScanner(
      tester,
      overrides: baseOverrides(lines: [const <OcrLine>[]], camera: camera),
    );

    expect(camera.initializeCalls, 1);
    // Neither a preview nor the spinner that waits for one.
    expect(find.byKey(const ValueKey('fakeCameraPreview')), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithIcon(FilledButton, Icons.camera_alt),
          )
          .onPressed,
      isNull,
    );
    // No torch to offer either.
    expect(find.byIcon(Icons.flash_off), findsNothing);
  });

  testWidgets('a camera that will not open reports it and does not crash', (
    tester,
  ) async {
    final camera = FakeCamera(failsToOpen: true);
    await _pumpScanner(
      tester,
      overrides: baseOverrides(lines: [const <OcrLine>[]], camera: camera),
    );

    expect(camera.initializeCalls, 1);
    expect(find.text('Something went wrong'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the camera is released when the app leaves and reopened on '
      'resume', (tester) async {
    final camera = FakeCamera(photoPath: photo);
    await _pumpScanner(
      tester,
      overrides: baseOverrides(lines: [const <OcrLine>[]], camera: camera),
    );
    expect(camera.initializeCalls, 1);
    expect(find.byKey(const ValueKey('fakeCameraPreview')), findsOneWidget);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    // Not [_settle]: with the camera gone the screen waits on a spinner,
    // which never settles.
    await tester.pump();
    expect(camera.disposeCalls, 1);
    expect(find.byKey(const ValueKey('fakeCameraPreview')), findsNothing);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump();
    expect(camera.initializeCalls, 2, reason: 'reopened exactly once');
    expect(camera.disposeCalls, 1);
    expect(find.byKey(const ValueKey('fakeCameraPreview')), findsOneWidget);
  });

  testWidgets('leaving the scanner releases the camera', (tester) async {
    final camera = FakeCamera(photoPath: photo);
    await _pumpScanner(
      tester,
      returnBarcodeOnly: true,
      overrides: baseOverrides(lines: [const <OcrLine>[]], camera: camera),
    );
    await tester.tap(find.text('open scanner'));
    await _settle(tester);
    expect(camera.initializeCalls, 1);
    expect(camera.disposeCalls, 0);

    await tester.pageBack();
    await _settle(tester);

    // Nothing else will: the port outlives the screen.
    expect(camera.disposeCalls, 1);
  });

  testWidgets('the review freezes the preview and retake starts it again', (
    tester,
  ) async {
    await _writePhoto(tester, photo);
    _mockTemporaryDirectory(temp.path);

    final camera = FakeCamera(photoPath: photo);
    await _pumpScanner(
      tester,
      overrides: baseOverrides(
        lines: [
          [_minsan('107018')],
          const <OcrLine>[],
        ],
        camera: camera,
      ),
    );
    await _shoot(tester);

    expect(camera.takePictureCalls, 1);
    expect(camera.pauseCalls, 1);
    expect(camera.resumeCalls, 0);

    await tester.tap(find.text('Retake'));
    await _settleWithIo(tester, rounds: 12);
    await _settle(tester);

    expect(camera.resumeCalls, 1);
    // The same camera, not a second one.
    expect(camera.initializeCalls, 1);
    expect(camera.disposeCalls, 0);
    expect(find.byKey(const ValueKey('scanRow1')), findsNothing);
    expect(find.byKey(const ValueKey('fakeCameraPreview')), findsOneWidget);
  });

  testWidgets('an open shutter closes every other way into a photo', (
    tester,
  ) async {
    await _writePhoto(tester, photo);
    _mockTemporaryDirectory(temp.path);

    final camera = _GatedCamera(photoPath: photo);
    await _pumpScanner(
      tester,
      overrides: baseOverrides(
        lines: [
          [_minsan('107018')],
          const <OcrLine>[],
        ],
        camera: camera,
      ),
    );

    await tester.tap(find.widgetWithIcon(FilledButton, Icons.camera_alt));
    await tester.pump();
    expect(camera.takePictureCalls, 1);

    final shutter = find.widgetWithIcon(FilledButton, Icons.camera_alt);
    expect(tester.widget<FilledButton>(shutter).onPressed, isNull);
    expect(
      tester
          .widget<IconButton>(
            find.widgetWithIcon(IconButton, Icons.photo_library_outlined),
          )
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.keyboard))
          .onPressed,
      isNull,
    );

    await tester.tap(shutter, warnIfMissed: false);
    await tester.pump();
    expect(camera.takePictureCalls, 1, reason: 'a second photo was refused');

    camera.gate.complete();
    await _settleWithIo(tester);
    await _settle(tester);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('scanRow1')),
        matching: find.text('107018'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('a torch the camera refuses leaves the indicator alone', (
    tester,
  ) async {
    final camera = FakeCamera(photoPath: photo)..torchWorks = false;
    await _pumpScanner(
      tester,
      overrides: baseOverrides(lines: [const <OcrLine>[]], camera: camera),
    );

    await tester.tap(find.byIcon(Icons.flash_off));
    await _settle(tester);

    expect(camera.torchOn, isFalse);
    expect(find.byIcon(Icons.flash_off), findsOneWidget);
    expect(find.byIcon(Icons.flash_on), findsNothing);
  });

  testWidgets('tapping the preview focuses where it was tapped', (
    tester,
  ) async {
    final camera = FakeCamera(photoPath: photo);
    await _pumpScanner(
      tester,
      overrides: baseOverrides(lines: [const <OcrLine>[]], camera: camera),
    );

    final preview = find.byKey(const ValueKey('fakeCameraPreview'));
    await tester.tapAt(tester.getCenter(preview));
    await _settle(tester);

    expect(camera.focusPoints, hasLength(1));
    expect(camera.focusPoints.single.dx, closeTo(0.5, 0.01));
    expect(camera.focusPoints.single.dy, closeTo(0.5, 0.01));
  });

  // ── Gallery ───────────────────────

  testWidgets('a gallery pick is recognised like a capture', (tester) async {
    await _writePhoto(tester, photo);
    _mockTemporaryDirectory(temp.path);

    final camera = FakeCamera(photoPath: photo);
    final gallery = FakeGallery(path: photo);
    await _pumpScanner(
      tester,
      overrides: baseOverrides(
        lines: [
          [_minsan('107018')],
          const <OcrLine>[],
        ],
        camera: camera,
        gallery: gallery,
      ),
    );

    await tester.tap(find.byIcon(Icons.photo_library_outlined));
    await _settleWithIo(tester);
    await _settle(tester);

    expect(gallery.calls, 1);
    expect(camera.takePictureCalls, 0);
    expect(camera.pauseCalls, 1);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('scanRow1')),
        matching: find.text('107018'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('a cancelled gallery pick stays on the camera', (tester) async {
    final gallery = FakeGallery();
    await _pumpScanner(
      tester,
      overrides: baseOverrides(lines: [const <OcrLine>[]], gallery: gallery),
    );

    await tester.tap(find.byIcon(Icons.photo_library_outlined));
    await _settleWithIo(tester, rounds: 6);
    await _settle(tester);

    expect(gallery.calls, 1);
    expect(find.text('Something went wrong'), findsNothing);
    // Still on the capture stage, and able to shoot again.
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithIcon(FilledButton, Icons.camera_alt),
          )
          .onPressed,
      isNotNull,
    );
  });

  testWidgets('a gallery that refuses to open reports the error', (
    tester,
  ) async {
    final gallery = FakeGallery(fails: true);
    await _pumpScanner(
      tester,
      overrides: baseOverrides(lines: [const <OcrLine>[]], gallery: gallery),
    );

    await tester.tap(find.byIcon(Icons.photo_library_outlined));
    await _settleWithIo(tester, rounds: 6);
    await _settle(tester);

    expect(gallery.calls, 1);
    expect(find.text('Something went wrong'), findsOneWidget);
    expect(tester.takeException(), isNull);
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithIcon(FilledButton, Icons.camera_alt),
          )
          .onPressed,
      isNotNull,
    );
  });

  testWidgets('a capture that writes no photo says so', (tester) async {
    // The real port answers null only when it holds no controller, which
    // the shutter's own gating excludes; silence would leave the user
    // tapping a button that does nothing.
    final camera = FakeCamera();
    await _pumpScanner(
      tester,
      overrides: baseOverrides(lines: [const <OcrLine>[]], camera: camera),
    );

    await tester.tap(find.widgetWithIcon(FilledButton, Icons.camera_alt));
    await _settle(tester);

    expect(camera.takePictureCalls, 1);
    expect(find.text('Something went wrong'), findsOneWidget);
    // Still on the camera, ready for another try.
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithIcon(FilledButton, Icons.camera_alt),
          )
          .onPressed,
      isNotNull,
    );
  });

  testWidgets('declining an AIC alternative stays on the photo', (
    tester,
  ) async {
    // Pinned as it is, not as it should be: the supplement path answers the
    // same refusal by leaving for Add Medication with the code as read
    // (see the test above), and the two dialogs therefore disagree. That
    // asymmetry predates the ports and is a product decision to make
    // deliberately, so this test records today's behaviour rather than
    // changing it.
    await _writePhoto(tester, photo);
    _mockTemporaryDirectory(temp.path);

    final harness = await _pumpScanner(
      tester,
      overrides: baseOverrides(
        lines: [
          [const OcrLine('AIC n. T34567891', _minsanBox)],
          const <OcrLine>[],
        ],
        extra: [
          aifaSearchProvider.overrideWithValue(
            (code) async =>
                code == '134567891' ? const [_tachipirina] : const [],
          ),
        ],
      ),
    );
    await _shoot(tester);
    await _tapRow(tester, 1);

    await tester.tap(find.text('Cancel'));
    await _settle(tester);

    expect(harness.pushed, isEmpty);
    expect(
      find.text('Product not found — enter details manually'),
      findsOneWidget,
    );
    // The review is still there, with the code as read.
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('scanRow1')),
        matching: find.text('734567891'),
      ),
      findsOneWidget,
    );
  });
}
