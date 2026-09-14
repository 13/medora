/// Medora - Dependency Injection Providers
///
/// Central place for all Riverpod providers that wire up the app.
library;

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:medora/core/supabase_config.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/datasources/dose_log_local_datasource.dart';
import 'package:medora/data/datasources/dose_log_remote_datasource.dart';
import 'package:medora/data/datasources/medication_local_datasource.dart';
import 'package:medora/data/datasources/medication_remote_datasource.dart';
import 'package:medora/data/datasources/prescription_local_datasource.dart';
import 'package:medora/data/datasources/prescription_remote_datasource.dart';
import 'package:medora/data/datasources/treatment_local_datasource.dart';
import 'package:medora/data/datasources/treatment_remote_datasource.dart';
import 'package:medora/data/datasources/family_local_datasource.dart';
import 'package:medora/data/datasources/family_remote_datasource.dart';
import 'package:medora/data/repositories/dose_log_repository_impl.dart';
import 'package:medora/data/repositories/family_repository_impl.dart';
import 'package:medora/data/repositories/medication_repository_impl.dart';
import 'package:medora/data/repositories/prescription_repository_impl.dart';
import 'package:medora/data/repositories/treatment_repository_impl.dart';
import 'package:medora/domain/repositories/dose_log_repository.dart';
import 'package:medora/domain/repositories/family_repository.dart';
import 'package:medora/domain/repositories/medication_repository.dart';
import 'package:medora/domain/repositories/prescription_repository.dart';
import 'package:medora/domain/repositories/treatment_repository.dart';
import 'package:medora/presentation/providers/app_mode_provider.dart';
import 'package:medora/presentation/providers/sync_providers.dart';
import 'package:medora/services/app_startup_tasks.dart';
import 'package:medora/services/connectivity_service.dart';
import 'package:medora/services/dose_maintenance_service.dart';
import 'package:medora/services/local_data_wiper.dart';
import 'package:medora/services/photo_storage.dart';
import 'package:medora/services/reminder_port.dart';
import 'package:medora/services/reminder_scheduler.dart';
import 'package:medora/services/reminder_service.dart';
import 'package:medora/services/sync_service.dart';
import 'package:medora/presentation/providers/medication_providers.dart';
import 'package:medora/presentation/providers/settings_providers.dart';
import 'package:medora/presentation/providers/treatment_providers.dart';
import 'package:medora/presentation/providers/dose_providers.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

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

final familyLocalDatasourceProvider = Provider<FamilyLocalDatasource>(
  (ref) => FamilyLocalDatasource(),
);

// ============================================================
// Supabase client (null in local-only mode or unconfigured builds)
// ============================================================

final supabaseClientProvider = Provider<SupabaseClient?>((ref) {
  final mode = ref.watch(appModeProvider);
  if (mode != AppMode.cloud) return null;
  return SupabaseConfig.clientOrNull;
});

// ============================================================
// Remote Datasource Providers (nullable)
// ============================================================

final medicationDatasourceProvider = Provider<MedicationRemoteDatasource?>((ref) {
  final client = ref.watch(supabaseClientProvider);
  return client == null ? null : MedicationRemoteDatasource(client);
});

final treatmentDatasourceProvider = Provider<TreatmentRemoteDatasource?>((ref) {
  final client = ref.watch(supabaseClientProvider);
  return client == null ? null : TreatmentRemoteDatasource(client);
});

final prescriptionDatasourceProvider = Provider<PrescriptionRemoteDatasource?>((ref) {
  final client = ref.watch(supabaseClientProvider);
  return client == null ? null : PrescriptionRemoteDatasource(client);
});

final doseLogDatasourceProvider = Provider<DoseLogRemoteDatasource?>((ref) {
  final client = ref.watch(supabaseClientProvider);
  return client == null ? null : DoseLogRemoteDatasource(client);
});

final familyDatasourceProvider = Provider<FamilyRemoteDatasource?>((ref) {
  final client = ref.watch(supabaseClientProvider);
  return client == null ? null : FamilyRemoteDatasource(client);
});

// ============================================================
// Repository Providers (offline-first; remote may be null)
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

final familyRepositoryProvider = Provider<FamilyRepository>(
  (ref) => FamilyRepositoryImpl(
    localDatasource: ref.watch(familyLocalDatasourceProvider),
    remoteDatasource: ref.watch(familyDatasourceProvider),
  ),
);

// ============================================================
// Service Providers
// ============================================================

final reminderPortProvider = Provider<ReminderPort>((ref) => ReminderService.instance);

