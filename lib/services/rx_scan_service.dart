/// Medora - turning a photographed or PDF prescription into a draft.
///
/// A photo's barcodes may be printed at any of the four right-angle
/// rotations the phone happened to be held at, so [RxScanService.scanPhoto]
/// tries 0/90/180/270 degrees until the barcodes read off it already give
/// `RxExtractor` an NRE/NRBE and a tax code — the two values a pharmacist
/// most needs and the ones never read from text (see `rx_extractor.dart`).
/// Text recognition then runs once, on whichever rotation decoded the most
/// barcodes (0° if none did).
///
/// A PDF's text layer, when it has one, is trusted over OCR: [scanPdf] only
/// runs text recognition on the rendered first page when the PDF carries no
/// text layer at all. Barcodes are always read off that rendered page.
///
/// Every failure — a port throwing, an oversized or unreadable photo — ends
/// in [RxScanResult.failed] and an empty draft rather than an exception: a
/// scan is convenience, and the form behind it always lets the user type
/// what a bad photo lost.
///
/// Every scan works in its own directory under `<temp>/rx_scan/`, made and
/// deleted around that one call, rather than in the shared temp root:
/// `Future.timeout` on a pass does not cancel the work behind it, so a late
/// PDF page render or rotation write can still land after the caller moved
/// on. Confined to the scan's own directory, a late write either lands
/// harmlessly in a directory about to be swept, or fails outright because
/// the directory is already gone (`pdf_page_port.dart` catches that). Each
/// new scan also sweeps sibling directories under `rx_scan/` older than
/// [kRxScanDirMaxAge] — a directory a delete couldn't fully clear (a write
/// landing mid-delete) is picked up by the next scan instead of leaking
/// forever.
library;

import 'dart:io';
import 'dart:ui';

import 'package:medora/domain/rx/rx_draft.dart';
import 'package:medora/domain/rx/rx_extractor.dart';
import 'package:medora/services/attachment_import.dart';
import 'package:medora/services/code_candidates.dart';
import 'package:medora/services/image_size.dart';
import 'package:medora/services/pdf_page_port.dart';
import 'package:medora/services/scanner_ports.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// The outcome of a scan: never thrown, always handed back to the UI.
class RxScanResult {
  const RxScanResult(
    this.draft, {
    this.failed = false,
    this.refusal,
    this.pageCount = 1,
  });

  final RxDraft draft;

  /// True when the scan could not be completed at all (an oversized photo
  /// or PDF, an unreadable file, a port that threw). [draft] is empty in
  /// that case; a partial read (some fields missing) is not a failure.
  final bool failed;

  /// Set when [failed] is true and the failure has a reason the UI can show
  /// (e.g. `AppLocalizations.rxAttachmentTooLarge` for
  /// [ImportRefusal.tooLarge]); null for every other failure, same as
  /// before this field existed.
  final ImportRefusal? refusal;

  /// Pages in the scanned PDF (1 for a photo). Only page 1 is read, so the
  /// UI says so when there were more.
  final int pageCount;
}

/// How long a single recognition pass (one rotation's barcodes, or the
/// text pass) may take, matching the passes in `scan_passes.dart`. A pass
/// that times out is treated as having found nothing, not as a failure.
const kRxScanPassTimeout = Duration(seconds: 15);

/// How long a scan's own temp directory is kept around for after it should
/// have been deleted before it is swept as stale by the next scan (see the
/// library doc comment).
const kRxScanDirMaxAge = Duration(minutes: 10);

class RxScanService {
  RxScanService({
    required this.barcodes,
    required this.text,
    required this.pdf,
    required this.knownTaxCodes,
    this._now = DateTime.now,
    this._tempRoot = getTemporaryDirectory,
  });

  final RawBarcodePort barcodes;
  final TextRecognitionPort text;
  final PdfPagePort pdf;
  final Future<Set<String>> Function() knownTaxCodes;

