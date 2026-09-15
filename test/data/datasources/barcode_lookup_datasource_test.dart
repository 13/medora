import 'package:flutter_test/flutter_test.dart';
import 'package:medora/data/datasources/barcode_lookup_datasource.dart';

void main() {
  group('BarcodeLookupDatasource.extractCodes', () {
    test('strips the leading letter of an AIC code', () {
      expect(BarcodeLookupDatasource.extractCodes('A023834118'), ['023834118']);
    });

    test('finds a 6-digit group code inside a sentence', () {
      expect(BarcodeLookupDatasource.extractCodes('AIC n. 034567 cpr'), [
        '034567',
      ]);
    });

    test('deduplicates repeated codes', () {
      expect(BarcodeLookupDatasource.extractCodes('A034567891 / 034567891'), [
        '034567891',
      ]);
    });

    test('never cuts a 13-digit EAN into a 9-digit prefix', () {
      expect(BarcodeLookupDatasource.extractCodes('8057737141836'), isEmpty);
      expect(
        BarcodeLookupDatasource.extractCodes('EAN 8001234567890'),
        isEmpty,
      );
    });

    test('ignores digit runs longer than 9 digits', () {
      expect(BarcodeLookupDatasource.extractCodes('1234567890'), isEmpty);
    });

    test('ignores numbers shorter than 6 digits', () {
      expect(BarcodeLookupDatasource.extractCodes('Lotto 12345'), isEmpty);
      expect(BarcodeLookupDatasource.extractCodes('Scad. 03/2027'), isEmpty);
    });

    test('an 8-digit run is matched whole', () {
      expect(BarcodeLookupDatasource.extractCodes('96385074'), ['96385074']);
    });

    test('manual entry of a full EAN falls back to the raw value', () {
      // The scanner's manual entry uses `codes.first` when present, else the
      // typed value; a full EAN must not turn into a 9-digit AIC prefix.
      const typed = '8057737141836';
      final codes = BarcodeLookupDatasource.extractCodes(typed);
      expect(codes.isNotEmpty ? codes.first : typed, typed);
    });
  });
}
