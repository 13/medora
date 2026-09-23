/// Medora - Prescription (Rx) Repository Interface
library;

import 'package:medora/core/result.dart';
import 'package:medora/domain/entities/rx.dart';
import 'package:medora/domain/entities/rx_dispensing.dart';
import 'package:medora/domain/rx/rx_rules.dart';

/// Prefix of the failure message when a save is refused because another
/// live prescription already has the NRE; the existing id follows.
const duplicateNrePrefix = 'duplicate_nre:';

class RxWithDispensings {
  const RxWithDispensings(this.rx, this.dispensings);
  final Rx rx;
  final List<RxDispensing> dispensings;

  RxStatus statusAt(DateTime now) => RxRules.statusOf(rx, dispensings, now);
}

abstract class RxRepository {
  Future<Result<List<RxWithDispensings>>> getAll();
  Future<Result<RxWithDispensings>> getById(String id);
  Future<Result<List<RxWithDispensings>>> getForTreatment(String treatmentId);

  /// Adds or updates [rx]. Refused ([duplicateNrePrefix]) when another live
  /// prescription has the same NRE.
  Future<Result<Rx>> saveRx(Rx rx);
  Future<Result<void>> deleteRx(String id);

  /// Records [dispensings] of [rxId]; each with `unitsAdded > 0` and an
  /// item linked to a medication adds those units to its stock.
  Future<Result<void>> redeem(String rxId, List<RxDispensing> dispensings);

  /// Removes a dispensing recorded by mistake. The stock is not touched:
  /// the user may already have counted it.
  Future<Result<void>> undoDispensing(String dispensingId);
}
