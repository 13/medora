/// Medora - Adding a prescription: scan a photo or file, or type it in.
///
/// [showAddRxSheet] offers scanning only where the on-device reader (ML
/// Kit) runs, i.e. `PlatformCapabilities.hasOnDeviceScanner` (Android and
/// iOS): camera, gallery or a PDF/file, camera further needing
/// `hasCamera`. Everywhere else (desktop, web) the add action goes straight
/// to the empty form — there is no reader to make a scan worthwhile even
/// where a file can still be picked. A picked source is read with
/// `RxScanService` behind a progress dialog, and the form opens prefilled
/// with what was read and the original to attach. Before the form opens:
/// - a refused scan (file too large) is reported and nothing opens;
/// - a prescription number that is already saved is reported with an
///   "Open" action, and the form does not open;
/// - a tax code no person has leads to a "new person?" question.
///
/// The picked original is a temp copy (the picker's own cache copy, or
/// ours from a content URI); it is deleted once the form is closed, and
/// only when it lives inside the app's temp directory.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:medora/core/platform_capabilities.dart';
import 'package:medora/domain/entities/person.dart';
import 'package:medora/domain/rx/nre.dart';
import 'package:medora/domain/rx/rx_draft.dart';
import 'package:medora/domain/rx/tax_code.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/presentation/providers/providers.dart';
import 'package:medora/presentation/providers/rx_providers.dart';
import 'package:medora/presentation/router/app_router.dart';
import 'package:medora/presentation/screens/rx/attachment_picker.dart';
import 'package:medora/services/attachment_import.dart';
import 'package:medora/services/rx_scan_service.dart';
import 'package:path/path.dart' as path;
import 'package:uuid/uuid.dart';

/// What `AppRoutes.addRx` carries in `state.extra` after a scan.
class RxScanPrefill {
  const RxScanPrefill({
    required this.draft,
    required this.originalPath,
    this.originalName,
  });

  final RxDraft draft;
  final String originalPath;
  final String? originalName;
}

enum _Source { camera, gallery, file, manual }

/// Starts adding a prescription from [context]: the source sheet, then the
/// scan (if one was picked), then the form. [treatmentId] and [personId]
/// are passed on to the form like the plain add route's query parameters;
/// a person found by the scanned tax code replaces [personId].
Future<void> showAddRxSheet(
  BuildContext context, {
  String? treatmentId,
  String? personId,
}) async {
  // The container, not a WidgetRef: the flow outlives the widget that
  // started it (the form is pushed on top, and the temp original is only
  // deleted once that closes).
  final container = ProviderScope.containerOf(context, listen: false);
  final caps = container.read(platformCapabilitiesProvider);
  final l10n = AppLocalizations.of(context);

  String location(String? person) {
    final query = {'treatmentId': ?treatmentId, 'personId': ?person};
    return Uri(path: AppRoutes.addRx, queryParameters: query).toString();
  }

  if (!caps.hasOnDeviceScanner) {
    await context.push(location(personId));
    return;
  }
  final source = await showModalBottomSheet<_Source>(
    context: context,
    builder: (ctx) => _SourceSheet(caps: caps),
  );
  if (source == null || !context.mounted) return;
  if (source == _Source.manual) {
    await context.push(location(personId));
    return;
  }

  final picker = container.read(attachmentPickerProvider);
  final ({String path, String? name})? picked;
  try {
    picked = await switch (source) {
      _Source.camera => picker.camera(),
      _Source.gallery => picker.gallery(),
      _ => picker.file(),
    };
  } catch (_) {
    if (context.mounted) _snack(context, l10n.genericError);
    return;
  }
  if (picked == null) return;
  try {
    if (!context.mounted) return;
    await _scanAndOpen(
      context,
      container,
      l10n,
      picked: picked,
      isPdf:
          source == _Source.file &&
          path.extension(picked.name ?? picked.path).toLowerCase() == '.pdf',
      location: location,
      personId: personId,
    );
  } finally {
    await cleanUpPickedFile(
      picked.path,
      picker: picker,
      viaFilePicker: source == _Source.file,
    );
  }
}

Future<void> _scanAndOpen(
  BuildContext context,
  ProviderContainer container,
  AppLocalizations l10n, {
  required ({String path, String? name}) picked,
  required bool isPdf,
  required String Function(String? personId) location,
  required String? personId,
}) async {
  final service = container.read(rxScanServiceProvider);
  final scan = await _withProgress(
    context,
    l10n.rxScanReading,
    () => isPdf ? service.scanPdf(picked.path) : service.scanPhoto(picked.path),
  );
  if (!context.mounted) return;
  if (scan.refusal == ImportRefusal.tooLarge) {
    _snack(context, l10n.rxAttachmentTooLarge);
    return;
  }
  final draft = scan.draft;

  // A number already saved: offer that prescription instead of a second
  // form. A failed read of the list is not a reason to stop — the save
  // runs the same check and refuses a duplicate itself.
  if (draft.nre case final nre?) {
    final normalized = Nre.normalize(nre);
    final all = await container.read(rxRepositoryProvider).getAll();
    if (!context.mounted) return;
    final existing = (all.dataOrNull ?? const [])
        .where((r) => r.rx.nre == normalized)
        .firstOrNull;
    if (existing != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.rxNreDuplicate),
          action: SnackBarAction(
            label: l10n.rxOpenExisting,
            onPressed: () => context.push(
              AppRoutes.rxDetail.replaceFirst(':id', existing.rx.id),
            ),
          ),
        ),
      );
      return;
    }
  }

  var person = personId;
  if (draft.taxCode case final taxCode?) {
    final found = await _personFor(context, container, l10n, draft, taxCode);
    if (!context.mounted) return;
    person = found ?? person;
  }

  if (scan.failed || draft.isEmpty) {
    _snack(context, l10n.rxScanNothing);
  } else if (scan.pageCount > 1) {
    _snack(context, l10n.rxScanFirstPageOnly);
  }
  await context.push(
    location(person),
    extra: RxScanPrefill(
      draft: draft,
      originalPath: picked.path,
      originalName: picked.name,
    ),
  );
}

