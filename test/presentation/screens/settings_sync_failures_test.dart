import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/core/platform_capabilities.dart';
import 'package:medora/core/supabase_config.dart';
import 'package:medora/data/datasources/dose_log_local_datasource.dart';
import 'package:medora/data/datasources/family_local_datasource.dart';
import 'package:medora/data/datasources/medication_local_datasource.dart';
import 'package:medora/data/datasources/prescription_local_datasource.dart';
import 'package:medora/data/datasources/treatment_local_datasource.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/models/medication_model.dart';
import 'package:medora/presentation/providers/providers.dart';
import 'package:medora/presentation/providers/settings_providers.dart';
import 'package:medora/presentation/providers/sync_providers.dart';
import 'package:medora/presentation/screens/settings/settings_screen.dart';
import 'package:medora/services/sync_failure_store.dart';
import 'package:medora/services/sync_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/fake_reminder_port.dart';
import '../../helpers/fake_remotes.dart';
import '../../helpers/pump_app.dart';
import '../../helpers/test_database.dart';

void main() {
  setUp(() async {
    SupabaseConfig.resetForTest();
    await setUpTestDatabase();
    // Cloud mode renders the sync tiles; the build itself stays unconfigured.
    SharedPreferences.setMockInitialValues({'app_mode': 'cloud'});
  });
  tearDown(tearDownTestDatabase);

  testWidgets('the failures dialog can discard a stuck local change', (
    tester,
  ) async {
    final now = DateTime.utc(2026, 3, 4, 12);
    final failures = SyncFailureStore.inMemory();
    final server = FakeServer(() => now);
    final meds = server.meds;
    final service = SyncService(
      medicationLocal: MedicationLocalDatasource(),
      medicationRemote: meds,
      treatmentLocal: TreatmentLocalDatasource(),
      treatmentRemote: server.treatments,
      prescriptionLocal: PrescriptionLocalDatasource(),
      prescriptionRemote: server.prescriptions,
      doseLogLocal: DoseLogLocalDatasource(),
      doseLogRemote: server.doses,
      familyLocal: FamilyLocalDatasource(),
      familyRemote: server.families,
      syncState: server.state,
      failures: failures,
      isOnline: () => true,
      currentUserId: () => 'user-a',
      onlineStream: const Stream<bool>.empty(),
      now: () => now,
    );
    addTearDown(service.dispose);

    // A row the server will never accept, and the copy the server already
    // holds — discarding the local change must bring that copy back.
    await MedicationLocalDatasource().upsert(
      const MedicationModel(id: 'bad', name: 'bad', quantity: 1),
      syncStatus: SyncStatus.pendingCreate,
    );
    meds.table.seed(
      const MedicationModel(id: 'bad', name: 'Server', quantity: 4).toJson(),
    );
    meds.table.failIds.add('bad');
    final report = (await service.syncAll())!;
    expect(report.failures, hasLength(1));
    // Let the service's return-to-idle delay fire before the tree is built.
    await tester.pump(const Duration(seconds: 3));

    await pumpMedoraApp(
      tester,
      const SettingsScreen(),
      overrides: [
        sharedPreferencesProvider.overrideWithValue(
          await SharedPreferences.getInstance(),
        ),
        syncStartupDelayProvider.overrideWithValue(Duration.zero),
        reminderPortProvider.overrideWithValue(FakePort()),
        platformCapabilitiesProvider.overrideWithValue(
          PlatformCapabilities.mobile,
        ),
        syncFailureStoreProvider.overrideWithValue(failures),
        syncServiceProvider.overrideWithValue(service),
      ],
    );
    await tester.pumpAndSettle();

    final summary = find.textContaining('1 failed');
    await tester.scrollUntilVisible(
      summary,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    final summaryTile = find.ancestor(
      of: summary,
      matching: find.byType(ListTile),
    );
    await tester.ensureVisible(summaryTile);
    await tester.pumpAndSettle();
    await tester.tap(summaryTile);
    await tester.pumpAndSettle();

    expect(find.text('medications · bad'), findsOneWidget);
    await tester.tap(find.text('Discard local change'));
    await tester.pumpAndSettle();

    // The row is gone from the dialog and accepted as the server's copy.
    expect(find.text('medications · bad'), findsNothing);
    final db = await AppDatabase.instance.database;
    final rows = await db.query(
      'medications',
      where: 'id = ?',
      whereArgs: ['bad'],
    );
    expect(rows.single['sync_status'], SyncStatus.synced);
    expect(rows.single['name'], 'Server');
    expect(await failures.get('medications', 'bad'), isNull);
  });

  testWidgets('the summary mentions rows waiting to retry only when there are '
      'some', (tester) async {
    final now = DateTime.utc(2026, 3, 4, 12);
    var clock = now;
    final failures = SyncFailureStore.inMemory();
    final server = FakeServer(() => clock);
    final meds = server.meds;
    final service = SyncService(
      medicationLocal: MedicationLocalDatasource(),
      medicationRemote: meds,
      treatmentLocal: TreatmentLocalDatasource(),
      treatmentRemote: server.treatments,
      prescriptionLocal: PrescriptionLocalDatasource(),
      prescriptionRemote: server.prescriptions,
      doseLogLocal: DoseLogLocalDatasource(),
      doseLogRemote: server.doses,
      familyLocal: FamilyLocalDatasource(),
      familyRemote: server.families,
      syncState: server.state,
      failures: failures,
      isOnline: () => true,
      currentUserId: () => 'user-a',
      onlineStream: const Stream<bool>.empty(),
      now: () => clock,
    );
    addTearDown(service.dispose);

    await MedicationLocalDatasource().upsert(
      const MedicationModel(id: 'bad', name: 'bad', quantity: 1),
      syncStatus: SyncStatus.pendingCreate,
    );
    meds.table.failIds.add('bad');
    await service.syncAll();
    // Second cycle, inside the backoff window: the row is skipped, not failed.
    clock = now.add(const Duration(seconds: 30));
    service.debugSetStateForTest(SyncState.idle);
    final second = (await service.syncAll())!;
    expect(second.skippedBackoff, 1);
    expect(second.failures, isEmpty);
    await tester.pump(const Duration(seconds: 3));

    await pumpMedoraApp(
      tester,
      const SettingsScreen(),
      overrides: [
        sharedPreferencesProvider.overrideWithValue(
          await SharedPreferences.getInstance(),
        ),
        syncStartupDelayProvider.overrideWithValue(Duration.zero),
        reminderPortProvider.overrideWithValue(FakePort()),
        platformCapabilitiesProvider.overrideWithValue(
          PlatformCapabilities.mobile,
        ),
        syncFailureStoreProvider.overrideWithValue(failures),
        syncServiceProvider.overrideWithValue(service),
      ],
    );
    await tester.pumpAndSettle();

    final summary = find.textContaining('1 waiting to retry');
    await tester.scrollUntilVisible(
      summary,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(summary, findsOneWidget);
  });

  testWidgets('a row waiting out its backoff is still reachable and can be '
      'discarded', (tester) async {
    final now = DateTime.utc(2026, 3, 4, 12);
    var clock = now;
    final failures = SyncFailureStore.inMemory();
    final server = FakeServer(() => clock);
    final meds = server.meds;
    final service = SyncService(
      medicationLocal: MedicationLocalDatasource(),
      medicationRemote: meds,
      treatmentLocal: TreatmentLocalDatasource(),
      treatmentRemote: server.treatments,
      prescriptionLocal: PrescriptionLocalDatasource(),
      prescriptionRemote: server.prescriptions,
      doseLogLocal: DoseLogLocalDatasource(),
      doseLogRemote: server.doses,
      familyLocal: FamilyLocalDatasource(),
      familyRemote: server.families,
      syncState: server.state,
      failures: failures,
      isOnline: () => true,
      currentUserId: () => 'user-a',
      onlineStream: const Stream<bool>.empty(),
      now: () => clock,
    );
    addTearDown(service.dispose);

    await MedicationLocalDatasource().upsert(
      const MedicationModel(id: 'bad', name: 'bad', quantity: 1),
      syncStatus: SyncStatus.pendingCreate,
    );
    meds.table.seed(
      const MedicationModel(id: 'bad', name: 'Server', quantity: 4).toJson(),
    );
    // The row already failed once; this cycle skips it inside its backoff
    // window, so the report has no failures at all.
    await failures.recordFailure('medications', 'bad', now);
    meds.table.failIds.add('bad');
    clock = now.add(const Duration(seconds: 30));
    final report = (await service.syncAll())!;
    expect(report.failures, isEmpty);
    expect(report.skippedBackoff, 1);
    await tester.pump(const Duration(seconds: 3));

    await pumpMedoraApp(
      tester,
      const SettingsScreen(),
      overrides: [
        sharedPreferencesProvider.overrideWithValue(
          await SharedPreferences.getInstance(),
        ),
        syncStartupDelayProvider.overrideWithValue(Duration.zero),
        reminderPortProvider.overrideWithValue(FakePort()),
        platformCapabilitiesProvider.overrideWithValue(
          PlatformCapabilities.mobile,
        ),
        syncFailureStoreProvider.overrideWithValue(failures),
        syncServiceProvider.overrideWithValue(service),
      ],
    );
    await tester.pumpAndSettle();

    final summary = find.textContaining('waiting to retry');
    await tester.scrollUntilVisible(
      summary,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    final summaryTile = find.ancestor(
      of: summary,
      matching: find.byType(ListTile),
    );
    await tester.ensureVisible(summaryTile);
    await tester.pumpAndSettle();
    await tester.tap(summaryTile);
    await tester.pumpAndSettle();

    expect(
      find.text('medications · bad'),
      findsOneWidget,
      reason: 'a backed-off row must still be listed',
    );
    await tester.tap(find.text('Discard local change'));
    await tester.pumpAndSettle();

    expect(find.text('medications · bad'), findsNothing);
    final db = await AppDatabase.instance.database;
    final rows = await db.query(
      'medications',
      where: 'id = ?',
      whereArgs: ['bad'],
    );
    expect(rows.single['name'], 'Server');
    expect(await failures.get('medications', 'bad'), isNull);
  });

  for (final (locale, text) in const [
    (
      'en',
      'The cloud project needs an update: apply '
          'supabase/migrations/20260918000000_sync_v2.sql',
    ),
    (
      'de',
      'Das Cloud-Projekt braucht ein Update: '
          'supabase/migrations/20260918000000_sync_v2.sql anwenden',
    ),
    (
      'it',
      'Il progetto cloud va aggiornato: applica '
          'supabase/migrations/20260918000000_sync_v2.sql',
    ),
  ]) {
    testWidgets('a project without the sync migration is named in Settings '
        '($locale)', (tester) async {
      final now = DateTime.utc(2026, 3, 4, 12);
      final server = FakeServer(() => now);
      server.state.migrated = false;
      final service = SyncService(
        medicationLocal: MedicationLocalDatasource(),
        medicationRemote: server.meds,
        treatmentLocal: TreatmentLocalDatasource(),
        treatmentRemote: server.treatments,
        prescriptionLocal: PrescriptionLocalDatasource(),
        prescriptionRemote: server.prescriptions,
        doseLogLocal: DoseLogLocalDatasource(),
        doseLogRemote: server.doses,
        familyLocal: FamilyLocalDatasource(),
        familyRemote: server.families,
        syncState: server.state,
        isOnline: () => true,
        currentUserId: () => 'user-a',
        onlineStream: const Stream<bool>.empty(),
        now: () => now,
      );
      addTearDown(service.dispose);
      final report = (await service.syncAll())!;
      expect(report.missingMigration, isNotNull);
      await tester.pump(const Duration(seconds: 3));

      await pumpMedoraApp(
        tester,
        const SettingsScreen(),
        locale: Locale(locale),
        overrides: [
          sharedPreferencesProvider.overrideWithValue(
            await SharedPreferences.getInstance(),
          ),
          syncStartupDelayProvider.overrideWithValue(Duration.zero),
          reminderPortProvider.overrideWithValue(FakePort()),
          platformCapabilitiesProvider.overrideWithValue(
            PlatformCapabilities.mobile,
          ),
          syncServiceProvider.overrideWithValue(service),
        ],
      );
      await tester.pumpAndSettle();
      final line = find.byKey(const Key('syncNeedsMigration'));
      await tester.scrollUntilVisible(
        line,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(
        find.descendant(of: line, matching: find.text(text)),
        findsOneWidget,
      );
    });
  }

  testWidgets('a migrated project shows no migration line', (tester) async {
    final now = DateTime.utc(2026, 3, 4, 12);
    final server = FakeServer(() => now);
    final service = SyncService(
      medicationLocal: MedicationLocalDatasource(),
      medicationRemote: server.meds,
      treatmentLocal: TreatmentLocalDatasource(),
      treatmentRemote: server.treatments,
      prescriptionLocal: PrescriptionLocalDatasource(),
      prescriptionRemote: server.prescriptions,
      doseLogLocal: DoseLogLocalDatasource(),
      doseLogRemote: server.doses,
      familyLocal: FamilyLocalDatasource(),
      familyRemote: server.families,
      syncState: server.state,
      isOnline: () => true,
      currentUserId: () => 'user-a',
      onlineStream: const Stream<bool>.empty(),
      now: () => now,
    );
    addTearDown(service.dispose);
    expect((await service.syncAll())!.isClean, isTrue);
    await tester.pump(const Duration(seconds: 3));
    await pumpMedoraApp(
      tester,
      const SettingsScreen(),
      overrides: [
        sharedPreferencesProvider.overrideWithValue(
          await SharedPreferences.getInstance(),
        ),
        syncStartupDelayProvider.overrideWithValue(Duration.zero),
        reminderPortProvider.overrideWithValue(FakePort()),
        platformCapabilitiesProvider.overrideWithValue(
          PlatformCapabilities.mobile,
        ),
        syncServiceProvider.overrideWithValue(service),
      ],
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('syncNeedsMigration')), findsNothing);
  });
}
