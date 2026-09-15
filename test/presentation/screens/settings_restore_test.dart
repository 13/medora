/// Settings -> "Restore from backup": the orchestration around
/// [BackupService.restore] - pick a file, confirm what it holds, apply it,
/// refresh everything that cached the old data, report.
///
/// The service itself is covered by `test/services/backup_service_test.dart`.
/// What is checked here is the wiring the screen owns: the manifest reaching
/// the dialog, the chosen mode and `markPending` reaching the service, the
/// reminders being reset and reconciled afterwards, the rows landing in the
/// database and the snackbar that follows.
///
/// A widget test runs on a fake clock, which never resolves real file I/O, so
/// the backup file is written and parsed in `setUp` (real async) and the seam
/// is a [_RecordingBackupService] that replays what was parsed there.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/core/platform_capabilities.dart';
import 'package:medora/core/supabase_config.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/presentation/providers/providers.dart';
import 'package:medora/presentation/providers/settings_providers.dart';
import 'package:medora/presentation/screens/settings/settings_screen.dart';
import 'package:medora/services/backup_service.dart';
import 'package:medora/services/photo_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import '../../helpers/fake_reminder_port.dart';
import '../../helpers/pump_app.dart';
import '../../helpers/seed.dart';
import '../../helpers/test_database.dart';

const _buildInfo = BuildInfo(
  version: '1.0.0',
  buildNumber: '11',
  buildDate: '2026-09-15T20:14:00Z',
  gitSha: 'abc1234',
  channel: 'ci',
  dartVersion: '3.12.2',
);

/// What the screen asked `restore` to do.
typedef _RestoreCall = ({RestoreMode mode, bool markPending});

/// Replays a backup that was read from disk before the fake clock started.
///
/// [inspect] hands back the manifest of the real file (or throws [failWith]),
/// and [restore] writes the rows the real export produced straight into the
/// in-memory database - sqflite works under the fake clock, `dart:io` does
/// not. The screen cannot tell the difference: it only ever sees the manifest,
/// the rows and the calls it made.
class _RecordingBackupService implements BackupService {
  _RecordingBackupService({
    required this.manifest,
    required this.rows,
    this.failWith,
  });

  final BackupManifest manifest;
  final Map<String, List<Map<String, Object?>>> rows;

  /// When set, [inspect] throws this instead of reporting the manifest.
  final BackupException? failWith;

  final calls = <_RestoreCall>[];

  @override
  Future<BackupManifest> inspect(File file) async {
    if (failWith != null) throw failWith!;
    return manifest;
  }

