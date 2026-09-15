import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/presentation/screens/scanner/scan_review_view.dart';
import 'package:medora/services/code_candidates.dart';

import '../../helpers/pump_app.dart';

final _png = Uint8List.fromList(const [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, //
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
  0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
  0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);

CodeCandidate _c(String code, CodeKind kind, Rect box) =>
    CodeCandidate(code: code, kind: kind, sourceText: 'Zeile $code', box: box);

final _aic1 = _c(
  '023834118',
  CodeKind.aic,
  const Rect.fromLTWH(100, 100, 300, 60),
);
final _aic2 = _c(
  '034567',
  CodeKind.aic,
  const Rect.fromLTWH(500, 400, 300, 60),
);
final _other = _c(
  '4R5T21',
  CodeKind.other,
  const Rect.fromLTWH(100, 700, 300, 60),
);

void _setSurface(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Future<void> _pump(
  WidgetTester tester, {
  List<CodeCandidate> candidates = const [],
  ValueChanged<CodeCandidate>? onSelected,
  VoidCallback? onRetake,
  VoidCallback? onManualEntry,
  bool busy = false,
}) async {
  await pumpMedoraApp(
    tester,
    Scaffold(
      body: ScanReviewView(
        image: MemoryImage(_png),
        imageSize: const Size(1000, 1000),
        candidates: candidates,
        onSelected: onSelected ?? (_) {},
        onRetake: onRetake ?? () {},
        onManualEntry: onManualEntry ?? () {},
        busy: busy,
      ),
    ),
    locale: const Locale('de'),
  );
}

void main() {
  testWidgets('sections, row numbers and markers follow the ranking', (
    tester,
  ) async {
    _setSurface(tester, const Size(800, 1600));
    await _pump(tester, candidates: [_aic1, _aic2, _other]);

    expect(find.text('Tippe auf den gewünschten Code'), findsOneWidget);
    final aicHeader = tester.getTopLeft(find.text('AIC-Codes')).dy;
    final otherHeader = tester.getTopLeft(find.text('Weitere Nummern')).dy;
    expect(aicHeader, lessThan(otherHeader));

    double rowTop(int n) =>
        tester.getTopLeft(find.byKey(ValueKey('scanRow$n'))).dy;
    expect(rowTop(1), greaterThan(aicHeader));
    expect(rowTop(1), lessThan(rowTop(2)));
    expect(rowTop(2), lessThan(otherHeader));
    expect(rowTop(3), greaterThan(otherHeader));

    for (var n = 1; n <= 3; n++) {
      expect(
        find.descendant(
          of: find.byKey(ValueKey('scanRow$n')),
          matching: find.text('$n'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(ValueKey('scanMarker$n')),
          matching: find.text('$n'),
        ),
        findsOneWidget,
      );
    }
    expect(find.text('023834118'), findsOneWidget);
    expect(find.text('Zeile 4R5T21'), findsOneWidget);
  });

  testWidgets('supplement and EAN sections sit between AIC and other', (
    tester,
  ) async {
    _setSurface(tester, const Size(800, 2000));
    await _pump(
      tester,
      candidates: [
        _aic1,
        _c('107018', CodeKind.supplement, const Rect.fromLTWH(0, 0, 10, 10)),
        _c('8057737141836', CodeKind.ean, const Rect.fromLTWH(0, 50, 10, 10)),
        _other,
      ],
    );
    final tops = [
      'AIC-Codes',
      'Nahrungsergänzungsmittel (Ministeriumscode)',
      'Barcodes (EAN)',
      'Weitere Nummern',
    ].map((t) => tester.getTopLeft(find.text(t)).dy).toList();
    expect(tops, orderedEquals([...tops]..sort()));
  });

  testWidgets('tapping a row or a marker selects the candidate', (
    tester,
  ) async {
    _setSurface(tester, const Size(800, 1600));
    final selected = <CodeCandidate>[];
    await _pump(
      tester,
      candidates: [_aic1, _aic2, _other],
      onSelected: selected.add,
    );

    await tester.tap(find.byKey(const ValueKey('scanRow1')));
    await tester.pump();
    expect(selected, [_aic1]);

    await tester.tap(find.byKey(const ValueKey('scanMarker2')));
    await tester.pump();
    expect(selected, [_aic1, _aic2]);
  });

  testWidgets('busy disables taps', (tester) async {
    _setSurface(tester, const Size(800, 1600));
    final selected = <CodeCandidate>[];
    var retakes = 0;
    await _pump(
      tester,
      candidates: [_aic1, _aic2, _other],
      onSelected: selected.add,
      onRetake: () => retakes++,
      busy: true,
    );

    await tester.tap(
      find.byKey(const ValueKey('scanRow1')),
      warnIfMissed: false,
    );
    await tester.tap(
      find.byKey(const ValueKey('scanMarker2')),
      warnIfMissed: false,
    );
    await tester.tap(find.text('Neues Foto'), warnIfMissed: false);
    await tester.pump();
    expect(selected, isEmpty);
    expect(retakes, 0);
  });

  testWidgets('no candidates shows the hint and wired buttons', (tester) async {
    var retakes = 0;
    var manual = 0;
    await _pump(
      tester,
      onRetake: () => retakes++,
      onManualEntry: () => manual++,
    );

    expect(
      find.text(
        'Kein Code erkannt. Fotografiere näher oder tippe den Code ein.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Neues Foto'));
    await tester.tap(find.text('Code manuell eingeben'));
    await tester.pump();
    expect(retakes, 1);
    expect(manual, 1);
  });

  testWidgets('no overflow at 360x800', (tester) async {
    _setSurface(tester, const Size(360, 800));
    await _pump(
      tester,
      candidates: [
        for (var i = 0; i < 12; i++)
          _c(
            'A0${i}0000000 mit sehr langem Quelltext',
            CodeKind.values[i % 4],
            Rect.fromLTWH(i * 80.0, i * 80.0, 200, 50),
          ),
      ],
    );
    expect(tester.takeException(), isNull);
  });
}
