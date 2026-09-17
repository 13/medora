/// Medora - How a local change records when it was made (`edited_at`).
///
/// The column is always UTC ISO 8601 text with a `Z`, never naive local
/// time: naive text is read back in whatever zone the phone is in by then,
/// and in the autumn fall-back hour a later edit would read as an earlier
/// one (design §6).
library;

/// The `edited_at` text of a change stamped [stamp] and made at [now].
///
/// [stamp] is normally [now]. It can be later: `updated_at` is never
/// stamped at or before the row's previous `updated_at` (`nextUpdatedAt`),
/// and a previous stamp written as naive local time in another zone, or
/// before the clock stepped back, can read as a time still to come. An edit
/// time is never later than [now], so such a change cannot beat a real
/// later edit on another device.
String editedAtText(DateTime stamp, DateTime now) =>
    (stamp.isAfter(now) ? now : stamp).toUtc().toIso8601String();