/// The id of the person [taxCode] belongs to: an existing one, or (for a
/// trusted code only) one the user chooses to create from the scan. Null
/// when there is none (skipped, or a repository failure, which is
/// reported).
Future<String?> _personFor(
  BuildContext context,
  ProviderContainer container,
  AppLocalizations l10n,
  RxDraft draft,
  String taxCode,
) async {
  final repository = container.read(personRepositoryProvider);
  final normalized = TaxCode.normalize(taxCode);
  final persons = await repository.getPersons();
  if (!context.mounted) return null;
  final list = persons.dataOrNull;
  if (list == null) {
    _snack(context, l10n.genericError);
    return null;
  }
  final match = list.where((p) => p.taxCode == normalized).firstOrNull;
  if (match != null) return match.id;
  // Only a trusted patient code (a barcode whose role a label or a known
  // person confirmed) may become a new person: a guessed one could be the
  // doctor's.
  if (!draft.fromBarcode.contains('taxCode')) return null;

  final name = _titleCase(draft.patientName);
  final create = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      content: Text(
        l10n.rxScanNewPerson(name ?? l10n.rxScanUnknownName, normalized),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: Text(l10n.skip),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(l10n.create),
        ),
      ],
    ),
  );
  if (create != true || !context.mounted) return null;
  final saved = await repository.savePerson(
    Person(
      id: const Uuid().v4(),
      name: name ?? normalized,
      taxCode: normalized,
    ),
  );
  if (saved.isSuccess) container.invalidate(personsProvider);
  if (!context.mounted) return null;
  if (saved.isFailure) _snack(context, l10n.genericError);
  return saved.dataOrNull?.id;
}

/// "ROSSI MARIO" → "Rossi Mario"; null for a blank or missing name.
String? _titleCase(String? raw) {
  final words = (raw ?? '').trim().split(RegExp(r'\s+'))
    ..removeWhere((w) => w.isEmpty);
  if (words.isEmpty) return null;
  return words
      .map((w) => w[0].toUpperCase() + w.substring(1).toLowerCase())
      .join(' ');
}

/// Runs [scan] behind a modal "Reading the prescription…" dialog, which
/// is closed whatever [scan] does.
Future<RxScanResult> _withProgress(
  BuildContext context,
  String message,
  Future<RxScanResult> Function() scan,
) async {
  BuildContext? dialogContext;
  final dialog = showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) {
      dialogContext = ctx;
      return PopScope(
        canPop: false,
        child: AlertDialog(
          content: Row(
            children: [
              const CircularProgressIndicator(),
              const SizedBox(width: 20),
              Expanded(child: Text(message)),
            ],
          ),
        ),
      );
    },
  );
  try {
    return await scan();
  } catch (_) {
    // The service reports failures in its result; this is belt and braces.
    return const RxScanResult(RxDraft(), failed: true);
  } finally {
    // The dialog route may not have built yet if the scan finished within
    // the same frame; wait for it before closing it.
    if (dialogContext == null) await WidgetsBinding.instance.endOfFrame;
    final ctx = dialogContext;
    if (ctx != null && ctx.mounted) Navigator.of(ctx).pop();
    await dialog;
  }
}

void _snack(BuildContext context, String message) => ScaffoldMessenger.of(
  context,
).showSnackBar(SnackBar(content: Text(message)));

class _SourceSheet extends StatelessWidget {
  const _SourceSheet({required this.caps});

  final PlatformCapabilities caps;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return SafeArea(
      child: Wrap(
        children: [
          ListTile(
            title: Text(
              l10n.rxScan,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          if (caps.hasCamera)
            ListTile(
              leading: const Icon(Icons.camera_alt_outlined),
              title: Text(l10n.rxAttachmentCamera),
              onTap: () => Navigator.pop(context, _Source.camera),
            ),
          ListTile(
            leading: const Icon(Icons.photo_library_outlined),
            title: Text(l10n.rxAttachmentGallery),
            onTap: () => Navigator.pop(context, _Source.gallery),
          ),
          ListTile(
            leading: const Icon(Icons.picture_as_pdf_outlined),
            title: Text(l10n.rxPdfOrFile),
            onTap: () => Navigator.pop(context, _Source.file),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.edit_outlined),
            title: Text(l10n.rxScanManual),
            onTap: () => Navigator.pop(context, _Source.manual),
          ),
        ],
      ),
    );
  }
}
