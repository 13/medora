/// Medora - Dependency Injection Providers
///
/// Central place for all Riverpod providers that wire up the app.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:medora/core/platform_capabilities.dart';
import 'package:medora/core/supabase_config.dart';
import 'package:medora/data/datasources/account_data_remote_datasource.dart';
import 'package:medora/data/datasources/barcode_lookup_datasource.dart';
import 'package:medora/data/datasources/dose_log_local_datasource.dart';
import 'package:medora/data/datasources/dose_log_remote_datasource.dart';
import 'package:medora/data/datasources/family_local_datasource.dart';
import 'package:medora/data/datasources/family_remote_datasource.dart';
import 'package:medora/data/datasources/medication_local_datasource.dart';
import 'package:medora/data/datasources/medication_remote_datasource.dart';
import 'package:medora/data/datasources/person_local_datasource.dart';
import 'package:medora/data/datasources/prescription_local_datasource.dart';
import 'package:medora/data/datasources/prescription_remote_datasource.dart';
import 'package:medora/data/datasources/rx_dispensing_local_datasource.dart';
import 'package:medora/data/datasources/rx_local_datasource.dart';
import 'package:medora/data/datasources/rx_remote_datasource.dart';
import 'package:medora/data/datasources/stock_outbox_local_datasource.dart';
import 'package:medora/data/datasources/sync_state_remote_datasource.dart';
import 'package:medora/data/datasources/treatment_local_datasource.dart';
import 'package:medora/data/datasources/treatment_remote_datasource.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/repositories/dose_log_repository_impl.dart';
import 'package:medora/data/repositories/family_repository_impl.dart';
import 'package:medora/data/repositories/medication_repository_impl.dart';
import 'package:medora/data/repositories/person_repository_impl.dart';
import 'package:medora/data/repositories/prescription_repository_impl.dart';
import 'package:medora/data/repositories/rx_repository_impl.dart';
import 'package:medora/data/repositories/treatment_repository_impl.dart';
import 'package:medora/data/sync/request_sync.dart';
import 'package:medora/domain/entities/person.dart';
import 'package:medora/domain/entities/prescription.dart';
import 'package:medora/domain/repositories/dose_log_repository.dart';
import 'package:medora/domain/repositories/family_repository.dart';
import 'package:medora/domain/repositories/medication_repository.dart';
import 'package:medora/domain/repositories/person_repository.dart';
import 'package:medora/domain/repositories/prescription_repository.dart';
import 'package:medora/domain/repositories/rx_repository.dart';
import 'package:medora/domain/repositories/treatment_repository.dart';
import 'package:medora/presentation/providers/app_config_provider.dart';
import 'package:medora/presentation/providers/app_mode_provider.dart';
import 'package:medora/presentation/providers/app_update_provider.dart';
import 'package:medora/presentation/providers/dose_providers.dart';
import 'package:medora/presentation/providers/medication_providers.dart';
import 'package:medora/presentation/providers/now_provider.dart';
import 'package:medora/presentation/providers/rx_providers.dart';
import 'package:medora/presentation/providers/settings_providers.dart';
import 'package:medora/presentation/providers/sync_providers.dart';
import 'package:medora/presentation/providers/treatment_providers.dart';
import 'package:medora/services/aifa_cache_service.dart';
import 'package:medora/services/app_startup_tasks.dart';
import 'package:medora/services/backup_file_picker.dart';
import 'package:medora/services/backup_service.dart';
import 'package:medora/services/connectivity_service.dart';
import 'package:medora/services/dose_maintenance_service.dart';
import 'package:medora/services/dose_schedule_service.dart';
import 'package:medora/services/local_data_wiper.dart';
import 'package:medora/services/mlkit_scanner_ports.dart';
import 'package:medora/services/photo_storage.dart';
import 'package:medora/services/reminder_port.dart';
import 'package:medora/services/reminder_scheduler.dart';
import 'package:medora/services/reminder_service.dart';
import 'package:medora/services/scan_temp_cleanup.dart';
import 'package:medora/services/scanner_ports.dart';
import 'package:medora/services/stock_alert_store.dart';
import 'package:medora/services/stock_reminder_scheduler.dart';
import 'package:medora/services/supplement_registry_service.dart';
import 'package:medora/services/sync_service.dart';
import 'package:path_provider/path_provider.dart';
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

final personLocalDatasourceProvider = Provider<PersonLocalDatasource>(
  (ref) => PersonLocalDatasource(now: ref.watch(nowProvider)),
);

