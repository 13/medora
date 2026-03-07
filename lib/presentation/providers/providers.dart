/// Medora - Dependency Injection Providers
///
/// Central place for all Riverpod providers that wire up the app.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:medora/data/datasources/dose_log_local_datasource.dart';
import 'package:medora/data/datasources/dose_log_remote_datasource.dart';
import 'package:medora/data/datasources/medication_local_datasource.dart';
import 'package:medora/data/datasources/medication_remote_datasource.dart';
import 'package:medora/data/datasources/prescription_local_datasource.dart';
import 'package:medora/data/datasources/prescription_remote_datasource.dart';
import 'package:medora/data/datasources/treatment_local_datasource.dart';
import 'package:medora/data/datasources/treatment_remote_datasource.dart';
import 'package:medora/data/repositories/dose_log_repository_impl.dart';
import 'package:medora/data/repositories/medication_repository_impl.dart';
import 'package:medora/data/repositories/prescription_repository_impl.dart';
import 'package:medora/data/repositories/treatment_repository_impl.dart';
import 'package:medora/domain/repositories/dose_log_repository.dart';
import 'package:medora/domain/repositories/medication_repository.dart';
import 'package:medora/domain/repositories/prescription_repository.dart';
import 'package:medora/domain/repositories/treatment_repository.dart';
import 'package:medora/services/connectivity_service.dart';
import 'package:medora/services/reminder_service.dart';
import 'package:medora/services/sync_service.dart';

// ============================================================
// Local Datasource Providers
// ============================================================

final medicationLocalDatasourceProvider = Provider<MedicationLocalDatasource>(
  (ref) => MedicationLocalDatasource(),
);

final treatmentLocalDatasourceProvider = Provider<TreatmentLocalDatasource>(
  (ref) => TreatmentLocalDatasource(),
);

final prescriptionLocalDatasourceProvider =
    Provider<PrescriptionLocalDatasource>(
  (ref) => PrescriptionLocalDatasource(),
);

final doseLogLocalDatasourceProvider = Provider<DoseLogLocalDatasource>(
  (ref) => DoseLogLocalDatasource(),
);

// ============================================================
// Remote Datasource Providers
// ============================================================

final medicationDatasourceProvider = Provider<MedicationRemoteDatasource>(
  (ref) => MedicationRemoteDatasource(),
);

final treatmentDatasourceProvider = Provider<TreatmentRemoteDatasource>(
  (ref) => TreatmentRemoteDatasource(),
);

final prescriptionDatasourceProvider =
    Provider<PrescriptionRemoteDatasource>(
  (ref) => PrescriptionRemoteDatasource(),
);

final doseLogDatasourceProvider = Provider<DoseLogRemoteDatasource>(
  (ref) => DoseLogRemoteDatasource(),
);

// ============================================================
// Repository Providers (offline-first)
// ============================================================

final medicationRepositoryProvider = Provider<MedicationRepository>(
  (ref) => MedicationRepositoryImpl(
    localDatasource: ref.watch(medicationLocalDatasourceProvider),
    remoteDatasource: ref.watch(medicationDatasourceProvider),
  ),
);

final treatmentRepositoryProvider = Provider<TreatmentRepository>(
  (ref) => TreatmentRepositoryImpl(
    localDatasource: ref.watch(treatmentLocalDatasourceProvider),
    remoteDatasource: ref.watch(treatmentDatasourceProvider),
  ),
);

final prescriptionRepositoryProvider = Provider<PrescriptionRepository>(
  (ref) => PrescriptionRepositoryImpl(
    localDatasource: ref.watch(prescriptionLocalDatasourceProvider),
    remoteDatasource: ref.watch(prescriptionDatasourceProvider),
  ),
);

final doseLogRepositoryProvider = Provider<DoseLogRepository>(
  (ref) => DoseLogRepositoryImpl(
    localDatasource: ref.watch(doseLogLocalDatasourceProvider),
    remoteDatasource: ref.watch(doseLogDatasourceProvider),
    prescriptionLocal: ref.watch(prescriptionLocalDatasourceProvider),
  ),
);

// ============================================================
// Service Providers
// ============================================================

final reminderServiceProvider = Provider<ReminderService>(
  (ref) => ReminderService.instance,
);

final connectivityServiceProvider = Provider<ConnectivityService>(
  (ref) => ConnectivityService.instance,
);

final syncServiceProvider = Provider<SyncService>(
  (ref) => SyncService(
    medicationLocal: ref.watch(medicationLocalDatasourceProvider),
    medicationRemote: ref.watch(medicationDatasourceProvider),
    treatmentLocal: ref.watch(treatmentLocalDatasourceProvider),
    treatmentRemote: ref.watch(treatmentDatasourceProvider),
    prescriptionLocal: ref.watch(prescriptionLocalDatasourceProvider),
    prescriptionRemote: ref.watch(prescriptionDatasourceProvider),
    doseLogLocal: ref.watch(doseLogLocalDatasourceProvider),
    doseLogRemote: ref.watch(doseLogDatasourceProvider),
  ),
);

/// Stream provider for connectivity status.
final connectivityStreamProvider = StreamProvider<bool>((ref) {
  return ConnectivityService.instance.onlineStream;
});

/// Stream provider for sync state.
final syncStateStreamProvider = StreamProvider<SyncState>((ref) {
  return ref.watch(syncServiceProvider).stateStream;
});


