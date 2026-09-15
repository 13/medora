import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:medora/services/code_candidates.dart';
import 'package:medora/services/scan_region.dart';

void main() {
  group('textRegionCrop', () {
    const image = Size(3000, 4000);

    test('the device label: union of line boxes expanded by 8%', () {
      final crop = textRegionCrop(const [
        Rect.fromLTRB(770, 1270, 2000, 1400),
        Rect.fromLTRB(831, 2008, 2032, 2190),
        Rect.fromLTRB(1500, 1600, 2530, 1700),
      ], image);
      // Union 770,1270 .. 2530,2190 = 1760x920; 8% is 140.8 x 73.6.
      expect(crop, const Rect.fromLTRB(629, 1196, 2671, 2264));
    });

    test('is clamped to the image', () {
      final crop = textRegionCrop(const [
        Rect.fromLTRB(10, 20, 1000, 1200),
        Rect.fromLTRB(-5, 0, 50, 50),
      ], image);
      // Union -5,0 .. 1000,1200 = 1005x1200; 8% is 80.4 x 96.
      expect(crop, const Rect.fromLTRB(0, 0, 1081, 1296));
    });

    test('null when there are no boxes', () {
      expect(textRegionCrop(const [], image), isNull);
    });

    test('null when the crop covers more than 60% of the image', () {
      // 2400x3000 = 60% exactly before expansion; expanded it exceeds 60%.
      expect(
        textRegionCrop(const [Rect.fromLTWH(300, 500, 2400, 3000)], image),
        isNull,
      );
    });

    test('a crop of at most 60% of the image is allowed', () {
      const square = Size(1000, 1000);
      // 500 wide + 40 each side = 580x1000 (clamped): 58%.
      expect(
        textRegionCrop(const [Rect.fromLTRB(100, 0, 600, 1000)], square),
        const Rect.fromLTRB(60, 0, 640, 1000),
      );
      // 520 wide + 41.6 each side = 58..662, 604x1000: 60.4%.
      expect(
        textRegionCrop(const [Rect.fromLTRB(100, 0, 620, 1000)], square),
        isNull,
      );
    });

    test('null for an empty image or degenerate boxes', () {
      expect(
        textRegionCrop(const [Rect.fromLTWH(0, 0, 10, 10)], Size.zero),
        isNull,
      );
      expect(
        textRegionCrop(const [Rect.fromLTWH(50, 50, 0, 0)], image),
        isNull,
      );
    });
  });

  group('needsRegionPass', () {
    const box = Rect.fromLTWH(0, 0, 100, 20);
    const ean = CodeCandidate(
      code: '8057737141836',
      kind: CodeKind.ean,
      sourceText: '8057737141836',
      box: box,
    );

    bool decide(List<String> texts, {List<CodeCandidate> barcodes = const []}) {
      final lines = [for (final t in texts) OcrLine(t, box)];
      return needsRegionPass(
        lines: lines,
        barcodes: barcodes,
        candidates: findCodeCandidates(lines, barcodes: barcodes),
      );
    }

    test('no barcode decoded', () {
      expect(decide(['COD MINSAN: 107018']), isTrue);
    });

    test('no candidates at all', () {
      expect(decide(['Integratore alimentare']), isTrue);
      expect(decide([]), isTrue);
    });

    test('a supplement label without a code', () {
      expect(
        decide(['COD MINSAN: @', '8 057737141836'], barcodes: [ean]),
        isTrue,
      );
    });

    test('an AIC label without a code', () {
      expect(decide(['A.I.C. n.', '8 057737141836'], barcodes: [ean]), isTrue);
    });

    test('complete: a barcode and every label has its code', () {
      expect(
        decide(['COD MINSAN: 107018', '8 057737141836'], barcodes: [ean]),
        isFalse,
      );
      expect(decide(['Integratore'], barcodes: [ean]), isFalse);
      expect(decide(['COD MINSAN:', '107018'], barcodes: [ean]), isFalse);
    });
  });

  group('offsets', () {
    const offset = Offset(600, 1160);

    test('offsetOcrLines moves line and element boxes', () {
      final moved = offsetOcrLines(const [
        OcrLine('COD MINSAN: 10T018', Rect.fromLTWH(221, 254, 565, 64), [
          OcrElement('10T018', Rect.fromLTWH(600, 254, 186, 64)),
        ]),
      ], offset);
      expect(moved.single.text, 'COD MINSAN: 10T018');
      expect(moved.single.box, const Rect.fromLTWH(821, 1414, 565, 64));
      expect(moved.single.elements.single.text, '10T018');
      expect(
        moved.single.elements.single.box,
        const Rect.fromLTWH(1200, 1414, 186, 64),
      );
    });

    test('offsetOcrLines scales crop pixels of a downscaled decode', () {
      // Review I3: the crop PNG holds the region at [scale] of photo pixels.
      final moved = offsetOcrLines(
        const [
          OcrLine('COD MINSAN: 10T018', Rect.fromLTWH(100, 50, 200, 30), [
            OcrElement('10T018', Rect.fromLTWH(220, 50, 80, 30)),
          ]),
        ],
        offset,
        scale: 0.5,
      );
      expect(moved.single.box, const Rect.fromLTWH(800, 1260, 400, 60));
      expect(
        moved.single.elements.single.box,
        const Rect.fromLTWH(1040, 1260, 160, 60),
      );
    });

    test('offsetCandidates scales crop pixels of a downscaled decode', () {
      final moved = offsetCandidates(
        const [
          CodeCandidate(
            code: '8057737141836',
            kind: CodeKind.ean,
            sourceText: '8057737141836',
            box: Rect.fromLTWH(10, 20, 300, 100),
          ),
        ],
        offset,
        scale: 0.25,
      );
      expect(moved.single.box, const Rect.fromLTWH(640, 1240, 1200, 400));
    });

    test('offsetCandidates moves boxes and keeps the rest', () {
      final moved = offsetCandidates(const [
        CodeCandidate(
          code: '8057737141836',
          kind: CodeKind.ean,
          sourceText: '8057737141836',
          box: Rect.fromLTWH(241, 682, 1116, 252),
          alternatives: ['1057737141836'],
        ),
      ], offset);
      expect(moved.single.alternatives, ['1057737141836']);
      expect(moved.single.code, '8057737141836');
      expect(moved.single.kind, CodeKind.ean);
      expect(moved.single.sourceText, '8057737141836');
      expect(moved.single.box, const Rect.fromLTWH(841, 1842, 1116, 252));
    });
  });

  test('the device photo: first pass plus region pass', () {
    // First pass on the full 3000x4000 photo (no barcode decoded).
    const firstLines = [
      OcrLine(
        'KOMe rikOtto 200ma,ziKCOgcOn',
        Rect.fromLTWH(770, 1270, 900, 60),
      ),
      OcrLine('COD MINSAN: @', Rect.fromLTWH(793, 1428, 369, 52)),
      OcrLine('8 057737141836', Rect.fromLTWH(831, 2008, 1201, 183)),
      OcrLine('Integratore', Rect.fromLTWH(1800, 1300, 730, 60)),
    ];
    final first = findCodeCandidates(firstLines);
    expect(
      needsRegionPass(lines: firstLines, barcodes: const [], candidates: first),
      isTrue,
    );
    final crop = textRegionCrop([
      for (final l in firstLines) l.box,
    ], const Size(3000, 4000));
    expect(crop, isNotNull);

    // Region pass, in crop coordinates, shifted back by the crop offset.
    const regionOffset = Offset(600, 1160);
    final regionLines = offsetOcrLines(const [
      OcrLine('COD MINSAN: 10T018', Rect.fromLTWH(221, 254, 565, 64)),
      OcrLine('8 "057737"141836', Rect.fromLTWH(316, 847, 1000, 150)),
    ], regionOffset);
    final regionBarcodes = offsetCandidates([
      CodeCandidate.eanFromBarcode(
        '8057737141836',
        const Rect.fromLTWH(241, 682, 1116, 252),
      )!,
    ], regionOffset);

    final merged = findCodeCandidates(
      firstLines,
      regionLines: regionLines,
      barcodes: regionBarcodes,
    );
    expect(merged.map((c) => '${c.kind.name}:${c.code}'), [
      'supplement:107018',
      'ean:8057737141836',
    ]);
    expect(merged.last.box, const Rect.fromLTWH(841, 1842, 1116, 252));
  });

  test('the device photo: region pass reads COD MINSAN: T07018', () {
    // Phone run at 58653b4: the region pass read the leading 1 as T.
    const regionOffset = Offset(629, 1198);
    final regionLines = offsetOcrLines(const [
      OcrLine('COD MINSAN: T07018', Rect.fromLTWH(0, 254, 565, 64)),
    ], regionOffset);
    final supplement = findCodeCandidates(regionLines).single;
    expect(supplement.kind, CodeKind.supplement);
    expect(supplement.code, '707018');
    expect(supplement.alternatives, ['107018']);
  });
}
