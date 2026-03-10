/// Medora - Extensions
library;

import 'package:flutter/material.dart';
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

extension StringExtensions on String {
  /// Generate a unique color based on the string content.
  /// Uses a more robust hashing distribution to avoid similar colors for similar words.
  Color get toColor {
    if (isEmpty) return Colors.grey;
    
    var hash = 0;
    for (var i = 0; i < length; i++) {
      // djb2-like hash for better distribution
      hash = codeUnitAt(i) + ((hash << 5) + hash);
    }
    
    // Spread the hash even more using a large prime multiplier
    final variantHash = (hash * 0x45d9f3b) & 0xFFFFFFFF;
    
    // Hue: 0-360
    final double h = (variantHash.abs() % 360).toDouble();
    
    // Lowered Lightness (30% to 45%) to ensure text is visible on light backgrounds.
    // Higher Saturation (70% to 90%) for more vibrant colors.
    final double s = 0.80 + ((variantHash.abs() % 20) / 100);
    final double l = 0.20 + ((variantHash.abs() % 15) / 100);
    
    return HSLColor.fromAHSL(1.0, h, s, l).toColor();
  }
}