final reminderSchedulerProvider = Provider<ReminderScheduler>((ref) {
  // reconcile() can still be mid-flight (it's fired via `unawaited`) after
  // the container is disposed (e.g. test teardown); cache the last-known
  // value and guard against reading a disposed Ref rather than throwing.
  var lastEnabled = ref.read(remindersEnabledProvider);
  return ReminderScheduler(
    port: ref.watch(reminderPortProvider),
    doses: ref.watch(doseLogRepositoryProvider),
    remindersEnabled: () {
      if (ref.mounted) lastEnabled = ref.read(remindersEnabledProvider);
      return lastEnabled;
    },
  );
});

final connectivityServiceProvider = Provider<ConnectivityService>(
  (ref) => ConnectivityService.instance,
);

final photoStorageProvider = Provider<PhotoStorage>((ref) => PhotoStorage.appDocuments());

/// Resolved photo file for a stored image name (null when absent/missing).
final resolvedPhotoProvider = FutureProvider.family<File?, String?>(
  (ref, stored) => ref.watch(photoStorageProvider).resolve(stored),
);

final localDataWiperProvider = Provider<LocalDataWiper>((ref) => LocalDataWiper(
      database: AppDatabase.instance,
      photos: ref.watch(photoStorageProvider),
      reminders: ref.watch(reminderPortProvider),
      prefs: ref.watch(sharedPreferencesProvider),
    ));

final syncServiceProvider = Provider<SyncService>((ref) {
  final service = SyncService(
    medicationLocal: ref.watch(medicationLocalDatasourceProvider),
    medicationRemote: ref.watch(medicationDatasourceProvider),
    treatmentLocal: ref.watch(treatmentLocalDatasourceProvider),
    treatmentRemote: ref.watch(treatmentDatasourceProvider),
    prescriptionLocal: ref.watch(prescriptionLocalDatasourceProvider),
    prescriptionRemote: ref.watch(prescriptionDatasourceProvider),
    doseLogLocal: ref.watch(doseLogLocalDatasourceProvider),
    doseLogRemote: ref.watch(doseLogDatasourceProvider),
    familyLocal: ref.watch(familyLocalDatasourceProvider),
    familyRemote: ref.watch(familyDatasourceProvider),
    cursors: ref.watch(syncCursorStoreProvider),
  );
  if (service.isAvailable) service.startAutoSync();
  ref.onDispose(service.dispose);
  return service;
});

/// Stream provider for connectivity status.
final connectivityStreamProvider = StreamProvider<bool>((ref) {
  return ConnectivityService.instance.onlineStream;
});

/// Stream provider for sync state.
final syncStateStreamProvider = StreamProvider<SyncState>((ref) {
  final syncService = ref.watch(syncServiceProvider);
  
  // Listen to the sync state and trigger UI refreshes on success.
  // Using a manual listener on the stream instead of listenSelf 
  // to avoid compatibility issues with certain Ref types.
  final subscription = syncService.stateStream.listen((state) {
    if (state == SyncState.success || state == SyncState.partial) {
      // Refresh key data providers after a sync that changed data; a partial
      // cycle still applied every row that did not fail.
      ref.read(medicationListProvider.notifier).refresh();
      ref.read(treatmentListProvider.notifier).refresh();
      ref.read(todaysDoseLogsProvider.notifier).refresh();
    }
  });

  ref.onDispose(() => subscription.cancel());

  return syncService.stateStream;
});

/// The report of the most recent sync cycle; re-evaluated on every state change.
final syncLastReportProvider = Provider<SyncReport?>((ref) {
  ref.watch(syncStateStreamProvider);
  return ref.watch(syncServiceProvider).lastReport;
});

// ============================================================
// Startup / maintenance
// ============================================================

final doseMaintenanceProvider = Provider<DoseMaintenanceService>(
  (ref) => DoseMaintenanceService(doses: ref.watch(doseLogRepositoryProvider)),
);

/// Delay before the startup sync; tests override this with Duration.zero.
final syncStartupDelayProvider = Provider<Duration>((_) => const Duration(seconds: 2));

/// Injectable clock. Screens/providers that need "now" read
/// `ref.read(nowProvider)()`; tests and goldens override it.
final nowProvider = Provider<DateTime Function()>((_) => DateTime.now);

final appStartupTasksProvider = Provider<AppStartupTasks>((ref) {
  return AppStartupTasks(
    maintenance: () async {
      final grace = Duration(minutes: ref.read(missedGraceMinutesProvider));
      final changed = await ref.read(doseMaintenanceProvider).markOverdueAsMissed(grace: grace);
      if (changed > 0) {
        await ref.read(todaysDoseLogsProvider.notifier).refresh();
        ref.read(doseDataVersionProvider.notifier).bump();
      }
    },
    reminders: () => ref.read(reminderSchedulerProvider).reconcile().then((_) {}),
    sync: () async {
      if (ref.read(appModeProvider) == AppMode.cloud) {
        await ref.read(syncServiceProvider).syncAll();
      }
    },
    syncDelay: ref.watch(syncStartupDelayProvider),
    minSyncInterval: const Duration(minutes: 5),
  );
});
