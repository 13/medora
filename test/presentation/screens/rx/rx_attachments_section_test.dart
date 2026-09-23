import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/core/platform_capabilities.dart';
import 'package:medora/core/result.dart';
import 'package:medora/data/datasources/attachment_local_datasource.dart';
import 'package:medora/data/local/attachment_files.dart';
import 'package:medora/domain/entities/attachment.dart';
import 'package:medora/domain/entities/person.dart';
import 'package:medora/domain/entities/rx.dart';
import 'package:medora/domain/repositories/rx_repository.dart';
import 'package:medora/domain/rx/rx_rules.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/l10n/generated/app_localizations_en.dart';
import 'package:medora/presentation/providers/now_provider.dart';
import 'package:medora/presentation/providers/providers.dart';
import 'package:medora/presentation/providers/rx_providers.dart';
import 'package:medora/presentation/screens/rx/rx_attachments_section.dart';
import 'package:medora/presentation/screens/rx/rx_list_view.dart';
import 'package:medora/services/attachment_import.dart';
import 'package:medora/services/attachment_transfer.dart';
import 'package:path/path.dart' as p;

import '../../../helpers/fake_attachment_repository.dart';

/// A picker fake so tests never touch platform channels; each source
/// returns whatever the test sets, null meaning "the user cancelled". The
/// paths returned are never actually read from disk — [_BytesImporter]
/// (the [attachmentImportProvider] override) supplies the bytes directly.
class _FakePicker implements AttachmentPicker {
  ({String path, String? name})? cameraResult;
  ({String path, String? name})? galleryResult;
  ({String path, String? name})? fileResult;

  @override
  Future<({String path, String? name})?> camera() async => cameraResult;
  @override
  Future<({String path, String? name})?> gallery() async => galleryResult;
  @override
  Future<({String path, String? name})?> file() async => fileResult;
}

/// Stands in for [AttachmentImport.fromPath]: real [File] I/O and the
/// isolate `fromPath` runs on both hang forever under `testWidgets`'s
/// fake-async test binding (real `dart:io` async calls, and anything
/// isolate-based, never gets pumped unless wrapped in `tester.runAsync`).
/// This runs the same [AttachmentImport.prepare] logic against in-memory
/// bytes instead, so tests still exercise the real refusal/success rules
/// without touching a real file or spawning an isolate.
class _BytesImporter {
  Uint8List bytes = Uint8List(0);

  Future<ImportResult> call(String path, {String? originalName}) async =>
      AttachmentImport.prepare(bytes, nameOrPath: originalName ?? path);
}

/// An [AttachmentTransfer] whose I/O methods are overridden, so it never
/// touches a real datasource, store or file. The dependencies it is built
/// with are never used (every method they'd otherwise drive is overridden
/// below) — they only satisfy the constructor.
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

  File? openResult;
  final openedIds = <String>[];
  var runCalls = 0;

  @override
  Future<File?> open(Attachment a) async {
    openedIds.add(a.id);
    return openResult;
  }

  @override
  Future<TransferReport> run() async {
    runCalls++;
    return TransferReport.none;
  }
}

const _pdfHeader = [0x25, 0x50, 0x44, 0x46, 0x2D]; // %PDF-

Uint8List _smallPdf() => Uint8List.fromList([..._pdfHeader, 1, 2, 3, 4, 5]);

/// A byte buffer that looks like a PDF and is over the size limit — an
/// in-memory allocation, never written to disk.
Uint8List _oversizedPdf() {
  final bytes = Uint8List(AttachmentImport.maxPdfBytes + 1);
  bytes.setRange(0, _pdfHeader.length, _pdfHeader);
  return bytes;
}

