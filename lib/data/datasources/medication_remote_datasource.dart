/// Medora - Medication Remote Datasource
///
/// Handles all Supabase interactions for medications.
library;

import 'package:medora/core/constants.dart';
import 'package:medora/data/models/medication_model.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// The migration that adds the `ean` column this datasource sends.
const medicationEanMigration =
    'supabase/migrations/20260916000000_medication_ean.sql';

/// A Supabase project whose `medications` table is missing a column the app
/// writes. The push that hit it keeps failing (and backing off) until the
/// project is migrated, so the message has to say which file fixes it —
/// without it the user only sees "1 row failed" (review I2).
class MissingMedicationColumnException implements Exception {
  const MissingMedicationColumnException(this.column, this.cause);

  /// The column the project does not have, as the server named it.
  final String column;
  final PostgrestException cause;

  @override
  String toString() =>
      'The Supabase project is missing the medications.$column column. '
      'Apply $medicationEanMigration to the project, then sync again '
      '(server: ${cause.message}).';
}

/// The first name the server quoted in its message — the column it could not
/// find.
final _quotedName = RegExp(r'''["']([A-Za-z_][A-Za-z0-9_]*)["']''');

/// [error] read as a missing column, else null: PostgREST answers `PGRST204`
/// when a payload key is not in its schema cache, Postgres `42703` when the
/// column does not exist at all.
MissingMedicationColumnException? missingMedicationColumn(Object error) {
  if (error is! PostgrestException) return null;
  if (error.code != 'PGRST204' && error.code != '42703') return null;
  final column = _quotedName.firstMatch(error.message)?.group(1);
  return MissingMedicationColumnException(column ?? 'ean', error);
}

/// Runs [send], turning a missing-column rejection into a
/// [MissingMedicationColumnException]. Every other error passes through
/// untouched.
Future<T> mapMedicationSchemaErrors<T>(Future<T> Function() send) async {
  try {
    return await send();
  } on PostgrestException catch (e) {
    final missing = missingMedicationColumn(e);
    if (missing != null) throw missing;
    rethrow;
  }
}

class MedicationRemoteDatasource {
  MedicationRemoteDatasource(this._client);

  final SupabaseClient _client;

  /// Get all medications for the current user.
  Future<List<MedicationModel>> getMedications() async {
    final response = await _client
        .from(AppConstants.medicationsTable)
        .select()
        .isFilter('deleted_at', null)
        .order('name');

    return (response as List)
        .map((json) => MedicationModel.fromJson(json as Map<String, dynamic>))
        .toList();
  }

  /// Rows changed after [since] (UTC); all rows when null. Includes tombstones.
  Future<List<MedicationModel>> getMedicationsSince(DateTime? since) async {
    final base = _client.from(AppConstants.medicationsTable).select();
    final filtered = since == null
        ? base
        : base.gt('updated_at', since.toUtc().toIso8601String());
    final response = await filtered.order('updated_at');
    return (response as List)
        .map((json) => MedicationModel.fromJson(json as Map<String, dynamic>))
        .toList();
  }

  /// The remote row's `updated_at`, or null when the row is not there.
  ///
  /// The push phase uses it to leave a remote row alone when it is newer than
  /// the local pending edit (true last-write-wins).
  Future<DateTime?> getUpdatedAt(String id) async {
    final response = await _client
        .from(AppConstants.medicationsTable)
        .select('updated_at')
        .eq('id', id)
        .maybeSingle();
    final raw = response?['updated_at'] as String?;
    return raw == null ? null : DateTime.parse(raw).toUtc();
  }

  /// Get a single medication by ID.
  /// The single row with [id], or null when the server does not have it.
  Future<MedicationModel?> getMedicationById(String id) async {
    final response = await _client
        .from(AppConstants.medicationsTable)
        .select()
        .eq('id', id)
        .maybeSingle();

    return response == null ? null : MedicationModel.fromJson(response);
  }

  /// Search medications by name or active ingredient.
  Future<List<MedicationModel>> searchMedications(String query) async {
    final response = await _client
        .from(AppConstants.medicationsTable)
        .select()
        .or('name.ilike.%$query%,active_ingredients.ilike.%$query%')
        .isFilter('deleted_at', null)
        .order('name');

    return (response as List)
        .map((json) => MedicationModel.fromJson(json as Map<String, dynamic>))
        .toList();
  }

  /// Add a new medication.
  Future<void> addMedication(MedicationModel model) =>
      mapMedicationSchemaErrors(() async {
        await _client
            .from(AppConstants.medicationsTable)
            .insert(model.toJson());
      });

  /// Update a medication.
  Future<void> updateMedication(MedicationModel model) =>
      mapMedicationSchemaErrors(() async {
        await _client
            .from(AppConstants.medicationsTable)
            .update(model.toJson())
            .eq('id', model.id);
      });

  /// Upsert a medication (insert or update).
  Future<void> upsertMedication(MedicationModel model) =>
      mapMedicationSchemaErrors(() async {
        await _client
            .from(AppConstants.medicationsTable)
            .upsert(model.toJson());
      });

  /// Delete a medication.
  /// Soft delete (tombstone). The row stays on the server with `deleted_at`
  /// set so other devices pull the deletion; see spec §4.6.
  Future<void> deleteMedication(String id) async {
    final now = DateTime.now().toUtc().toIso8601String();
    await _client
        .from(AppConstants.medicationsTable)
        .update({'deleted_at': now, 'updated_at': now})
        .eq('id', id);
  }

  /// Update medication quantity by delta.
  Future<void> updateQuantity(String id, int delta) async {
    final current = await getMedicationById(id);
    if (current == null) return;
    final newQuantity = (current.quantity + delta).clamp(0, 999999);

    await _client
        .from(AppConstants.medicationsTable)
        .update({'quantity': newQuantity})
        .eq('id', id);
  }
}
