/// Medora - Dose maintenance.
///
/// Turns stale pending doses into "missed" so history and stats are honest.
library;

import 'package:flutter/foundation.dart';
import 'package:medora/domain/repositories/dose_log_repository.dart';

class DoseMaintenanceService {
  DoseMaintenanceService({
    required DoseLogRepository doses,
    DateTime Function()? now,
  }) : _doses = doses,
       _now = now ?? DateTime.now;

  final DoseLogRepository _doses;
  final DateTime Function() _now;

  /// Marks pending doses older than [grace] as missed. Returns the count.
  Future<int> markOverdueAsMissed({required Duration grace}) async {
    final cutoff = _now().subtract(grace);
    final result = await _doses.markOverduePendingAsMissed(cutoff);
    final count = result.dataOrNull ?? 0;
    if (count > 0) debugPrint('Doses: marked $count overdue dose(s) as missed');
    return count;
  }
}
