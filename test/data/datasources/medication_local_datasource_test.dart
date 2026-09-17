import 'package:flutter_test/flutter_test.dart';
import 'package:medora/data/datasources/medication_local_datasource.dart';
import 'package:medora/data/datasources/stock_outbox_local_datasource.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/models/medication_model.dart';

import '../../helpers/test_database.dart';

void main() {
  setUp(setUpTestDatabase);
  tearDown(tearDownTestDatabase);

  final datasource = MedicationLocalDatasource();

  Future<void> insert(MedicationModel model) =>
      datasource.upsert(model, syncStatus: SyncStatus.synced);

  test(
    'a scanned code matches either the label code or the pack EAN',
    () async {
      await insert(
        const MedicationModel(
          id: 'm1',
          name: 'Tachipirina',
          quantity: 1,
          barcode: 'A1',
        ),
      );
      await insert(
        const MedicationModel(
          id: 'm2',
          name: 'Zinco-C',
          quantity: 1,
          barcode: '107018',
          ean: '8057737141836',
        ),
      );

      expect((await datasource.getMedicationByBarcode('A1'))?.id, 'm1');
      expect((await datasource.getMedicationByBarcode('107018'))?.id, 'm2');
      expect(
        (await datasource.getMedicationByBarcode('8057737141836'))?.id,
        'm2',
      );
      expect(await datasource.getMedicationByBarcode('8000000000000'), isNull);
    },
  );

  test('an exact label-code match wins over an EAN match', () async {
    // Review I3: the app itself creates the collision — a plain EAN scan
    // saves `barcode=<EAN>`, a label-code scan of the same pack saves
    // `barcode=107018, ean=<EAN>`. Without an ORDER BY, `LIMIT 1` returned
    // whichever row SQLite's plan happened to reach first.
    await insert(
      const MedicationModel(
        id: 'm-ean',
        name: 'Scanned as an EAN',
        quantity: 1,
        ean: '8057737141836',
      ),
    );
    await insert(
      const MedicationModel(
        id: 'm-code',
        name: 'Scanned by its label code',
        quantity: 1,
        barcode: '8057737141836',
      ),
    );

    expect(
      (await datasource.getMedicationByBarcode('8057737141836'))?.id,
      'm-code',
    );
  });

  test('two EAN matches resolve to the same row every time', () async {
    for (final id in ['m-b', 'm-a']) {
      await insert(
        MedicationModel(
          id: id,
          name: 'Zinco-C',
          quantity: 1,
          ean: '8057737141836',
        ),
      );
    }

    for (var i = 0; i < 3; i++) {
      expect(
        (await datasource.getMedicationByBarcode('8057737141836'))?.id,
        'm-a',
        reason: 'lookup $i',
      );
    }
  });

  test('the pack EAN survives a local write and read back', () async {
    await insert(
      const MedicationModel(
        id: 'm1',
        name: 'Zinco-C',
        quantity: 1,
        barcode: '107018',
        ean: '8057737141836',
      ),
    );

    final read = await datasource.getMedicationById('m1');
    expect(read?.ean, '8057737141836');
    expect(read?.toDomain().ean, '8057737141836');
  });

  test('a medication pending deletion is not found by its EAN', () async {
    await insert(
      const MedicationModel(
        id: 'm1',
        name: 'Zinco-C',
        quantity: 1,
        ean: '8057737141836',
      ),
    );
    await datasource.markDeleted('m1');

    expect(await datasource.getMedicationByBarcode('8057737141836'), isNull);
  });

  group('a stock change', () {
    final stamped = DateTime.utc(2026, 3, 1, 8);
    final later = DateTime.utc(2026, 3, 5, 9);
    final ds = MedicationLocalDatasource(now: () => later);

    Future<Map<String, Object?>> row() async =>
        (await (await AppDatabase.instance.database).query(
          'medications',
        )).single;

    Future<void> seed({int? version}) async {
      await insert(
        MedicationModel(
          id: 'm1',
          name: 'Moment',
          quantity: 10,
          updatedAt: stamped,
        ),
      );
      await (await AppDatabase.instance.database).update('medications', {
        'edited_at': stamped.toIso8601String(),
        'sync_version': version,
      });
    }

    Future<List<(int?, int?)>> waiting() async => [
      for (final op in await StockOutboxLocalDatasource().pending())
        (op.delta, op.setTo),
    ];

    test('that waits as a change leaves the row, its status and its stamps '
        'alone', () async {
      await seed(version: 3);
      final before = await row();

      await ds.adjustQuantity('m1', -2, opId: 'op1');

      final after = await row();
      expect(after['quantity'], 8);
      expect({...after, 'quantity': 10}, before);
      expect(await waiting(), [(-2, null)]);
    });

    test('that does not wait is stamped as a local write, and keeps the '
        'status', () async {
      await seed();

      await ds.adjustQuantity(
        'm1',
        -2,
        opId: 'op1',
        queueing: StockQueueing.ifKnownToServer,
      );

      final after = await row();
      expect(after['quantity'], 8);
      expect(after['sync_status'], SyncStatus.synced);
      expect(DateTime.parse(after['updated_at']! as String).toUtc(), later);
      expect(DateTime.parse(after['edited_at']! as String).toUtc(), later);
      expect(await waiting(), isEmpty);
    });

    test('without an op id nothing waits', () async {
      await seed(version: 3);

      await ds.adjustQuantity('m1', 5);

      expect((await row())['quantity'], 15);
      expect(await waiting(), isEmpty);
    });

    test('is brought into range as the server does', () async {
      await seed(version: 3);

      await ds.adjustQuantity('m1', -50, opId: 'op1');
      expect((await row())['quantity'], 0);
      await ds.adjustQuantity('m1', 0x7fffffffffffffff, opId: 'op2');
      expect((await row())['quantity'], maxStock);
    });

    test('of a deleted medication changes nothing', () async {
      await seed(version: 3);
      await ds.markDeleted('m1');

      expect(await ds.adjustQuantity('m1', -1, opId: 'op1'), isNull);

      expect((await row())['quantity'], 10);
      expect(await waiting(), isEmpty);
    });
  });
}