final rxLocalDatasourceProvider = Provider<RxLocalDatasource>(
  (ref) => RxLocalDatasource(now: ref.watch(nowProvider)),
);

final rxDispensingLocalDatasourceProvider =
    Provider<RxDispensingLocalDatasource>(
      (ref) => RxDispensingLocalDatasource(now: ref.watch(nowProvider)),
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

final medicationDatasourceProvider = Provider<MedicationRemoteDatasource?>((
  ref,
) {
  final client = ref.watch(supabaseClientProvider);
  return client == null ? null : MedicationRemoteDatasource(client);
});

final treatmentDatasourceProvider = Provider<TreatmentRemoteDatasource?>((ref) {
  final client = ref.watch(supabaseClientProvider);
  return client == null ? null : TreatmentRemoteDatasource(client);
});

final prescriptionDatasourceProvider = Provider<PrescriptionRemoteDatasource?>((
  ref,
) {
  final client = ref.watch(supabaseClientProvider);
  return client == null ? null : PrescriptionRemoteDatasource(client);
});

final doseLogDatasourceProvider = Provider<DoseLogRemoteDatasource?>((ref) {
  final client = ref.watch(supabaseClientProvider);
  return client == null ? null : DoseLogRemoteDatasource(client);
});

/// Persons, prescription documents and their dispensings on the server;
/// null in local-only mode.
final rxRemoteDatasourceProvider = Provider<RxRemoteDatasource?>((ref) {
  final client = ref.watch(supabaseClientProvider);
  return client == null ? null : RxRemoteDatasource(client);
});

final familyDatasourceProvider = Provider<FamilyRemoteDatasource?>((ref) {
  final client = ref.watch(supabaseClientProvider);
  return client == null ? null : FamilyRemoteDatasource(client);
});

final syncStateDatasourceProvider = Provider<SyncStateRemoteDatasource?>((ref) {
  final client = ref.watch(supabaseClientProvider);
  return client == null ? null : SyncStateRemoteDatasource(client);
});

/// "Delete all data" on the server; null in local-only mode.
final accountDataDatasourceProvider = Provider<AccountDataRemoteDatasource?>((
  ref,
) {
  final client = ref.watch(supabaseClientProvider);
  return client == null ? null : AccountDataRemoteDatasource(client);
});

/// The stock changes waiting to go out (sync v2).
final stockOutboxDatasourceProvider = Provider<StockOutboxLocalDatasource>(
  (ref) => StockOutboxLocalDatasource(),
);

// ============================================================
// Repository Providers (offline-first; remote may be null)
// ============================================================

/// How a repository asks for a sync after a write. The sync cycle is the
/// only push path for medications, treatments, prescriptions and dose logs:
/// a write asks for one, and it queues behind a cycle that is already
/// running. Null in local-only mode ([remote] is null), where nothing is
/// pushed.
RequestSync? _requestSyncInCloud(Ref ref, Object? remote) =>
    remote == null ? null : () => ref.read(syncServiceProvider).syncAll();

final medicationRepositoryProvider = Provider<MedicationRepository>(
  (ref) => MedicationRepositoryImpl(
    localDatasource: ref.watch(medicationLocalDatasourceProvider),
    requestSync: _requestSyncInCloud(
      ref,
      ref.watch(medicationDatasourceProvider),
    ),
    now: ref.watch(nowProvider),
  ),
);

final treatmentRepositoryProvider = Provider<TreatmentRepository>(
  (ref) => TreatmentRepositoryImpl(
    localDatasource: ref.watch(treatmentLocalDatasourceProvider),
    requestSync: _requestSyncInCloud(
      ref,
      ref.watch(treatmentDatasourceProvider),
    ),
    now: ref.watch(nowProvider),
  ),
);

final prescriptionRepositoryProvider = Provider<PrescriptionRepository>(
  (ref) => PrescriptionRepositoryImpl(
    localDatasource: ref.watch(prescriptionLocalDatasourceProvider),
    requestSync: _requestSyncInCloud(
      ref,
      ref.watch(prescriptionDatasourceProvider),
    ),
    now: ref.watch(nowProvider),
  ),
);

final doseLogRepositoryProvider = Provider<DoseLogRepository>(
  (ref) => DoseLogRepositoryImpl(
    localDatasource: ref.watch(doseLogLocalDatasourceProvider),
    prescriptionLocal: ref.watch(prescriptionLocalDatasourceProvider),
    requestSync: _requestSyncInCloud(ref, ref.watch(doseLogDatasourceProvider)),
    now: ref.watch(nowProvider),
  ),
);

final familyRepositoryProvider = Provider<FamilyRepository>(
  (ref) => FamilyRepositoryImpl(
    localDatasource: ref.watch(familyLocalDatasourceProvider),
    remoteDatasource: ref.watch(familyDatasourceProvider),
    now: ref.watch(nowProvider),
  ),
);

final personRepositoryProvider = Provider<PersonRepository>(
  (ref) => PersonRepositoryImpl(
    local: ref.watch(personLocalDatasourceProvider),
    requestSync: _requestSyncInCloud(
      ref,
      ref.watch(rxRemoteDatasourceProvider),
    ),
    now: ref.watch(nowProvider),
  ),
);

final rxRepositoryProvider = Provider<RxRepository>(
  (ref) => RxRepositoryImpl(
    rxLocal: ref.watch(rxLocalDatasourceProvider),
    dispensingLocal: ref.watch(rxDispensingLocalDatasourceProvider),
    medications: ref.watch(medicationRepositoryProvider),
    requestSync: _requestSyncInCloud(
      ref,
      ref.watch(rxRemoteDatasourceProvider),
    ),
    now: ref.watch(nowProvider),
  ),
);

// ============================================================
// Service Providers
// ============================================================

final reminderPortProvider = Provider<ReminderPort>(
  (ref) => ReminderService.instance,
);

final reminderSchedulerProvider = Provider<ReminderScheduler>((ref) {
  // reconcile() can still be mid-flight (it's fired via `unawaited`) after
  // the container is disposed (e.g. test teardown); cache the last-known
  // value and guard against reading a disposed Ref rather than throwing.
  var lastEnabled = ref.read(remindersEnabledProvider);
  final scheduler = ReminderScheduler(
    port: ref.watch(reminderPortProvider),
    doses: ref.watch(doseLogRepositoryProvider),
    remindersEnabled: () {
      if (ref.mounted) lastEnabled = ref.read(remindersEnabledProvider);
      return lastEnabled;
    },
  );

  // Notification text is baked in when a notification is scheduled, and the
  // scheduler's diff only looks at id + time — so after a language change up
  // to 30 queued reminders would keep speaking the old language for a week.
  // Drop the snapshot and re-schedule everything in the new language.
  ref.listen(localeProvider, (previous, next) {
    if (previous == next) return;
    scheduler.reset();
    unawaited(scheduler.reconcile());
  });

  return scheduler;
});

/// Owns the stock and expiry notifications; the dose reminders are
/// [reminderSchedulerProvider]'s. Separate schedulers, disjoint id slots.
final stockReminderSchedulerProvider = Provider<StockReminderScheduler>((ref) {
  // "Enable notifications" is the master switch: with it off the app
  // schedules nothing at all, so the stock switch is read through it rather
  // than beside it. Otherwise the two settings could disagree about what is
  // booked, and the UI would be the one that is wrong.
  bool enabled(Ref ref) =>
      ref.read(remindersEnabledProvider) &&
      ref.read(stockRemindersEnabledProvider);

  // Same guard as the dose scheduler: reconcile() can still be in flight
  // after the container is disposed, so cache the last-known value rather
  // than reading a disposed Ref.
  var lastEnabled = enabled(ref);
  final scheduler = StockReminderScheduler(
    port: ref.watch(reminderPortProvider),
    medications: ref.watch(medicationRepositoryProvider),
    stockRemindersEnabled: () {
      if (ref.mounted) lastEnabled = enabled(ref);
      return lastEnabled;
    },
    now: ref.watch(nowProvider),
    // Persisted: this scheduler cannot fall back on cancelAll(), so an alert
    // booked in a previous session can only be cancelled if its id survived
    // the restart.
    store: StockAlertStore(ref.watch(sharedPreferencesProvider)),
    rxInputs: () async {
      final rx = await ref.read(rxRepositoryProvider).getAll();
      final list = rx.dataOrNull;
      if (list == null) return null;
      final persons = await ref.read(personRepositoryProvider).getPersons();
      persons.when(
        success: (_) {},
        failure: (message) =>
            debugPrint('Stock reminders: could not load persons: $message'),
      );
      final plans = await ref
          .read(prescriptionRepositoryProvider)
          .getActivePrescriptions();
      plans.when(
        success: (_) {},
        failure: (message) => debugPrint(
          'Stock reminders: could not load dosing plans: $message',
        ),
      );
      return RxReminderInputs(
        rx: list,
        persons: {
          for (final p in persons.dataOrNull ?? const <Person>[]) p.id: p,
        },
        plannedMedicationIds: {
          for (final p in plans.dataOrNull ?? const <Prescription>[])
            p.medicationId,
        },
      );
    },
  );

  // Notification text is baked in when the alert is scheduled, so a language
  // change has to rebuild the queued ones. The ids are stable, so this
  // replaces them in place.
  ref.listen(localeProvider, (previous, next) {
    if (previous == next) return;
    scheduler.reset();
    unawaited(scheduler.reconcile());
  });

  return scheduler;
});

final connectivityServiceProvider = Provider<ConnectivityService>(
  (ref) => ConnectivityService.instance,
);

final photoStorageProvider = Provider<PhotoStorage>(
  (ref) => PhotoStorage.appDocuments(),
);

/// Resolved photo file for a stored image name (null when absent/missing).
final resolvedPhotoProvider = FutureProvider.family<File?, String?>(
  (ref, stored) => ref.watch(photoStorageProvider).resolve(stored),
);

final backupServiceProvider = Provider<BackupService>((ref) {
  final info = ref.watch(buildInfoProvider).value;
  return BackupService(
    database: AppDatabase.instance,
    photos: ref.watch(photoStorageProvider),
    now: ref.watch(nowProvider),
    appVersion: info == null ? '' : '${info.version}+${info.buildNumber}',
  );
});

/// The system file picker for a backup; widget tests inject their own.
final backupFilePickerProvider = Provider<Future<File?> Function()>(
  (ref) => pickBackupFile,
);

final localDataWiperProvider = Provider<LocalDataWiper>(
  (ref) => LocalDataWiper(
    database: AppDatabase.instance,
    photos: ref.watch(photoStorageProvider),
    reminders: ref.watch(reminderPortProvider),
    prefs: ref.watch(sharedPreferencesProvider),
  ),
);

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
    rxRemote: ref.watch(rxRemoteDatasourceProvider),
    familyLocal: ref.watch(familyLocalDatasourceProvider),
    familyRemote: ref.watch(familyDatasourceProvider),
    syncState: ref.watch(syncStateDatasourceProvider),
    stockOutbox: ref.watch(stockOutboxDatasourceProvider),
    cursors: ref.watch(syncCursorStoreProvider),
    failures: ref.watch(syncFailureStoreProvider),
    now: ref.watch(nowProvider),
    // Belt and braces: the auth screen records the data owner right after a
    // sign-in, but if that ever did not happen (an app killed mid-flow, a
    // session restored from disk) the first clean cycle records it.
    onFirstSuccessfulSync: (userId) async {
      final marker = ref.read(localUploadMarkerProvider);
      if (marker.ownerUserId == null) await marker.setOwner(userId);
    },
    // A prescription made or rescheduled on another device: its doses (and
    // so its reminders) are generated here; the listener in
    // [syncStateStreamProvider] reconciles the reminders once the cycle ends.
    onPrescriptionsPulled: (pulled) async {
      await ref.read(doseScheduleServiceProvider).applyPulled(pulled);
    },
    // "Delete all data" on another device: the photos of the medications
    // it removed here go too (the lists and reminders refresh when the
    // cycle ends, as after every sync).
    onRemoteWipe: (removed) async {
      if (kIsWeb) return;
      final photos = ref.read(photoStorageProvider);
      for (final name in removed.photos) {
        await photos.delete(name);
      }
    },
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
      ref.invalidateRxData();
      unawaited(_afterSync(ref));
      // The plain refresh() does not re-plan the stock alerts (only the
      // mutation methods do), so without this a restock on another device
      // still announces "0 left" here until the next cold start.
      unawaited(ref.read(stockReminderSchedulerProvider).reconcile());
    }
  });

  ref.onDispose(subscription.cancel);

  return syncService.stateStream;
});