  @override
  Future<BackupManifest> restore(
    File file, {
    required RestoreMode mode,
    bool markPending = false,
  }) async {
    calls.add((mode: mode, markPending: markPending));
    final db = await AppDatabase.instance.database;
    await db.transaction((txn) async {
      for (final table in const [
        'families',
        'family_members',
        'medications',
        'treatments',
        'prescriptions',
        'dose_logs',
      ]) {
        if (mode == RestoreMode.replace) await txn.delete(table);
        for (final row in rows[table] ?? const <Map<String, Object?>>[]) {
          await txn.insert(table, {
            ...row,
            'sync_status': markPending
                ? SyncStatus.pendingUpdate
                : SyncStatus.synced,
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        }
      }
    });
    return manifest;
  }

  @override
  Future<File> exportToFile(Directory dir, {bool includePhotos = true}) =>
      throw UnimplementedError();

  @override
  Future<int> countPhotos() async => manifest.photoCount;

  @override
  Future<int> estimatePhotoBytes() async => 0;
}

void main() {
  late Directory photoRoot;
  late Directory outDir;
  late File backupFile;
  late BackupManifest manifest;
  late Map<String, List<Map<String, Object?>>> rows;
  late FakePort port;

  setUp(() async {
    SupabaseConfig.resetForTest();
    await setUpTestDatabase();
    SharedPreferences.setMockInitialValues({});
    port = FakePort();
    photoRoot = await Directory.systemTemp.createTemp('medora_restore_photos_');
    outDir = await Directory.systemTemp.createTemp('medora_restore_out_');

    // A real backup of a seeded cabinet, written and read back out here where
    // the clock is real; the widget test only replays it.
    final service = BackupService(
      database: AppDatabase.instance,
      photos: PhotoStorage(rootDirectory: () async => photoRoot),
      now: () => DateTime(2026, 3, 4, 17, 5),
      appVersion: '1.0.0+11',
    );
    final db = await AppDatabase.instance.database;
    final seeded = await seedPrescription(db);
    await seedDoseLog(db, seeded.prescriptionId, DateTime(2026, 3, 1, 8));
    backupFile = await service.exportToFile(outDir);
    manifest = await service.inspect(backupFile);
    rows = {
      for (final table in BackupService.tables)
        table: [
          for (final row in await db.query(table))
            {
              for (final entry in row.entries)
                if (entry.key != 'sync_status') entry.key: entry.value,
            },
        ],
    };
    await AppDatabase.instance.clearAllData();
  });

  tearDown(() async {
    await tearDownTestDatabase();
    if (photoRoot.existsSync()) await photoRoot.delete(recursive: true);
    if (outDir.existsSync()) await outDir.delete(recursive: true);
  });

  Future<List<Override>> overrides(
    BackupService service, {
    bool pickerCancels = false,
  }) async => [
    sharedPreferencesProvider.overrideWithValue(
      await SharedPreferences.getInstance(),
    ),
    syncStartupDelayProvider.overrideWithValue(Duration.zero),
    reminderPortProvider.overrideWithValue(port),
    platformCapabilitiesProvider.overrideWithValue(PlatformCapabilities.mobile),
    buildInfoProvider.overrideWith((ref) async => _buildInfo),
    backupServiceProvider.overrideWithValue(service),
    backupFilePickerProvider.overrideWithValue(
      () async => pickerCancels ? null : backupFile,
    ),
  ];

  /// Opens Settings on a tall screen and taps "Restore from backup".
  Future<void> tapRestore(WidgetTester tester, List<Override> given) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await pumpMedoraApp(tester, const SettingsScreen(), overrides: given);
    await tester.pumpAndSettle();

    final tile = find.text('Restore from backup');
    await tester.scrollUntilVisible(
      tile,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(tile);
    await tester.pumpAndSettle();
  }

  testWidgets('a local-only restore confirms, applies and reports', (
    tester,
  ) async {
    final service = _RecordingBackupService(manifest: manifest, rows: rows);
    await tapRestore(tester, await overrides(service));

    // The dialog describes the file that was picked.
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.textContaining('${manifest.totalRows} rows'), findsOneWidget);
    expect(find.text('1.0.0+11'), findsOneWidget);

    final cancelledBefore = port.cancelAllCalls;
    // "Replace everything" is preselected.
    await tester.tap(find.text('Restore'));
    await tester.pumpAndSettle();

    expect(service.calls, [(mode: RestoreMode.replace, markPending: false)]);
    expect(find.text('Restored ${manifest.totalRows} rows'), findsOneWidget);

    final db = await AppDatabase.instance.database;
    expect(await db.query('medications'), hasLength(1));
    expect(await db.query('dose_logs'), hasLength(1));
    expect(
      port.cancelAllCalls,
      greaterThan(cancelledBefore),
      reason: 'the reminders are reset and reconciled after a restore',
    );
  });

  testWidgets('cloud mode marks the restored rows for upload, and merge is '
      'passed through', (tester) async {
    SharedPreferences.setMockInitialValues({'app_mode': 'cloud'});
    final service = _RecordingBackupService(manifest: manifest, rows: rows);
    await tapRestore(tester, await overrides(service));

    await tester.tap(find.text('Merge with this device'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Restore'));
    await tester.pumpAndSettle();

    expect(service.calls, [(mode: RestoreMode.merge, markPending: true)]);
    final db = await AppDatabase.instance.database;
    final statuses = (await db.query(
      'medications',
      columns: ['sync_status'],
    )).map((row) => row['sync_status']).toSet();
    expect(statuses, {SyncStatus.pendingUpdate});
  });

  testWidgets('backing out of the dialog restores nothing', (tester) async {
    final service = _RecordingBackupService(manifest: manifest, rows: rows);
    await tapRestore(tester, await overrides(service));

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(service.calls, isEmpty);
    final db = await AppDatabase.instance.database;
    expect(await db.query('medications'), isEmpty);
  });

  testWidgets('a file that is not a backup is reported and changes nothing', (
    tester,
  ) async {
    final service = _RecordingBackupService(
      manifest: manifest,
      rows: rows,
      failWith: const BackupException(BackupErrorKind.notABackup),
    );
    await tapRestore(tester, await overrides(service));

    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('That file is not a Medora backup.'), findsOneWidget);
    expect(service.calls, isEmpty);
    final db = await AppDatabase.instance.database;
    expect(await db.query('medications'), isEmpty);
  });

  testWidgets('cancelling the file picker is not an error', (tester) async {
    final service = _RecordingBackupService(manifest: manifest, rows: rows);
    await tapRestore(tester, await overrides(service, pickerCancels: true));

    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byType(SnackBar), findsNothing);
    expect(service.calls, isEmpty);
  });
}
