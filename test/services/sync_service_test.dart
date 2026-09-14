import 'package:flutter_test/flutter_test.dart';
import 'package:medora/data/datasources/dose_log_local_datasource.dart';
import 'package:medora/data/datasources/family_local_datasource.dart';
import 'package:medora/data/datasources/medication_local_datasource.dart';
import 'package:medora/data/datasources/prescription_local_datasource.dart';
import 'package:medora/data/datasources/treatment_local_datasource.dart';
import 'package:medora/services/sync_service.dart';

void main() {
  SyncService makeLocalOnly() => SyncService(
        medicationLocal: MedicationLocalDatasource(),
        medicationRemote: null,
        treatmentLocal: TreatmentLocalDatasource(),
        treatmentRemote: null,
        prescriptionLocal: PrescriptionLocalDatasource(),
        prescriptionRemote: null,
        doseLogLocal: DoseLogLocalDatasource(),
        doseLogRemote: null,
        familyLocal: FamilyLocalDatasource(),
        familyRemote: null,
      );

  test('local-only service is unavailable and syncAll is a no-op', () async {
    final service = makeLocalOnly();
    expect(service.isAvailable, isFalse);
    await service.syncAll();
    expect(service.currentState, SyncState.idle);
    service.dispose();
  });

  test('dispose is idempotent and later state changes do not throw', () {
    final service = makeLocalOnly();
    service.dispose();
    expect(service.dispose, returnsNormally);
    expect(() => service.debugSetStateForTest(SyncState.success), returnsNormally);
  });
}
