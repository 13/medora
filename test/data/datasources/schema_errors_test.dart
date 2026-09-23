import 'package:flutter_test/flutter_test.dart';
import 'package:medora/data/datasources/schema_errors.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  test('PGRST205 and 42P01 name the migration that creates the table', () {
    for (final code in ['PGRST205', '42P01']) {
      final e = missingTable(
        PostgrestException(message: 'no table', code: code),
        table: 'rx',
        migration: 'supabase/migrations/20260923000000_rx.sql',
      );
      expect(e, isNotNull);
      expect(e.toString(), contains('20260923000000_rx.sql'));
    }
  });

  test('a single-row read reports the code inside the answer', () {
    // postgrest 2.9 throws a `maybeSingle` error again as the HTTP status,
    // with the server's answer as its message.
    final e = missingTable(
      const PostgrestException(
        message:
            '{"code":"PGRST205","message":"Could not find the table '
            "'public.rx' in the schema cache\"}",
        code: '404',
      ),
      table: 'rx',
      migration: 'supabase/migrations/20260923000000_rx.sql',
    );
    expect(e, isNotNull);
  });

  test('other errors are not a missing table', () {
    expect(
      missingTable(
        const PostgrestException(message: 'x', code: '23505'),
        table: 'rx',
        migration: 'm',
      ),
      isNull,
    );
    expect(
      missingTable(
        const PostgrestException(message: '{"code":"PGRST116"}', code: '406'),
        table: 'rx',
        migration: 'm',
      ),
      isNull,
    );
  });
}