  /// Injected in tests so the [kRxScanDirMaxAge] sweep can be exercised
  /// without a real 10-minute wait.
  final DateTime Function() _now;

  /// The app temp dir `rx_scan/` lives under; injected in tests so they
  /// use a real directory from `Directory.systemTemp` in a plain `test()`
  /// instead of mocking the path_provider channel.
  final Future<Directory> Function() _tempRoot;

  /// Reads a photographed prescription. Barcodes are tried at 0°, 90°,
  /// 180° then 270°, accumulating what each rotation decodes; the loop
  /// stops as soon as the accumulated values already give an NRE/NRBE and a
  /// tax code (the values `RxDraft.fromBarcode` marks as trusted), rather
  /// than always trying all four. Text recognition then runs once, on the
  /// rotation that decoded the most barcodes (0° if none decoded any).
  Future<RxScanResult> scanPhoto(String path) async {
    try {
      if (await File(path).length() > AttachmentImport.maxPdfBytes) {
        return const RxScanResult(
          RxDraft(),
          failed: true,
          refusal: ImportRefusal.tooLarge,
        );
      }
      final size = await readImageSize(path);
      if (size.width * size.height > AttachmentImport.maxImagePixels) {
        return const RxScanResult(
          RxDraft(),
          failed: true,
          refusal: ImportRefusal.tooLarge,
        );
      }
      final known = await knownTaxCodes();
      final dir = await _newScanDir();
      try {
        final rotations = [
          for (var turns = 0; turns < 4; turns++)
            (quarterTurns: turns, outPath: p.join(dir.path, 'rot_$turns.png')),
        ];
        final written = await writeImageCropRotations(
          path,
          Rect.fromLTWH(0, 0, size.width, size.height),
          rotations,
          maxDecodeSide: AttachmentImport.maxLongEdge,
        ).timeout(kRxScanPassTimeout, onTimeout: () => null);
        if (written == null) return const RxScanResult(RxDraft(), failed: true);

        final pool = <String>[];
        final countByTurns = <int, int>{};
        for (final rotation in rotations) {
          final decoded = await barcodes
              .valuesIn(ScanImageFile(rotation.outPath))
              .timeout(kRxScanPassTimeout, onTimeout: () => const <String>[]);
          countByTurns[rotation.quarterTurns] = decoded.length;
          pool.addAll(decoded);
          final probe = RxExtractor.extract(
            barcodes: pool,
            text: '',
            knownTaxCodes: known,
          );
          if (probe.nre != null && probe.taxCode != null) break;
        }

        var winner = rotations.first;
        for (final rotation in rotations) {
          if ((countByTurns[rotation.quarterTurns] ?? 0) >
              (countByTurns[winner.quarterTurns] ?? 0)) {
            winner = rotation;
          }
        }
        final lines = await text
            .linesIn(ScanImageFile(winner.outPath))
            .timeout(kRxScanPassTimeout, onTimeout: () => const <OcrLine>[]);
        return RxScanResult(
          RxExtractor.extract(
            barcodes: pool,
            text: _joinedText(lines),
            knownTaxCodes: known,
          ),
        );
      } finally {
        try {
          await dir.delete(recursive: true);
        } on FileSystemException {
          // Best-effort: a rotation write still landing after this scan's
          // own timeout is swept as stale by a later scan (see the library
          // doc comment), not a failure of this one.
        }
      }
    } catch (_) {
      return const RxScanResult(RxDraft(), failed: true);
    }
  }

