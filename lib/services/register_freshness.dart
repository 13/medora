/// Medora - how old a cached register is
///
/// The supplement register dates itself (`sourceUpdated`, the Ministry's
/// "aggiornato al"), which is what the user cares about; the AIFA cache does
/// not, so its download date stands in. Both are compared in whole calendar
/// days, like every other date rule in the app.
library;

import 'package:flutter/foundation.dart';
import 'package:medora/core/clock.dart';

/// How old a register may get before the app asks for an update.
const int registerStaleDays = 45;

@immutable
class RegisterFreshness {
  const RegisterFreshness({
    required this.days,
    required this.isStale,
    required this.isMissing,
  });

  /// Whole days since the register's date, null when it has none.
  final int? days;

  /// Whether the register is [registerStaleDays] old or older (or undated).
  final bool isStale;

  /// Whether nothing is cached at all.
  final bool isMissing;
}

/// See the library doc. [count] is the number of cached rows: zero means the
/// register was never downloaded, which is "missing", not "stale". Rows
/// without any date are treated as stale — the app cannot tell how old they
/// are, and offering the update is the safe answer.
RegisterFreshness registerFreshness({
  required DateTime now,
  DateTime? sourceUpdated,
  DateTime? lastSync,
  int count = 0,
}) {
  if (count <= 0) {
    return const RegisterFreshness(days: null, isStale: false, isMissing: true);
  }
  final dated = sourceUpdated ?? lastSync;
  if (dated == null) {
    return const RegisterFreshness(days: null, isStale: true, isMissing: false);
  }
  final days = calendarDaysBetween(dated, now);
  return RegisterFreshness(
    days: days,
    isStale: days >= registerStaleDays,
    isMissing: false,
  );
}
