/// Review I2: a Supabase project without the `ean` column must fail with a
/// message that names the migration, not with a raw PostgREST code that the
/// push then retries forever.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:medora/data/datasources/medication_remote_datasource.dart';
import 'package:medora/data/datasources/schema_errors.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  test('PGRST204 for a missing column names the column and the migration', () {
    const error = PostgrestException(
      message:
          "Could not find the 'ean' column of 'medications' in the schema "
          'cache',
      code: 'PGRST204',
    );

    final missing = missingMedicationColumn(error);
    expect(missing, isNotNull);
    expect(missing!.column, 'ean');
    expect(missing.table, 'medications');
    expect(missing.toString(), contains('medications.ean'));
    expect(
      missing.toString(),
      contains('supabase/migrations/20260916000000_medication_ean.sql'),
    );
    expect(missing.toString(), contains('ean'));
  });

  test('a Postgres 42703 undefined column is recognised too', () {
    const error = PostgrestException(
      message: 'column "ean" of relation "medications" does not exist',
      code: '42703',
    );

    expect(missingMedicationColumn(error)?.column, 'ean');
  });

  test('any other Postgrest error is left alone', () {
    const error = PostgrestException(
      message: 'new row violates row-level security policy',
      code: '42501',
    );

    expect(missingMedicationColumn(error), isNull);
    expect(missingMedicationColumn(StateError('offline')), isNull);
  });

  test(
    'a push against a project without the column reports the migration',
    () async {
      await expectLater(
        mapMedicationSchemaErrors<void>(
          () async => throw const PostgrestException(
            message:
                "Could not find the 'ean' column of 'medications' in the "
                'schema cache',
            code: 'PGRST204',
          ),
        ),
        throwsA(
          isA<MissingColumnException>().having(
            (e) => e.toString(),
            'message',
            contains('20260916000000_medication_ean.sql'),
          ),
        ),
      );
    },
  );

  test('a push that succeeds is untouched', () async {
    expect(await mapMedicationSchemaErrors(() async => 42), 42);
    await expectLater(
      mapMedicationSchemaErrors<void>(
        () async => throw StateError('network down'),
      ),
      throwsA(isA<StateError>()),
    );
  });
}
