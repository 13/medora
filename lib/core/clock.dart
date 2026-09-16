/// Medora - Injectable clock.
///
/// The single "now" seam: entities take a `DateTime now`, providers and
/// widgets read it from `nowProvider`, and only [systemNow] ever calls
/// `DateTime.now()` on behalf of the UI layer.
library;

/// Signature of an injectable clock.
typedef Now = DateTime Function();

/// The default clock: the real wall clock.
DateTime systemNow() => DateTime.now();

/// Whole calendar days from [from] to [to], ignoring the time of day.
///
/// Both dates are re-anchored to UTC midnight first, so a daylight-saving
/// transition inside the range cannot shave an hour off the result.
int calendarDaysBetween(DateTime from, DateTime to) => DateTime.utc(
  to.year,
  to.month,
  to.day,
).difference(DateTime.utc(from.year, from.month, from.day)).inDays;

/// The `updated_at` to stamp on a row whose stored value is [previous].
///
/// Normally [now], but never earlier than one millisecond after [previous]:
/// a device clock that jumps backwards (an NTP correction, a manual change,
/// a second device in another timezone writing the row) would otherwise
/// stamp an edit that looks older than the copy it replaces, and
/// last-write-wins sync would throw the edit away.
DateTime nextUpdatedAt(DateTime? previous, DateTime now) {
  if (previous == null) return now;
  final floor = previous.add(const Duration(milliseconds: 1));
  return now.isAfter(floor) ? now : floor;
}

/// The `updated_at` of a dose row the app generated from a schedule.
///
/// It is the weakest stamp there is, so under last-write-wins any copy of the
/// same dose that a person actually touched, on any device, is newer.
final DateTime generatedUpdatedAt = DateTime.utc(1970);

/// The `updated_at` of a change the app made on its own (marking an overdue
/// dose missed) to a row stamped [previous]: just past [previous], never the
/// current time, so the change loses to any real edit made elsewhere since
/// that copy was stored.
DateTime automaticUpdatedAt(DateTime? previous) =>
    previous == null ? generatedUpdatedAt : nextUpdatedAt(previous, previous);
