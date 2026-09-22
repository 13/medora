/// What a year of sick leave adds up to.
///
/// Sick leave is a *range* on a treatment (`sickLeaveFrom`/`sickLeaveTo`,
/// date only, open while `to` is null), never a per-day record, so every
/// day-level answer here is derived.
///
/// Everything comes from one deduplicated set of dates rather than from a
/// sum of per-treatment lengths, because two treatments can overlap — a flu
/// and a back injury in the same week — and summing them reports more days
/// off than the year contains.
///
/// Nothing reads the clock: an open leave counts up to the `now` it is
/// given, so the same data always produces the same answer under test.
library;

import 'package:medora/domain/entities/treatment.dart';

/// Midnight of [date]'s calendar day, which is how a day is identified here.
DateTime _dayOf(DateTime date) => DateTime(date.year, date.month, date.day);

/// The days of [year] any of [treatments] was signed off, each counted once.
///
/// Both ends of a leave are included: a note "from Monday to Friday" is five
/// days. An open leave runs to [now] and no further, and contributes nothing
/// when it has not started yet. A range whose end precedes its start — which
/// a synced or restored row can carry, since the form never validated it —
/// contributes nothing rather than throwing.
Set<DateTime> sickDaysIn(
  int year,
  List<Treatment> treatments, {
  required DateTime now,
}) {
  final days = <DateTime>{};
  for (final treatment in treatments) {
    days.addAll(_daysOfLeave(treatment, year: year, now: now));
  }
  return days;
}

/// The days of [year] one treatment's leave covers.
Set<DateTime> _daysOfLeave(
  Treatment treatment, {
  required int year,
  required DateTime now,
}) {
  final from = treatment.sickLeaveFrom;
  if (from == null) return const {};
  final start = _dayOf(from);
  final end = _dayOf(treatment.sickLeaveTo ?? now);
  if (end.isBefore(start)) return const {};

  // Only the part inside the year: a leave from 20 December to 8 January
  // belongs to both years, each holding its own days.
  final firstOfYear = DateTime(year);
  final lastOfYear = DateTime(year, 12, 31);
  var day = start.isBefore(firstOfYear) ? firstOfYear : start;
  final last = end.isAfter(lastOfYear) ? lastOfYear : end;

  final days = <DateTime>{};
  while (!day.isAfter(last)) {
    days.add(day);
    // Through `DateTime(y, m, d + 1)` rather than `add(Duration(days: 1))`:
    // adding 24 hours across a daylight-saving change lands at 23:00 the
    // same day and the loop stalls on it.
    day = DateTime(day.year, day.month, day.day + 1);
  }
  return days;
}

/// The earliest year any of [treatments] has sick leave in, or null when
/// none does — the year stepper's lower bound.
int? firstSickLeaveYear(List<Treatment> treatments) {
  int? earliest;
  for (final treatment in treatments) {
    final from = treatment.sickLeaveFrom;
    if (from == null) continue;
    if (earliest == null || from.year < earliest) earliest = from.year;
  }
  return earliest;
}

/// One illness and the days of the year attributable to it.
class TreatmentDays {
  const TreatmentDays(this.name, this.days);

  final String name;
  final int days;
}

/// A year of sick leave, counted.
class SickLeaveStats {
  const SickLeaveStats({
    required this.year,
    required this.days,
    required this.episodes,
    required this.longestEpisodeDays,
    required this.averageEpisodeDays,
    required this.byMonth,
    required this.byTreatment,
  });

  /// Reads [year] out of [treatments], as of [now].
  factory SickLeaveStats.of(
    int year,
    List<Treatment> treatments, {
    required DateTime now,
  }) {
    final days = sickDaysIn(year, treatments, now: now);

    // Per treatment: the days of *this* year its leave covers. Two leaves
    // of the same illness are one line and their days are added, so a name
    // appears once however often it recurs.
    final perName = <String, Set<DateTime>>{};
    final episodeLengths = <int>[];
    for (final treatment in treatments) {
      final own = _daysOfLeave(treatment, year: year, now: now);
      if (own.isEmpty) continue;
      episodeLengths.add(own.length);
      (perName[treatment.name] ??= <DateTime>{}).addAll(own);
    }

    final byMonth = List<int>.filled(12, 0);
    for (final day in days) {
      byMonth[day.month - 1]++;
    }

    final byTreatment =
        [
          for (final entry in perName.entries)
            TreatmentDays(entry.key, entry.value.length),
        ]..sort((a, b) {
          final byDays = b.days.compareTo(a.days);
          // Ties by name, so the list does not reshuffle between reads.
          return byDays != 0 ? byDays : a.name.compareTo(b.name);
        });

    return SickLeaveStats(
      year: year,
      days: days,
      episodes: episodeLengths.length,
      longestEpisodeDays: episodeLengths.isEmpty
          ? 0
          : episodeLengths.reduce((a, b) => a > b ? a : b),
      averageEpisodeDays: episodeLengths.isEmpty
          ? 0
          : episodeLengths.reduce((a, b) => a + b) / episodeLengths.length,
      byMonth: byMonth,
      byTreatment: byTreatment,
    );
  }

  final int year;

  /// Every day of the year signed off, counted once however many illnesses
  /// covered it. The year grid draws exactly this.
  final Set<DateTime> days;

  /// How many separate leaves touched the year. Two overlapping leaves are
  /// two episodes even though they share days.
  final int episodes;

  final int longestEpisodeDays;
  final double averageEpisodeDays;

  /// Days per month, January first. Sums to [totalDays].
  final List<int> byMonth;

  /// Illnesses by the days attributable to them, longest first. These sum to
  /// **at least** [totalDays]: a day covered by two illnesses is attributable
  /// to both, and dividing it between them would invent a half-day nobody
  /// was signed off for.
  final List<TreatmentDays> byTreatment;

  int get totalDays => days.length;

  bool get isEmpty => days.isEmpty;
}