  /// Reads a PDF prescription: page 1's text layer, then barcodes on page
  /// 1 rendered to an image; later pages are not read (see
  /// [RxScanResult.pageCount]). Text recognition on that rendered page only
  /// runs when page 1 carries no text layer at all.
  Future<RxScanResult> scanPdf(String path) async {
    try {
      if (await File(path).length() > AttachmentImport.maxPdfBytes) {
        return const RxScanResult(
          RxDraft(),
          failed: true,
          refusal: ImportRefusal.tooLarge,
        );
      }
      final known = await knownTaxCodes();
      final dir = await _newScanDir();
      try {
        final read = await pdf
            .read(path, dir.path)
            .timeout(
              kRxScanPassTimeout,
              onTimeout: () => (text: '', firstPagePng: null, pageCount: 1),
            );
        final png = read.firstPagePng;
        if (png == null) {
          return RxScanResult(
            RxExtractor.extract(
              barcodes: const [],
              text: read.text,
              knownTaxCodes: known,
            ),
            pageCount: read.pageCount,
          );
        }
        final decoded = await barcodes
            .valuesIn(ScanImageFile(png))
            .timeout(kRxScanPassTimeout, onTimeout: () => const <String>[]);
        var pageText = read.text;
        if (pageText.trim().isEmpty) {
          final lines = await text
              .linesIn(ScanImageFile(png))
              .timeout(kRxScanPassTimeout, onTimeout: () => const <OcrLine>[]);
          pageText = _joinedText(lines);
        }
        return RxScanResult(
          RxExtractor.extract(
            barcodes: decoded,
            text: pageText,
            knownTaxCodes: known,
          ),
          pageCount: read.pageCount,
        );
      } finally {
        try {
          await dir.delete(recursive: true);
        } on FileSystemException {
          // Best-effort: a leaked page render is not a scan failure, and a
          // late write still landing after this scan's own timeout is swept
          // as stale by a later scan (see the library doc comment).
        }
      }
    } catch (_) {
      return const RxScanResult(RxDraft(), failed: true);
    }
  }

  /// A fresh directory under `<temp>/rx_scan/` for one scan's own temporary
  /// files, e.g. `<temp>/rx_scan/1730000000000_a1b2c3/`. Sweeps sibling
  /// directories older than [kRxScanDirMaxAge] first — see the library doc
  /// comment for why they can be left behind.
  Future<Directory> _newScanDir() async {
    final root = Directory(p.join((await _tempRoot()).path, 'rx_scan'));
    await root.create(recursive: true);
    await _pruneStaleScanDirs(root);
    return root.createTemp('${_now().millisecondsSinceEpoch}_');
  }

  /// Deletes every directory directly under [root] whose name encodes a
  /// timestamp (the leading `<millisecondsSinceEpoch>_` every [_newScanDir]
  /// writes) older than [kRxScanDirMaxAge]. A directory a scan failed to
  /// delete outright — most likely a write landing mid-delete — is picked
  /// up here on the next scan instead of accumulating forever.
  Future<void> _pruneStaleScanDirs(Directory root) async {
    final cutoff = _now().subtract(kRxScanDirMaxAge);
    await for (final entry in root.list()) {
      if (entry is! Directory) continue;
      final stamp = _scanDirStamp(p.basename(entry.path));
      if (stamp == null || !stamp.isBefore(cutoff)) continue;
      try {
        await entry.delete(recursive: true);
      } on FileSystemException {
        // Best-effort: tried again by the next scan.
      }
    }
  }

  /// The timestamp encoded in a [_newScanDir] directory name, or null for a
  /// name that doesn't start with `<digits>_` (nothing else should be under
  /// `rx_scan/`, but a foreign directory there is left alone rather than
  /// guessed at).
  static DateTime? _scanDirStamp(String dirName) {
    final separator = dirName.indexOf('_');
    if (separator <= 0) return null;
    final millis = int.tryParse(dirName.substring(0, separator));
    return millis == null ? null : DateTime.fromMillisecondsSinceEpoch(millis);
  }

  /// OCR lines in reading order (top to bottom, then left to right), joined
  /// the way `RxExtractor` expects: one line of text per line break.
  static String _joinedText(List<OcrLine> lines) {
    final sorted = [...lines]
      ..sort((a, b) {
        final byTop = a.box.top.compareTo(b.box.top);
        return byTop != 0 ? byTop : a.box.left.compareTo(b.box.left);
      });
    return sorted.map((line) => line.text).join('\n');
  }
}
