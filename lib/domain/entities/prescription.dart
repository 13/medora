/// Medora - Prescription Entity
///
/// Represents a medication prescription within a treatment plan.
library;

class Prescription {
  const Prescription({
    required this.id,
    required this.treatmentId,
    required this.medicationId,
    required this.dosage,
    this.dosageAmount,
    this.dosageUnit,
    this.intervalHours = 8,
    this.durationDays = 7,
    required this.startTime,
    this.isActive = true,
    this.autoDiminish = false,
    this.notes,
    this.createdAt,
    this.updatedAt,
    this.scheduleType = 'fixed_interval',
    this.scheduleTimes,
    // Joined fields (nullable)
    this.medicationName,
    this.treatmentName,
  });

  final String id;
  final String treatmentId;
  final String medicationId;

  /// Free-text dosage string (legacy / display fallback, e.g. "20 Tropfen").
  final String dosage;

  /// Numeric amount, e.g. 1.5 (tablets), 20 (drops).
  final double? dosageAmount;

  /// Unit override for this prescription, e.g. "pills".
  /// If null, falls back to the medication's quantityUnit or the dosage text.
  final String? dosageUnit;

  final int intervalHours;
  final int durationDays;
  final DateTime startTime;
  final bool isActive;
  final bool autoDiminish;
  final String? notes;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  /// 'fixed_interval', 'times_per_day' or 'as_needed'.
  ///
  /// An 'as_needed' prescription ("bei Bedarf") has no schedule at all: it
  /// generates no doses, so nothing is ever due, overdue or reminded, and
  /// each intake is recorded when it happens. Its [intervalHours] and
  /// [durationDays] keep their stored values but mean nothing.
  final String scheduleType;

  /// List of time strings like ['08:00', '12:00', '18:00'] for times_per_day
  final List<String>? scheduleTimes;

  // Optional joined fields for display
  final String? medicationName;
  final String? treatmentName;

  /// How many units of the medication's stock one dose uses, for
  /// auto-diminish. [medicationUnit] is the unit the stock is counted in.
  ///
  /// The dosage says how much of the *substance* is taken, which is not
  /// always a count of stock units: "400 mg" of ibuprofen is one tablet, not
  /// 400. The rule never takes more than the dose uses:
  /// - an amount in the stock's own unit, or with no unit at all, is
  ///   counted; pieces, pills and tablets count the same things, and a
  ///   medication without a unit is taken to be counted in such items;
  /// - drops from a stock in ml count twenty to the millilitre;
  /// - any other volume (ml, drops) takes nothing: one dose of a syrup kept
  ///   as bottles is not a whole bottle;
  /// - any other unit ("400 mg") is one pack unit;
  /// - a fraction is rounded down, so half a tablet takes nothing (the app
  ///   keeps no fractional remainder).
  ///
  /// Free-text dosages are read as a number ("1,5", "1/2", "½") and a unit,
  /// with English, German and Italian unit names.
  int unitsPerDose({String? medicationUnit}) {
    final stockUnit = _unitKey(medicationUnit);
    final double amount;
    final String? unit;
    final amountValue = dosageAmount;
    if (amountValue != null) {
      amount = amountValue;
      unit = _unitKey(dosageUnit) ?? stockUnit;
    } else {
      final match = RegExp(
        r'^(\d+(?:[.,]\d+)?(?:\s*/\s*\d+)?|[½¼¾])\s*(\S*)',
      ).firstMatch(dosage.trim());
      final parsed = match == null ? null : _parseAmount(match.group(1)!);
      if (parsed == null) return 1;
      amount = parsed;
      unit = _unitKey(match!.group(2));
    }
    final double units;
    if (unit == null || _sameStock(unit, stockUnit)) {
      units = amount;
    } else if (unit == 'drops' && stockUnit == 'ml') {
      units = amount / _dropsPerMl;
    } else if (_volumeUnits.contains(unit)) {
      return 0;
    } else {
      return 1;
    }
    final whole = units.floor();
    return whole < 0 ? 0 : whole;
  }

  /// Drops in a millilitre, by the usual pharmacopoeia convention.
  static const _dropsPerMl = 20;

  static const _volumeUnits = {'ml', 'drops'};

  /// Units that name the same kind of item.
  static const _itemUnits = {'pieces', 'pills', 'tablets'};

  /// True when a dose in [unit] is counted in the stock's [stockUnit]; a
  /// stock without a unit counts items.
  static bool _sameStock(String unit, String? stockUnit) {
    if (stockUnit == null) return _countingUnits.contains(unit);
    if (unit == stockUnit) return true;
    return _itemUnits.contains(unit) && _itemUnits.contains(stockUnit);
  }

