# Phase 0 — Build & Local-Only Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Medora build and run from a fresh clone with no configuration and no network, with cloud sync (Supabase) as an optional mode, a migration ledger, platform gating, and a working test/CI baseline.

**Architecture:** Configuration moves from a bundled `.env` asset to `--dart-define` values read by a pure `AppConfig`. A persisted `AppMode` (`localOnly` | `cloud`) decides whether remote datasources exist at all; repositories accept a nullable remote and skip sync when it is null. Routing gets a single `redirect` for auth and a single `BiometricGate` in a `ShellRoute`. `AppDatabase` gains an ordered migration list recorded in a `schema_migrations` table and a test-only path override so every data test runs against a real in-memory SQLite.

**Tech Stack:** Flutter 3.44 (via `fvm`), Dart 3.11, flutter_riverpod 3, go_router 17, sqflite + sqflite_common_ffi, supabase_flutter 2, flutter_local_notifications 21, flutter_test.

Spec: `docs/superpowers/specs/2026-09-14-medora-offline-first-overhaul-design.md` (Phase 0 = §5 "Phase 0", plus §4.1, §4.2, §4.3, §4.8).

## Global Constraints

- Run every Flutter/Dart command through `fvm`: `fvm flutter …`, `fvm dart …`. Working directory is the repo root `/home/ben/repo/medora`.
- Flutter channel pinned by `.fvmrc` = `stable` (currently 3.44.6). Dart SDK `^3.11.0`.
- Default app mode is `AppMode.localOnly`. The app must never throw when Supabase is not configured.
- Supabase credentials come only from `--dart-define=SUPABASE_URL=… --dart-define=SUPABASE_ANON_KEY=…` (or `--dart-define-from-file`). No `.env` asset. `flutter_dotenv` is removed.
- Anonymous Supabase sign-in ("Continue as guest") is removed entirely (spec §8.1).
- All user-visible strings go through `AppLocalizations` (ARB files `lib/l10n/app_en.arb`, `app_de.arb`, `app_it.arb`). After editing ARB files run `fvm flutter gen-l10n`. Generated files under `lib/l10n/generated/` are committed.
- Keep the existing Clean Architecture layout (`core/`, `domain/`, `data/`, `services/`, `presentation/`). Do not introduce Drift/Isar.
- Package imports only: `package:medora/...`.
- Every task ends with `fvm flutter analyze` reporting `No issues found!` and `fvm flutter test` green, then a commit. Commit messages end with:
  ```
  Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01BAjdzp9JhksW2XbhM6CPBS
  ```
- `fvm flutter analyze` and `fvm flutter pub get` may touch `lib/l10n/generated/*`; only commit those when a task intentionally changed ARB files.

## File map (what Phase 0 creates or changes)

| Path | Responsibility |
|---|---|
| `lib/core/app_config.dart` (new) | Pure, testable holder of Supabase URL/key from dart-defines. |
| `lib/core/supabase_config.dart` | `isConfigured`, `clientOrNull`, `requireClient()`; never throws on access. |
| `lib/core/platform_capabilities.dart` (new) | `hasCamera`, `hasLocalNotifications`, `hasFileShare`, `hasBiometrics` + provider. |
| `lib/data/local/app_database.dart` | Base schema, migration ledger, `debugPathOverride`, `reset()`. |
| `lib/data/local/migrations.dart` (new) | Ordered `List<Migration>`; migration 11 adds `deleted_at` columns. |
| `lib/data/datasources/*_remote_datasource.dart` | Take `SupabaseClient` by constructor. |
| `lib/data/repositories/*_repository_impl.dart` | Nullable remote; skip background sync when null. |
| `lib/services/sync_service.dart` | Nullable remotes; `syncAll` no-ops in local-only mode. |
| `lib/presentation/providers/app_mode_provider.dart` (new) | Persisted `AppMode`. |
| `lib/presentation/providers/providers.dart` | `supabaseClientProvider`, nullable remote providers, family providers (deduplicated). |
| `lib/presentation/providers/auth_providers.dart` | Safe `authStateProvider`; guest sign-in removed; `isOfflineModeProvider` removed. |
| `lib/presentation/providers/family_providers.dart` | Uses providers from `providers.dart`; no duplicate datasource providers. |
| `lib/presentation/router/app_router.dart` | `appRouterProvider` with `redirect`, `ShellRoute` + `BiometricGate`. |
| `lib/presentation/widgets/biometric_gate.dart` (new) | Single biometric lock overlay. |
| `lib/presentation/screens/auth/auth_screen.dart` | "Use on this device" primary path; guest removed. |
| `lib/presentation/screens/settings/settings_screen.dart` | "Cloud sync" section; account section only in cloud mode. |
| `lib/presentation/screens/family/family_screen.dart` | Local-only empty state. |
| `lib/presentation/widgets/sync_icon_button.dart` | Hidden in local-only mode. |
| `lib/core/theme.dart` | Bundled Inter via `fontFamily`, `google_fonts` removed. |
| `assets/fonts/Inter-*.ttf` (new) | Bundled font. |
| `ios/Runner/Info.plist`, `web/manifest.json` | Usage strings; PWA metadata. |
| `test/helpers/test_database.dart` (new) | In-memory sqflite bootstrap for tests. |
| `test/**` (new) | Unit tests per task. |
| `.github/workflows/ci.yml` (new) | analyze, test, build web, build apk (debug). |
| `README.md`, `dart_defines.example.json` (new) | Setup without Supabase; optional cloud config. |

---

### Task 1: AppConfig from dart-defines; remove `.env` asset (unblocks the build)

**Files:**
- Create: `lib/core/app_config.dart`
- Create: `dart_defines.example.json`
- Modify: `lib/core/supabase_config.dart`
- Modify: `lib/main.dart:6-49`
- Modify: `pubspec.yaml` (remove `flutter_dotenv`, remove `- .env` asset)
- Delete: `.env.example`
- Test: `test/core/app_config_test.dart`

**Interfaces:**
- Produces:
  ```dart
  class AppConfig {
    const AppConfig({required this.supabaseUrl, required this.supabaseAnonKey});
    factory AppConfig.fromEnvironment();           // reads String.fromEnvironment
    final String supabaseUrl; final String supabaseAnonKey;
    bool get isCloudAvailable;                     // both non-empty
  }
  class SupabaseConfig {
    static Future<void> initialize(AppConfig config);
    static bool get isConfigured;
    static SupabaseClient? get clientOrNull;
    static SupabaseClient requireClient();          // throws AuthException('Cloud sync is not configured')
    static String? get currentUserId;
    static bool get isAuthenticated;
  }
  ```

- [ ] **Step 1: Write the failing test**

Create `test/core/app_config_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/core/app_config.dart';

void main() {
  group('AppConfig', () {
    test('isCloudAvailable is false when either value is empty', () {
      expect(const AppConfig(supabaseUrl: '', supabaseAnonKey: '').isCloudAvailable, isFalse);
      expect(const AppConfig(supabaseUrl: 'https://x.supabase.co', supabaseAnonKey: '').isCloudAvailable, isFalse);
      expect(const AppConfig(supabaseUrl: '', supabaseAnonKey: 'key').isCloudAvailable, isFalse);
    });

    test('isCloudAvailable is true when both values are set', () {
      const config = AppConfig(supabaseUrl: 'https://x.supabase.co', supabaseAnonKey: 'key');
      expect(config.isCloudAvailable, isTrue);
    });

    test('fromEnvironment defaults to empty strings when no dart-defines are given', () {
      final config = AppConfig.fromEnvironment();
      expect(config.supabaseUrl, '');
      expect(config.supabaseAnonKey, '');
      expect(config.isCloudAvailable, isFalse);
    });
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `fvm flutter test test/core/app_config_test.dart`
Expected: FAIL — either `No file or variants found for asset: .env.` (asset bundle error) or `Target of URI doesn't exist: 'package:medora/core/app_config.dart'`.

- [ ] **Step 3: Create `lib/core/app_config.dart`**

```dart
/// Medora - Build-time configuration.
///
/// Values come from `--dart-define` (or `--dart-define-from-file`).
/// When absent, the app runs in local-only mode and cloud sync is unavailable.
library;

class AppConfig {
  const AppConfig({
    required this.supabaseUrl,
    required this.supabaseAnonKey,
  });

  /// Read from compile-time environment. Both default to empty strings.
  factory AppConfig.fromEnvironment() {
    return const AppConfig(
      supabaseUrl: String.fromEnvironment('SUPABASE_URL'),
      supabaseAnonKey: String.fromEnvironment('SUPABASE_ANON_KEY'),
    );
  }

  final String supabaseUrl;
  final String supabaseAnonKey;

  /// True when the build carries a complete Supabase configuration.
  bool get isCloudAvailable =>
      supabaseUrl.trim().isNotEmpty && supabaseAnonKey.trim().isNotEmpty;
}
```

- [ ] **Step 4: Rewrite `lib/core/supabase_config.dart`**

```dart
/// Medora - Supabase Configuration
///
/// Never throws on access: when the build has no Supabase configuration,
/// [clientOrNull] is null and [isConfigured] is false.
library;

import 'package:flutter/foundation.dart';
import 'package:medora/core/app_config.dart';
import 'package:medora/core/errors.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class SupabaseConfig {
  SupabaseConfig._();

  static bool _initialized = false;

  /// True after a successful [initialize] with a complete [AppConfig].
  static bool get isConfigured => _initialized;

  /// The Supabase client, or null when cloud is not configured.
  static SupabaseClient? get clientOrNull =>
      _initialized ? Supabase.instance.client : null;

  /// The Supabase client; throws [AuthException] when not configured.
  static SupabaseClient requireClient() {
    final client = clientOrNull;
    if (client == null) {
      throw const AuthException('Cloud sync is not configured');
    }
    return client;
  }

  /// Initialize Supabase if [config] is complete. Safe to call without config.
  static Future<void> initialize(AppConfig config) async {
    if (_initialized) return;
    if (!config.isCloudAvailable) {
      debugPrint('ℹ Supabase not configured — local-only build');
      return;
    }
    await Supabase.initialize(
      url: config.supabaseUrl,
      // ignore: deprecated_member_use
      anonKey: config.supabaseAnonKey,
    );
    _initialized = true;
    debugPrint('✅ Supabase initialized');
  }

  /// Get the current authenticated user ID, or null.
  static String? get currentUserId => clientOrNull?.auth.currentUser?.id;

  /// Whether we have a valid Supabase session.
  static bool get isAuthenticated => clientOrNull?.auth.currentSession != null;

  /// Test-only: forget initialization state.
  @visibleForTesting
  static void resetForTest() => _initialized = false;
}
```

Note: `anonKey` is deprecated in supabase_flutter 2.9 in favor of `publishableKey`; keep `anonKey` for now and add `// ignore: deprecated_member_use` on that line so `flutter analyze` is clean. (Task 8 revisits.)

- [ ] **Step 5: Update `lib/main.dart`**

Replace the imports and `main()` body:

