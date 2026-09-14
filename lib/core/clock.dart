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
