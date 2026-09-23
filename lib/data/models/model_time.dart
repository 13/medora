/// Medora - A timestamp column read from a server or local row.
///
/// Shared by the models that keep a plain `DateTime?` column (`created_at`,
/// `updated_at`, `deleted_at`, and the person/rx date-only columns):
/// anything that is not a parseable string reads as null.
library;

/// The instant [raw] holds, or null when it is not a string, or not a date.
DateTime? parseStamp(Object? raw) =>
    raw is String ? DateTime.tryParse(raw) : null;