```dart
/// Medora - Home Medicine Cabinet Manager
///
/// Main entry point for the application.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:medora/core/app_config.dart';
import 'package:medora/core/supabase_config.dart';
import 'package:medora/core/theme.dart';
import 'package:medora/data/local/db_setup.dart' if (dart.library.html) 'package:medora/data/local/db_setup_web.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/presentation/providers/settings_providers.dart';
import 'package:medora/presentation/router/app_router.dart';
import 'package:medora/services/connectivity_service.dart';
import 'package:medora/services/reminder_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  setupDatabaseFactory();

  final prefs = await SharedPreferences.getInstance();

  // Cloud is optional: this is a no-op when no dart-defines are present.
  await _initSafe('Supabase', () => SupabaseConfig.initialize(AppConfig.fromEnvironment()));

  _initServicesInBackground();

  runApp(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
      ],
      child: const MedoraApp(),
    ),
  );
}
```

Keep `_initServicesInBackground`, `_initSafe`, and `MedoraApp` exactly as they are (Task 5 changes `MedoraApp` to use `appRouterProvider`).

- [ ] **Step 6: Update `pubspec.yaml`**

Remove the line `  flutter_dotenv: ^6.0.0` under `# Utilities`, and remove `    - .env` from `flutter: assets:`. The assets block becomes:

```yaml
  assets:
    - assets/icon/medora_icon.png
    - assets/icon/medora_icon_pill.png
```

Then: `git rm .env.example` and create `dart_defines.example.json`:

```json
{
  "SUPABASE_URL": "https://your-project.supabase.co",
  "SUPABASE_ANON_KEY": "your-anon-key-here"
}
```

Add `dart_defines.json` to `.gitignore` (append a line `dart_defines.json` under the existing `.env` entry).

- [ ] **Step 7: Install and verify**

Run: `fvm flutter pub get && fvm flutter analyze`
Expected: `No issues found!` (the `.env` asset warning is gone; `anonKey` deprecation is suppressed).

Run: `fvm flutter test test/core/app_config_test.dart`
Expected: `All tests passed!` (3 tests).

Run: `fvm flutter test`
Expected: all tests pass (the old placeholder `test/widget_test.dart` still runs).

- [ ] **Step 8: Commit**

```bash
git add -A lib/core/app_config.dart lib/core/supabase_config.dart lib/main.dart pubspec.yaml pubspec.lock .gitignore dart_defines.example.json .env.example test/core/app_config_test.dart
git commit -m "feat(config): read Supabase config from dart-defines, drop .env asset

Fresh clones can now build and test without creating a .env file.
Supabase becomes optional: SupabaseConfig never throws when unconfigured.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01BAjdzp9JhksW2XbhM6CPBS"
```

---

### Task 2: Test database harness + migration ledger

**Files:**
- Create: `test/helpers/test_database.dart`
- Create: `lib/data/local/migrations.dart`
- Modify: `lib/data/local/app_database.dart`
- Test: `test/data/local/app_database_test.dart`

**Interfaces:**
- Produces:
  ```dart
  // lib/data/local/migrations.dart
  class Migration { const Migration(this.version, this.run); final int version; final Future<void> Function(Database db) run; }
  const int kSchemaVersion = 11;
  final List<Migration> kMigrations;   // ascending, versions 11..kSchemaVersion

  // lib/data/local/app_database.dart
  class AppDatabase {
    static AppDatabase instance;
    @visibleForTesting static String? debugPathOverride;   // e.g. inMemoryDatabasePath
    Future<Database> get database;
    Future<void> close();
    @visibleForTesting Future<void> reset();                // close + forget cached handle
    static Future<void> createBaseSchema(Database db);      // the v10 schema (was _onCreate)
    Future<List<int>> appliedMigrations();                  // from schema_migrations
    Future<void> clearAllData();
  }

  // test/helpers/test_database.dart
  Future<void> setUpTestDatabase();     // call in setUp(): ffi init, in-memory path, reset
  Future<void> tearDownTestDatabase();  // call in tearDown()
  ```

- [ ] **Step 1: Write the failing tests**

Create `test/helpers/test_database.dart`:

```dart
import 'package:medora/data/local/app_database.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

bool _ffiReady = false;

/// Point [AppDatabase] at a fresh in-memory SQLite database.
/// Call from `setUp`.
Future<void> setUpTestDatabase() async {
  if (!_ffiReady) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    _ffiReady = true;
  }
  await AppDatabase.instance.reset();
  AppDatabase.debugPathOverride = inMemoryDatabasePath;
}

/// Close the in-memory database. Call from `tearDown`.
Future<void> tearDownTestDatabase() async {
  await AppDatabase.instance.reset();
  AppDatabase.debugPathOverride = null;
}
```

Create `test/data/local/app_database_test.dart`:

```dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/local/migrations.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../helpers/test_database.dart';

Future<Set<String>> columnsOf(Database db, String table) async {
  final rows = await db.rawQuery('PRAGMA table_info($table)');
  return rows.map((r) => r['name'] as String).toSet();
}

void main() {
  setUp(setUpTestDatabase);
  tearDown(tearDownTestDatabase);

  test('fresh database has all tables and records every migration as applied', () async {
    final db = await AppDatabase.instance.database;
    final tables = (await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table'",
    )).map((r) => r['name'] as String).toSet();

    expect(tables, containsAll(['medications', 'treatments', 'prescriptions', 'dose_logs', 'families', 'family_members', 'schema_migrations']));
    expect(await AppDatabase.instance.appliedMigrations(), kMigrations.map((m) => m.version).toList());
  });

  test('migration 11 adds deleted_at to synced tables', () async {
    final db = await AppDatabase.instance.database;
    for (final table in ['medications', 'treatments', 'prescriptions', 'dose_logs']) {
      expect(await columnsOf(db, table), contains('deleted_at'), reason: table);
    }
  });

  test('upgrading a v10 database applies pending migrations exactly once', () async {
    // Build a v10 file database with the legacy schema, then reopen through AppDatabase.
    final dir = await Directory.systemTemp.createTemp('medora_mig_');
    final path = p.join(dir.path, 'medora.db');
    final legacy = await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(version: 10, onCreate: (db, _) => AppDatabase.createBaseSchema(db)),
    );
    expect(await columnsOf(legacy, 'medications'), isNot(contains('deleted_at')));
    await legacy.close();

    AppDatabase.debugPathOverride = path;
    await AppDatabase.instance.reset();
    final upgraded = await AppDatabase.instance.database;

    expect(await columnsOf(upgraded, 'medications'), contains('deleted_at'));
    expect(await AppDatabase.instance.appliedMigrations(), [11]);

    // Reopen: nothing re-applied, no duplicate rows.
    await AppDatabase.instance.reset();
    final again = await AppDatabase.instance.database;
    expect(await AppDatabase.instance.appliedMigrations(), [11]);
    await again.close();
    await dir.delete(recursive: true);
  });

  test('clearAllData empties every table', () async {
    final db = await AppDatabase.instance.database;
    await db.insert('medications', {'id': 'm1', 'name': 'Tachipirina', 'quantity': 1});
    await AppDatabase.instance.clearAllData();
    expect(await db.query('medications'), isEmpty);
  });
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `fvm flutter test test/data/local/app_database_test.dart`
Expected: FAIL — `Target of URI doesn't exist: 'package:medora/data/local/migrations.dart'` and undefined `reset`/`debugPathOverride`.

- [ ] **Step 3: Create `lib/data/local/migrations.dart`**

```dart
/// Medora - Local schema migrations.
///
/// Add a new [Migration] with the next version number at the END of
/// [kMigrations] and bump [kSchemaVersion]. Never edit an existing migration.
library;

import 'package:sqflite/sqflite.dart';

class Migration {
  const Migration(this.version, this.run);

  final int version;
  final Future<void> Function(Database db) run;
}

/// Current schema version. Must equal the last entry of [kMigrations].
const int kSchemaVersion = 11;

final List<Migration> kMigrations = [
  // v11: tombstone column for sync (spec §4.3). photo_file arrives with Phase 1.
  Migration(11, (db) async {
    for (final table in ['medications', 'treatments', 'prescriptions', 'dose_logs']) {
      await db.execute('ALTER TABLE $table ADD COLUMN deleted_at TEXT');
    }
  }),
];
```

- [ ] **Step 4: Rewrite the database lifecycle in `lib/data/local/app_database.dart`**

Replace everything from `class AppDatabase {` through the end of `_onUpgrade` with the following. Keep the existing `SyncStatus` class and the `clearAllData` / `close` methods (modify as shown).

```dart
/// Singleton database helper for the app.
class AppDatabase {
  AppDatabase._();

  static final AppDatabase instance = AppDatabase._();
  static Database? _database;

  /// Test-only: when set, the database opens at this path
  /// (use [inMemoryDatabasePath] for a throwaway database).
  @visibleForTesting
  static String? debugPathOverride;

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase() async {
    final path = debugPathOverride ??
        (kIsWeb ? 'medora.db' : join(await getDatabasesPath(), 'medora.db'));

    return databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: kSchemaVersion,
        onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
        onCreate: (db, version) async {
          await createBaseSchema(db);
          await _createLedger(db);
          for (final m in kMigrations) {
            await m.run(db);
            await _record(db, m.version);
          }
        },
        onUpgrade: (db, oldVersion, newVersion) async {
          await _createLedger(db);
          final applied = (await _applied(db)).toSet();
          for (final m in kMigrations) {
            if (m.version <= oldVersion || applied.contains(m.version)) continue;
            await m.run(db);
            await _record(db, m.version);
          }
        },
      ),
    );
  }

  static Future<void> _createLedger(Database db) => db.execute(
        'CREATE TABLE IF NOT EXISTS schema_migrations (version INTEGER PRIMARY KEY, applied_at TEXT NOT NULL)',
      );

  static Future<void> _record(Database db, int version) => db.insert(
        'schema_migrations',
        {'version': version, 'applied_at': DateTime.now().toIso8601String()},
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );

  static Future<List<int>> _applied(Database db) async {
    final rows = await db.query('schema_migrations', columns: ['version'], orderBy: 'version');
    return rows.map((r) => r['version'] as int).toList();
  }

  /// Versions recorded in `schema_migrations`, ascending.
  Future<List<int>> appliedMigrations() async => _applied(await database);

  /// The base (v10) schema. New columns go into [kMigrations], not here.
  static Future<void> createBaseSchema(Database db) async {
    // ... paste the body of the old _onCreate here unchanged (CREATE TABLE
    //     medications / treatments / prescriptions / dose_logs / families /
    //     family_members and the CREATE INDEX statements) ...
  }

  Future<void> clearAllData() async {
    final db = await database;
    await db.delete('dose_logs');
    await db.delete('prescriptions');
    await db.delete('treatments');
    await db.delete('medications');
    await db.delete('family_members');
    await db.delete('families');
  }

  Future<void> close() async {
    final db = _database;
    if (db != null) {
      await db.close();
      _database = null;
    }
  }

  /// Test-only: close and forget the cached handle.
  @visibleForTesting
  Future<void> reset() => close();
}
```

Update the imports at the top of the file to:

```dart
import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
import 'package:medora/data/local/migrations.dart';
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';
```

The web branch previously called `databaseFactory.openDatabase('medora.db', …)` without `onConfigure`; the unified code above passes `onConfigure` on all platforms — `sqflite_common_ffi_web` accepts it.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `fvm flutter test test/data/local/app_database_test.dart`
Expected: `All tests passed!` (4 tests).

Run: `fvm flutter analyze`
Expected: `No issues found!`

- [ ] **Step 6: Commit**

