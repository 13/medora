/// Review I2: a Supabase project without the `ean` column must fail with a
/// message that names the migration, not with a raw PostgREST code that the
/// push then retries forever. The write path itself is covered in
/// `sync_table_test.dart`.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:medora/data/datasources/medication_remote_datasource.dart';
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
}
