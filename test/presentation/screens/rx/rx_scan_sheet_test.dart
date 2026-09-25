import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:medora/core/extensions.dart';
import 'package:medora/core/platform_capabilities.dart';
import 'package:medora/core/result.dart';
import 'package:medora/data/datasources/attachment_local_datasource.dart';
import 'package:medora/data/local/attachment_files.dart';
import 'package:medora/domain/entities/attachment.dart';
import 'package:medora/domain/entities/medication.dart';
import 'package:medora/domain/entities/person.dart';
import 'package:medora/domain/entities/rx.dart';
import 'package:medora/domain/entities/rx_dispensing.dart';
import 'package:medora/domain/repositories/medication_repository.dart';
import 'package:medora/domain/repositories/person_repository.dart';
import 'package:medora/domain/repositories/rx_repository.dart';
import 'package:medora/domain/rx/rx_draft.dart';
import 'package:medora/domain/rx/rx_rules.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/presentation/providers/now_provider.dart';
import 'package:medora/presentation/providers/providers.dart';
import 'package:medora/presentation/providers/settings_providers.dart';
import 'package:medora/presentation/router/app_router.dart';
import 'package:medora/presentation/screens/rx/attachment_picker.dart';
import 'package:medora/presentation/screens/rx/rx_form_screen.dart';
import 'package:medora/presentation/screens/rx/rx_scan_sheet.dart';
import 'package:medora/services/attachment_import.dart';
import 'package:medora/services/attachment_transfer.dart';
import 'package:medora/services/rx_scan_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../helpers/fake_attachment_repository.dart';
import '../../../helpers/fake_reminder_port.dart';
import '../../../helpers/test_database.dart';

// Invented fixture data only (see the project constraints).
const _taxCode = 'RSSMRA85T10A562S';
const _nre = '041A00012345678';

class _FakeScan implements RxScanService {
  RxScanResult result = const RxScanResult(RxDraft());
  final photoPaths = <String>[];
  final pdfPaths = <String>[];

  @override
  Future<RxScanResult> scanPhoto(String path) async {
    photoPaths.add(path);
    return result;
  }