```bash
git add lib/data/local/app_database.dart lib/data/local/migrations.dart test/helpers/test_database.dart test/data/local/app_database_test.dart
git commit -m "feat(db): add migration ledger and in-memory test harness

schema_migrations table records applied versions; migration 11 adds
deleted_at tombstone columns. AppDatabase.debugPathOverride lets tests
run against real SQLite via sqflite_common_ffi.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01BAjdzp9JhksW2XbhM6CPBS"
```

---
### Task 3: Unit tests for `Prescription.scheduledDoseTimes`

Pure-logic coverage for the code that drives every dose and reminder. No production change unless a test exposes a bug (none expected; if one fails, fix `lib/domain/entities/prescription.dart` minimally and note it in the commit).

**Files:**
- Test: `test/domain/entities/prescription_test.dart`

**Interfaces:**
- Consumes: `Prescription` from `lib/domain/entities/prescription.dart` (constructor fields `intervalHours`, `durationDays`, `startTime`, `scheduleType`, `scheduleTimes`; getters `scheduledDoseTimes`, `dosesPerDay`, `endTime`).

- [ ] **Step 1: Write the tests**

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/domain/entities/prescription.dart';

Prescription _p({
  int intervalHours = 8,
  int durationDays = 7,
  DateTime? startTime,
  String scheduleType = 'fixed_interval',
  List<String>? scheduleTimes,
}) {
  return Prescription(
    id: 'p1',
    treatmentId: 't1',
    medicationId: 'm1',
    dosage: '1 tablet',
    intervalHours: intervalHours,
    durationDays: durationDays,
    startTime: startTime ?? DateTime(2026, 3, 1, 8, 0),
    scheduleType: scheduleType,
    scheduleTimes: scheduleTimes,
  );
}

void main() {
  group('fixed_interval', () {
    test('generates durationDays * (24 / interval) doses starting at startTime', () {
      final times = _p(intervalHours: 8, durationDays: 2).scheduledDoseTimes;
      expect(times.length, 6);
      expect(times.first, DateTime(2026, 3, 1, 8, 0));
      expect(times.last, DateTime(2026, 3, 3, 0, 0));
    });

    test('is sorted ascending and strictly before endTime', () {
      final p = _p(intervalHours: 6, durationDays: 3);
      final times = p.scheduledDoseTimes;
      for (var i = 1; i < times.length; i++) {
        expect(times[i].isAfter(times[i - 1]), isTrue);
      }
      expect(times.every((t) => t.isBefore(p.endTime)), isTrue);
    });

    test('clamps interval below 1 hour to 1 hour (no infinite loop)', () {
      final times = _p(intervalHours: 0, durationDays: 1).scheduledDoseTimes;
      expect(times.length, 24);
    });

    test('caps at 1000 doses for absurd durations', () {
      final times = _p(intervalHours: 1, durationDays: 365).scheduledDoseTimes;
      expect(times.length, 1000);
    });

    test('dosesPerDay rounds up', () {
      expect(_p(intervalHours: 8).dosesPerDay, 3);
      expect(_p(intervalHours: 7).dosesPerDay, 4);
    });
  });

  group('times_per_day', () {
    test('uses the given clock times on each day of the duration', () {
      final times = _p(
        scheduleType: 'times_per_day',
        scheduleTimes: ['08:00', '20:00'],
        durationDays: 3,
        startTime: DateTime(2026, 3, 1, 7, 0),
      ).scheduledDoseTimes;
      expect(times.length, 6);
      expect(times[0], DateTime(2026, 3, 1, 8, 0));
      expect(times[1], DateTime(2026, 3, 1, 20, 0));
      expect(times.last, DateTime(2026, 3, 3, 20, 0));
    });

    test('skips times on the first day that are before startTime and continues until endTime', () {
      final times = _p(
        scheduleType: 'times_per_day',
        scheduleTimes: ['08:00', '20:00'],
        durationDays: 1,
        startTime: DateTime(2026, 3, 1, 12, 0),
      ).scheduledDoseTimes;
      expect(times, [DateTime(2026, 3, 1, 20, 0), DateTime(2026, 3, 2, 8, 0)]);
    });

    test('includes a time equal to startTime (minute precision)', () {
      final times = _p(
        scheduleType: 'times_per_day',
        scheduleTimes: ['08:00'],
        durationDays: 1,
        startTime: DateTime(2026, 3, 1, 8, 0),
      ).scheduledDoseTimes;
      expect(times, [DateTime(2026, 3, 1, 8, 0)]);
    });

    test('falls back to fixed interval when scheduleTimes is empty', () {
      final times = _p(
        scheduleType: 'times_per_day',
        scheduleTimes: const [],
        intervalHours: 12,
        durationDays: 1,
      ).scheduledDoseTimes;
      expect(times.length, 2);
    });

    test('dosesPerDay equals number of times', () {
      expect(_p(scheduleType: 'times_per_day', scheduleTimes: ['08:00', '12:00', '18:00']).dosesPerDay, 3);
    });
  });
}
```

- [ ] **Step 2: Run the tests**

Run: `fvm flutter test test/domain/entities/prescription_test.dart`
Expected: `All tests passed!` (10 tests). If any fails, the assertion documents intended behavior from the existing implementation — inspect `scheduledDoseTimes` before changing either side.

- [ ] **Step 3: Commit**

```bash
git add test/domain/entities/prescription_test.dart
git commit -m "test(domain): cover Prescription.scheduledDoseTimes

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01BAjdzp9JhksW2XbhM6CPBS"
```

---

### Task 4: `AppMode` + null-safe remote layer

In local-only mode no remote datasource exists. Remote datasources receive a `SupabaseClient` by constructor; providers hand out `null` when the app is local-only or the build has no Supabase config; repositories and `SyncService` accept nullable remotes and skip network work when null.

**Files:**
- Create: `lib/presentation/providers/app_mode_provider.dart`
- Modify: `lib/data/datasources/medication_remote_datasource.dart`, `treatment_remote_datasource.dart`, `prescription_remote_datasource.dart`, `dose_log_remote_datasource.dart`, `family_remote_datasource.dart`
- Modify: `lib/data/repositories/medication_repository_impl.dart`, `treatment_repository_impl.dart`, `prescription_repository_impl.dart`, `dose_log_repository_impl.dart`, `family_repository_impl.dart`
- Modify: `lib/services/sync_service.dart`
- Modify: `lib/presentation/providers/providers.dart`, `family_providers.dart`, `auth_providers.dart`
- Modify: `lib/presentation/widgets/sync_icon_button.dart`
- Test: `test/presentation/providers/app_mode_provider_test.dart`, `test/data/repositories/medication_repository_local_only_test.dart`

**Interfaces:**
- Produces:
  ```dart
  enum AppMode { localOnly, cloud }
  final appModeProvider = NotifierProvider<AppModeNotifier, AppMode>;  // .set(AppMode)
  final supabaseClientProvider = Provider<SupabaseClient?>;             // null unless cloud && configured
  final medicationDatasourceProvider = Provider<MedicationRemoteDatasource?>;   // same for treatment/prescription/doseLog/family
  final familyRepositoryProvider = Provider<FamilyRepository>;           // moved to providers.dart
  // Repositories: `final XRemoteDatasource? remoteDatasource;`
  // SyncService: all *Remote fields nullable; `bool get isAvailable`.
  ```
- Removed: `isOfflineModeProvider`, `OfflineModeNotifier`, `AuthController.enterOfflineMode`, `AuthController.signInAnonymously`, duplicate `familyLocalDatasourceProvider`/`familyRemoteDatasourceProvider` in `family_providers.dart`.

- [ ] **Step 1: Write the failing tests**

`test/presentation/providers/app_mode_provider_test.dart`:

```dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/presentation/providers/app_mode_provider.dart';
import 'package:medora/presentation/providers/providers.dart';
import 'package:medora/presentation/providers/settings_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  ProviderContainer makeContainer() => ProviderContainer(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      );

  test('defaults to localOnly', () {
    final c = makeContainer();
    addTearDown(c.dispose);
    expect(c.read(appModeProvider), AppMode.localOnly);
  });

  test('set persists across containers', () async {
    final c1 = makeContainer();
    await c1.read(appModeProvider.notifier).set(AppMode.cloud);
    c1.dispose();

    final c2 = makeContainer();
    addTearDown(c2.dispose);
    expect(c2.read(appModeProvider), AppMode.cloud);
  });

  test('remote datasources are null in localOnly mode', () {
    final c = makeContainer();
    addTearDown(c.dispose);
    expect(c.read(supabaseClientProvider), isNull);
    expect(c.read(medicationDatasourceProvider), isNull);
    expect(c.read(familyDatasourceProvider), isNull);
  });

  test('remote datasources stay null in cloud mode when the build is unconfigured', () async {
    final c = makeContainer();
    addTearDown(c.dispose);
    await c.read(appModeProvider.notifier).set(AppMode.cloud);
    expect(c.read(supabaseClientProvider), isNull);
    expect(c.read(medicationDatasourceProvider), isNull);
  });
}
```

`test/data/repositories/medication_repository_local_only_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/data/datasources/medication_local_datasource.dart';
import 'package:medora/data/repositories/medication_repository_impl.dart';
import 'package:medora/domain/entities/medication.dart';

import '../../helpers/test_database.dart';