void main() {
  final l10n = AppLocalizationsEn();
  late Directory tempDir;

  setUp(() {
    // Synchronous I/O only: real *async* `dart:io` calls (and the
    // `AttachmentFiles` internals that make one to create a missing
    // folder) hang forever under `testWidgets` unless wrapped in
    // `tester.runAsync`, so the attachments folder is pre-created here.
    tempDir = Directory.systemTemp.createTempSync('rx-attachments-test');
    Directory(
      p.join(tempDir.path, AttachmentFiles.folder),
    ).createSync(recursive: true);
  });
  tearDown(() => tempDir.deleteSync(recursive: true));

  Future<void> pump(
    WidgetTester tester, {
    required FakeAttachmentRepository repo,
    required _FakeTransfer transfer,
    required _FakePicker picker,
    _BytesImporter? importer,
    bool hasCamera = true,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          attachmentRepositoryProvider.overrideWithValue(repo),
          attachmentTransferProvider.overrideWithValue(transfer),
          attachmentPickerProvider.overrideWithValue(picker),
          attachmentImportProvider.overrideWithValue(
            (importer ?? _BytesImporter()).call,
          ),
          attachmentFilesProvider.overrideWithValue(
            AttachmentFiles(rootDirectory: () async => tempDir),
          ),
          platformCapabilitiesProvider.overrideWithValue(
            hasCamera ? PlatformCapabilities.mobile : PlatformCapabilities.web,
          ),
        ],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: Locale('en'),
          home: Scaffold(body: RxAttachmentsSection(rxId: 'rx1')),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  const photo = Attachment(
    id: 'a1',
    ownerKind: AttachmentOwnerKind.rx,
    ownerId: 'rx1',
    kind: AttachmentKind.photo,
    mime: 'image/jpeg',
    sizeBytes: 10,
    sha256: 'abc',
  );

  testWidgets(
    'choosing "file" with a PDF path adds an attachment and triggers a '
    'transfer run',
    (tester) async {
      final repo = FakeAttachmentRepository();
      final transfer = _FakeTransfer();
      final picker = _FakePicker()
        ..fileResult = (path: 'fake/doc.pdf', name: 'doc.pdf');
      final importer = _BytesImporter()..bytes = _smallPdf();
      await pump(
        tester,
        repo: repo,
        transfer: transfer,
        picker: picker,
        importer: importer,
      );

      await tester.tap(find.byTooltip(l10n.rxAttachmentAdd));
      await tester.pumpAndSettle();
      await tester.tap(find.text(l10n.rxAttachmentFile));
      await tester.pumpAndSettle();

      expect(repo.added, hasLength(1));
      expect(repo.added.single.kind, AttachmentKind.pdf);
      expect(transfer.runCalls, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a refused import (too large) shows the matching message; nothing is '
    'added',
    (tester) async {
      final repo = FakeAttachmentRepository();
      final transfer = _FakeTransfer();
      final picker = _FakePicker()
        ..fileResult = (path: 'fake/big.pdf', name: 'big.pdf');
      final importer = _BytesImporter()..bytes = _oversizedPdf();
      await pump(
        tester,
        repo: repo,
        transfer: transfer,
        picker: picker,
        importer: importer,
      );

      await tester.tap(find.byTooltip(l10n.rxAttachmentAdd));
      await tester.pumpAndSettle();
      await tester.tap(find.text(l10n.rxAttachmentFile));
      await tester.pumpAndSettle();

      expect(find.text('The file is larger than 20 MB'), findsOneWidget);
      expect(repo.added, isEmpty);
    },
  );

  testWidgets('tapping an attachment whose open returns null shows the '
      'not-available message', (tester) async {
    final repo = FakeAttachmentRepository(attachments: const [photo]);
    final transfer = _FakeTransfer();
    await pump(tester, repo: repo, transfer: transfer, picker: _FakePicker());

    await tester.tap(find.byKey(const ValueKey('a1')));
    await tester.pumpAndSettle();

    expect(find.text(l10n.rxAttachmentNotAvailable), findsOneWidget);
    expect(transfer.openedIds, ['a1']);
  });

  testWidgets(
    'long-pressing an attachment asks first; confirming calls delete, and '
    'a failing delete shows the generic error',
    (tester) async {
      final repo = FakeAttachmentRepository(attachments: const [photo])
        ..deleteResult = const Result.failure('boom');
      final transfer = _FakeTransfer();
      await pump(tester, repo: repo, transfer: transfer, picker: _FakePicker());

      await tester.longPress(find.byKey(const ValueKey('a1')));
      await tester.pumpAndSettle();
      expect(find.text(l10n.rxAttachmentDeleteConfirm), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, l10n.delete));
      await tester.pumpAndSettle();

      expect(repo.deletedIds, ['a1']);
      expect(find.text(l10n.genericError), findsOneWidget);
    },
  );

  testWidgets('cancelling the delete confirmation deletes nothing', (
    tester,
  ) async {
    final repo = FakeAttachmentRepository(attachments: const [photo]);
    final transfer = _FakeTransfer();
    await pump(tester, repo: repo, transfer: transfer, picker: _FakePicker());

    await tester.longPress(find.byKey(const ValueKey('a1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.cancel));
    await tester.pumpAndSettle();

    expect(repo.deletedIds, isEmpty);
  });

  testWidgets('the add sheet offers the camera only when the device has one', (
    tester,
  ) async {
    final repo = FakeAttachmentRepository();
    final transfer = _FakeTransfer();
    await pump(
      tester,
      repo: repo,
      transfer: transfer,
      picker: _FakePicker(),
      hasCamera: false,
    );

    await tester.tap(find.byTooltip(l10n.rxAttachmentAdd));
    await tester.pumpAndSettle();

    expect(find.text(l10n.rxAttachmentCamera), findsNothing);
    expect(find.text(l10n.rxAttachmentGallery), findsOneWidget);
  });

  testWidgets(
    'the list tile of an rx with attachments shows the attachment icon',
    (tester) async {
      final rx = Rx(
        id: 'rx1',
        kind: RxKind.ssn,
        issuedOn: DateTime(2026, 9),
        items: const [RxItem(id: 'i', description: 'Med')],
      );
      final repo = FakeAttachmentRepository(attachments: const [photo]);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            attachmentRepositoryProvider.overrideWithValue(repo),
            nowProvider.overrideWithValue(() => DateTime(2026, 9, 23)),
            personsProvider.overrideWith((ref) async => const <Person>[]),
            rxListProvider.overrideWith(
              (ref) async => [RxWithDispensings(rx, const [])],
            ),
          ],
          child: const MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: Locale('en'),
            home: Scaffold(body: RxListView()),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.attach_file), findsOneWidget);
    },
  );
}
