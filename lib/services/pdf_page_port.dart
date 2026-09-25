/// Medora - reading a PDF prescription: its text layer and a page image.
///
/// `RxScanService` needs two things from a PDF: whatever text layer it
/// carries (an electronic prescription saved to PDF usually has one; a
/// scanned paper one does not), and page 1 rendered as an image so its
/// barcodes (and, when there is no text layer, its text) can be read the
/// same way a photo's are. `PdfrxPagePort` is the only file that imports
/// `pdfrx`; tests use a fake instead so no unit test loads PDFium.
///
/// The rendered page is written into a directory the caller passes in
/// (`RxScanService`'s own per-scan directory), not the shared temp root:
/// `Future.timeout` does not cancel the render behind it, so a call that
/// timed out can still be writing its PNG after the caller already moved on
/// and deleted the directory it made for this scan. Writing into a
/// directory that no longer exists throws; see [read].
library;

import 'dart:io';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:pdfrx/pdfrx.dart';

/// What [PdfPagePort.read] found: page 1's text layer and rendered image,
/// and how many pages the PDF has.
typedef PdfRead = ({String text, String? firstPagePng, int pageCount});

/// Reads a PDF for the scan service.
abstract class PdfPagePort {
  /// [PdfRead.text] is page 1's text layer only (a prescription is one page;
  /// later pages would mix in another's numbers), empty when it has none (a
  /// scanned paper prescription saved as PDF, or a page that failed to
  /// load). [PdfRead.firstPagePng] is page 1 rendered to a PNG file under
  /// [outputDir] (long edge ~2400 px, the same bound `RxScanService` rotates
  /// a photo to) for barcode scanning; null when the PDF has no pages,
  /// rendering failed, or [outputDir] was gone by the time the render
  /// finished. The file is temporary: the caller deletes [outputDir] (the
  /// whole directory, not just this file) once done.
  /// [PdfRead.pageCount] lets the caller say when pages were left unread.
  Future<PdfRead> read(String pdfPath, String outputDir);
}

/// [PdfPagePort] on `pdfrx` (PDFium).
class PdfrxPagePort implements PdfPagePort {
  /// The long edge page 1 is rendered to, matching the bound a photo is
  /// rotated to before its barcode passes (`AttachmentImport.maxLongEdge`).
  static const maxLongEdge = 2400;

  @override
  Future<PdfRead> read(String pdfPath, String outputDir) async {
    // Safe to call before every use: it is idempotent, and this port never
    // sits behind a pdfrx widget that would have called it already.
    await pdfrxFlutterInitialize();
    final document = await PdfDocument.openFile(pdfPath);
    try {
      final pages = document.pages;
      if (pages.isEmpty) return (text: '', firstPagePng: null, pageCount: 0);
      final text = await pages.first.loadText();
      final png = await _renderFirstPage(pages.first, outputDir);
      return (
        text: text?.fullText ?? '',
        firstPagePng: png,
        pageCount: pages.length,
      );
    } finally {
      await document.dispose();
    }
  }

  /// Renders [page] to a PNG file under [outputDir], its long edge scaled
  /// to [maxLongEdge]; null when rendering fails, or when [outputDir] no
  /// longer exists by the time the write happens (the caller's scan already
  /// timed out and cleaned up — see the library doc comment).
  Future<String?> _renderFirstPage(PdfPage page, String outputDir) async {
    final longEdge = page.width > page.height ? page.width : page.height;
    final scale = longEdge <= 0 ? 1.0 : maxLongEdge / longEdge;
    final width = (page.width * scale).round().clamp(1, 1 << 20);
    final height = (page.height * scale).round().clamp(1, 1 << 20);
    final image = await page.render(
      fullWidth: width.toDouble(),
      fullHeight: height.toDouble(),
    );
    if (image == null) return null;
    try {
      final decoded = img.Image.fromBytes(
        width: image.width,
        height: image.height,
        bytes: image.pixels.buffer,
        order: img.ChannelOrder.bgra,
      );
      final out = p.join(
        outputDir,
        'page_${DateTime.now().microsecondsSinceEpoch}.png',
      );
      try {
        await File(out).writeAsBytes(img.encodePng(decoded), flush: true);
      } on FileSystemException {
        return null;
      }
      return out;
    } finally {
      image.dispose();
    }
  }
}
