import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/presentation/screens/rx/pharmacy_screen.dart';
import 'package:medora/presentation/widgets/code128.dart';

void main() {
  Future<void> pump(WidgetTester tester, List<PharmacyCode> codes) async {
    // Three barcode sections (each ~180dp) plus the app bar overflow the
    // default 800×600 test surface, which would leave the last one
    // unbuilt inside the ListView's viewport; a taller surface avoids
    // scrolling to reach it.
    tester.view.physicalSize = const Size(400, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: PharmacyScreen(title: 'Ben', codes: codes),
      ),
    );
  }

  testWidgets(
    'an SSN prescription shows both NRE halves and the tax code, labelled',
    (tester) async {
      await pump(tester, const [
        PharmacyCode(label: 'NRE 1/2', value: '041A0'),
        PharmacyCode(label: 'NRE 2/2', value: '0012345678'),
        PharmacyCode(label: 'Tax code', value: 'RSSMRA85T10A562S'),
      ]);

      expect(find.text('NRE 1/2'), findsOneWidget);
      expect(find.text('041A0'), findsOneWidget);
      expect(find.text('NRE 2/2'), findsOneWidget);
      expect(find.text('0012345678'), findsOneWidget);
      expect(find.text('Tax code'), findsOneWidget);
      expect(find.text('RSSMRA85T10A562S'), findsOneWidget);
      expect(find.byType(Code128Barcode), findsNWidgets(3));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a white prescription shows the NRBE, its PIN and the tax code, '
      'labelled', (tester) async {
    await pump(tester, const [
      PharmacyCode(label: 'Prescription number (NRBE)', value: 'G00001234567'),
      PharmacyCode(label: 'PIN', value: '7XQ2K'),
      PharmacyCode(label: 'Tax code', value: 'RSSMRA85T10A562S'),
    ]);

    expect(find.text('Prescription number (NRBE)'), findsOneWidget);
    expect(find.text('G00001234567'), findsOneWidget);
    expect(find.text('PIN'), findsOneWidget);
    expect(find.text('7XQ2K'), findsOneWidget);
    expect(find.text('Tax code'), findsOneWidget);
    expect(find.text('RSSMRA85T10A562S'), findsOneWidget);
    expect(find.byType(Code128Barcode), findsNWidgets(3));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a single code still renders fine', (tester) async {
    await pump(tester, const [
      PharmacyCode(label: 'Prescription number (NRBE)', value: 'G00001234567'),
    ]);
    expect(find.byType(Code128Barcode), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
