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

  testWidgets('busy disables taps, retake and manual entry', (tester) async {
    _setSurface(tester, const Size(800, 1600));
    final selected = <CodeCandidate>[];
    var retakes = 0;
    var manual = 0;
    await _pump(
      tester,
      candidates: [_aic1, _aic2, _other],
      onSelected: selected.add,
      onRetake: () => retakes++,
      onManualEntry: () => manual++,
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
    await tester.tap(find.text('Code manuell eingeben'), warnIfMissed: false);
    await tester.pump();
    expect(selected, isEmpty);
    expect(retakes, 0);
    expect(manual, 0);
    final manualButton = tester.widget<ButtonStyleButton>(
      find.ancestor(
        of: find.text('Code manuell eingeben'),
        matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
      ),
    );
    expect(manualButton.enabled, isFalse);
  });

  testWidgets('markers expose a numbered button label', (tester) async {
    _setSurface(tester, const Size(800, 1600));
    final handle = tester.ensureSemantics();
    await _pump(tester, candidates: [_aic1, _aic2]);
    expect(
      tester.getSemantics(find.byKey(const ValueKey('scanMarker1'))),
      isSemantics(
        label: '1: 023834118',
        isButton: true,
        hasEnabledState: true,
        isEnabled: true,
        hasTapAction: true,
      ),
    );
    handle.dispose();
  });

  testWidgets('busy markers are not enabled for semantics', (tester) async {
    _setSurface(tester, const Size(800, 1600));
    final handle = tester.ensureSemantics();
    await _pump(tester, candidates: [_aic1], busy: true);
    expect(
      tester.getSemantics(find.byKey(const ValueKey('scanMarker1'))),
      isSemantics(
        label: '1: 023834118',
        isButton: true,
        hasEnabledState: true,
        isEnabled: false,
        hasTapAction: false,
      ),
    );
    handle.dispose();
  });

  testWidgets('a marker sits at the candidate box scaled to the photo', (
    tester,
  ) async {
    _setSurface(tester, const Size(800, 1600));
    await _pump(tester, candidates: [_aic1]);
    final photo = tester.getRect(find.byType(InteractiveViewer));
    // 1000x1000 image in a 45% of 1600 = 720 dp square.
    expect(photo.size, const Size(720, 720));
    const scale = 720 / 1000;
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('scanMarker1'))),
      photo.topLeft +
          Offset(_aic1.box.left * scale, _aic1.box.top * scale - 20),
    );
  });

  testWidgets('rows paint their tint on their own clipped Material', (
    tester,
  ) async {
    _setSurface(tester, const Size(800, 1600));
    await _pump(tester, candidates: [_aic1, _other]);
    final scheme = Theme.of(
      tester.element(find.byKey(const ValueKey('scanRow1'))),
    ).colorScheme;

    Material rowMaterial(int n) => tester.widget<Material>(
      find
          .ancestor(
            of: find.byKey(ValueKey('scanRow$n')),
            matching: find.byType(Material),
          )
          .first,
    );
    final aic = rowMaterial(1);
    expect(aic.color, scheme.primaryContainer);
    expect(aic.clipBehavior, Clip.antiAlias);
    final other = rowMaterial(2);
    expect(other.type, MaterialType.transparency);
    expect(other.clipBehavior, Clip.antiAlias);
    expect(
      tester.widget<ListTile>(find.byKey(const ValueKey('scanRow1'))).tileColor,
      isNull,
    );
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

  testWidgets('dragging in selection mode reports the selected fractions', (
    tester,
  ) async {
    _setSurface(tester, const Size(800, 1600));
    Rect? selected;
    await pumpMedoraApp(
      tester,
      Scaffold(
        body: ScanReviewView(
          image: MemoryImage(_png),
          imageSize: const Size(1000, 1000),
          candidates: const [],
          onSelected: (_) {},
          onRetake: () {},
          onManualEntry: () {},
          selecting: true,
          onToggleSelecting: () {},
          onRescanArea: (area) => selected = area,
        ),
      ),
      locale: const Locale('de'),
    );
    final photo = find.byKey(const ValueKey('scanPhoto'));
    final box = tester.getRect(photo);
    await tester.timedDragFrom(
      box.topLeft + Offset(box.width / 4, box.height / 4),
      Offset(box.width / 4, box.height / 4),
      const Duration(milliseconds: 200),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('scanRescanArea')));
    await tester.pumpAndSettle();
    expect(selected, isNotNull);
    expect(selected!.left, closeTo(0.25, 0.02));
    expect(selected!.top, closeTo(0.25, 0.02));
    expect(selected!.right, closeTo(0.5, 0.02));
    expect(selected!.bottom, closeTo(0.5, 0.02));
  });

  testWidgets('the select-area button toggles the mode', (tester) async {
    _setSurface(tester, const Size(800, 1600));
    var toggled = 0;
    await pumpMedoraApp(
      tester,
      Scaffold(
        body: ScanReviewView(
          image: MemoryImage(_png),
          imageSize: const Size(1000, 1000),
          candidates: const [],
          onSelected: (_) {},
          onRetake: () {},
          onManualEntry: () {},
          onToggleSelecting: () => toggled++,
          onRescanArea: (_) {},
        ),
      ),
      locale: const Locale('de'),
    );
    await tester.tap(find.byKey(const ValueKey('scanSelectArea')));
    expect(toggled, 1);
  });

  testWidgets('without a rescan callback the button is absent', (tester) async {
    _setSurface(tester, const Size(800, 1600));
    await pumpMedoraApp(
      tester,
      Scaffold(
        body: ScanReviewView(
          image: MemoryImage(_png),
          imageSize: const Size(1000, 1000),
          candidates: const [],
          onSelected: (_) {},
          onRetake: () {},
          onManualEntry: () {},
        ),
      ),
      locale: const Locale('de'),
    );
    expect(find.byKey(const ValueKey('scanSelectArea')), findsNothing);
  });

  testWidgets('the rescan button appears only once an area is drawn', (
    tester,
  ) async {
    _setSurface(tester, const Size(800, 1600));
    await pumpMedoraApp(
      tester,
      Scaffold(
        body: ScanReviewView(
          image: MemoryImage(_png),
          imageSize: const Size(1000, 1000),
          candidates: const [],
          onSelected: (_) {},
          onRetake: () {},
          onManualEntry: () {},
          selecting: true,
          onToggleSelecting: () {},
          onRescanArea: (_) {},
        ),
      ),
      locale: const Locale('de'),
    );
    expect(find.byKey(const ValueKey('scanRescanArea')), findsNothing);
    expect(
      find.text('Ziehe einen Rahmen um den Code und scanne die Auswahl.'),
      findsOneWidget,
    );
  });

  testWidgets('no overflow at 360x800 with the rescan controls', (
    tester,
  ) async {
    _setSurface(tester, const Size(360, 800));
    await pumpMedoraApp(
      tester,
      Scaffold(
        body: ScanReviewView(
          image: MemoryImage(_png),
          imageSize: const Size(1000, 1000),
          candidates: [
            for (var i = 0; i < 12; i++)
              _c(
                'A0${i}0000000 mit sehr langem Quelltext',
                CodeKind.values[i % 4],
                Rect.fromLTWH(i * 80.0, i * 80.0, 200, 50),
              ),
          ],
          onSelected: (_) {},
          onRetake: () {},
          onManualEntry: () {},
          selecting: true,
          onToggleSelecting: () {},
          onRescanArea: (_) {},
        ),
      ),
      locale: const Locale('de'),
    );
    final photo = find.byKey(const ValueKey('scanPhoto'));
    final box = tester.getRect(photo);
    await tester.timedDragFrom(
      box.topLeft + Offset(box.width / 4, box.height / 4),
      Offset(box.width / 4, box.height / 4),
      const Duration(milliseconds: 200),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('scanRescanArea')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
