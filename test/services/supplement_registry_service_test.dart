import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:medora/services/supplement_registry_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  final fixture = File('test/fixtures/integratori_sample.csv');
  final gzipped = gzip.encode(fixture.readAsBytesSync());
  const meta = '{"rows":3,"sourceUpdated":"2026-09-01","builtAt":"x"}';
  final syncedAt = DateTime(2026, 9, 15, 10, 30);

  late Database db;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = await databaseFactoryFfiNoIsolate.openDatabase(inMemoryDatabasePath);
  });
  tearDown(() => db.close());

  MockClient serving({List<int>? data, int status = 200}) =>
      MockClient.streaming((request, _) async {
        if (request.url.toString() == SupplementRegistryService.metaUrl) {
          return http.StreamedResponse(Stream.value(meta.codeUnits), 200);
        }
        expect(request.url.toString(), SupplementRegistryService.dataUrl);
        final body = data ?? gzipped;
        return http.StreamedResponse(
          Stream.fromIterable([
            body.sublist(0, body.length ~/ 2),
            body.sublist(body.length ~/ 2),
          ]),
          status,
          contentLength: body.length,
        );
      });

  SupplementRegistryService service(http.Client client) =>
      SupplementRegistryService(
        client: client,
        openDatabase: () async => db,
        now: () => syncedAt,
      );

  test('sync stores the rows, count, sync time and source date', () async {
    final s = service(serving());
    final progress = <double>[];
    expect(await s.hasData(), isFalse);

    expect(await s.sync(onProgress: progress.add), 3);

    expect(await s.count(), 3);
    expect(await s.lastSync(), syncedAt);
    expect(await s.sourceUpdated(), DateTime.parse('2026-09-01'));
    expect(progress, isNotEmpty);
    expect(progress.last, 1.0);
    expect(progress, everyElement(inInclusiveRange(0.0, 1.0)));
  });

  test('findByCode matches exactly and ignores leading zeros', () async {
    final s = service(serving());
    await s.sync();

    const zinco = SupplementEntry(
      code: '107018',
      product: 'ZINCO-C',
      company: 'SYGNUM SRL',
    );
    expect(await s.findByCode('107018'), [zinco]);
    expect(await s.findByCode('0107018'), [zinco]);
    expect(await s.findByCode('COD MINSAN: 107018'), [zinco]);
    expect((await s.findByCode('123')).single.code, '00123');
    expect(await s.findByCode('10701'), isEmpty);
    expect(await s.findByCode('abc'), isEmpty);
  });

  test('keeps a quoted company containing a comma', () async {
    final s = service(serving());
    await s.sync();
    expect((await s.findByCode('98765')).single.company, 'ACME, S.P.A.');
  });

  test('searchByName is case-insensitive', () async {
    final s = service(serving());
    await s.sync();
    final names = (await s.searchByName('zinco')).map((e) => e.product);
    expect(names, ['ZINCO COMPLEX', 'ZINCO-C']);
    expect(await s.searchByName('z'), isEmpty);
  });

  test('lookups return nothing before the first download', () async {
    final s = service(serving());
    expect(await s.findByCode('107018'), isEmpty);
    expect(await s.searchByName('zinco'), isEmpty);
  });

  test('non-gzip data leaves the previous table intact', () async {
    await service(serving()).sync();
    final broken = service(serving(data: '<!doctype html>'.codeUnits));

    await expectLater(broken.sync(), throwsFormatException);

    expect(await broken.count(), 3);
    expect((await broken.findByCode('107018')).single.product, 'ZINCO-C');
  });

  test('an HTTP error leaves the previous table intact', () async {
    await service(serving()).sync();
    final failing = service(serving(status: 404));

    await expectLater(failing.sync(), throwsA(isA<http.ClientException>()));

    expect(await failing.count(), 3);
    expect(await failing.findByCode('107018'), hasLength(1));
  });

  test('a missing meta file stores no source date', () async {
    final client = MockClient.streaming((request, _) async {
      if (request.url.toString() == SupplementRegistryService.metaUrl) {
        return http.StreamedResponse(const Stream.empty(), 404);
      }
      return http.StreamedResponse(Stream.value(gzipped), 200);
    });
    final s = service(client);
    expect(await s.sync(), 3);
    expect(await s.sourceUpdated(), isNull);
  });

  test('a failed database open is retried on the next call', () async {
    var opens = 0;
    final s = SupplementRegistryService(
      client: serving(),
      openDatabase: () async {
        opens++;
        if (opens == 1) throw StateError('disk busy');
        return db;
      },
      now: () => syncedAt,
    );

    await expectLater(s.sync(), throwsStateError);
    expect(await s.sync(), 3);
    expect(opens, 2);
    expect(await s.findByCode('107018'), hasLength(1));
  });

  test('concurrent sync calls share one download', () async {
    var downloads = 0;
    final release = Completer<void>();
    final client = MockClient.streaming((request, _) async {
      if (request.url.toString() == SupplementRegistryService.metaUrl) {
        return http.StreamedResponse(Stream.value(meta.codeUnits), 200);
      }
      downloads++;
      await release.future;
      return http.StreamedResponse(Stream.value(gzipped), 200);
    });
    final s = service(client);
    final firstProgress = <double>[];
    final secondProgress = <double>[];

    final first = s.sync(onProgress: firstProgress.add);
    final second = s.sync(onProgress: secondProgress.add);
    release.complete();

    expect(await Future.wait([first, second]), [3, 3]);
    expect(downloads, 1);
    expect(firstProgress.last, 1.0);
    expect(secondProgress.last, 1.0);

    // Once finished, a new call downloads again.
    expect(await s.sync(), 3);
    expect(downloads, 2);
  });

  test('the code_key index exists after a sync', () async {
    await service(serving()).sync();
    final indexes = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'index' "
      "AND tbl_name = 'supplements'",
    );
    expect(indexes.map((r) => r['name']), ['idx_supplements_code_key']);
  });

  test('parseRegisterGzip rejects an unexpected header', () {
    final bytes = gzip.encode('a,b,c\n1,2,3\n'.codeUnits);
    expect(
      () => parseRegisterGzip(Uint8List.fromList(bytes)),
      throwsFormatException,
    );
  });

  test('codeKey strips non-digits and leading zeros', () {
    expect(SupplementRegistryService.codeKey(' 0107018 '), '107018');
    expect(SupplementRegistryService.codeKey('000'), '');
  });
}