/// After a sync: generate what the pulled data still lacks (see
/// [DoseScheduleService.ensureScheduled]), then refetch every dose view and
/// re-plan the reminders from the result.
Future<void> _afterSync(Ref ref) async {
  try {
    await ref.read(doseScheduleServiceProvider).ensureScheduled();
    if (!ref.mounted) return;
    ref.invalidateDoseData();
    await ref.read(reminderSchedulerProvider).reconcile();
  } catch (e) {
    debugPrint('Sync: refreshing doses after the sync failed: $e');
  }
}

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

/// Keeps every prescription's doses in line with its schedule, whichever
/// device changed it.
final doseScheduleServiceProvider = Provider<DoseScheduleService>(
  (ref) => DoseScheduleService(
    prescriptions: ref.watch(prescriptionRepositoryProvider),
    doses: ref.watch(doseLogRepositoryProvider),
    now: ref.watch(nowProvider),
  ),
);

/// Delay before the startup sync; tests override this with Duration.zero.
final syncStartupDelayProvider = Provider<Duration>(
  (_) => const Duration(seconds: 2),
);

final appStartupTasksProvider = Provider<AppStartupTasks>((ref) {
  // Once per process: these tasks re-run on every foreground resume, and
  // returning from the gallery picker resumes the app exactly as a scan
  // starts writing its crops. The sweep's own age guard is the second line
  // of defence; leftovers are picked up on the next launch either way.
  var sweptScanTemp = false;
  return AppStartupTasks(
    maintenance: () async {
      // Doses a pull or an older build left out come first, so the sweep
      // and the reminders below see them.
      final regenerated = await ref
          .read(doseScheduleServiceProvider)
          .ensureScheduled();
      final grace = Duration(minutes: ref.read(missedGraceMinutesProvider));
      final changed = await ref
          .read(doseMaintenanceProvider)
          .markOverdueAsMissed(grace: grace);
      if (changed > 0 || regenerated > 0) {
        await ref.read(todaysDoseLogsProvider.notifier).refresh();
        ref.read(doseDataVersionProvider.notifier).bump();
      }
      // Crop folders orphaned by a crash mid-scan (see scan_temp_cleanup).
      if (!kIsWeb && !sweptScanTemp) {
        sweptScanTemp = true;
        await cleanScanTempDirs(await getTemporaryDirectory());
      }
    },
    reminders: () async {
      await ref.read(reminderSchedulerProvider).reconcile();
      await ref.read(stockReminderSchedulerProvider).reconcile();
    },
    sync: () async {
      if (ref.read(appModeProvider) == AppMode.cloud) {
        await ref.read(syncServiceProvider).syncAll();
      }
    },
    syncEnabled: () => ref.read(appModeProvider) == AppMode.cloud,
    // Least urgent step, so it runs last - and only where an update could
    // actually be installed: Android, with a repo configured at build time.
    updateCheck:
        ref.read(platformCapabilitiesProvider).hasInAppUpdates &&
            ref.read(appConfigProvider).hasInAppUpdates
        ? () => ref.read(appUpdateProvider.notifier).check()
        : null,
    syncDelay: ref.watch(syncStartupDelayProvider),
    minSyncInterval: const Duration(minutes: 5),
  );
});