  /// "2", "1,5", "1/2" or "½" as a number, or null.
  static double? _parseAmount(String raw) {
    switch (raw) {
      case '½':
        return 0.5;
      case '¼':
        return 0.25;
      case '¾':
        return 0.75;
    }
    final parts = raw.split('/');
    final value = double.tryParse(parts.first.trim().replaceAll(',', '.'));
    if (value == null || parts.length == 1) return value;
    final divisor = double.tryParse(parts[1].trim());
    return divisor == null || divisor == 0 ? null : value / divisor;
  }

  /// The quantity-unit key [raw] names (`tablets` for "Tabletten"), the
  /// lower-cased word itself when it is no known unit ("mg"), or null when
  /// there is none.
  static String? _unitKey(String? raw) {
    var word = (raw ?? '').trim().toLowerCase();
    while (word.endsWith('.')) {
      word = word.substring(0, word.length - 1);
    }
    if (word.isEmpty) return null;
    for (final MapEntry(:key, :value) in _unitNames.entries) {
      if (key == word || value.contains(word)) return key;
    }
    return word;
  }

  /// Units that count whole items, so a medication without a unit is
  /// assumed to be counted in them.
  static const _countingUnits = {
    'pieces',
    'pills',
    'tablets',
    'capsules',
    'bustine',
    'ampoules',
    'suppositories',
    'patches',
  };

  /// The quantity-unit keys and the words a dosage may use for them.
  static const _unitNames = {
    'pieces': {'piece', 'pc', 'pcs', 'stück', 'stk', 'pezzo', 'pezzi'},
    'pills': {'pill', 'pille', 'pillen', 'pillola', 'pillole'},
    'tablets': {
      'tablet',
      'tab',
      'tabs',
      'tbl',
      'tablette',
      'tabletten',
      'compressa',
      'compresse',
      'cpr',
      'cp',
    },
    'capsules': {
      'capsule',
      'cap',
      'caps',
      'cps',
      'kapsel',
      'kapseln',
      'capsula',
    },
    'ml': {'milliliter', 'millilitre', 'millilitro', 'millilitri'},
    'drops': {'drop', 'tropfen', 'goccia', 'gocce', 'gtt'},
    'bustine': {'bustina', 'sachet', 'sachets', 'beutel', 'btl'},
    'ampoules': {
      'ampoule',
      'ampule',
      'ampules',
      'ampulle',
      'ampullen',
      'fiala',
      'fiale',
    },
    'suppositories': {'suppository', 'zäpfchen', 'supposta', 'supposte'},
    'patches': {'patch', 'pflaster', 'cerotto', 'cerotti'},
  };

  /// Formatted dosage string: amount + unit if available, otherwise raw dosage text.
  String displayDosage({String? medicationUnit}) {
    if (dosageAmount != null) {
      final amount = dosageAmount! % 1 == 0
          ? dosageAmount!.toInt().toString()
          : dosageAmount!.toString();
      final unit = dosageUnit ?? medicationUnit;
      if (unit != null && unit.isNotEmpty) return '$amount $unit';
      // No unit at all — fall back to raw dosage text (e.g. "20 Tropfen")
      return dosage.isNotEmpty ? dosage : amount;
    }
    return dosage;
  }

  /// The start plus [durationDays] calendar days, at the start's wall-clock
  /// time: the end of the course as a date, which is what a times-per-day
  /// schedule is bounded by. Counted on the calendar rather than in 24-hour
  /// steps: across a DST change a day is 23 or 25 hours long, and elapsed
  /// days would move the end by an hour (a spring start's end lands at 09:00
  /// instead of 08:00, and the 08:00 dose of the day after the last is
  /// generated).
  ///
  /// Not the bound of a fixed-interval schedule, which counts real hours:
  /// use [scheduleEnd] to ask whether a dose time falls inside the course.
  DateTime get endTime {
    final s = startTime;
    final day = s.day + durationDays;
    return s.isUtc
        ? DateTime.utc(
            s.year,
            s.month,
            day,
            s.hour,
            s.minute,
            s.second,
            s.millisecond,
            s.microsecond,
          )
        : DateTime(
            s.year,
            s.month,
            day,
            s.hour,
            s.minute,
            s.second,
            s.millisecond,
            s.microsecond,
          );
  }

  /// The instant the generated doses stay strictly before.
  ///
  /// For a fixed interval, [durationDays] times 24 elapsed hours after the
  /// start: its doses are stepped in real hours, so bounding them by the
  /// calendar [endTime] would add a dose to a course that spans the autumn
  /// change (a 25-hour day) — 8 doses for "every 24 h for 7 days". For a
  /// times-per-day schedule (and anything else) the calendar [endTime].
  DateTime get scheduleEnd =>
      _isFixedInterval ? startTime.add(Duration(days: durationDays)) : endTime;