void main() {
  setUp(setUpTestDatabase);
  tearDown(tearDownTestDatabase);

  test('add, read, update quantity and delete work with no remote datasource', () async {
    final repo = MedicationRepositoryImpl(
      localDatasource: MedicationLocalDatasource(),
      remoteDatasource: null,
    );

    final added = await repo.addMedication(const Medication(id: 'm1', name: 'Moment', quantity: 10));
    expect(added.isSuccess, isTrue);

    final list = await repo.getMedications();
    expect(list.dataOrNull?.map((m) => m.name), ['Moment']);

    final bumped = await repo.updateQuantity('m1', -3);
    expect(bumped.dataOrNull?.quantity, 7);

    final deleted = await repo.deleteMedication('m1');
    expect(deleted.isSuccess, isTrue);
    expect((await repo.getMedications()).dataOrNull, isEmpty);
  });
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `fvm flutter test test/presentation/providers/app_mode_provider_test.dart test/data/repositories/medication_repository_local_only_test.dart`
Expected: FAIL — missing `app_mode_provider.dart`; `remoteDatasource: null` not allowed (`MedicationRemoteDatasource` non-nullable).

- [ ] **Step 3: Create `lib/presentation/providers/app_mode_provider.dart`**

```dart
/// Medora - App mode (local-only vs cloud sync), persisted.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:medora/presentation/providers/settings_providers.dart';

enum AppMode { localOnly, cloud }

const _kAppMode = 'app_mode';

final appModeProvider = NotifierProvider<AppModeNotifier, AppMode>(AppModeNotifier.new);

class AppModeNotifier extends Notifier<AppMode> {
  @override
  AppMode build() {
    final prefs = ref.watch(sharedPreferencesProvider);
    return prefs.getString(_kAppMode) == AppMode.cloud.name ? AppMode.cloud : AppMode.localOnly;
  }

  Future<void> set(AppMode mode) async {
    state = mode;
    await ref.read(sharedPreferencesProvider).setString(_kAppMode, mode.name);
  }
}
```

- [ ] **Step 4: Give every remote datasource a constructor-injected client**

Apply the same edit to the five files. Shown in full for `medication_remote_datasource.dart`; the other four differ only in class name and the calls listed after.

`lib/data/datasources/medication_remote_datasource.dart` — replace the header and every `SupabaseConfig.client` with `_client`:

```dart
/// Medora - Medication Remote Datasource
///
/// Handles all Supabase interactions for medications.
library;

import 'package:medora/core/constants.dart';
import 'package:medora/data/models/medication_model.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class MedicationRemoteDatasource {
  MedicationRemoteDatasource(this._client);

  final SupabaseClient _client;

  /// Get all medications for the current user.
  Future<List<MedicationModel>> getMedications() async {
    final response = await _client
        .from(AppConstants.medicationsTable)
        .select()
        .order('name');
    // … rest of the method unchanged …
```

Mechanical rule for all five files: delete `import 'package:medora/core/supabase_config.dart';`, add `import 'package:supabase_flutter/supabase_flutter.dart';`, change the constructor to `XRemoteDatasource(this._client);` with `final SupabaseClient _client;`, and replace every `SupabaseConfig.client` with `_client`. Files and expected replacement counts:

| File | Constructor line becomes | `SupabaseConfig.client` occurrences |
|---|---|---|
| `medication_remote_datasource.dart` | `MedicationRemoteDatasource(this._client);` | 8 |
| `treatment_remote_datasource.dart` | `TreatmentRemoteDatasource(this._client);` | 8 |
| `prescription_remote_datasource.dart` | `PrescriptionRemoteDatasource(this._client);` | 10 |
| `dose_log_remote_datasource.dart` | `DoseLogRemoteDatasource(this._client);` | 7 |
| `family_remote_datasource.dart` | `FamilyRemoteDatasource(this._client);` and delete the line `final _client = SupabaseConfig.client;`, add `final SupabaseClient _client;` | 0 (already uses `_client`) |

Verify: `grep -rn "SupabaseConfig.client\b" lib/data/datasources/` prints nothing.

- [ ] **Step 5: Make repositories accept a nullable remote**

`lib/data/repositories/medication_repository_impl.dart` — change the field and the background helper:

```dart
  final MedicationLocalDatasource localDatasource;
  final MedicationRemoteDatasource? remoteDatasource;
```

```dart
  /// Fire-and-forget remote sync. No-op in local-only mode.
  void _syncInBackground(
    Future<dynamic> Function(MedicationRemoteDatasource remote) remoteFn,
    String id,
  ) {
    final remote = remoteDatasource;
    if (remote == null) return;
    if (!ConnectivityService.instance.isOnline) return;
    Future(() async {
      try {
        await remoteFn(remote);
        await localDatasource.markSynced(id);
      } catch (e) {
        debugPrint('⚠ Background sync failed for medication $id: $e');
      }
    });
  }
```

and every call site passes the remote in:

```dart
      _syncInBackground((r) => r.addMedication(model), model.id);
      _syncInBackground((r) => r.updateMedication(model), model.id);
      _syncInBackground((r) async {
        await r.deleteMedication(id);
        await localDatasource.hardDelete(id);
      }, id);
      _syncInBackground((r) => r.updateQuantity(id, delta), id);
```

Apply the identical shape to:

- `treatment_repository_impl.dart`: field `final TreatmentRemoteDatasource? remoteDatasource;`, helper signature `Future<dynamic> Function(TreatmentRemoteDatasource remote) remoteFn`, call sites `(r) => r.addTreatment(model)`, `(r) => r.updateTreatment(model)`, `(r) async { await r.deleteTreatment(id); await localDatasource.hardDelete(id); }`, `(r) => r.endTreatment(id)`.
- `prescription_repository_impl.dart`: field `final PrescriptionRemoteDatasource? remoteDatasource;`, call sites `(r) => r.addPrescription(model)`, `(r) => r.updatePrescription(model)`, `(r) async { await r.deletePrescription(id); await localDatasource.hardDelete(id); }`, `(r) => r.deactivatePrescription(id)`, `(r) => r.reactivatePrescription(id)`.
- `dose_log_repository_impl.dart`: field `final DoseLogRemoteDatasource? remoteDatasource;`; `_syncRemoteInBackground` takes `Future<dynamic> Function(DoseLogRemoteDatasource remote) remoteFn` with the same null guard; call sites `(r) => r.addDoseLog(model)`, `(r) => r.updateDoseLogStatus(id, 'taken', takenTime: now)`, `(r) => r.updateDoseLogStatus(id, 'skipped')`, `(r) => r.updateDoseLogStatus(id, 'missed')`, `(r) => r.updateDoseLogStatus(id, 'pending', takenTime: null)`. `_syncRemoteBatchInBackground` starts with `final remote = remoteDatasource; if (remote == null) return;` and calls `remote.addDoseLogsBatch(models)`.
- `family_repository_impl.dart`: field `final FamilyRemoteDatasource? remoteDatasource;`. Each `remoteDatasource.` use becomes a local `final remote = remoteDatasource;` guard:
  - `createFamily`: `if (remote != null && ConnectivityService.instance.isOnline) { try { await remote.createFamily(family); await remote.addMember(member); … } catch (_) {} }`
  - `joinFamily`, `regenerateInviteCode`: at the top, `final remote = remoteDatasource; if (remote == null) return const Result.failure('Cloud sync is required for family sharing');` then use `remote.`.
  - `leaveFamily`, `removeMember`: `if (remote != null && ConnectivityService.instance.isOnline) { try { await remote.removeMember(...); } catch (_) {} }`.

Verify: `grep -n "remoteDatasource\." lib/data/repositories/*.dart` prints nothing (all uses go through a non-null local).

- [ ] **Step 6: Make `SyncService` local-only aware**

In `lib/services/sync_service.dart` make the five remote fields nullable and add an availability guard:

```dart
  final MedicationLocalDatasource medicationLocal;
  final MedicationRemoteDatasource? medicationRemote;
  final TreatmentLocalDatasource treatmentLocal;
  final TreatmentRemoteDatasource? treatmentRemote;
  final PrescriptionLocalDatasource prescriptionLocal;
  final PrescriptionRemoteDatasource? prescriptionRemote;
  final DoseLogLocalDatasource doseLogLocal;
  final DoseLogRemoteDatasource? doseLogRemote;
  final FamilyLocalDatasource familyLocal;
  final FamilyRemoteDatasource? familyRemote;

  /// True when every remote datasource exists (cloud mode, configured build).
  bool get isAvailable =>
      medicationRemote != null &&
      treatmentRemote != null &&
      prescriptionRemote != null &&
      doseLogRemote != null &&
      familyRemote != null;
```

At the top of `syncAll`, `forcePush`, and `forcePull` add as the first statement:

```dart
    if (!isAvailable) {
      debugPrint('Sync: skipped (local-only mode)');
      return;
    }
```

Inside the private push/pull helpers, replace each `medicationRemote.` with `medicationRemote!.` (and likewise `treatmentRemote!.`, `prescriptionRemote!.`, `doseLogRemote!.`, `familyRemote!.`). These helpers are only reachable after the `isAvailable` guard.

- [ ] **Step 7: Rewrite the DI wiring in `lib/presentation/providers/providers.dart`**

Replace the "Remote Datasource Providers", "Repository Providers" and the `syncServiceProvider` sections with:

```dart
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
```

`syncServiceProvider` keeps its shape (the constructor now accepts nullables). Add imports:

```dart
import 'package:medora/core/supabase_config.dart';
import 'package:medora/data/repositories/family_repository_impl.dart';
import 'package:medora/domain/repositories/family_repository.dart';
import 'package:medora/presentation/providers/app_mode_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
```

In `lib/presentation/providers/family_providers.dart` delete the three provider declarations `familyLocalDatasourceProvider`, `familyRemoteDatasourceProvider`, `familyRepositoryProvider` and their now-unused imports (`family_local_datasource.dart`, `family_remote_datasource.dart`, `family_repository_impl.dart`, `family_repository.dart`), and add `import 'package:medora/presentation/providers/providers.dart';`.

- [ ] **Step 8: Make auth providers safe and remove guest/offline flags**

Rewrite `lib/presentation/providers/auth_providers.dart`:

```dart
/// Medora - Authentication Providers
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:medora/core/supabase_config.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Supabase auth state. Emits a single "signed out" state when the build has
/// no Supabase configuration, so watchers never see an error.
final authStateProvider = StreamProvider<AuthState>((ref) {
  final client = SupabaseConfig.clientOrNull;
  if (client == null) {
    return Stream.value(const AuthState(AuthChangeEvent.signedOut, null));
  }
  return client.auth.onAuthStateChange;
});

/// The signed-in Supabase user, or null.
final currentUserProvider = Provider<User?>((ref) {
  final authState = ref.watch(authStateProvider).value;
  return authState?.session?.user ?? SupabaseConfig.clientOrNull?.auth.currentUser;
});

/// Global provider for biometric lock state.
final isBiometricLockedProvider =
    NotifierProvider<BiometricLockNotifier, bool>(BiometricLockNotifier.new);

class BiometricLockNotifier extends Notifier<bool> {
  @override
  bool build() => true;

  void setLocked(bool locked) => state = locked;
}

/// Auth actions (cloud mode only).
final authControllerProvider =
    NotifierProvider<AuthController, AsyncValue<void>>(AuthController.new);

class AuthController extends Notifier<AsyncValue<void>> {
  @override
  AsyncValue<void> build() => const AsyncData(null);

  Future<void> signInWithEmail(String email, String password) async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      await SupabaseConfig.requireClient().auth.signInWithPassword(
        email: email,
        password: password,
      );
    });
  }

  Future<void> signUpWithEmail(String email, String password) async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      await SupabaseConfig.requireClient().auth.signUp(
        email: email,
        password: password,
      );
    });
  }

  Future<void> signOut() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      await SupabaseConfig.clientOrNull?.auth.signOut();
    });
  }
}
```

- [ ] **Step 9: Fix the remaining compile errors from removed symbols**

Run `fvm flutter analyze` and fix each reported use:

- `lib/presentation/router/app_router.dart`: remove `isOfflineModeProvider` usage — replace `final isOffline = ref.watch(isOfflineModeProvider);` with `final isOffline = ref.watch(appModeProvider) == AppMode.localOnly;` and add `import 'package:medora/presentation/providers/app_mode_provider.dart';`. (Task 5 replaces this guard entirely.)
- `lib/presentation/screens/auth/auth_screen.dart`: delete the `OutlinedButton` calling `signInAnonymously` and the `TextButton.icon` calling `enterOfflineMode`; replace the latter with `TextButton.icon(onPressed: () => ref.read(appModeProvider.notifier).set(AppMode.localOnly), icon: const Icon(Icons.cloud_off), label: Text(l10n.useOfflineMode))` and import `app_mode_provider.dart`. (Task 5 redesigns this screen.)
- `lib/presentation/widgets/sync_icon_button.dart`: at the top of `build`, `if (ref.watch(appModeProvider) != AppMode.cloud) return const SizedBox.shrink();` with the import.
- `lib/presentation/screens/settings/settings_screen.dart`: the delete-all handler uses `SupabaseConfig.client` — change to `final client = SupabaseConfig.clientOrNull; if (client != null && SupabaseConfig.isAuthenticated) { … }`.
- Any `kIsWeb` logout `IconButton` in `home_screen.dart`, `medication_list_screen.dart`, `treatment_list_screen.dart`, `dose_schedule_screen.dart`: change the condition to `if (kIsWeb && ref.watch(appModeProvider) == AppMode.cloud)` and add the import.

Run: `fvm flutter analyze`
Expected: `No issues found!`

- [ ] **Step 10: Run all tests**

Run: `fvm flutter test`
Expected: `All tests passed!` (app_config 3, app_database 4, prescription 10, app_mode 4, medication repo 1, widget placeholder 1).

- [ ] **Step 11: Commit**

```bash
git add -A lib test
git commit -m "feat(core): add AppMode and make the remote layer optional

Remote datasources take a SupabaseClient by constructor and are null in
local-only mode or unconfigured builds. Repositories and SyncService skip
network work when no remote exists. Guest sign-in and the in-memory offline
flag are removed in favor of a persisted AppMode.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01BAjdzp9JhksW2XbhM6CPBS"
```

---
### Task 5: Router redirect, single `BiometricGate`, local-first Auth screen, Cloud-sync settings

**Files:**
- Create: `lib/presentation/widgets/biometric_gate.dart`
- Modify: `lib/presentation/router/app_router.dart` (full rewrite)
- Modify: `lib/main.dart` (`MedoraApp.build`)
- Modify: `lib/presentation/screens/auth/auth_screen.dart` (full rewrite)
- Modify: `lib/presentation/screens/settings/settings_screen.dart` (Account + new Cloud sync section)
- Modify: `lib/presentation/screens/family/family_screen.dart` (local-only empty state)
- Modify: `lib/l10n/app_en.arb`, `app_de.arb`, `app_it.arb` (+ regenerate)
- Test: `test/presentation/router/app_router_redirect_test.dart`, `test/presentation/screens/auth_screen_test.dart`

**Interfaces:**
- Produces:
  ```dart
  final appRouterProvider = Provider<GoRouter>;
  String? computeRedirect({required AppMode mode, required bool hasSession, required String location});  // pure, tested
  class BiometricGate extends ConsumerStatefulWidget { const BiometricGate({required this.child}); }
  ```
- Consumes: `appModeProvider`, `authStateProvider`, `isBiometricLockedProvider`, `biometricsEnabledProvider`, `SecurityService`.

- [ ] **Step 1: Add localization keys**

Append to `lib/l10n/app_en.arb` (before the final `}`; keep valid JSON — add a comma to the previous last entry):

```json
  "useOnThisDevice": "Use Medora on this device",
  "useOnThisDeviceDesc": "Your data stays on this device. You can turn on cloud sync later in Settings.",
  "orSignInForCloud": "Or sign in to sync across devices",
  "cloudSync": "Cloud sync",
  "cloudSyncOn": "On — signed in as {email}",
  "@cloudSyncOn": { "placeholders": { "email": { "type": "String" } } },
  "cloudSyncOff": "Off — data is stored only on this device",
  "cloudSyncUnavailable": "Unavailable — this build has no cloud configuration",
  "turnOnCloudSync": "Turn on cloud sync",
  "turnOffCloudSync": "Turn off cloud sync",
  "turnOffCloudSyncConfirm": "You will be signed out. Your data stays on this device.",
  "localOnlyMode": "Local only",
  "unlockMedora": "Unlock Medora",
  "cloudRequiredForFamily": "Family sharing needs cloud sync. Turn it on in Settings.",
  "invalidEmail": "Enter a valid email address",
  "passwordTooShort": "Password must be at least 6 characters",
  "turnOn": "Turn on",
  "turnOff": "Turn off"
```

Append to `lib/l10n/app_de.arb`:

```json
  "useOnThisDevice": "Medora auf diesem Gerät verwenden",
  "useOnThisDeviceDesc": "Deine Daten bleiben auf diesem Gerät. Cloud-Sync kannst du später in den Einstellungen aktivieren.",
  "orSignInForCloud": "Oder anmelden, um geräteübergreifend zu synchronisieren",
  "cloudSync": "Cloud-Synchronisierung",
  "cloudSyncOn": "An — angemeldet als {email}",
  "@cloudSyncOn": { "placeholders": { "email": { "type": "String" } } },
  "cloudSyncOff": "Aus — Daten werden nur auf diesem Gerät gespeichert",
  "cloudSyncUnavailable": "Nicht verfügbar — dieser Build hat keine Cloud-Konfiguration",
  "turnOnCloudSync": "Cloud-Sync einschalten",
  "turnOffCloudSync": "Cloud-Sync ausschalten",
  "turnOffCloudSyncConfirm": "Du wirst abgemeldet. Deine Daten bleiben auf diesem Gerät.",
  "localOnlyMode": "Nur lokal",
  "unlockMedora": "Medora entsperren",
  "cloudRequiredForFamily": "Familienfreigabe benötigt Cloud-Sync. Aktiviere ihn in den Einstellungen.",
  "invalidEmail": "Gib eine gültige E-Mail-Adresse ein",
  "passwordTooShort": "Das Passwort muss mindestens 6 Zeichen haben",
  "turnOn": "Einschalten",
  "turnOff": "Ausschalten"
```

Append to `lib/l10n/app_it.arb`:

```json
  "useOnThisDevice": "Usa Medora su questo dispositivo",
  "useOnThisDeviceDesc": "I tuoi dati restano su questo dispositivo. Potrai attivare la sincronizzazione cloud dalle Impostazioni.",
  "orSignInForCloud": "Oppure accedi per sincronizzare tra dispositivi",
  "cloudSync": "Sincronizzazione cloud",
  "cloudSyncOn": "Attiva — accesso come {email}",
  "@cloudSyncOn": { "placeholders": { "email": { "type": "String" } } },
  "cloudSyncOff": "Disattiva — i dati sono salvati solo su questo dispositivo",
  "cloudSyncUnavailable": "Non disponibile — questa build non ha una configurazione cloud",
  "turnOnCloudSync": "Attiva sincronizzazione cloud",
  "turnOffCloudSync": "Disattiva sincronizzazione cloud",
  "turnOffCloudSyncConfirm": "Verrai disconnesso. I tuoi dati restano su questo dispositivo.",
  "localOnlyMode": "Solo locale",
  "unlockMedora": "Sblocca Medora",
  "cloudRequiredForFamily": "La condivisione familiare richiede la sincronizzazione cloud. Attivala nelle Impostazioni.",
  "invalidEmail": "Inserisci un indirizzo email valido",
  "passwordTooShort": "La password deve avere almeno 6 caratteri",
  "turnOn": "Attiva",
  "turnOff": "Disattiva"
```

Remove the keys `continueAsGuest` and `useOfflineMode` from all three ARB files.

Run: `fvm flutter gen-l10n`
Expected: no output; `lib/l10n/generated/app_localizations.dart` now declares `useOnThisDevice`, `cloudSyncOn(String email)`, etc. `untranslated.txt` is empty (`{}`).

- [ ] **Step 2: Write the failing redirect test**

`test/presentation/router/app_router_redirect_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/presentation/providers/app_mode_provider.dart';
import 'package:medora/presentation/router/app_router.dart';

void main() {
  group('computeRedirect', () {
    test('local-only never goes to /auth and leaves /auth for home', () {
      expect(computeRedirect(mode: AppMode.localOnly, hasSession: false, location: '/'), isNull);
      expect(computeRedirect(mode: AppMode.localOnly, hasSession: false, location: '/medications/add'), isNull);
      expect(computeRedirect(mode: AppMode.localOnly, hasSession: false, location: '/auth'), '/');
    });

    test('cloud without session goes to /auth', () {
      expect(computeRedirect(mode: AppMode.cloud, hasSession: false, location: '/'), '/auth');
      expect(computeRedirect(mode: AppMode.cloud, hasSession: false, location: '/settings'), '/auth');
      expect(computeRedirect(mode: AppMode.cloud, hasSession: false, location: '/auth'), isNull);
    });

    test('cloud with session stays, and leaves /auth for home', () {
      expect(computeRedirect(mode: AppMode.cloud, hasSession: true, location: '/doses'), isNull);
      expect(computeRedirect(mode: AppMode.cloud, hasSession: true, location: '/auth'), '/');
    });
  });
}
```

Run: `fvm flutter test test/presentation/router/app_router_redirect_test.dart`
Expected: FAIL — `computeRedirect` undefined.

- [ ] **Step 3: Create `lib/presentation/widgets/biometric_gate.dart`**

```dart
/// Medora - Biometric lock overlay.
///
/// Mounted once (ShellRoute) so exactly one lifecycle observer exists.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/presentation/providers/auth_providers.dart';
import 'package:medora/presentation/providers/settings_providers.dart';
import 'package:medora/services/security_service.dart';

class BiometricGate extends ConsumerStatefulWidget {
  const BiometricGate({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<BiometricGate> createState() => _BiometricGateState();
}

class _BiometricGateState extends ConsumerState<BiometricGate>
    with WidgetsBindingObserver {
  bool _isAuthenticating = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkBiometrics());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!ref.read(biometricsEnabledProvider)) return;
    if (state == AppLifecycleState.paused) {
      ref.read(isBiometricLockedProvider.notifier).setLocked(true);
    } else if (state == AppLifecycleState.resumed) {
      _checkBiometrics();
    }
  }

  Future<void> _checkBiometrics() async {
    final lock = ref.read(isBiometricLockedProvider.notifier);
    if (!ref.read(biometricsEnabledProvider)) {
      lock.setLocked(false);
      return;
    }
    if (!ref.read(isBiometricLockedProvider) || _isAuthenticating) return;

    _isAuthenticating = true;
    try {
      if (!await SecurityService.instance.canAuthenticate()) {
        if (mounted) lock.setLocked(false);
        return;
      }
      final ok = await SecurityService.instance.authenticate();
      if (ok && mounted) lock.setLocked(false);
    } finally {
      _isAuthenticating = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final locked = ref.watch(isBiometricLockedProvider) && ref.watch(biometricsEnabledProvider);
    if (!locked) return widget.child;

    final l10n = AppLocalizations.of(context);
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Image.asset(
              'assets/icon/medora_icon.png',
              height: 120,
              errorBuilder: (_, __, ___) => Icon(Icons.lock_outline, size: 80, color: Theme.of(context).colorScheme.primary),
            ),
            const SizedBox(height: 32),
            FilledButton.icon(
              onPressed: _checkBiometrics,
              icon: const Icon(Icons.fingerprint),
              label: Text(l10n.unlockMedora),
            ),
          ],
        ),
      ),
    );
  }
}
```

- [ ] **Step 4: Rewrite `lib/presentation/router/app_router.dart`**

```dart
/// Medora - App Router Configuration
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:medora/core/supabase_config.dart';
import 'package:medora/presentation/providers/app_mode_provider.dart';
import 'package:medora/presentation/providers/auth_providers.dart';
import 'package:medora/presentation/screens/auth/auth_screen.dart';
import 'package:medora/presentation/screens/dose/dose_history_screen.dart';
import 'package:medora/presentation/screens/export/export_screen.dart';
import 'package:medora/presentation/screens/family/family_screen.dart';
import 'package:medora/presentation/screens/main_shell_screen.dart';
import 'package:medora/presentation/screens/medication/add_medication_screen.dart';
import 'package:medora/presentation/screens/medication/medication_detail_screen.dart';
import 'package:medora/presentation/screens/scanner/barcode_scanner_screen.dart';
import 'package:medora/presentation/screens/settings/settings_screen.dart';
import 'package:medora/presentation/screens/treatment/add_treatment_screen.dart';
import 'package:medora/presentation/screens/treatment/treatment_detail_screen.dart';
import 'package:medora/presentation/widgets/biometric_gate.dart';

/// Route paths as constants.
class AppRoutes {
  AppRoutes._();

  static const home = '/';
  static const auth = '/auth';
  static const medications = '/medications';
  static const medicationDetail = '/medications/:id';
  static const addMedication = '/medications/add';
  static const editMedication = '/medications/:id/edit';
  static const treatments = '/treatments';
  static const treatmentDetail = '/treatments/:id';
  static const addTreatment = '/treatments/add';
  static const editTreatment = '/treatments/:id/edit';
  static const doses = '/doses';
  static const doseHistory = '/doses/history';
  static const scanner = '/scanner';
  static const settings = '/settings';
  static const family = '/family';
  static const export = '/export';
}

/// Pure redirect rule (unit-tested).
/// Returns the location to go to, or null to stay.
String? computeRedirect({
  required AppMode mode,
  required bool hasSession,
  required String location,
}) {
  final onAuth = location == AppRoutes.auth;
  if (mode == AppMode.localOnly) return onAuth ? AppRoutes.home : null;
  if (!hasSession) return onAuth ? null : AppRoutes.auth;
  return onAuth ? AppRoutes.home : null;
}

/// Notifies GoRouter when app mode or auth session changes.
class _RouterRefresh extends ChangeNotifier {
  _RouterRefresh(Ref ref) {
    ref.listen(appModeProvider, (_, __) => notifyListeners());
    ref.listen(authStateProvider, (_, __) => notifyListeners());
  }
}

final appRouterProvider = Provider<GoRouter>((ref) {
  final refresh = _RouterRefresh(ref);
  ref.onDispose(refresh.dispose);

  return GoRouter(
    initialLocation: AppRoutes.home,
    refreshListenable: refresh,
    redirect: (context, state) {
      final mode = ref.read(appModeProvider);
      final hasSession = ref.read(authStateProvider).value?.session != null ||
          SupabaseConfig.isAuthenticated;
      return computeRedirect(
        mode: mode,
        hasSession: hasSession,
        location: state.matchedLocation,
      );
    },
    routes: [
      GoRoute(
        path: AppRoutes.auth,
        builder: (context, state) => const AuthScreen(),
      ),
      ShellRoute(
        builder: (context, state, child) => BiometricGate(child: child),
        routes: [
          GoRoute(path: AppRoutes.home, builder: (_, __) => const MainShellScreen(initialIndex: 0)),
          GoRoute(path: AppRoutes.medications, builder: (_, __) => const MainShellScreen(initialIndex: 1)),
          GoRoute(path: AppRoutes.treatments, builder: (_, __) => const MainShellScreen(initialIndex: 2)),
          GoRoute(path: AppRoutes.doses, builder: (_, __) => const MainShellScreen(initialIndex: 3)),
          GoRoute(
            path: AppRoutes.addMedication,
            builder: (_, state) => AddMedicationScreen(
              initialBarcode: state.uri.queryParameters['barcode'],
              lookupResult: state.extra,
            ),
          ),
          GoRoute(
            path: AppRoutes.editMedication,
            builder: (_, state) => AddMedicationScreen(medicationId: state.pathParameters['id']),
          ),
          GoRoute(
            path: AppRoutes.medicationDetail,
            builder: (_, state) => MedicationDetailScreen(medicationId: state.pathParameters['id']!),
          ),
          GoRoute(path: AppRoutes.addTreatment, builder: (_, __) => const AddTreatmentScreen()),
          GoRoute(
            path: AppRoutes.editTreatment,
            builder: (_, state) => AddTreatmentScreen(treatmentId: state.pathParameters['id']),
          ),
          GoRoute(
            path: AppRoutes.treatmentDetail,
            builder: (_, state) => TreatmentDetailScreen(treatmentId: state.pathParameters['id']!),
          ),
          GoRoute(path: AppRoutes.doseHistory, builder: (_, __) => const DoseHistoryScreen()),
          GoRoute(
            path: AppRoutes.scanner,
            builder: (_, state) => BarcodeScannerScreen(
              returnBarcodeOnly: state.uri.queryParameters['returnOnly'] == 'true',
            ),
          ),
          GoRoute(path: AppRoutes.settings, builder: (_, __) => const SettingsScreen()),
          GoRoute(path: AppRoutes.family, builder: (_, __) => const FamilyScreen()),
          GoRoute(path: AppRoutes.export, builder: (_, __) => const ExportScreen()),
        ],
      ),
    ],
  );
});
```

Route ordering note: go_router matches `/medications/add` before `/medications/:id` only if `add` is declared first — the order above preserves the original file's order.

In `lib/main.dart` `MedoraApp.build`, replace `routerConfig: appRouter,` with `routerConfig: ref.watch(appRouterProvider),`.

- [ ] **Step 5: Rewrite `lib/presentation/screens/auth/auth_screen.dart`**

```dart
/// Medora - Auth screen.
///
/// Primary path: use the app locally with no account.
/// Secondary path: sign in / sign up for cloud sync (only when the build is configured).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:medora/core/supabase_config.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/presentation/providers/app_mode_provider.dart';
import 'package:medora/presentation/providers/auth_providers.dart';

class AuthScreen extends ConsumerStatefulWidget {
  const AuthScreen({super.key});

  @override
  ConsumerState<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends ConsumerState<AuthScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _isSignUp = false;
  bool _obscurePassword = true;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    final email = _emailController.text.trim();
    final password = _passwordController.text;
    final auth = ref.read(authControllerProvider.notifier);
    if (_isSignUp) {
      await auth.signUpWithEmail(email, password);
    } else {
      await auth.signInWithEmail(email, password);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final authState = ref.watch(authControllerProvider);
    final cloudAvailable = SupabaseConfig.isConfigured;

    ref.listen(authControllerProvider, (previous, next) {
      if (next is AsyncError) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(next.error.toString())),
        );
      }
    });

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Image.asset(
                      'assets/icon/medora_icon_pill.png',
                      height: 160,
                      errorBuilder: (_, __, ___) => Icon(Icons.medication, size: 80, color: theme.colorScheme.primary),
                    ),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    l10n.appTitle,
                    style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.bold),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 32),

                  // ── Primary: local-only ──
                  FilledButton.icon(
                    onPressed: () => ref.read(appModeProvider.notifier).set(AppMode.localOnly),
                    icon: const Icon(Icons.phone_android),
                    label: Text(l10n.useOnThisDevice),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    l10n.useOnThisDeviceDesc,
                    style: theme.textTheme.bodySmall,
                    textAlign: TextAlign.center,
                  ),

                  // ── Secondary: cloud ──
                  if (cloudAvailable) ...[
                    const SizedBox(height: 24),
                    Row(
                      children: [
                        const Expanded(child: Divider()),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: Text(l10n.orSignInForCloud, style: theme.textTheme.bodySmall),
                        ),
                        const Expanded(child: Divider()),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Form(
                      key: _formKey,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          TextFormField(
                            controller: _emailController,
                            decoration: InputDecoration(labelText: l10n.email, prefixIcon: const Icon(Icons.email)),
                            keyboardType: TextInputType.emailAddress,
                            autofillHints: const [AutofillHints.email],
                            validator: (v) => (v == null || !v.contains('@')) ? l10n.invalidEmail : null,
                          ),
                          const SizedBox(height: 16),
                          TextFormField(
                            controller: _passwordController,
                            decoration: InputDecoration(
                              labelText: l10n.password,
                              prefixIcon: const Icon(Icons.lock),
                              suffixIcon: IconButton(
                                icon: Icon(_obscurePassword ? Icons.visibility : Icons.visibility_off),
                                onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                              ),
                            ),
                            obscureText: _obscurePassword,
                            autofillHints: const [AutofillHints.password],
                            validator: (v) => (v == null || v.length < 6) ? l10n.passwordTooShort : null,
                          ),
                          const SizedBox(height: 16),
                          OutlinedButton(
                            onPressed: authState.isLoading ? null : _submit,
                            child: authState.isLoading
                                ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                                : Text(_isSignUp ? l10n.signUp : l10n.signIn),
                          ),
                          TextButton(
                            onPressed: () => setState(() => _isSignUp = !_isSignUp),
                            child: Text(_isSignUp ? l10n.alreadyHaveAccount : l10n.dontHaveAccount),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
```

Note: choosing "Use on this device" sets `AppMode.localOnly`; the router redirect then leaves `/auth`. A successful sign-in emits an auth state change; the redirect leaves `/auth` as well. The screen only appears when mode is `cloud`, so `set(AppMode.localOnly)` is the "back to local" action.

- [ ] **Step 6: Settings — replace the Account section with a Cloud sync section**

In `lib/presentation/screens/settings/settings_screen.dart`, add imports:

```dart
import 'package:medora/core/supabase_config.dart';   // already present
import 'package:medora/presentation/providers/app_mode_provider.dart';
```

Add to `build` after `final user = ref.watch(currentUserProvider);`:

```dart
    final appMode = ref.watch(appModeProvider);
    final cloudAvailable = SupabaseConfig.isConfigured;
```

Replace the `// ── Account ──` block (from `_SectionTitle(user?.isAnonymous …` through the following `const Divider(),`) with:

```dart
          // ── Cloud sync ─────────────────────────────────────
          _SectionTitle(l10n.cloudSync),
          ListTile(
            leading: Icon(
              !cloudAvailable
                  ? Icons.cloud_off
                  : appMode == AppMode.cloud ? Icons.cloud_done : Icons.phone_android,
            ),
            title: Text(
              !cloudAvailable
                  ? l10n.cloudSyncUnavailable
                  : appMode == AppMode.cloud
                      ? l10n.cloudSyncOn(user?.email ?? '')
                      : l10n.cloudSyncOff,
            ),
            trailing: !cloudAvailable
                ? null
                : appMode == AppMode.cloud
                    ? TextButton(
                        onPressed: () => _confirmTurnOffCloud(context, ref, l10n),
                        child: Text(l10n.turnOff),
                      )
                    : FilledButton.tonal(
                        onPressed: () => ref.read(appModeProvider.notifier).set(AppMode.cloud),
                        child: Text(l10n.turnOn),
                      ),
          ),
          const Divider(),
```

Add the helper method to `SettingsScreen`:

```dart
  Future<void> _confirmTurnOffCloud(BuildContext context, WidgetRef ref, AppLocalizations l10n) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.turnOffCloudSync),
        content: Text(l10n.turnOffCloudSyncConfirm),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(l10n.cancel)),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(l10n.turnOff)),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(appModeProvider.notifier).set(AppMode.localOnly);
    await ref.read(authControllerProvider.notifier).signOut();
  }
```

Wrap the whole `// ── Data & Sync ──` section (status tile, Sync Now tile, Force Push/Pull row, and its trailing `Divider`) in `if (appMode == AppMode.cloud) ...[ … ],` so it is hidden in local-only mode. Likewise wrap the `familySharing` `ListTile` under `// ── Features ──` in `if (appMode == AppMode.cloud)`.

- [ ] **Step 7: Family screen — local-only empty state**

In `lib/presentation/screens/family/family_screen.dart` `FamilyScreen.build`, before `final familyAsync = …`:

```dart
    if (ref.watch(appModeProvider) != AppMode.cloud) {
      return Scaffold(
        appBar: AppBar(title: Text(l10n.familySharingTitle)),
        body: EmptyStateWidget(
          icon: Icons.cloud_off,
          title: l10n.cloudRequiredForFamily,
        ),
      );
    }
```

Add `import 'package:medora/presentation/providers/app_mode_provider.dart';`.

- [ ] **Step 8: Write the Auth screen widget test**

`test/presentation/screens/auth_screen_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/presentation/providers/app_mode_provider.dart';
import 'package:medora/presentation/providers/settings_providers.dart';
import 'package:medora/presentation/screens/auth/auth_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('unconfigured build shows only the local-only path and selecting it sets AppMode.localOnly',
      (tester) async {
    SharedPreferences.setMockInitialValues({'app_mode': 'cloud'});
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: AuthScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(container.read(appModeProvider), AppMode.cloud);
    expect(find.text('Use Medora on this device'), findsOneWidget);
    expect(find.byType(TextFormField), findsNothing); // no cloud form without config

    await tester.tap(find.text('Use Medora on this device'));
    await tester.pumpAndSettle();

    expect(container.read(appModeProvider), AppMode.localOnly);
    expect(prefs.getString('app_mode'), 'localOnly');
  });
}
```

Replace `test/widget_test.dart` placeholder: delete the file (`git rm test/widget_test.dart`).

- [ ] **Step 9: Analyze and test**

Run: `fvm flutter analyze`
Expected: `No issues found!` (remove any now-unused imports the analyzer reports, e.g. `medora/presentation/providers/auth_providers.dart` in screens that no longer sign out).

Run: `fvm flutter test`
Expected: `All tests passed!`

- [ ] **Step 10: Manual smoke run (Linux desktop)**

Run: `fvm flutter run -d linux`
Expected: app opens directly on the Dashboard (no auth screen), no red error, adding a medication works and survives a restart. Run once more with `--dart-define=SUPABASE_URL=https://example.supabase.co --dart-define=SUPABASE_ANON_KEY=x`: Settings shows "Cloud sync: Off" with a "Turn on" button; tapping it shows the Auth screen with the sign-in form; "Use Medora on this device" returns to the Dashboard.

- [ ] **Step 11: Commit**

```bash
git add -A lib test
git commit -m "feat(auth): local-first auth flow with router redirect and single biometric gate

Auth is decided by one GoRouter redirect from AppMode + session.
BiometricGate lives in a ShellRoute so only one lifecycle observer exists.
Auth screen leads with 'Use Medora on this device'; Settings gains a
Cloud sync section; family sharing is hidden in local-only mode.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01BAjdzp9JhksW2XbhM6CPBS"
```

---
### Task 6: Bundle Inter, remove `google_fonts`

**Files:**
- Create: `assets/fonts/Inter-Regular.ttf`, `Inter-Medium.ttf`, `Inter-SemiBold.ttf`, `Inter-Bold.ttf`, `assets/fonts/OFL.txt`
- Modify: `pubspec.yaml` (remove `google_fonts`, add `fonts:`)
- Modify: `lib/core/theme.dart`
- Test: `test/core/theme_test.dart`

**Interfaces:**
- Produces: `AppTheme.lightThemeFrom(Color)` / `darkThemeFrom(Color)` unchanged in signature; `ThemeData.textTheme.bodyMedium!.fontFamily == 'Inter'`.

- [ ] **Step 1: Write the failing test**

`test/core/theme_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/core/theme.dart';

void main() {
  test('themes use the bundled Inter family (no runtime font download)', () {
    final light = AppTheme.lightThemeFrom(Colors.teal);
    final dark = AppTheme.darkThemeFrom(Colors.teal);
    expect(light.textTheme.bodyMedium?.fontFamily, 'Inter');
    expect(dark.textTheme.bodyMedium?.fontFamily, 'Inter');
    expect(light.useMaterial3, isTrue);
  });
}
```

Run: `fvm flutter test test/core/theme_test.dart`
Expected: FAIL — `fontFamily` is `'Inter_regular'`/null-ish from `GoogleFonts`, not `'Inter'`.

- [ ] **Step 2: Download the font files**

```bash
cd /tmp && curl -L -o inter.zip https://github.com/rsms/inter/releases/download/v4.1/Inter-4.1.zip && unzip -o -q inter.zip -d inter
mkdir -p /home/ben/repo/medora/assets/fonts
cp inter/extras/ttf/Inter-Regular.ttf inter/extras/ttf/Inter-Medium.ttf inter/extras/ttf/Inter-SemiBold.ttf inter/extras/ttf/Inter-Bold.ttf /home/ben/repo/medora/assets/fonts/
cp inter/LICENSE.txt /home/ben/repo/medora/assets/fonts/OFL.txt
ls -la /home/ben/repo/medora/assets/fonts
```

Expected: four `.ttf` files (roughly 300–400 KB each) and `OFL.txt`. If the release layout differs, the static TTFs are the files named `Inter-<Weight>.ttf` (not `InterDisplay-*`, not `InterVariable*`).

- [ ] **Step 3: Update `pubspec.yaml`**

Remove `  google_fonts: ^8.0.2`. Under `flutter:` add after `assets:`:

```yaml
  fonts:
    - family: Inter
      fonts:
        - asset: assets/fonts/Inter-Regular.ttf
          weight: 400
        - asset: assets/fonts/Inter-Medium.ttf
          weight: 500
        - asset: assets/fonts/Inter-SemiBold.ttf
          weight: 600
        - asset: assets/fonts/Inter-Bold.ttf
          weight: 700
```

- [ ] **Step 4: Update `lib/core/theme.dart`**

Remove `import 'package:google_fonts/google_fonts.dart';`. In `lightThemeFrom` replace `final textTheme = GoogleFonts.interTextTheme();` with:

```dart
    final textTheme = Typography.material2021(platform: TargetPlatform.android)
        .black
        .apply(fontFamily: 'Inter');
```

In `darkThemeFrom` replace `final textTheme = GoogleFonts.interTextTheme(ThemeData.dark().textTheme);` with:

```dart
    final textTheme = Typography.material2021(platform: TargetPlatform.android)
        .white
        .apply(fontFamily: 'Inter');
```

Add `fontFamily: 'Inter',` as a top-level `ThemeData` argument in both builders (right after `useMaterial3: true,`) so widgets that build their own `TextStyle` also get Inter.

- [ ] **Step 5: Verify**

Run: `fvm flutter pub get && fvm flutter analyze && fvm flutter test test/core/theme_test.dart`
Expected: `No issues found!` and `All tests passed!`.

Run: `grep -rn "google_fonts\|GoogleFonts" lib pubspec.yaml`
Expected: no output.

- [ ] **Step 6: Commit**

```bash
git add assets/fonts pubspec.yaml pubspec.lock lib/core/theme.dart test/core/theme_test.dart
git commit -m "feat(theme): bundle Inter and drop google_fonts runtime download

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01BAjdzp9JhksW2XbhM6CPBS"
```

---

### Task 7: Platform capabilities, web-safe screens, iOS usage strings, web manifest

**Files:**
- Create: `lib/core/platform_capabilities.dart`
- Modify: `lib/presentation/screens/home/home_screen.dart` (scanner button)
- Modify: `lib/presentation/screens/medication/add_medication_screen.dart` (scanner buttons, photo section)
- Modify: `lib/presentation/screens/medication/medication_detail_screen.dart` (photo on web)
- Modify: `lib/presentation/screens/settings/settings_screen.dart` (biometrics tile)
- Modify: `ios/Runner/Info.plist`
- Modify: `web/manifest.json`, `web/index.html` (`<title>`)
- Test: `test/core/platform_capabilities_test.dart`

**Interfaces:**
- Produces:
  ```dart
  class PlatformCapabilities {
    const PlatformCapabilities({required this.hasCamera, required this.hasLocalNotifications, required this.hasFileShare, required this.hasBiometrics});
    factory PlatformCapabilities.detect();   // kIsWeb / Platform checks
    static const web = PlatformCapabilities(hasCamera: false, hasLocalNotifications: false, hasFileShare: false, hasBiometrics: false);
    static const mobile = PlatformCapabilities(hasCamera: true, hasLocalNotifications: true, hasFileShare: true, hasBiometrics: true);
    static const desktop = PlatformCapabilities(hasCamera: false, hasLocalNotifications: false, hasFileShare: true, hasBiometrics: false);
  }
  final platformCapabilitiesProvider = Provider<PlatformCapabilities>;   // override in tests
  ```

- [ ] **Step 1: Write the failing test**

`test/core/platform_capabilities_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/core/platform_capabilities.dart';

void main() {
  test('presets are internally consistent', () {
    expect(PlatformCapabilities.web.hasCamera, isFalse);
    expect(PlatformCapabilities.web.hasFileShare, isFalse);
    expect(PlatformCapabilities.mobile.hasCamera, isTrue);
    expect(PlatformCapabilities.mobile.hasLocalNotifications, isTrue);
    expect(PlatformCapabilities.desktop.hasCamera, isFalse);
    expect(PlatformCapabilities.desktop.hasFileShare, isTrue);
  });

  test('detect() on the test host (Linux) yields the desktop preset', () {
    expect(PlatformCapabilities.detect(), PlatformCapabilities.desktop);
  });
}
```

Run: `fvm flutter test test/core/platform_capabilities_test.dart`
Expected: FAIL — file missing.

- [ ] **Step 2: Create `lib/core/platform_capabilities.dart`**

```dart
/// Medora - Platform capability flags.
///
/// Screens read these instead of sprinkling `kIsWeb` / `Platform.isX` checks.
library;

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show immutable, kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';

@immutable
class PlatformCapabilities {
  const PlatformCapabilities({
    required this.hasCamera,
    required this.hasLocalNotifications,
    required this.hasFileShare,
    required this.hasBiometrics,
  });

  /// Camera + ML Kit OCR (mobile only).
  final bool hasCamera;

  /// Scheduled local notifications (mobile only; desktop plugins cannot schedule).
  final bool hasLocalNotifications;

  /// share_plus with files (everything except web).
  final bool hasFileShare;

  /// local_auth biometrics.
  final bool hasBiometrics;

  static const web = PlatformCapabilities(
    hasCamera: false, hasLocalNotifications: false, hasFileShare: false, hasBiometrics: false,
  );
  static const mobile = PlatformCapabilities(
    hasCamera: true, hasLocalNotifications: true, hasFileShare: true, hasBiometrics: true,
  );
  static const desktop = PlatformCapabilities(
    hasCamera: false, hasLocalNotifications: false, hasFileShare: true, hasBiometrics: false,
  );

  factory PlatformCapabilities.detect() {
    if (kIsWeb) return web;
    if (Platform.isAndroid || Platform.isIOS) return mobile;
    return desktop;
  }

  @override
  bool operator ==(Object other) =>
      other is PlatformCapabilities &&
      other.hasCamera == hasCamera &&
      other.hasLocalNotifications == hasLocalNotifications &&
      other.hasFileShare == hasFileShare &&
      other.hasBiometrics == hasBiometrics;

  @override
  int get hashCode => Object.hash(hasCamera, hasLocalNotifications, hasFileShare, hasBiometrics);
}

final platformCapabilitiesProvider =
    Provider<PlatformCapabilities>((ref) => PlatformCapabilities.detect());
```

- [ ] **Step 3: Gate screens**

- `home_screen.dart` `HomeScreen.build`: `final caps = ref.watch(platformCapabilitiesProvider);` and wrap the scanner `IconButton` in `if (caps.hasCamera)`.
- `add_medication_screen.dart`: in `build`, `final caps = ref.watch(platformCapabilitiesProvider);`. Wrap the AppBar `qr_code_scanner` `IconButton` and the barcode-field suffix scanner `IconButton` in `if (caps.hasCamera)`. Replace `_buildPhotoSection(l10n)` + following `SizedBox` with `if (!kIsWeb) ...[ _buildPhotoSection(l10n), const SizedBox(height: 16) ],`.
- `medication_detail_screen.dart`: change `if (med.imagePath != null && File(med.imagePath!).existsSync()) ...[` to `if (!kIsWeb && med.imagePath != null && File(med.imagePath!).existsSync()) ...[` and add `import 'package:flutter/foundation.dart' show kIsWeb;`.
- `settings_screen.dart`: wrap the `// ── Security ──` section (`_SectionTitle("Security")`, the `SwitchListTile`, its `Divider`) in `if (ref.watch(platformCapabilitiesProvider).hasBiometrics) ...[ … ],`.

Add `import 'package:medora/core/platform_capabilities.dart';` to each modified screen.

- [ ] **Step 4: iOS usage strings**

In `ios/Runner/Info.plist`, inside the top-level `<dict>` (e.g. right after the `CADisableMinimumFrameDurationOnPhone` pair), add:

```xml
	<key>NSCameraUsageDescription</key>
	<string>Medora uses the camera to read the AIC code printed on medication packages.</string>
	<key>NSPhotoLibraryUsageDescription</key>
	<string>Medora lets you attach a photo of a medication package from your library.</string>
	<key>NSFaceIDUsageDescription</key>
	<string>Medora can lock your medicine cabinet behind Face ID.</string>
```

- [ ] **Step 5: Web manifest and title**

Replace `web/manifest.json` with:

```json
{
    "name": "Medora",
    "short_name": "Medora",
    "start_url": ".",
    "display": "standalone",
    "background_color": "#FFFFFF",
    "theme_color": "#2E7D6F",
    "description": "Home medicine cabinet manager: inventory, expiry alerts, treatments and dose tracking.",
    "orientation": "portrait-primary",
    "prefer_related_applications": false,
    "icons": [
        { "src": "icons/Icon-192.png", "sizes": "192x192", "type": "image/png" },
        { "src": "icons/Icon-512.png", "sizes": "512x512", "type": "image/png" },
        { "src": "icons/Icon-maskable-192.png", "sizes": "192x192", "type": "image/png", "purpose": "maskable" },
        { "src": "icons/Icon-maskable-512.png", "sizes": "512x512", "type": "image/png", "purpose": "maskable" }
    ]
}
```

In `web/index.html` change `<title>medora</title>` to `<title>Medora</title>` and `<meta name="description" content="medication cabinet">` to `content="Home medicine cabinet manager"`.

- [ ] **Step 6: Verify**

Run: `fvm flutter analyze && fvm flutter test`
Expected: clean, all green.

Run: `fvm flutter build web --release`
Expected: `✓ Built build/web`. (This is the compile-time proof that no unguarded `dart:io` call is reached on web at build; the runtime guard is the `kIsWeb` check added above.)

- [ ] **Step 7: Commit**

```bash
git add lib/core/platform_capabilities.dart lib/presentation test/core/platform_capabilities_test.dart ios/Runner/Info.plist web/manifest.json web/index.html
git commit -m "feat(platform): capability gating, iOS usage strings, web manifest

Scanner, photo and biometrics UI appear only where supported. Medication
detail no longer touches dart:io File on web.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01BAjdzp9JhksW2XbhM6CPBS"
```

---

### Task 8: Version constant and deprecated `anonKey`

**Files:**
- Modify: `lib/core/constants.dart:13`
- Modify: `lib/core/supabase_config.dart` (initialize)
- Modify: `lib/presentation/screens/settings/settings_screen.dart` (version fallback)
- Test: `test/core/supabase_config_test.dart`

- [ ] **Step 1: Write the failing test**

`test/core/supabase_config_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/core/app_config.dart';
import 'package:medora/core/errors.dart';
import 'package:medora/core/supabase_config.dart';

void main() {
  setUp(SupabaseConfig.resetForTest);

  test('initialize without config leaves Supabase unconfigured and never throws', () async {
    await SupabaseConfig.initialize(const AppConfig(supabaseUrl: '', supabaseAnonKey: ''));
    expect(SupabaseConfig.isConfigured, isFalse);
    expect(SupabaseConfig.clientOrNull, isNull);
    expect(SupabaseConfig.currentUserId, isNull);
    expect(SupabaseConfig.isAuthenticated, isFalse);
    expect(() => SupabaseConfig.requireClient(), throwsA(isA<AuthException>()));
  });
}
```

Run: `fvm flutter test test/core/supabase_config_test.dart`
Expected: PASS already (Task 1 implemented this) — keep it as the regression guard; if it fails, fix `SupabaseConfig` before continuing.

- [ ] **Step 2: Remove the stale version constant**

In `lib/core/constants.dart` delete the line `static const String appVersion = '1.0.0';`. In `settings_screen.dart` change the About tile fallback `orElse: () => AppConstants.appVersion,` to `orElse: () => '…',`.

- [ ] **Step 3: Use `publishableKey`**

In `SupabaseConfig.initialize` replace

```dart
    await Supabase.initialize(
      url: config.supabaseUrl,
      // ignore: deprecated_member_use
      anonKey: config.supabaseAnonKey,
    );
```

with

```dart
    await Supabase.initialize(
      url: config.supabaseUrl,
      publishableKey: config.supabaseAnonKey,
    );
```

(`supabase_flutter` 2.9 accepts legacy `anon` keys through `publishableKey`.) If the analyzer reports `publishableKey` as undefined, the installed version is older than the deprecation notice suggests — run `fvm flutter pub upgrade supabase_flutter` and retry.

- [ ] **Step 4: Verify and commit**

Run: `fvm flutter analyze && fvm flutter test`
Expected: clean, green.

```bash
git add lib/core/constants.dart lib/core/supabase_config.dart lib/presentation/screens/settings/settings_screen.dart test/core/supabase_config_test.dart
git commit -m "chore(core): drop stale appVersion constant, use publishableKey

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01BAjdzp9JhksW2XbhM6CPBS"
```

---

### Task 9: CI workflow and README setup rewrite

**Files:**
- Create: `.github/workflows/ci.yml`
- Modify: `README.md` (Prerequisites + Setup sections)
- Delete: `README_TECH.md` (content folded into README; stale architecture tree)

- [ ] **Step 1: Create `.github/workflows/ci.yml`**

```yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: subosito/flutter-action@v2
        with:
          channel: stable
          cache: true
      - run: flutter --version
      - run: flutter pub get
      - run: flutter gen-l10n
      - run: git diff --exit-code -- lib/l10n/generated || (echo "Run 'flutter gen-l10n' and commit the result" && exit 1)
      - run: flutter analyze --fatal-infos
      - run: flutter test

  build-web:
    runs-on: ubuntu-latest
    needs: test
    steps:
      - uses: actions/checkout@v4
      - uses: subosito/flutter-action@v2
        with:
          channel: stable
          cache: true
      - run: flutter pub get
      - run: flutter build web --release

  build-android:
    runs-on: ubuntu-latest
    needs: test
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-java@v4
        with:
          distribution: temurin
          java-version: '17'
      - uses: subosito/flutter-action@v2
        with:
          channel: stable
          cache: true
      - run: flutter pub get
      - run: flutter build apk --debug
```

- [ ] **Step 2: Rewrite README setup**

Replace everything in `README.md` from `## Prerequisites` to the end with:

```markdown
## Prerequisites

- **FVM** — Flutter Version Manager ([install guide](https://fvm.app/documentation/getting-started/installation))
- **Flutter stable** (3.44+) — managed via FVM (`.fvmrc`)
- Android Studio / Xcode for device builds (optional for Linux/Web)

## Run it (no configuration needed)

```bash
fvm install
fvm flutter pub get
fvm flutter run            # pick a device: Android, iOS, Linux, Windows, Chrome
```

Medora works completely offline. All data lives in a local SQLite database on the device.

## Optional: cloud sync with Supabase

1. Create a Supabase project and run `supabase/initial_schema.sql` in the SQL editor.
2. Copy `dart_defines.example.json` to `dart_defines.json` and fill in your project URL and anon/publishable key.
3. Run or build with the defines:

```bash
fvm flutter run --dart-define-from-file=dart_defines.json
fvm flutter build apk --release --dart-define-from-file=dart_defines.json
```

Then open **Settings → Cloud sync → Turn on** and sign in. Without defines the app runs local-only and the cloud section says so.

## Development

```bash
fvm flutter analyze
fvm flutter test
fvm flutter gen-l10n       # after editing lib/l10n/*.arb
```

Architecture: Clean Architecture (`lib/domain`, `lib/data`, `lib/presentation`, `lib/services`) with Riverpod 3 for state, go_router for navigation, sqflite for local storage, optional Supabase for sync. Design docs live in `docs/superpowers/specs/`.

## Platform notes

- Android: `minSdk 28`. Release builds need your own keystore (see `android/app/build.gradle.kts`).
- iOS: camera, photo library and Face ID usage strings are in `ios/Runner/Info.plist`.
- Web: installable PWA; OCR scanning, photos and notifications are not available in the browser.
- Linux/Windows: full local functionality; scheduled notifications are not supported by the desktop plugins.

## License

Private project. All rights reserved.
```

Also fix the Features bullet `**Barcode Scanner** — Scan medication package barcodes using the device camera (\`mobile_scanner\`)…` to: `**AIC Code Scanner** — Point the camera at an Italian medication package; on-device OCR (ML Kit) reads the AIC code and looks it up in the AIFA database (cached locally after a one-time download).`

Delete `README_TECH.md`: `git rm README_TECH.md`.

- [ ] **Step 3: Verify locally what CI will run**

Run: `fvm flutter gen-l10n && git status --short lib/l10n/generated`
Expected: no changes listed.

Run: `fvm flutter analyze --fatal-infos && fvm flutter test`
Expected: clean and green.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/ci.yml README.md
git rm -q README_TECH.md
git commit -m "ci: add GitHub Actions (analyze, test, web + apk builds); README for zero-config setup

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01BAjdzp9JhksW2XbhM6CPBS"
```

---

## Phase 0 exit criteria (from the spec)

- [ ] Fresh clone → `fvm flutter pub get && fvm flutter run -d linux` with no config: Dashboard opens, add medication → create treatment → add prescription → take a dose → restart → data present.
- [ ] Same on an Android device/emulator.
- [ ] `fvm flutter test` green; CI workflow green on the PR.
- [ ] `fvm flutter build web --release` succeeds.
- [ ] With dart-defines: Settings → Cloud sync → Turn on → sign in → Sync Now runs without error.
