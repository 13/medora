/// Medora - Extensions
library;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

extension DateTimeExtensions on DateTime {
  /// Locale-aware date, e.g. 'Mar 5, 2026' (en) / '05.03.2026' (de).
  String get formatted => DateFormat.yMMMd().format(this);

  /// Locale-aware short date, e.g. 'Mar 5' (en).
  String get shortFormatted => DateFormat.MMMd().format(this);

  /// Locale-aware time, e.g. '14:07'.
  String get timeFormatted => DateFormat.Hm().format(this);

  /// Locale-aware date and time.
  String get dateTimeFormatted => DateFormat.yMMMd().add_Hm().format(this);

  /// Locale-aware short weekday name, e.g. 'Mon'.
  String get weekdayShort => DateFormat.E().format(this);
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
