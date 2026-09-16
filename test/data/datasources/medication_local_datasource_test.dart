import 'package:flutter_test/flutter_test.dart';
import 'package:medora/data/datasources/medication_local_datasource.dart';
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
}
