/// Medora - Reporting a Supabase project that lacks a migration.
///
/// A push to a project whose table is missing a column the app writes keeps
/// failing (and backing off) until the project is migrated. The sync
/// failures dialog shows the error's text, so the text has to name the
/// migration file that fixes it; a bare PostgREST code only invites
/// "discard", which replaces the local data with the server's.
library;

import 'package:supabase_flutter/supabase_flutter.dart';

/// A Supabase project whose [table] has no [column], which [migration]
/// adds.
class MissingColumnException implements Exception {
  const MissingColumnException({
    required this.table,
    required this.column,
    required this.migration,
    required this.cause,
  });

  final String table;

  /// The column the project does not have, as the server named it.
  final String column;

  /// The migration file that adds it, relative to the repository root.
  final String migration;
  final PostgrestException cause;

  @override
  String toString() =>
      'The Supabase project is missing the $table.$column column. '
      'Apply $migration to the project, then sync again '
      '(server: ${cause.message}).';
}

/// The first name the server quoted in its message — the column it could not
/// find.
final _quotedName = RegExp(r'''["']([A-Za-z_][A-Za-z0-9_]*)["']''');

/// [error] read as a missing column of [table], else null: PostgREST answers
/// `PGRST204` when a payload key is not in its schema cache, Postgres
/// `42703` when the column does not exist at all. [fallbackColumn] names the
/// column when the message quotes none.
MissingColumnException? missingColumn(
  Object error, {
  required String table,
  required String migration,
  required String fallbackColumn,
}) {
  if (error is! PostgrestException) return null;
  if (error.code != 'PGRST204' && error.code != '42703') return null;
  final column = _quotedName.firstMatch(error.message)?.group(1);
  return MissingColumnException(
    table: table,
    column: column ?? fallbackColumn,
    migration: migration,
    cause: error,
  );
}

/// Runs [send], turning a missing-column rejection into a
/// [MissingColumnException] (see [missingColumn]). Every other error passes
/// through untouched.
Future<T> mapMissingColumn<T>(
  Future<T> Function() send, {
  required String table,
  required String migration,
  required String fallbackColumn,
}) async {
  try {
    return await send();
  } on PostgrestException catch (e) {
    final missing = missingColumn(
      e,
      table: table,
      migration: migration,
      fallbackColumn: fallbackColumn,
    );
    if (missing != null) throw missing;
    rethrow;
  }
}

/// A Supabase project without the sync v2 migration ([migration]): it has
/// no `medora_sync_state` function, or one that reports an older schema.
/// The sync cycle stops before it writes anything.
class MissingMigrationException implements Exception {
  const MissingMigrationException({required this.migration, this.cause});

  /// The migration file to apply, relative to the repository root.
  final String migration;

  /// The server's answer, when there was one.
  final Object? cause;

  @override
  String toString() =>
      'The Supabase project is missing the sync v2 migration. '
      'Apply $migration to the project, then sync again'
      '${cause is PostgrestException ? ' (server: ${(cause! as PostgrestException).message})' : ''}.';
}
