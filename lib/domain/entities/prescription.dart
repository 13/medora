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
  /// 400. So an amount is only counted when it is expressed in the stock's
  /// own unit (or in a counting unit such as tablets or capsules when the
  /// medication has no unit), or when it has no unit at all; any other dose
  /// is one pack unit. Free-text dosages are read as a number and a unit, with
  /// English, German and Italian unit names. The amount is rounded, so a
  /// quarter tablet takes nothing.
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
        r'^(\d+(?:[.,]\d+)?)\s*(\S*)',
      ).firstMatch(dosage.trim());
      final parsed = match == null
          ? null
          : double.tryParse(match.group(1)!.replaceAll(',', '.'));
      if (parsed == null) return 1;
      amount = parsed;
      unit = _unitKey(match!.group(2));
    }
    final counted =
        unit == null ||
        (stockUnit != null ? unit == stockUnit : _countingUnits.contains(unit));
    if (!counted) return 1;
    final units = amount.round();
    return units < 0 ? 0 : units;
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
    },
    'capsules': {'capsule', 'cap', 'caps', 'kapsel', 'kapseln', 'capsula'},
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

  /// Calculate the end time based on start + duration.
  DateTime get endTime => startTime.add(Duration(days: durationDays));

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
    final end = endTime;
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
        currentDate = currentDate.add(const Duration(days: 1));
      }
    } else {
      // Fixed interval (ensure interval is at least 1h to avoid infinite loop)
      final safeInterval = intervalHours < 1 ? 1 : intervalHours;
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
