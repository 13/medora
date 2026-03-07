/// Medora - Date/Time Extensions
library;

import 'package:intl/intl.dart';

extension DateTimeExtensions on DateTime {
  /// Format as 'MMM dd, yyyy' (e.g., 'Jan 15, 2026')
  String get formatted => DateFormat('MMM dd, yyyy').format(this);

  /// Format as 'MMM dd' (e.g., 'Jan 15')
  String get shortFormatted => DateFormat('MMM dd').format(this);

  /// Format as 'HH:mm' (e.g., '14:30')
  String get timeFormatted => DateFormat('HH:mm').format(this);

  /// Format as 'MMM dd, yyyy HH:mm'
  String get dateTimeFormatted =>
      DateFormat('MMM dd, yyyy HH:mm').format(this);

  /// Returns true if this date is today.
  bool get isToday {
    final now = DateTime.now();
    return year == now.year && month == now.month && day == now.day;
  }

  /// Returns true if this date is before today (expired).
  bool get isPast {
    final today = DateTime.now();
    return isBefore(DateTime(today.year, today.month, today.day));
  }

  /// Returns the number of days from now.
  int get daysFromNow {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final target = DateTime(year, month, day);
    return target.difference(today).inDays;
  }

  /// Returns true if within [days] from now.
  bool isWithinDays(int days) {
    final d = daysFromNow;
    return d >= 0 && d <= days;
  }
}

extension NullableDateTimeExtensions on DateTime? {
  /// Format or return fallback.
  String formattedOr([String fallback = '—']) {
    return this?.formatted ?? fallback;
  }
}

