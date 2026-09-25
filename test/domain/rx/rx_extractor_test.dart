import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:medora/domain/rx/rx_draft.dart';
import 'package:medora/domain/rx/rx_extractor.dart';
import 'package:medora/domain/rx/rx_rules.dart';

// Invented data only (see test/fixtures/rx_scan).
const _patient = 'RSSMRA85T10A562S';
const _doctor = 'BNCLCU70A01A952Z';
const _ssnBarcodes = ['041A0', '0012345678', _patient];
const _whiteBarcodes = [
  'STAMPATO DA SISTEMATS - RICETTA BIANCA',
  'G00001234567',
  '7XQ2K',
  _patient,
  _doctor,
];

String _fixture(String name) =>
    File('test/fixtures/rx_scan/$name.txt').readAsStringSync();

String _reversed(String text) =>
    text.trimRight().split('\n').reversed.join('\n');

Set<String> _itemKeys(RxDraft d) => {
  for (final i in d.items) '${i.aic}|${i.description}|${i.packs}|${i.posology}',
};

void main() {
  late String ssn;
  late String white;

  setUpAll(() {
    ssn = _fixture('ssn_promemoria');
    white = _fixture('white_promemoria');
  });

  group('SSN promemoria', () {
    test('reads every field', () {
      final d = RxExtractor.extract(barcodes: _ssnBarcodes, text: ssn);

      expect(d.kind, RxKind.ssn);
      expect(d.nre, '041A00012345678');
      expect(d.pin, isNull);
      expect(d.taxCode, _patient);
      expect(d.doctorTaxCode, _doctor);
      expect(d.doctor, 'Bianchi Luca');
      expect(d.patientName, 'Rossi Mario');
      expect(d.issuedOn, DateTime(2026, 3, 3));
      expect(d.validUntil, DateTime(2026, 4, 2));
      expect(d.validDays, 30);
      expect(d.maxDispensings, isNull);
      expect(d.exemptionCode, isNull);
      expect(d.priority, isNull);
      expect(d.items, hasLength(1));
      final item = d.items.single;
      expect(item.aic, '012345678');
      expect(item.description, 'PARACETAMOLO*20CPR 500MG');
      expect(item.packs, 1);
      expect(item.posology, '1x3 bei Bedarf');
      expect(d.fromBarcode, {'nre', 'taxCode'});
      expect(d.isEmpty, isFalse);
    });

    test('an exemption and a priority are read when filled in', () {
      final text = ssn
          .replaceFirst('ESENZIONE:NON ESENTE', 'ESENZIONE: E01')
          .replaceFirst('BEFREIUNG:NICHT BEFREIT', 'BEFREIUNG: E01')
          .replaceFirst('(U,B,D,P):', '(U,B,D,P): B');
      final d = RxExtractor.extract(barcodes: _ssnBarcodes, text: text);
      expect(d.exemptionCode, 'E01');
      expect(d.priority, RxPriority.b);
    });
  });

  group('white electronic promemoria', () {
    test('reads every field', () {
      final d = RxExtractor.extract(barcodes: _whiteBarcodes, text: white);

      expect(d.kind, RxKind.whiteRepeatable);
      expect(d.nre, 'G00001234567');
      expect(d.pin, '7XQ2K');
      expect(d.taxCode, _patient);
      expect(d.doctorTaxCode, _doctor);
      expect(d.issuedOn, DateTime(2026, 3, 3));
      expect(d.validUntil, DateTime(2026, 9, 3));
      expect(d.validDays, isNull);
      expect(d.maxDispensings, 10);
      expect(d.doctor, 'Bianchi Luca');
      expect(d.patientName, isNull);
      expect(d.exemptionCode, isNull);
      expect(d.items, hasLength(2));
      expect(d.items[0].aic, '011111111');
      expect(d.items[0].description, 'IBUPROFENE*12CPR 400MG');
      expect(d.items[0].packs, 1);
      expect(d.items[0].posology, '1 ABENDS');
      expect(d.items[1].aic, '022222222');
      expect(d.items[1].description, 'SALINA*SPRAY NASALE 20ML');
      expect(d.items[1].packs, 1);
      expect(d.items[1].posology, '3X TÄGLICH');
      expect(d.fromBarcode, {'nre', 'pin', 'taxCode', 'doctorTaxCode'});
    });

    test('a white prescription without repeats is plain white', () {
      final text = white
          .split('\n')
          .where((l) => !l.startsWith('RIPETIBILE'))
          .join('\n');
      final d = RxExtractor.extract(barcodes: _whiteBarcodes, text: text);
      expect(d.kind, RxKind.white);
      expect(d.maxDispensings, isNull);
    });
  });

  group('patient vs doctor', () {
    final swapped = ['G00001234567', '7XQ2K', _doctor, _patient];

    test('a tax code known on this device is the patient', () {
      final d = RxExtractor.extract(
        barcodes: swapped,
        text: white,
        knownTaxCodes: {_patient},
      );
      expect(d.taxCode, _patient);
      expect(d.doctorTaxCode, _doctor);
    });

    test('a known tax code wins even without any labels', () {
      final d = RxExtractor.extract(
        barcodes: swapped,
        text: '',
        knownTaxCodes: {_patient},
      );
      expect(d.taxCode, _patient);
      expect(d.doctorTaxCode, _doctor);
    });

    test('without known codes, the nearest label decides', () {
      final d = RxExtractor.extract(barcodes: swapped, text: white);
      expect(d.taxCode, _patient);
      expect(d.doctorTaxCode, _doctor);
    });

    test('with neither, barcode order decides but is not trusted', () {
      final d = RxExtractor.extract(barcodes: swapped, text: '');
      expect(d.taxCode, _doctor);
      expect(d.doctorTaxCode, _patient);
      expect(d.fromBarcode, isNot(contains('taxCode')));
      expect(d.fromBarcode, isNot(contains('doctorTaxCode')));
    });

    test('labels that do not separate the codes fall back to order', () {
      final d = RxExtractor.extract(
        barcodes: const [],
        text:
            'C.F. PAZIENTE/STEUERNUMMER DES PATIENTEN '
            'STEUERN. DES ARZ./COD. FIS. MED.\n'
            '$_patient $_doctor',
      );
      expect(d.taxCode, _patient);
      expect(d.doctorTaxCode, _doctor);
    });

    test('a lone doctor-labelled code is never the doctor alone', () {
      final d = RxExtractor.extract(
        barcodes: const [_doctor],
        text: 'STEUERN. DES ARZ./COD. FIS. MED. $_doctor',
      );
      expect(d.doctorTaxCode, isNull);
      expect(d.fromBarcode, isNot(contains('doctorTaxCode')));
    });
  });

  group('shuffled lines', () {
    test('SSN in reverse reading order gives the same values', () {
      final a = RxExtractor.extract(barcodes: _ssnBarcodes, text: ssn);
      final b = RxExtractor.extract(
        barcodes: _ssnBarcodes,
        text: _reversed(ssn),
      );
      expect(b.nre, a.nre);
      expect(b.taxCode, a.taxCode);
      expect(b.doctorTaxCode, a.doctorTaxCode);
      expect(b.issuedOn, a.issuedOn);
      expect(b.validUntil, a.validUntil);
      expect(_itemKeys(b), _itemKeys(a));
    });

    test('white in reverse reading order gives the same values', () {
      final a = RxExtractor.extract(barcodes: _whiteBarcodes, text: white);
      final b = RxExtractor.extract(
        barcodes: _whiteBarcodes,
        text: _reversed(white),
      );
      expect(b.nre, a.nre);
      expect(b.pin, a.pin);
      expect(b.taxCode, a.taxCode);
      expect(b.doctorTaxCode, a.doctorTaxCode);
      expect(b.issuedOn, a.issuedOn);
      expect(b.validUntil, a.validUntil);
      expect(b.maxDispensings, a.maxDispensings);
      expect(_itemKeys(b), _itemKeys(a));
    });
  });

  group('OCR noise', () {
    test('an O read for a 0 inside an AIC is corrected', () {
      final text = ssn.replaceFirst('(012345678)', '(O12345678)');
      final d = RxExtractor.extract(barcodes: _ssnBarcodes, text: text);
      expect(d.items.single.aic, '012345678');
    });

    test('an AIC split by one OCR space is joined', () {
      final text = ssn.replaceFirst('(012345678)', '(01234567 8)');
      final d = RxExtractor.extract(barcodes: _ssnBarcodes, text: text);
      expect(d.items.single.aic, '012345678');
    });

    test('long digit runs (authentication code, phone) are no AIC', () {
      final d = RxExtractor.extract(
        barcodes: const [],
        text:
            'CODICE AUTENTICAZIONE:030320261234567890123456 ABC\n'
            'TEL 0471123456789 STUDIO MEDICO',
      );
      expect(d.items, isEmpty);
    });

    test('without barcodes the NRE is not invented from text', () {
      final d = RxExtractor.extract(barcodes: const [], text: ssn);
      expect(d.nre, isNull);
      expect(d.pin, isNull);
      expect(d.kind, RxKind.ssn);
      expect(d.taxCode, _patient);
      expect(d.doctorTaxCode, _doctor);
      expect(d.fromBarcode, isEmpty);
    });

    test('umlauts read as plain letters are accepted', () {
      final text = white
          .replaceAll('GÜLTIG', 'GULTIG')
          .replaceAll('FÜR', 'FUR')
          .replaceAll('VALIDA FINO AL', 'VALIDA FIN AL');
      final d = RxExtractor.extract(barcodes: _whiteBarcodes, text: text);
      expect(d.validUntil, DateTime(2026, 9, 3));
      expect(d.maxDispensings, 10);
    });

    test('an impossible date is dropped', () {
      final text = white.replaceAll('03/09/2026', '31/02/2026');
      final d = RxExtractor.extract(barcodes: _whiteBarcodes, text: text);
      expect(d.validUntil, isNull);
      expect(d.issuedOn, DateTime(2026, 3, 3));
    });

    test('an invalid NRE barcode pair is dropped', () {
      final d = RxExtractor.extract(
        barcodes: const ['041A0', '12345'],
        text: '',
      );
      expect(d.nre, isNull);
    });
  });

  group('conflicting barcodes', () {
    test('two SSN sheets in one photo give no NRE', () {
      final d = RxExtractor.extract(
        barcodes: const ['041A0', '0012345678', '041A0', '0012345679'],
        text: '',
      );
      expect(d.nre, isNull);
      expect(d.fromBarcode, isNot(contains('nre')));
    });

    test('two different NRE first halves give no NRE', () {
      final d = RxExtractor.extract(
        barcodes: const ['041A0', '0012345678', '042A0'],
        text: '',
      );
      expect(d.nre, isNull);
    });

    test('the same barcode read twice is no conflict', () {
      final d = RxExtractor.extract(
        barcodes: const ['041A0', '0012345678', '041A0', '0012345678'],
        text: '',
      );
      expect(d.nre, '041A00012345678');
    });

    test('two white sheets in one photo give no NRBE and no PIN', () {
      final d = RxExtractor.extract(
        barcodes: const ['G00001234567', '7XQ2K', 'G00001234568', '8YR3L'],
        text: '',
      );
      expect(d.nre, isNull);
      expect(d.pin, isNull);
      expect(d.fromBarcode, isEmpty);
    });

    test('two different PINs leave the PIN empty', () {
      final d = RxExtractor.extract(
        barcodes: const ['G00001234567', '7XQ2K', '8YR3L'],
        text: '',
      );
      expect(d.nre, 'G00001234567');
      expect(d.pin, isNull);
      expect(d.fromBarcode, {'nre'});
    });

    test('a missing PIN barcode is not replaced by an NRE first half', () {
      final d = RxExtractor.extract(
        barcodes: const ['G00001234567', '041A0'],
        text: '',
      );
      expect(d.nre, 'G00001234567');
      expect(d.pin, isNull);
      expect(d.fromBarcode, {'nre'});
    });
  });

  group('issue date', () {
    test('a birth date on the patient line is not the issue date', () {
      final d = RxExtractor.extract(
        barcodes: const [],
        text:
            'ZUNAME UND NAME DES BETREUTEN:ROSSI MARIO 10/12/1985\n'
            'DATUM/DATA:\n'
            'PRESCRIZIONE VALIDA PER 30 GIORNI',
      );
      expect(d.issuedOn, isNull);
      expect(d.validUntil, isNull);
    });

    test('an implausibly old date after the label is dropped', () {
      final d = RxExtractor.extract(
        barcodes: const [],
        text: 'DATUM/DATA: ROSSI MARIO NATO 10/12/1985',
      );
      expect(d.issuedOn, isNull);
    });

    test('the birth date value is skipped wherever it appears', () {
      final d = RxExtractor.extract(
        barcodes: const [],
        text:
            'ZUNAME UND NAME DES BETREUTEN:ROSSI MARIO 10/12/2005\n'
            'DATUM/DATA: 10/12/2005',
      );
      expect(d.issuedOn, isNull);
    });

    test('an issue date after the stated validity is dropped', () {
      final d = RxExtractor.extract(
        barcodes: const [],
        text:
            'DATUM/DATA: 03/03/2026\n'
            'VALIDA FINO AL: 01/03/2026',
      );
      expect(d.issuedOn, isNull);
      expect(d.validUntil, DateTime(2026, 3));
    });

    test('a day without its leading zero is read', () {
      final d = RxExtractor.extract(
        barcodes: const [],
        text: 'DATUM/DATA: 3/03/2026',
      );
      expect(d.issuedOn, DateTime(2026, 3, 3));
    });
  });

  group('dosage alignment', () {
    test('an empty white dosage stays with its own item', () {
      final text = white.replaceFirst(
        'POSOLOGIA/POSOLOGIE: 1 ABENDS TDL: NO/NEIN',
        'POSOLOGIA/POSOLOGIE:',
      );
      final d = RxExtractor.extract(barcodes: _whiteBarcodes, text: text);
      expect(d.items[0].description, 'IBUPROFENE*12CPR 400MG');
      expect(d.items[0].posology, isNull);
      expect(d.items[1].posology, '3X TÄGLICH');
    });

    const twoSsnItems = [
      'MENGE QTA',
      '(012345678) PARACETAMOLO*20CPR 500MG 1',
      "(EGA) PARACETAMOLO 500MG 20 UNITA' USO ORALE - 1x3 bei Bedarf",
      '(012745038) EUTIROX*50CPR 50MCG 1',
      "(EGA) LEVOTIROXINA 50MCG 50 UNITA' USO ORALE - 1 morgens",
    ];

    test('SSN dosage lines attach to the item right above', () {
      final d = RxExtractor.extract(
        barcodes: const [],
        text: twoSsnItems.join('\n'),
      );
      expect(d.items[0].posology, '1x3 bei Bedarf');
      expect(d.items[1].posology, '1 morgens');
    });

    test('SSN dosage lines in reverse order are not guessed', () {
      final d = RxExtractor.extract(
        barcodes: const [],
        text: twoSsnItems.reversed.join('\n'),
      );
      expect(d.items, hasLength(2));
      for (final item in d.items) {
        expect(item.posology, isNull);
      }
    });
  });

  test('a trailing number without the SSN quantity column is the name', () {
    final d = RxExtractor.extract(
      barcodes: const [],
      text: '(012745038) EUTIROX 50',
    );
    expect(d.items.single.description, 'EUTIROX 50');
    expect(d.items.single.packs, 1);
  });

  test('a valid NRE pair makes it SSN despite white text', () {
    final d = RxExtractor.extract(
      barcodes: const ['041A0', '0012345678'],
      text: 'RICETTA BIANCA',
    );
    expect(d.kind, RxKind.ssn);
  });

  test('a doctor name continued on the next line is joined', () {
    final d = RxExtractor.extract(
      barcodes: const [],
      text:
          'COGNOME E NOME DEL MEDICO/NACHNAME UND NAME DES ARZTES: BIANCHI\n'
          'LUCA\n'
          'CODICE FISCALE/STEUERNUMMER',
    );
    expect(d.doctor, 'Bianchi Luca');
  });

  test('apostrophes survive title-casing', () {
    final d = RxExtractor.extract(
      barcodes: const [],
      text: "ZUNAME UND NAME DES ARZTES:D'ANGELO ANNA",
    );
    expect(d.doctor, "D'Angelo Anna");
  });

  test('nothing recognisable is empty', () {
    final d = RxExtractor.extract(
      barcodes: const ['4006381333931', 'https://example.org'],
      text: 'Hello world\nNothing to see here 42',
    );
    expect(d.isEmpty, isTrue);
    expect(const RxDraft().isEmpty, isTrue);
  });
}