// ============================================================
// Food-supplement register
// ============================================================

/// The offline food-supplement register; overridden in widget tests.
final supplementRegistryServiceProvider = Provider<SupplementRegistryService>((
  ref,
) {
  final service = SupplementRegistryService(now: ref.watch(nowProvider));
  ref.onDispose(service.close);
  return service;
});

// ============================================================
// Scanner ports (camera, gallery, ML Kit)
// ============================================================
// The scanner screen reads these instead of constructing the plugins, so a
// widget test can pump it with fakes (see `scanner_ports.dart`). The
// detectors are closed with the container, which is what the screen used to
// do in `dispose`.

final textRecognitionPortProvider = Provider<TextRecognitionPort>((ref) {
  final port = MlKitTextRecognitionPort();
  ref.onDispose(port.close);
  return port;
});

final barcodeScanPortProvider = Provider<BarcodeScanPort>((ref) {
  final port = MlKitBarcodeScanPort();
  ref.onDispose(port.close);
  return port;
});

/// One camera for the whole container, which is what the routes allow:
/// the scanner is the only screen that opens one and it always leaves by
/// `pushReplacement`, so two live scanners never share it. Two would fight
/// over this instance — the second's `initialize` takes the camera, the
/// first's `dispose` closes it.
final cameraPortProvider = Provider<CameraPort>((ref) {
  final port = CameraControllerPort();
  ref.onDispose(port.dispose);
  return port;
});

final galleryPortProvider = Provider<GalleryPort>(
  (ref) => ImagePickerGalleryPort(),
);

/// AIFA lookup by code, behind a function so widget tests can answer it
/// without the on-device cache (a singleton over `sqflite`) or the network.
final aifaSearchProvider =
    Provider<Future<List<AifaSearchResult>> Function(String code)>(
      (ref) => AifaCacheService.instance.search,
    );