  /// Whether [scheduledDoseTimes] steps in elapsed hours.
  bool get _isFixedInterval =>
      scheduleType != 'as_needed' &&
      !(scheduleType == 'times_per_day' &&
          scheduleTimes != null &&
          scheduleTimes!.isNotEmpty);

  /// Number of doses per day. Zero for an as-needed prescription.
  int get dosesPerDay {
    if (scheduleType == 'as_needed') return 0;
    if (scheduleType == 'times_per_day' && scheduleTimes != null) {
      return scheduleTimes!.length;
    }
    return (24 / (intervalHours < 1 ? 1 : intervalHours)).ceil();
  }

  /// Generate all scheduled dose times for this prescription.
  /// Includes a sanity limit of 1000 doses to prevent performance issues
  /// if a user enters an extremely long duration or tiny interval.
  List<DateTime> get scheduledDoseTimes {
    // No schedule, so no generated doses: nothing pending for the dashboard,
    // the reminders or the missed-dose sweep to find.
    if (scheduleType == 'as_needed') return const [];
    final times = <DateTime>[];
    final end = scheduleEnd;
    const maxDoses = 1000;

    if (scheduleType == 'times_per_day' &&
        scheduleTimes != null &&
        scheduleTimes!.isNotEmpty) {
      // Generate times for each day at the specified times
      var currentDate = DateTime(
        startTime.year,
        startTime.month,
        startTime.day,
      );
      while (currentDate.isBefore(end) && times.length < maxDoses) {
        for (final timeStr in scheduleTimes!) {
          if (times.length >= maxDoses) break;
          final parts = timeStr.split(':');
          final h = int.tryParse(parts[0]) ?? 8;
          final m = parts.length > 1 ? (int.tryParse(parts[1]) ?? 0) : 0;
          final dt = DateTime(
            currentDate.year,
            currentDate.month,
            currentDate.day,
            h,
            m,
          );
          if (dt.isAfter(startTime.subtract(const Duration(minutes: 1))) &&
              dt.isBefore(end)) {
            times.add(dt);
          }
        }
        // The next calendar day: midnight plus 24 hours is 23:00 of the
        // same day after the autumn change and 01:00 after the spring one,
        // which walks one day twice and later skips one.
        currentDate = DateTime(
          currentDate.year,
          currentDate.month,
          currentDate.day + 1,
        );
      }
    } else {
      // Fixed interval (ensure interval is at least 1h to avoid infinite loop)
      final safeInterval = intervalHours < 1 ? 1 : intervalHours;
      // Stepped in elapsed hours on purpose, unlike the calendar days above:
      // "every 8 hours" means 8 real hours between doses, so across a DST
      // change the wall-clock times shift by an hour.
      var current = startTime;
      while (current.isBefore(end) && times.length < maxDoses) {
        times.add(current);
        current = current.add(Duration(hours: safeInterval));
      }
    }

    times.sort();
    return times;
  }

  /// The next [dosesPerDay] scheduled dose times, for the sheet's schedule
  /// preview. Not "the first day's times": for a fixed interval that does
  /// not divide 24h these run past midnight, and for a times-per-day
  /// schedule they start at the next configured time, not at today's first.
  List<DateTime> previewTimes() =>
      scheduledDoseTimes.take(dosesPerDay).toList();

  Prescription copyWith({
    String? id,
    String? treatmentId,
    String? medicationId,
    String? dosage,
    double? dosageAmount,
    String? dosageUnit,
    int? intervalHours,
    int? durationDays,
    DateTime? startTime,
    bool? isActive,
    bool? autoDiminish,
    String? notes,
    DateTime? createdAt,
    DateTime? updatedAt,
    String? scheduleType,
    List<String>? scheduleTimes,
    String? medicationName,
    String? treatmentName,
  }) {
    return Prescription(
      id: id ?? this.id,
      treatmentId: treatmentId ?? this.treatmentId,
      medicationId: medicationId ?? this.medicationId,
      dosage: dosage ?? this.dosage,
      dosageAmount: dosageAmount ?? this.dosageAmount,
      dosageUnit: dosageUnit ?? this.dosageUnit,
      intervalHours: intervalHours ?? this.intervalHours,
      durationDays: durationDays ?? this.durationDays,
      startTime: startTime ?? this.startTime,
      isActive: isActive ?? this.isActive,
      autoDiminish: autoDiminish ?? this.autoDiminish,
      notes: notes ?? this.notes,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      scheduleType: scheduleType ?? this.scheduleType,
      scheduleTimes: scheduleTimes ?? this.scheduleTimes,
      medicationName: medicationName ?? this.medicationName,
      treatmentName: treatmentName ?? this.treatmentName,
    );
  }
}