  @override
  Future<RxScanResult> scanPdf(String path) async {
    pdfPaths.add(path);
    return result;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _FakePicker implements AttachmentPicker {
  ({String path, String? name})? result = (path: 'fake/rx.jpg', name: 'rx.jpg');

  @override
  Future<({String path, String? name})?> camera() async => result;
  @override
  Future<({String path, String? name})?> gallery() async => result;
  @override
  Future<({String path, String? name})?> file() async => result;
}

class _RxRepo implements RxRepository {
  _RxRepo({this.existing = const []});
  final List<Rx> existing;
  final saved = <Rx>[];

  @override
  Future<Result<List<RxWithDispensings>>> getAll() async => Result.success([
    for (final r in existing) RxWithDispensings(r, const []),
  ]);
  @override
  Future<Result<Rx>> saveRx(Rx rx) async {
    saved.add(rx);
    return Result.success(rx);
  }

  @override
  Future<Result<RxWithDispensings>> getById(String id) async =>
      const Result.failure('none');
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

class _PersonRepo implements PersonRepository {
  _PersonRepo(this.persons);
  final List<Person> persons;
  final saved = <Person>[];

  @override
  Future<Result<List<Person>>> getPersons() async =>
      Result.success([...persons]);
  @override
  Future<Result<Person?>> getByTaxCode(String taxCode) async =>
      Result.success(persons.where((p) => p.taxCode == taxCode).firstOrNull);
  @override
  Future<Result<Person>> savePerson(Person person) async {
    saved.add(person);
    persons.add(person);
    return Result.success(person);
  }

  @override
  Future<Result<void>> deletePerson(String id) async =>
      const Result.success(null);
}

class _Meds implements MedicationRepository {
  _Meds(this.medications);
  final List<Medication> medications;

  @override
  Future<Result<List<Medication>>> getMedications() async =>
      Result.success(medications);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _FakeTransfer extends AttachmentTransfer {
  _FakeTransfer()
    : super(
        local: AttachmentLocalDatasource(),
        repository: FakeAttachmentRepository(),
        files: AttachmentFiles(rootDirectory: () async => Directory.systemTemp),
        store: null,
        currentUserId: () => null,
        isOnline: () => false,
      );

  var runCalls = 0;

  @override
  Future<TransferReport> run() async {
    runCalls++;
    return TransferReport.none;
  }
}

/// Stands in for [AttachmentImport.fromPath] (real file I/O and its
/// isolate never complete under the fake-async test binding).
class _Importer {
  final paths = <String>[];

  Future<ImportResult> call(String path, {String? originalName}) async {
    paths.add(path);
    final bytes = Uint8List.fromList([1, 2, 3]);
    return Imported(
      kind: AttachmentKind.photo,
      mime: 'image/jpeg',
      bytes: bytes,
      sha256: 'abc',
      originalName: originalName,
    );
  }
}

class _Harness {
  final scan = _FakeScan();
  final picker = _FakePicker();
  final attachments = FakeAttachmentRepository();
  final transfer = _FakeTransfer();
  final importer = _Importer();
  late _RxRepo rx = _RxRepo();
  late _PersonRepo persons = _PersonRepo([]);
  late _Meds meds = _Meds(const []);

  /// Passed to the sheet like the treatment detail's add button does.
  String? treatmentId;
}

void main() {
  setUp(() async {
    await setUpTestDatabase();
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(tearDownTestDatabase);

  Future<void> pump(WidgetTester tester, _Harness h) async {
    // Tall enough for the whole prefilled form, which a ListView would
    // otherwise only build in part.
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (context, _) => Scaffold(
            body: Center(
              child: Builder(
                builder: (context) => ElevatedButton(
                  onPressed: () =>
                      showAddRxSheet(context, treatmentId: h.treatmentId),
                  child: const Text('start'),
                ),
              ),
            ),
          ),
        ),
        // The same builder as the app router's.
        GoRoute(
          path: AppRoutes.addRx,
          builder: (_, state) {
            final scan = state.extra is RxScanPrefill
                ? state.extra! as RxScanPrefill
                : null;
            return RxFormScreen(
              treatmentId: state.uri.queryParameters['treatmentId'],
              personId: state.uri.queryParameters['personId'],
              draft: scan?.draft,
              originalPath: scan?.originalPath,
              originalName: scan?.originalName,
            );
          },
        ),
        GoRoute(
          path: AppRoutes.rxDetail,
          builder: (_, state) => Text('detail ${state.pathParameters['id']}'),
        ),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          rxScanServiceProvider.overrideWithValue(h.scan),
          attachmentPickerProvider.overrideWithValue(h.picker),
          attachmentImportProvider.overrideWithValue(h.importer.call),
          attachmentRepositoryProvider.overrideWithValue(h.attachments),
          attachmentTransferProvider.overrideWithValue(h.transfer),
          rxRepositoryProvider.overrideWithValue(h.rx),
          personRepositoryProvider.overrideWithValue(h.persons),
          medicationRepositoryProvider.overrideWithValue(h.meds),
          platformCapabilitiesProvider.overrideWithValue(
            PlatformCapabilities.mobile,
          ),
          nowProvider.overrideWithValue(() => DateTime(2026, 9, 23, 10)),
          sharedPreferencesProvider.overrideWithValue(
            await SharedPreferences.getInstance(),
          ),
          reminderPortProvider.overrideWithValue(FakePort()),
        ],
        child: MaterialApp.router(
          routerConfig: router,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> startScan(
    WidgetTester tester, {
    String source = 'Take photo',
  }) async {
    await tester.tap(find.text('start'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(source));
    await tester.pumpAndSettle();
  }

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

  const mario = Person(id: 'p1', name: 'Mario Rossi', taxCode: _taxCode);

  final fullDraft = RxDraft(
    kind: RxKind.ssn,
    nre: _nre,
    taxCode: _taxCode,
    patientName: 'ROSSI MARIO',
    doctor: 'BIANCHI LUCA',
    issuedOn: DateTime(2026, 3, 3),
    validUntil: DateTime(2026, 4, 2),
    exemptionCode: 'E01',
    items: const [
      RxDraftItem(
        aic: '012745093',
        description: 'TACHIPIRINA 500 MG 20 CPR',
        packs: 2,
        posology: '1 cp al bisogno',
      ),
    ],
    fromBarcode: const {'nre', 'taxCode'},
  );

  testWidgets('offers every source plus manual entry on a phone', (
    tester,
  ) async {
    await pump(tester, _Harness());
    await tester.tap(find.text('start'));
    await tester.pumpAndSettle();
    expect(find.text('Scan prescription'), findsOneWidget);
    expect(find.text('Take photo'), findsOneWidget);
    expect(find.text('Choose photo'), findsOneWidget);
    expect(find.text('PDF or image file'), findsOneWidget);
    await tester.tap(find.text('Enter manually'));
    await tester.pumpAndSettle();
    expect(find.text('New prescription'), findsOneWidget);
    expect(find.text('Read from the scan – please check'), findsNothing);
  });

  testWidgets(
    'a full SSN draft prefills every field, marks the text-read ones, and '
    'saves with the original attached and the item linked',
    (tester) async {
      final h = _Harness()
        ..persons = _PersonRepo([mario])
        ..meds = _Meds(const [
          Medication(
            id: 'm1',
            name: 'Tachipirina',
            quantity: 20,
            barcode: '012745093',
          ),
        ]);
      h.scan.result = RxScanResult(fullDraft);
      await pump(tester, h);
      await startScan(tester);

      expect(h.scan.photoPaths, ['fake/rx.jpg']);
      expect(find.text('New prescription'), findsOneWidget);
      // The known tax code selected its person, without asking.
      expect(find.text('Mario Rossi'), findsOneWidget);
      expect(find.textContaining('as a person?'), findsNothing);
      final nreField = tester.widget<TextField>(
        find.descendant(
          of: find.byKey(const Key('rx_nre')),
          matching: find.byType(TextField),
        ),
      );
      expect(nreField.controller!.text, _nre);
      // From a barcode: no hint on the NRE.
      expect(nreField.decoration!.helperText, isNull);
      expect(find.text(DateTime(2026, 3, 3).formatted), findsOneWidget);
      expect(find.text(DateTime(2026, 4, 2).formatted), findsOneWidget);
      expect(find.text('BIANCHI LUCA'), findsOneWidget);
      expect(find.text('E01'), findsOneWidget);
      expect(find.text('TACHIPIRINA 500 MG 20 CPR'), findsOneWidget);
      expect(find.text('1 cp al bisogno'), findsOneWidget);
      // kind, issued, valid until, doctor, exemption and the item.
      expect(find.text('Read from the scan – please check'), findsNWidgets(6));

      await save(tester);
      final rx = h.rx.saved.single;
      expect(rx.kind, RxKind.ssn);
      expect(rx.nre, _nre);
      expect(rx.personId, 'p1');
      expect(rx.issuedOn, DateTime(2026, 3, 3));
      expect(rx.validUntil, DateTime(2026, 4, 2));
      expect(rx.doctor, 'BIANCHI LUCA');
      expect(rx.exemptionCode, 'E01');
      final item = rx.items.single;
      expect(item.aic, '012745093');
      expect(item.packs, 2);
      expect(item.posology, '1 cp al bisogno');
      expect(item.medicationId, 'm1');

      expect(h.importer.paths, ['fake/rx.jpg']);
      expect(h.attachments.added.single.originalName, 'rx.jpg');
      expect(h.attachments.attachments.single.ownerId, rx.id);
      expect(h.transfer.runCalls, 1);
      expect(find.text('start'), findsOneWidget);
    },
  );

  testWidgets(
    'a scanned item links to the active pack, never an archived one sharing '
    'its AIC',
    (tester) async {
      final h = _Harness()
        ..persons = _PersonRepo([mario])
        ..meds = _Meds(const [
          Medication(
            id: 'old',
            name: 'Tachipirina (discontinued)',
            quantity: 0,
            barcode: '012745093',
            isArchived: true,
          ),
          Medication(
            id: 'active',
            name: 'Tachipirina',
            quantity: 20,
            barcode: '012745093',
          ),
        ]);
      h.scan.result = RxScanResult(fullDraft);
      await pump(tester, h);
      await startScan(tester);
      await save(tester);
      expect(h.rx.saved.single.items.single.medicationId, 'active');
    },
  );

  testWidgets('a scan started from a treatment is saved for it', (
    tester,
  ) async {
    final h = _Harness()
      ..persons = _PersonRepo([mario])
      ..treatmentId = 't1';
    h.scan.result = RxScanResult(fullDraft);
    await pump(tester, h);
    await startScan(tester);
    await save(tester);
    expect(h.rx.saved.single.treatmentId, 't1');
    expect(h.rx.saved.single.personId, 'p1');
  });

  testWidgets('a scanned validity survives a kind change', (tester) async {
    final h = _Harness()..persons = _PersonRepo([mario]);
    h.scan.result = RxScanResult(fullDraft);
    await pump(tester, h);
    await startScan(tester);
    await tester.tap(find.text('National health service (SSN)').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Referral').last);
    await tester.pumpAndSettle();
    expect(find.text(DateTime(2026, 4, 2).formatted), findsOneWidget);
  });

  testWidgets(
    'an unknown tax code asks to create the person, who is then selected',
    (tester) async {
      final h = _Harness();
      h.scan.result = RxScanResult(fullDraft);
      await pump(tester, h);
      await startScan(tester);

      expect(
        find.text('Add Rossi Mario (RSSMRA85T10A562S) as a person?'),
        findsOneWidget,
      );
      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();

      final person = h.persons.saved.single;
      expect(person.name, 'Rossi Mario');
      expect(person.taxCode, _taxCode);
      expect(find.text('New prescription'), findsOneWidget);
      expect(find.text('Rossi Mario'), findsOneWidget);
      await save(tester);
      expect(h.rx.saved.single.personId, person.id);
    },
  );

  testWidgets('skipping the new person opens the form with no person', (
    tester,
  ) async {
    final h = _Harness();
    h.scan.result = const RxScanResult(
      RxDraft(taxCode: _taxCode, fromBarcode: {'taxCode'}),
    );
    await pump(tester, h);
    await startScan(tester);
    expect(
      find.text('Add unknown name (RSSMRA85T10A562S) as a person?'),
      findsOneWidget,
    );
    await tester.tap(find.text('Skip'));
    await tester.pumpAndSettle();
    expect(h.persons.saved, isEmpty);
    expect(find.text('New prescription'), findsOneWidget);
  });

  testWidgets('a guessed tax code offers no new person', (tester) async {
    final h = _Harness();
    // Read from text, or a barcode whose role was only guessed: not trusted.
    h.scan.result = const RxScanResult(
      RxDraft(taxCode: _taxCode, patientName: 'ROSSI MARIO'),
    );
    await pump(tester, h);
    await startScan(tester);
    expect(find.textContaining('as a person?'), findsNothing);
    expect(h.persons.saved, isEmpty);
    expect(find.text('New prescription'), findsOneWidget);
    expect(find.text('Rossi Mario'), findsNothing);
  });

  testWidgets('a guessed tax code still selects a person who has it', (
    tester,
  ) async {
    final h = _Harness()..persons = _PersonRepo([mario]);
    h.scan.result = const RxScanResult(RxDraft(taxCode: _taxCode));
    await pump(tester, h);
    await startScan(tester);
    expect(find.text('Mario Rossi'), findsOneWidget);
  });

  testWidgets('an NRE already saved is reported and no form opens', (
    tester,
  ) async {
    final h = _Harness()
      ..persons = _PersonRepo([mario])
      ..rx = _RxRepo(
        existing: [
          Rx(
            id: 'rx-old',
            kind: RxKind.ssn,
            nre: _nre,
            issuedOn: DateTime(2026, 3, 3),
          ),
        ],
      );
    h.scan.result = RxScanResult(fullDraft);
    await pump(tester, h);
    await startScan(tester);

    expect(find.text('New prescription'), findsNothing);
    expect(
      find.text('This prescription number is already saved'),
      findsOneWidget,
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.text('detail rx-old'), findsOneWidget);
  });

  testWidgets('nothing recognised opens an empty form with a message, and the '
      'original is still attached on save', (tester) async {
    final h = _Harness()..picker.result = (path: 'fake/rx.pdf', name: 'rx.pdf');
    h.scan.result = const RxScanResult(RxDraft(), failed: true);
    await pump(tester, h);
    await startScan(tester, source: 'PDF or image file');

    expect(h.scan.pdfPaths, ['fake/rx.pdf']);
    expect(
      find.text('Nothing could be read – please fill in by hand'),
      findsOneWidget,
    );
    expect(find.text('New prescription'), findsOneWidget);
    expect(find.text('Read from the scan – please check'), findsNothing);
    // Let the message go, so it no longer covers the Save button.
    await tester.pump(const Duration(seconds: 10));
    await tester.pumpAndSettle();
    await save(tester);
    expect(h.rx.saved.single.items, isEmpty);
    expect(h.attachments.added.single.originalName, 'rx.pdf');
    expect(h.transfer.runCalls, 1);
  });

  testWidgets('a multi-page PDF says only the first page was read', (
    tester,
  ) async {
    final h = _Harness()..picker.result = (path: 'fake/rx.pdf', name: 'rx.pdf');
    h.scan.result = const RxScanResult(
      RxDraft(doctor: 'BIANCHI LUCA'),
      pageCount: 2,
    );
    await pump(tester, h);
    await startScan(tester, source: 'PDF or image file');
    expect(find.text('Only the first page was read'), findsOneWidget);
    expect(find.text('New prescription'), findsOneWidget);
  });

  testWidgets('a one-page PDF says nothing about pages', (tester) async {
    final h = _Harness()..picker.result = (path: 'fake/rx.pdf', name: 'rx.pdf');
    h.scan.result = const RxScanResult(RxDraft(doctor: 'BIANCHI LUCA'));
    await pump(tester, h);
    await startScan(tester, source: 'PDF or image file');
    expect(find.text('Only the first page was read'), findsNothing);
  });

  testWidgets('a file too large to scan is reported and no form opens', (
    tester,
  ) async {
    final h = _Harness();
    h.scan.result = const RxScanResult(
      RxDraft(),
      failed: true,
      refusal: ImportRefusal.tooLarge,
    );
    await pump(tester, h);
    await startScan(tester, source: 'Choose photo');
    expect(find.text('The file is larger than 20 MB'), findsOneWidget);
    expect(find.text('New prescription'), findsNothing);
    expect(find.text('Reading the prescription…'), findsNothing);
  });

  testWidgets('a failed attach is reported; the prescription stays saved', (
    tester,
  ) async {
    final h = _Harness()..persons = _PersonRepo([mario]);
    h.attachments.addResult = const Result.failure('disk full');
    h.scan.result = RxScanResult(fullDraft);
    await pump(tester, h);
    await startScan(tester);
    await save(tester);
    expect(h.rx.saved, hasLength(1));
    expect(find.text('Something went wrong'), findsOneWidget);
    expect(h.transfer.runCalls, 0);
  });

  /// Re-pumps a bare "start" button under [caps] and taps it, for the
  /// platforms with no on-device scanner (the sheet never opens for them).
  Future<void> startWithoutScanner(
    WidgetTester tester,
    PlatformCapabilities caps,
  ) async {
    await tester.pumpWidget(const SizedBox.shrink());
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (context, _) => Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () => showAddRxSheet(context),
                child: const Text('start'),
              ),
            ),
          ),
        ),
        GoRoute(path: AppRoutes.addRx, builder: (_, _) => const Text('form')),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [platformCapabilitiesProvider.overrideWithValue(caps)],
        child: MaterialApp.router(
          routerConfig: router,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('start'));
    await tester.pumpAndSettle();
  }

  testWidgets('without a file system the add goes straight to the form', (
    tester,
  ) async {
    final h = _Harness();
    await pump(tester, h);
    await startWithoutScanner(tester, PlatformCapabilities.web);
    expect(find.text('Take photo'), findsNothing);
    expect(find.text('form'), findsOneWidget);
  });

  testWidgets(
    'with a file system but no on-device scanner (desktop) the add still '
    'goes straight to the form',
    (tester) async {
      final h = _Harness();
      await pump(tester, h);
      expect(PlatformCapabilities.desktop.hasFileSystem, isTrue);
      expect(PlatformCapabilities.desktop.hasOnDeviceScanner, isFalse);
      await startWithoutScanner(tester, PlatformCapabilities.desktop);
      expect(find.text('Scan prescription'), findsNothing);
      expect(find.text('form'), findsOneWidget);
    },
  );
}
