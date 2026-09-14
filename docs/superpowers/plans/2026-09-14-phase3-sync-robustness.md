# Phase 3 — Sync Robustness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make cloud sync (Supabase, opt-in) converge across devices: deletions propagate (tombstones), pulls are incremental (delta by `updated_at`), every sync produces an honest `SyncReport` shown in Settings, family membership syncs both ways, and the app syncs automatically when connectivity returns and when the user turns cloud sync on.

**Architecture:** `SyncService` keeps its push-then-pull cycle but gains injectable seams (clock, connectivity, user id, cursor store) so it is unit-tested against in-memory fake remote datasources that mirror Supabase semantics (JSON rows, server-stamped `updated_at`, `deleted_at` tombstones). Remote "delete" becomes a soft delete (`deleted_at`), pull applies tombstones as local hard deletes, and per-table pull cursors live in SharedPreferences. Server changes ship as a Supabase migration (`deleted_at` columns, tombstone cascade triggers, family RLS fixes and a `join_family` RPC). An optional, manually-triggered CI job runs a convergence test against a local Supabase.

**Tech Stack:** Flutter 3.44.6 (`fvm`), Dart 3.11, flutter_riverpod 3, supabase_flutter 2.x (`SupabaseClient`), sqflite (+ffi in tests), shared_preferences, connectivity_plus, GitHub Actions + `supabase/setup-cli`.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-09-14-medora-offline-first-overhaul-design.md` §4.6 and §5 Phase 3. Do not re-litigate decisions in §3/§8.
- Flutter runs via `fvm` (`fvm flutter ...`). Package imports only (`package:medora/...`). Every task ends with `fvm flutter analyze --fatal-infos` clean and `fvm flutter test` green (baseline: Phase 2 suite incl. goldens). Guards `test/presentation/theme_sweep_test.dart` and `test/presentation/l10n_sweep_test.dart` stay green.
- Local-only mode must be untouched in behaviour: with all remote datasources `null`, `SyncService.isAvailable` is false and every sync entry point is a no-op that leaves state `idle`.
- Conflict rule stays last-write-wins by `updated_at` for locally pending rows; a remote tombstone always wins (local hard delete), even over a locally pending update.
- Remote deletes are soft: `deleteX(id)` on a remote datasource sets `deleted_at` (and the server trigger bumps `updated_at`); it never issues a SQL `DELETE` on the four synced tables. Family member removal remains a hard delete (no tombstone column on `family_members`).
- Pull cursors: key `sync.last_pull_at.<table>` in SharedPreferences, value ISO-8601 UTC; stored value = newest pulled `updated_at` minus 1 second (deliberate 1 s overlap; upserts are idempotent). Force pull and "turn on cloud sync" clear all cursors. Families/members are always pulled in full.
- Timestamps sent to Supabase are UTC ISO-8601 (`toUtc().toIso8601String()`); timestamps parsed from Supabase are converted with `.toLocal()` where the model already does so (dose logs).
- `SyncReport { startedAt, finishedAt, pushed, pulled, deleted, failures: List<SyncFailure(table, id, error)>, fatal }`; `SyncState` gains `partial` (finished with ≥ 1 failure, no fatal). Every `switch` over `SyncState` must stay exhaustive.
- Auto-sync on reconnect: only on an offline→online transition, debounced 2 s, via `syncAll()` (which is already throttled by its own `syncing` guard). Never on app start (startup sync stays in `AppStartupTasks`).
- ARB en/de/it for every new user-facing string; run `fvm flutter gen-l10n`; commit `lib/l10n/generated/`; `untranslated.txt` must be `{}`.
- Supabase schema changes go under `supabase/migrations/<timestamp>_<name>.sql` (CLI naming). `supabase/initial_schema.sql` moves to `supabase/migrations/20260901000000_initial_schema.sql` (git mv, content unchanged) and README points at the migrations folder. Never edit an existing migration after it is committed.
- Commits end with the two attribution lines given in the session's system reminder.

---

## File structure

| Path | Responsibility |
|---|---|
| `lib/services/sync_service.dart` | Push/pull cycle, LWW merge, tombstone application, report building, auto-sync subscription. Rewritten in Task 1–3 (full file given in Task 3). |
| `lib/services/sync_report.dart` (new) | `SyncFailure`, `SyncReport` value types. |
| `lib/services/sync_cursor_store.dart` (new) | Per-table `last_pull_at` persistence (prefs or in-memory). |
| `lib/services/local_upload_marker.dart` (new) | Marks every local row pending for upload and clears cursors (used when cloud sync is turned on). |
| `lib/data/models/{medication,treatment,prescription,dose_log}_model.dart` | Gain `deletedAt`; UTC on the wire. |
| `lib/data/datasources/*_remote_datasource.dart` | Soft delete, `getXSince(DateTime?)`, family upsert/join RPC/membership by user. |
| `lib/data/datasources/*_local_datasource.dart` | `deleted_at` in rows; family member pending-delete helpers. |
| `lib/data/repositories/family_repository_impl.dart` | Pending operations for leave/remove; RPC join. |
| `lib/presentation/providers/sync_providers.dart` (new) | `syncCursorStoreProvider`, `localUploadMarkerProvider`, `syncLastReportProvider`. |
| `lib/presentation/providers/providers.dart`, `app_mode_provider.dart` | Wire seams, start auto-sync, mark-for-upload on turn-on. |
| `lib/presentation/screens/settings/settings_screen.dart`, `widgets/sync_status_chip.dart` | `partial` state, last report tile + failures dialog. |
| `supabase/migrations/20260914000000_tombstones_and_family.sql` (new), `supabase/config.toml` (new) | Server schema + local CLI config. |
| `test/helpers/fake_remotes.dart` (new) | In-memory fakes implementing the five remote datasource classes. |
| `test/services/sync_service_test.dart` (rewritten), `sync_cursor_store_test.dart`, `local_upload_marker_test.dart`, `test/presentation/widgets/sync_status_chip_test.dart`, `test/data/repositories/family_repository_test.dart`, `test/integration/sync_convergence_test.dart` | Tests. |
| `.github/workflows/ci.yml`, `README.md` | Manual integration job; docs. |

---

### Task 1: Testable `SyncService` seams + in-memory fake remotes + baseline push/pull tests

**Files:**
- Create: `test/helpers/fake_remotes.dart`, `lib/services/sync_cursor_store.dart`, `test/services/sync_cursor_store_test.dart`
- Modify: `lib/services/sync_service.dart` (constructor seams only; behaviour unchanged), `lib/presentation/providers/providers.dart` (`syncServiceProvider`)
- Test: `test/services/sync_service_test.dart` (rewrite; keep the two existing local-only tests)

**Interfaces:**
- Produces: `SyncService({..., SyncCursorStore? cursors, bool Function()? isOnline, String? Function()? currentUserId, Stream<bool>? onlineStream, DateTime Function()? now})` — every optional seam defaults to the current singleton (`ConnectivityService.instance`, `SupabaseConfig`, `DateTime.now`, `SyncCursorStore.inMemory()`).
- Produces: `SyncCursorStore` with `Future<DateTime?> lastPullAt(String table)`, `Future<void> setLastPullAt(String table, DateTime utc)`, `Future<void> clear()`; constructors `SyncCursorStore(SharedPreferences prefs)` and `SyncCursorStore.inMemory()`.
- Produces: `FakeRemoteTable`, `FakeMedicationRemote`, `FakeTreatmentRemote`, `FakePrescriptionRemote`, `FakeDoseLogRemote`, `FakeFamilyRemote` (each `implements` the real class; see code). Later tasks add `getXSince` and family methods to the real classes and to these fakes.

- [ ] **Step 1: Cursor store test**

`test/services/sync_cursor_store_test.dart`:
```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/services/sync_cursor_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('in-memory store round-trips and clears', () async {
    final store = SyncCursorStore.inMemory();
    expect(await store.lastPullAt('medications'), isNull);
    final t = DateTime.utc(2026, 3, 4, 15, 0, 0);
    await store.setLastPullAt('medications', t);
    expect(await store.lastPullAt('medications'), t);
    await store.clear();
    expect(await store.lastPullAt('medications'), isNull);
  });

  test('prefs store persists under sync.last_pull_at.<table> as UTC ISO', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final store = SyncCursorStore(prefs);
    await store.setLastPullAt('dose_logs', DateTime(2026, 3, 4, 16, 30)); // local time in
    final raw = prefs.getString('sync.last_pull_at.dose_logs');
    expect(raw, endsWith('Z'));
    expect(await store.lastPullAt('dose_logs'), DateTime(2026, 3, 4, 16, 30).toUtc());
    await store.clear();
    expect(prefs.getString('sync.last_pull_at.dose_logs'), isNull);
  });
}
```

- [ ] **Step 2: Run it — expect compile failure (file missing).**

`fvm flutter test test/services/sync_cursor_store_test.dart`

- [ ] **Step 3: Implement `lib/services/sync_cursor_store.dart`**

```dart
/// Medora - Per-table pull cursors for delta sync.
///
/// Stores the newest remote `updated_at` seen per table (minus a 1 s overlap,
/// applied by the caller) so the next pull can ask only for newer rows.
library;

import 'package:shared_preferences/shared_preferences.dart';

class SyncCursorStore {
  SyncCursorStore(SharedPreferences prefs) : _prefs = prefs;

  /// Non-persistent store for tests and for builds without cloud sync.
  SyncCursorStore.inMemory() : _prefs = null;

  static const keyPrefix = 'sync.last_pull_at.';

  final SharedPreferences? _prefs;
  final Map<String, DateTime> _memory = {};

  Future<DateTime?> lastPullAt(String table) async {
    final prefs = _prefs;
    if (prefs == null) return _memory[table];
    final raw = prefs.getString('$keyPrefix$table');
    return raw == null ? null : DateTime.tryParse(raw)?.toUtc();
  }

  Future<void> setLastPullAt(String table, DateTime at) async {
    final utc = at.toUtc();
    final prefs = _prefs;
    if (prefs == null) {
      _memory[table] = utc;
      return;
    }
    await prefs.setString('$keyPrefix$table', utc.toIso8601String());
  }

  Future<void> clear() async {
    _memory.clear();
    final prefs = _prefs;
    if (prefs == null) return;
    for (final key in prefs.getKeys().where((k) => k.startsWith(keyPrefix)).toList()) {
      await prefs.remove(key);
    }
  }
}
```

- [ ] **Step 4: Run — expect PASS.**

- [ ] **Step 5: Fake remotes helper**

`test/helpers/fake_remotes.dart` — one JSON-row table per remote, mirroring Supabase: rows are stored as the `toJson()` map, read back through `fromJson`, `updated_at` is stamped by the fake "server" on update, tombstones are `deleted_at`. `failIds` makes any write for those ids throw (per-row error tests). `sinceCalls` records the `since` argument of every delta fetch (Task 4).

```dart
import 'package:medora/data/datasources/dose_log_remote_datasource.dart';
import 'package:medora/data/datasources/family_remote_datasource.dart';
import 'package:medora/data/datasources/medication_remote_datasource.dart';
import 'package:medora/data/datasources/prescription_remote_datasource.dart';
import 'package:medora/data/datasources/treatment_remote_datasource.dart';
import 'package:medora/data/models/dose_log_model.dart';
import 'package:medora/data/models/family_member_model.dart';
import 'package:medora/data/models/family_model.dart';
import 'package:medora/data/models/medication_model.dart';
import 'package:medora/data/models/prescription_model.dart';
import 'package:medora/data/models/treatment_model.dart';

/// A fake Supabase table: JSON rows keyed by id, server-stamped `updated_at`,
/// soft delete via `deleted_at`.
class FakeRemoteTable {
  FakeRemoteTable(this.clock);

  final DateTime Function() clock;
  final Map<String, Map<String, dynamic>> rows = {};
  final Set<String> failIds = {};
  final List<DateTime?> sinceCalls = [];

  void _guard(String id) {
    if (failIds.contains(id)) throw StateError('remote failure for $id');
  }

  /// Insert keeps the client's `updated_at` (or stamps now); update stamps now
  /// like the `update_updated_at` trigger.
  void upsert(Map<String, dynamic> json) {
    final id = json['id'] as String;
    _guard(id);
    final now = clock().toUtc().toIso8601String();
    final existing = rows[id];
    final merged = {...?existing, ...json};
    merged['updated_at'] = existing == null ? (json['updated_at'] ?? now) : now;
    rows[id] = merged;
  }

  void tombstone(String id) {
    _guard(id);
    final existing = rows[id];
    if (existing == null) return;
    final now = clock().toUtc().toIso8601String();
    rows[id] = {...existing, 'deleted_at': now, 'updated_at': now};
  }

  void hardDelete(String id) {
    _guard(id);
    rows.remove(id);
  }

  List<Map<String, dynamic>> all() => rows.values.map((r) => Map<String, dynamic>.from(r)).toList();

  List<Map<String, dynamic>> since(DateTime? since) {
    sinceCalls.add(since);
    if (since == null) return all();
    return all().where((r) {
      final u = r['updated_at'] as String?;
      return u != null && DateTime.parse(u).toUtc().isAfter(since.toUtc());
    }).toList();
  }

  /// Test helper: seed a row that is already synced remotely.
  void seed(Map<String, dynamic> json, {DateTime? updatedAt}) {
    rows[json['id'] as String] = {
      ...json,
      'updated_at': (updatedAt ?? clock()).toUtc().toIso8601String(),
    };
  }
}

class FakeMedicationRemote implements MedicationRemoteDatasource {
  FakeMedicationRemote(DateTime Function() clock) : table = FakeRemoteTable(clock);
  final FakeRemoteTable table;

  @override
  Future<List<MedicationModel>> getMedications() async =>
      table.all().map(MedicationModel.fromJson).toList();
  @override
  Future<List<MedicationModel>> getMedicationsSince(DateTime? since) async =>
      table.since(since).map(MedicationModel.fromJson).toList();
  @override
  Future<MedicationModel> getMedicationById(String id) async =>
      MedicationModel.fromJson(table.rows[id]!);
  @override
  Future<List<MedicationModel>> searchMedications(String query) async =>
      (await getMedications()).where((m) => m.name.contains(query)).toList();
  @override
  Future<void> addMedication(MedicationModel model) async => table.upsert(model.toJson());
  @override
  Future<void> updateMedication(MedicationModel model) async => table.upsert(model.toJson());
  @override
  Future<void> upsertMedication(MedicationModel model) async => table.upsert(model.toJson());
  @override
  Future<void> deleteMedication(String id) async => table.tombstone(id);
  @override
  Future<void> updateQuantity(String id, int delta) async {
    final row = table.rows[id]!;
    table.upsert({...row, 'quantity': (row['quantity'] as int) + delta});
  }
}

class FakeTreatmentRemote implements TreatmentRemoteDatasource {
  FakeTreatmentRemote(DateTime Function() clock) : table = FakeRemoteTable(clock);
  final FakeRemoteTable table;

  @override
  Future<List<TreatmentModel>> getTreatments() async =>
      table.all().map(TreatmentModel.fromJson).toList();
  @override
  Future<List<TreatmentModel>> getTreatmentsSince(DateTime? since) async =>
      table.since(since).map(TreatmentModel.fromJson).toList();
  @override
  Future<List<TreatmentModel>> getActiveTreatments() async =>
      (await getTreatments()).where((t) => t.isActive).toList();
  @override
  Future<TreatmentModel> getTreatmentById(String id) async =>
      TreatmentModel.fromJson(table.rows[id]!);
  @override
  Future<void> addTreatment(TreatmentModel model) async => table.upsert(model.toJson());
  @override
  Future<void> updateTreatment(TreatmentModel model) async => table.upsert(model.toJson());
  @override
  Future<void> upsertTreatment(TreatmentModel model) async => table.upsert(model.toJson());
  @override
  Future<void> deleteTreatment(String id) async => table.tombstone(id);
  @override
  Future<void> endTreatment(String id) async =>
      table.upsert({...table.rows[id]!, 'is_active': false});
}

class FakePrescriptionRemote implements PrescriptionRemoteDatasource {
  FakePrescriptionRemote(DateTime Function() clock) : table = FakeRemoteTable(clock);
  final FakeRemoteTable table;

  @override
  Future<List<PrescriptionModel>> getPrescriptions() async =>
      table.all().map(PrescriptionModel.fromJson).toList();
  @override
  Future<List<PrescriptionModel>> getPrescriptionsSince(DateTime? since) async =>
      table.since(since).map(PrescriptionModel.fromJson).toList();
  @override
  Future<List<PrescriptionModel>> getPrescriptionsByTreatment(String treatmentId) async =>
      (await getPrescriptions()).where((p) => p.treatmentId == treatmentId).toList();
  @override
  Future<List<PrescriptionModel>> getActivePrescriptions() async =>
      (await getPrescriptions()).where((p) => p.isActive).toList();
  @override
  Future<PrescriptionModel> getPrescriptionById(String id) async =>
      PrescriptionModel.fromJson(table.rows[id]!);
  @override
  Future<void> addPrescription(PrescriptionModel model) async => table.upsert(model.toJson());
  @override
  Future<void> updatePrescription(PrescriptionModel model) async => table.upsert(model.toJson());
  @override
  Future<void> upsertPrescription(PrescriptionModel model) async => table.upsert(model.toJson());
  @override
  Future<void> deletePrescription(String id) async => table.tombstone(id);
  @override
  Future<void> deactivatePrescription(String id) async =>
      table.upsert({...table.rows[id]!, 'is_active': false});
  @override
  Future<void> reactivatePrescription(String id) async =>
      table.upsert({...table.rows[id]!, 'is_active': true});
}

class FakeDoseLogRemote implements DoseLogRemoteDatasource {
  FakeDoseLogRemote(DateTime Function() clock) : table = FakeRemoteTable(clock);
  final FakeRemoteTable table;

  @override
  Future<List<DoseLogModel>> getDoseLogs() async =>
      table.all().map(DoseLogModel.fromJson).toList();
  @override
  Future<List<DoseLogModel>> getDoseLogsSince(DateTime? since) async =>
      table.since(since).map(DoseLogModel.fromJson).toList();
  @override
  Future<List<DoseLogModel>> getTodaysDoseLogs() async => getDoseLogs();
  @override
  Future<void> addDoseLog(DoseLogModel model) async => table.upsert(model.toJson());
  @override
  Future<void> addDoseLogsBatch(List<DoseLogModel> models) async {
    for (final m in models) {
      table.upsert(m.toJson());
    }
  }
  @override
  Future<void> upsertDoseLog(DoseLogModel model) async => table.upsert(model.toJson());
  @override
  Future<void> updateDoseLogStatus(String id, String status, {DateTime? takenTime}) async =>
      table.upsert({
        ...table.rows[id]!,
        'status': status,
        'taken_time': takenTime?.toUtc().toIso8601String(),
      });
  @override
  Future<void> deleteDoseLog(String id) async => table.tombstone(id);
}

class FakeFamilyRemote implements FamilyRemoteDatasource {
  FakeFamilyRemote(DateTime Function() clock, {this.currentUserId = 'user-a'})
      : families = FakeRemoteTable(clock),
        members = FakeRemoteTable(clock);
  final FakeRemoteTable families;
  final FakeRemoteTable members;
  String currentUserId;

  @override
  Future<FamilyModel> createFamily(FamilyModel family) async {
    families.upsert(family.toJson());
    return FamilyModel.fromJson(families.rows[family.id]!);
  }
  @override
  Future<void> upsertFamily(FamilyModel family) async => families.upsert(family.toJson());
  @override
  Future<FamilyModel?> getFamilyByInviteCode(String code) async {
    final row = families.all().where((r) => r['invite_code'] == code).firstOrNull;
    return row == null ? null : FamilyModel.fromJson(row);
  }
  @override
  Future<FamilyModel?> getFamilyById(String id) async {
    final row = families.rows[id];
    return row == null ? null : FamilyModel.fromJson(row);
  }
  @override
  Future<FamilyMemberModel> addMember(FamilyMemberModel member) async {
    members.upsert(member.toJson());
    return FamilyMemberModel.fromJson(members.rows[member.id]!);
  }
  @override
  Future<void> upsertMember(FamilyMemberModel member) async => members.upsert(member.toJson());
  @override
  Future<List<FamilyMemberModel>> getMembers(String familyId) async => members
      .all()
      .where((r) => r['family_id'] == familyId)
      .map(FamilyMemberModel.fromJson)
      .toList();
  @override
  Future<void> removeMember(String memberId) async => members.hardDelete(memberId);
  @override
  Future<FamilyMemberModel?> getCurrentMembership() async {
    final row = members.all().where((r) => r['user_id'] == currentUserId).firstOrNull;
    return row == null ? null : FamilyMemberModel.fromJson(row);
  }
  @override
  Future<String> regenerateInviteCode(String familyId) async {
    families.upsert({...families.rows[familyId]!, 'invite_code': 'NEWCODE'});
    return 'NEWCODE';
  }
  @override
  Future<void> deleteFamily(String familyId) async => families.hardDelete(familyId);
  @override
  Future<({FamilyModel family, FamilyMemberModel member})> joinFamily(
      String inviteCode, String displayName) async {
    final family = await getFamilyByInviteCode(inviteCode);
    if (family == null) throw StateError('Invalid invite code');
    final member = FamilyMemberModel(
      id: 'member-$currentUserId',
      familyId: family.id,
      userId: currentUserId,
      displayName: displayName,
      role: 'member',
    );
    members.upsert(member.toJson());
    return (family: family, member: FamilyMemberModel.fromJson(members.rows[member.id]!));
  }
}
```

The fake references `getXSince`, `upsertFamily`, `upsertMember`, `joinFamily` which do not exist yet on the real classes. **In this task, add those members to the real classes as thin Supabase implementations** (their sync-side use comes in Tasks 4–5):

- `MedicationRemoteDatasource.getMedicationsSince(DateTime? since)`:
```dart
  /// Rows changed after [since] (UTC); all rows when null. Includes tombstones.
  Future<List<MedicationModel>> getMedicationsSince(DateTime? since) async {
    var query = _client.from(AppConstants.medicationsTable).select();
    if (since != null) {
      query = query.gt('updated_at', since.toUtc().toIso8601String());
    }
    final response = await query.order('updated_at');
    return (response as List)
        .map((json) => MedicationModel.fromJson(json as Map<String, dynamic>))
        .toList();
  }
```
  Same shape for `TreatmentRemoteDatasource.getTreatmentsSince`, `PrescriptionRemoteDatasource.getPrescriptionsSince`, and `DoseLogRemoteDatasource.getDoseLogsSince` (keep the dose-log select string `'*, prescriptions(id, medications(name))'`). If the `PostgrestFilterBuilder`/`PostgrestTransformBuilder` types make the `var query` reassignment fail to type-check, build it as `final base = _client.from(...).select(); final filtered = since == null ? base : base.gt(...); final response = await filtered.order('updated_at');`.
- `FamilyRemoteDatasource`:
```dart
  Future<void> upsertFamily(FamilyModel family) async {
    await _client.from('families').upsert(family.toJson());
  }

  Future<void> upsertMember(FamilyMemberModel member) async {
    await _client.from('family_members').upsert(member.toJson());
  }

  /// Joins via the `join_family` RPC (security definer; see the 2026-09-14
  /// migration) so a non-owner can join without a SELECT policy on families.
  Future<({FamilyModel family, FamilyMemberModel member})> joinFamily(
      String inviteCode, String displayName) async {
    final response = await _client.rpc('join_family', params: {
      'p_invite_code': inviteCode,
      'p_display_name': displayName,
    }) as Map<String, dynamic>;
    return (
      family: FamilyModel.fromJson(response['family'] as Map<String, dynamic>),
      member: FamilyMemberModel.fromJson(response['member'] as Map<String, dynamic>),
    );
  }
```
  and change `getCurrentMembership()` to filter by the signed-in user:
```dart
  Future<FamilyMemberModel?> getCurrentMembership() async {
    final userId = _client.auth.currentUser?.id;
    if (userId == null) return null;
    final response = await _client
        .from('family_members')
        .select()
        .eq('user_id', userId)
        .limit(1)
        .maybeSingle();
    if (response == null) return null;
    return FamilyMemberModel.fromJson(response);
  }
```
  Also make `FamilyMemberModel.fromJson` and `FamilyModel.fromJson` tolerate the fake's rows (they already parse `joined_at`/`created_at` as optional strings — verify; the fake never sets them).

- [ ] **Step 6: Seams in `SyncService`**

In `lib/services/sync_service.dart` change the constructor and the three singleton reads:

```dart
  SyncService({
    required this.medicationLocal,
    required this.medicationRemote,
    required this.treatmentLocal,
    required this.treatmentRemote,
    required this.prescriptionLocal,
    required this.prescriptionRemote,
    required this.doseLogLocal,
    required this.doseLogRemote,
    required this.familyLocal,
    required this.familyRemote,
    SyncCursorStore? cursors,
    bool Function()? isOnline,
    String? Function()? currentUserId,
    Stream<bool>? onlineStream,
    DateTime Function()? now,
  })  : _cursors = cursors ?? SyncCursorStore.inMemory(),
        _isOnline = isOnline ?? (() => ConnectivityService.instance.isOnline),
        _currentUserId = currentUserId ?? (() => SupabaseConfig.currentUserId),
        _onlineStream = onlineStream ?? ConnectivityService.instance.onlineStream,
        _now = now ?? DateTime.now;

  final SyncCursorStore _cursors;
  final bool Function() _isOnline;
  final String? Function() _currentUserId;
  final Stream<bool> _onlineStream;
  final DateTime Function() _now;

  bool get _isAuthenticated => _currentUserId() != null;
```
Replace every `ConnectivityService.instance.isOnline` with `_isOnline()`, every `SupabaseConfig.isAuthenticated` with `_isAuthenticated`, every `SupabaseConfig.currentUserId` with `_currentUserId()`, `DateTime.now()` in `syncAll` with `_now()`, and `startAutoSync` to listen on `_onlineStream`. Import `package:medora/services/sync_cursor_store.dart`. Nothing else changes yet.

In `lib/presentation/providers/providers.dart` pass `cursors: ref.watch(syncCursorStoreProvider)` — create `lib/presentation/providers/sync_providers.dart`:

```dart
/// Medora - Sync-related providers that must not depend on providers.dart
/// (app_mode_provider.dart imports this file).
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:medora/presentation/providers/settings_providers.dart';
import 'package:medora/services/sync_cursor_store.dart';

final syncCursorStoreProvider = Provider<SyncCursorStore>(
  (ref) => SyncCursorStore(ref.watch(sharedPreferencesProvider)),
);
```

- [ ] **Step 7: Baseline sync tests with fakes**

Rewrite `test/services/sync_service_test.dart` (keep the two existing local-only tests verbatim, then add):

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/data/datasources/dose_log_local_datasource.dart';
import 'package:medora/data/datasources/family_local_datasource.dart';
import 'package:medora/data/datasources/medication_local_datasource.dart';
import 'package:medora/data/datasources/prescription_local_datasource.dart';
import 'package:medora/data/datasources/treatment_local_datasource.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/models/medication_model.dart';
import 'package:medora/services/sync_cursor_store.dart';
import 'package:medora/services/sync_service.dart';

import '../helpers/fake_remotes.dart';
import '../helpers/test_database.dart';

class Harness {
  Harness({DateTime? start}) : clock = _Clock(start ?? DateTime.utc(2026, 3, 4, 12)) {
    meds = FakeMedicationRemote(clock.now);
    treatments = FakeTreatmentRemote(clock.now);
    prescriptions = FakePrescriptionRemote(clock.now);
    doses = FakeDoseLogRemote(clock.now);
    family = FakeFamilyRemote(clock.now);
    cursors = SyncCursorStore.inMemory();
    service = SyncService(
      medicationLocal: MedicationLocalDatasource(),
      medicationRemote: meds,
      treatmentLocal: TreatmentLocalDatasource(),
      treatmentRemote: treatments,
      prescriptionLocal: PrescriptionLocalDatasource(),
      prescriptionRemote: prescriptions,
      doseLogLocal: DoseLogLocalDatasource(),
      doseLogRemote: doses,
      familyLocal: FamilyLocalDatasource(),
      familyRemote: family,
      cursors: cursors,
      isOnline: () => online,
      currentUserId: () => userId,
      onlineStream: const Stream.empty(),
      now: clock.now,
    );
  }

  final _Clock clock;
  bool online = true;
  String? userId = 'user-a';
  late final FakeMedicationRemote meds;
  late final FakeTreatmentRemote treatments;
  late final FakePrescriptionRemote prescriptions;
  late final FakeDoseLogRemote doses;
  late final FakeFamilyRemote family;
  late final SyncCursorStore cursors;
  late final SyncService service;
}

class _Clock {
  _Clock(this._now);
  DateTime _now;
  DateTime now() => _now;
  void advance(Duration d) => _now = _now.add(d);
}

Future<Map<String, dynamic>?> localRow(String table, String id) async {
  final db = await AppDatabase.instance.database;
  final rows = await db.query(table, where: 'id = ?', whereArgs: [id]);
  return rows.isEmpty ? null : rows.first;
}

void main() {
  setUp(setUpTestDatabase);
  tearDown(tearDownTestDatabase);

  // (existing) local-only tests unchanged …

  group('with fake remotes', () {
    test('pushes a pending local medication and marks it synced', () async {
      final h = Harness();
      await MedicationLocalDatasource().upsert(
        const MedicationModel(id: 'm1', name: 'Moment', quantity: 3),
        syncStatus: SyncStatus.pendingCreate,
      );
      await h.service.syncAll();
      expect(h.meds.table.rows['m1']?['name'], 'Moment');
      expect((await localRow('medications', 'm1'))?['sync_status'], SyncStatus.synced);
      expect(h.service.currentState, SyncState.success);
    });

    test('pulls a remote medication into the local database', () async {
      final h = Harness();
      h.meds.table.seed(const MedicationModel(id: 'm2', name: 'Tachipirina', quantity: 1).toJson());
      await h.service.syncAll();
      expect((await localRow('medications', 'm2'))?['name'], 'Tachipirina');
      expect((await localRow('medications', 'm2'))?['sync_status'], SyncStatus.synced);
    });

    test('remote newer than local pending wins; local newer is kept', () async {
      final h = Harness();
      final local = MedicationLocalDatasource();
      // Local pending edit at T+10min, remote edit at T+20min → remote wins.
      await local.upsert(
        MedicationModel(id: 'm3', name: 'Local', quantity: 1, updatedAt: h.clock.now().add(const Duration(minutes: 10))),
        syncStatus: SyncStatus.pendingUpdate,
      );
      h.meds.table.seed(
        const MedicationModel(id: 'm3', name: 'Remote', quantity: 1).toJson(),
        updatedAt: h.clock.now().add(const Duration(minutes: 20)),
      );
      // Push happens first and would overwrite remote; make the push fail so
      // the pull phase decides.
      h.meds.table.failIds.add('m3');
      await h.service.syncAll();
      expect((await localRow('medications', 'm3'))?['name'], 'Remote');
    });

    test('skips when offline or signed out', () async {
      final h = Harness()..online = false;
      await h.service.syncAll();
      expect(h.service.currentState, SyncState.idle);
      h.online = true;
      h.userId = null;
      await h.service.syncAll();
      expect(h.service.currentState, SyncState.idle);
    });
  });
}
```

Note for the third test: with today's `_pushBatch` swallowing errors, the pending local row stays pending, then `_safeUpsertMedication` sees remote `updated_at` (T+20) after local (T+10) and takes remote. If `MedicationModel` has no `const` constructor with those fields, drop `const`.

- [ ] **Step 8: Run `fvm flutter test test/services/`, then `fvm flutter analyze --fatal-infos`, then the full suite. All green.**

- [ ] **Step 9: Commit** — `test(sync): injectable SyncService seams, cursor store, in-memory fake remotes`

---

### Task 2: Tombstones — models, remote soft delete, pull applies deletes, Supabase migration

**Files:**
- Modify: `lib/data/models/{medication,treatment,prescription,dose_log}_model.dart`, `lib/data/datasources/{medication,treatment,prescription,dose_log}_remote_datasource.dart`, `lib/data/datasources/{medication,treatment,prescription,dose_log}_local_datasource.dart`, `lib/services/sync_service.dart`
- Create: `supabase/migrations/20260914000000_tombstones_and_family.sql`; `git mv supabase/initial_schema.sql supabase/migrations/20260901000000_initial_schema.sql`
- Test: `test/services/sync_service_test.dart` (add group), `test/data/models/tombstone_roundtrip_test.dart`

**Interfaces:**
- Produces: `deletedAt` (`DateTime?`) on the four models; `fromJson` reads `deleted_at`, `toJson` writes `'deleted_at'`; `fromLocalMap` reads it; local `_toRow`/`toLocalMap` write it.
- Produces: remote `deleteX(id)` = soft delete (`update {deleted_at: now, updated_at: now}`).
- Produces: local `markDeleted(id)` also stamps `deleted_at` (spec §4.6).
- Consumes: Task 1 fakes (`tombstone()` already models the server behaviour).

- [ ] **Step 1: Model round-trip test**

`test/data/models/tombstone_roundtrip_test.dart`:
```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/data/models/dose_log_model.dart';
import 'package:medora/data/models/medication_model.dart';
import 'package:medora/data/models/prescription_model.dart';
import 'package:medora/data/models/treatment_model.dart';

void main() {
  final deleted = DateTime.utc(2026, 3, 4, 10);

  test('medication deleted_at survives toJson/fromJson and is UTC on the wire', () {
    final m = MedicationModel(id: 'm', name: 'x', quantity: 1, deletedAt: deleted);
    final json = m.toJson();
    expect(json['deleted_at'], '2026-03-04T10:00:00.000Z');
    expect(MedicationModel.fromJson(json).deletedAt?.toUtc(), deleted);
    expect(MedicationModel.fromJson({...json, 'deleted_at': null}).deletedAt, isNull);
  });

  test('treatment, prescription and dose log carry deleted_at', () {
    final t = TreatmentModel(id: 't', name: 'x', startDate: DateTime(2026, 3, 1), deletedAt: deleted);
    expect(TreatmentModel.fromJson(t.toJson()).deletedAt?.toUtc(), deleted);
    final p = PrescriptionModel(id: 'p', treatmentId: 't', medicationId: 'm', dosage: '1', startTime: DateTime(2026, 3, 1, 8), deletedAt: deleted);
    expect(PrescriptionModel.fromJson(p.toJson()).deletedAt?.toUtc(), deleted);
    final d = DoseLogModel(id: 'd', prescriptionId: 'p', scheduledTime: DateTime(2026, 3, 1, 8), deletedAt: deleted);
    expect(DoseLogModel.fromJson(d.toJson()).deletedAt?.toUtc(), deleted);
  });

  test('dose log wire timestamps are UTC', () {
    final d = DoseLogModel(id: 'd', prescriptionId: 'p', scheduledTime: DateTime(2026, 3, 1, 8), takenTime: DateTime(2026, 3, 1, 8, 5));
    final json = d.toJson();
    expect((json['scheduled_time'] as String), endsWith('Z'));
    expect((json['taken_time'] as String), endsWith('Z'));
    expect(DoseLogModel.fromJson(json).scheduledTime, DateTime(2026, 3, 1, 8));
  });
}
```

- [ ] **Step 2: Run — fails (no `deletedAt`).**

- [ ] **Step 3: Models.** In each of the four models add `this.deletedAt` to the constructor and `final DateTime? deletedAt;`; in `fromJson` add
```dart
      deletedAt: json['deleted_at'] != null ? DateTime.parse(json['deleted_at'] as String) : null,
```
in `toJson` add `'deleted_at': deletedAt?.toUtc().toIso8601String(),` and change the existing `'updated_at': updatedAt?.toIso8601String()` to `updatedAt?.toUtc().toIso8601String()`; in `fromLocalMap` add `deletedAt: map['deleted_at'] != null ? DateTime.tryParse(map['deleted_at'] as String) : null,`. For `DoseLogModel.toJson` convert `scheduled_time`, `taken_time`, `created_at`, `updated_at` with `.toUtc()` (local storage keeps naive local strings — do not touch `toLocalMap`/`_toRow` formats other than adding `deleted_at`). `PrescriptionModel.toLocalMap` and each `_toRow` add `'deleted_at': m.deletedAt?.toIso8601String()`. Keep `copyWith`-style helpers, if present, in sync.

- [ ] **Step 4: Remote soft delete.** In each remote datasource replace the body of `deleteX(id)`:
```dart
  /// Soft delete (tombstone). The row stays on the server with `deleted_at`
  /// set so other devices pull the deletion; see spec §4.6.
  Future<void> deleteMedication(String id) async {
    final now = DateTime.now().toUtc().toIso8601String();
    await _client
        .from(AppConstants.medicationsTable)
        .update({'deleted_at': now, 'updated_at': now})
        .eq('id', id);
  }
```
(same for treatments, prescriptions, dose_logs). Local `markDeleted(id)` in the four local datasources also writes `'deleted_at': DateTime.now().toIso8601String()` alongside `sync_status`. (`prescription_local_datasource.markDeleted` and `dose_log_local_datasource` equivalents: find them with `grep -n markDeleted lib/data/datasources/`.)

- [ ] **Step 5: Pull applies tombstones + per-row isolation.** In `SyncService` change each `_pullX` loop body to isolate rows and apply deletes:
```dart
  Future<void> _pullMedications({bool force = false}) async {
    try {
      final remoteMeds = await medicationRemote!.getMedications();
      for (final m in remoteMeds) {
        try {
          if (m.deletedAt != null) {
            await medicationLocal.hardDelete(m.id);
          } else {
            await _safeUpsertMedication(m, force: force);
          }
        } catch (e) {
          debugPrint('Sync: pull medications row ${m.id} error: $e');
        }
      }
    } catch (e) { debugPrint('Sync: pull medications error: $e'); }
  }
```
Same for treatments, prescriptions and dose logs (`doseLogLocal.hardDelete(d.id)` when `d.deletedAt != null`). Task 3 replaces these with a generic `_pullTable` that also counts; keep this step minimal.

- [ ] **Step 6: Sync tests (append to the fake-remotes group)**

```dart
    test('remote tombstone hard-deletes the local row even if locally pending', () async {
      final h = Harness();
      final local = MedicationLocalDatasource();
      await local.upsert(const MedicationModel(id: 'm4', name: 'Gone', quantity: 1), syncStatus: SyncStatus.pendingUpdate);
      h.meds.table.seed(const MedicationModel(id: 'm4', name: 'Gone', quantity: 1).toJson());
      h.meds.table.failIds.add('m4'); // push fails so the pending row is still pending at pull time
      h.meds.table.failIds.remove('m4');
      h.meds.table.tombstone('m4');
      h.meds.table.failIds.add('m4');
      await h.service.syncAll();
      expect(await localRow('medications', 'm4'), isNull);
    });

    test('local delete pushes a tombstone and hard-deletes locally', () async {
      final h = Harness();
      h.meds.table.seed(const MedicationModel(id: 'm5', name: 'Bye', quantity: 1).toJson());
      await h.service.syncAll(); // now local synced
      await MedicationLocalDatasource().markDeleted('m5');
      expect((await localRow('medications', 'm5'))?['deleted_at'], isNotNull);
      await h.service.syncAll();
      expect(h.meds.table.rows['m5']?['deleted_at'], isNotNull);
      expect(await localRow('medications', 'm5'), isNull);
    });

    test('a remotely deleted treatment cascades to local prescriptions and dose logs', () async {
      final h = Harness();
      final db = await AppDatabase.instance.database;
      final seeded = await seedPrescription(db);
      await seedDoseLog(db, seeded.prescriptionId, DateTime(2026, 3, 1, 8));
      h.treatments.table.seed((await TreatmentLocalDatasource().getTreatmentById(seeded.treatmentId))!.toJson());
      h.treatments.table.tombstone(seeded.treatmentId);
      await h.service.syncAll();
      expect(await localRow('treatments', seeded.treatmentId), isNull);
      expect(await localRow('prescriptions', seeded.prescriptionId), isNull);
      expect((await db.query('dose_logs')), isEmpty);
    });
```
Add `import '../helpers/seed.dart';`. In the first test the `failIds` juggling exists only to keep the push from clearing the pending flag; simplify if a cleaner sequence achieves "local pending + remote tombstoned" (e.g. seed and tombstone first, then mark local pending, then `failIds.add` before `syncAll`) — the assertion is what matters.

- [ ] **Step 7: Supabase migration**

`git mv supabase/initial_schema.sql supabase/migrations/20260901000000_initial_schema.sql`, then create `supabase/migrations/20260914000000_tombstones_and_family.sql`:

```sql
-- ============================================================
-- Medora - Tombstones for sync + family RLS fixes (Phase 3)
-- Apply after 20260901000000_initial_schema.sql.
-- ============================================================

-- 1. Tombstone columns. Deletes from the app set deleted_at instead of
--    removing the row, so other devices can pull the deletion. Hard purge of
--    old tombstones is a server-side job (not part of this migration).
ALTER TABLE medications   ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMPTZ;
ALTER TABLE treatments    ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMPTZ;
ALTER TABLE prescriptions ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMPTZ;
ALTER TABLE dose_logs     ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMPTZ;

-- 2. Delta pull indexes (pull asks for updated_at > cursor).
CREATE INDEX IF NOT EXISTS idx_med_updated   ON medications(user_id, updated_at);
CREATE INDEX IF NOT EXISTS idx_treat_updated ON treatments(user_id, updated_at);
CREATE INDEX IF NOT EXISTS idx_presc_updated ON prescriptions(updated_at);
CREATE INDEX IF NOT EXISTS idx_dose_updated  ON dose_logs(updated_at);

-- 3. Tombstone cascade: deleting a parent tombstones its children so every
--    device sees the whole subtree disappear (local FK cascade would handle
--    the first device, but other devices pull children independently).
CREATE OR REPLACE FUNCTION cascade_tombstone_treatment()
RETURNS TRIGGER AS $$
BEGIN
  IF NEW.deleted_at IS NOT NULL AND OLD.deleted_at IS NULL THEN
    UPDATE prescriptions SET deleted_at = NEW.deleted_at
      WHERE treatment_id = NEW.id AND deleted_at IS NULL;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION cascade_tombstone_medication()
RETURNS TRIGGER AS $$
BEGIN
  IF NEW.deleted_at IS NOT NULL AND OLD.deleted_at IS NULL THEN
    UPDATE prescriptions SET deleted_at = NEW.deleted_at
      WHERE medication_id = NEW.id AND deleted_at IS NULL;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION cascade_tombstone_prescription()
RETURNS TRIGGER AS $$
BEGIN
  IF NEW.deleted_at IS NOT NULL AND OLD.deleted_at IS NULL THEN
    UPDATE dose_logs SET deleted_at = NEW.deleted_at
      WHERE prescription_id = NEW.id AND deleted_at IS NULL;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS treatments_tombstone_cascade ON treatments;
CREATE TRIGGER treatments_tombstone_cascade
  AFTER UPDATE OF deleted_at ON treatments
  FOR EACH ROW EXECUTE FUNCTION cascade_tombstone_treatment();

DROP TRIGGER IF EXISTS medications_tombstone_cascade ON medications;
CREATE TRIGGER medications_tombstone_cascade
  AFTER UPDATE OF deleted_at ON medications
  FOR EACH ROW EXECUTE FUNCTION cascade_tombstone_medication();

DROP TRIGGER IF EXISTS prescriptions_tombstone_cascade ON prescriptions;
CREATE TRIGGER prescriptions_tombstone_cascade
  AFTER UPDATE OF deleted_at ON prescriptions
  FOR EACH ROW EXECUTE FUNCTION cascade_tombstone_prescription();

-- 4. Family RLS: members (not only owners) can read their family and update
--    their own membership row; a user may insert their own membership.
DROP POLICY IF EXISTS "families_select" ON families;
CREATE POLICY "families_select" ON families
  FOR SELECT USING (
    owner_id = auth.uid() OR
    EXISTS (SELECT 1 FROM family_members m WHERE m.family_id = id AND m.user_id = auth.uid())
  );

DROP POLICY IF EXISTS "family_members_insert" ON family_members;
CREATE POLICY "family_members_insert" ON family_members
  FOR INSERT WITH CHECK (
    user_id = auth.uid() OR
    EXISTS (SELECT 1 FROM families f WHERE f.id = family_id AND f.owner_id = auth.uid())
  );

CREATE POLICY "family_members_update" ON family_members
  FOR UPDATE USING (
    user_id = auth.uid() OR
    EXISTS (SELECT 1 FROM families f WHERE f.id = family_id AND f.owner_id = auth.uid())
  );

-- 5. Join by invite code without exposing the families table to strangers.
CREATE OR REPLACE FUNCTION join_family(p_invite_code TEXT, p_display_name TEXT)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_family families%ROWTYPE;
  v_member family_members%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'not authenticated';
  END IF;
  SELECT * INTO v_family FROM families WHERE invite_code = p_invite_code;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'invalid invite code';
  END IF;
  SELECT * INTO v_member FROM family_members
    WHERE family_id = v_family.id AND user_id = auth.uid();
  IF NOT FOUND THEN
    INSERT INTO family_members (family_id, user_id, display_name, role)
      VALUES (v_family.id, auth.uid(), p_display_name, 'member')
      RETURNING * INTO v_member;
  END IF;
  RETURN json_build_object('family', row_to_json(v_family), 'member', row_to_json(v_member));
END;
$$;

REVOKE ALL ON FUNCTION join_family(TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION join_family(TEXT, TEXT) TO authenticated;
```

- [ ] **Step 8: Run the three test files, `fvm flutter analyze --fatal-infos`, full suite. Green.**

- [ ] **Step 9: Commit** — `feat(sync): tombstones — soft remote delete, pull applies deletes, Supabase migration`

---

### Task 3: `SyncReport`, per-row error collection, `SyncState.partial`, Settings "last sync" tile

**Files:**
- Create: `lib/services/sync_report.dart`
- Modify: `lib/services/sync_service.dart` (full rewrite below), `lib/presentation/providers/sync_providers.dart` (+`syncLastReportProvider`), `lib/presentation/providers/providers.dart` (`syncStateStreamProvider` refresh also on `partial`), `lib/presentation/screens/settings/settings_screen.dart`, `lib/presentation/widgets/sync_status_chip.dart`, ARB en/de/it (+gen)
- Test: `test/services/sync_service_test.dart` (+group), `test/presentation/widgets/sync_status_chip_test.dart`

**Interfaces:**
- Produces: `SyncFailure(table, id, error)`, `SyncReport` (mutable during a cycle; consumers only read `service.lastReport`), `SyncState.partial`, `SyncService.lastReport`, `Future<SyncReport?> syncAll()` (null when skipped), `syncLastReportProvider`.
- ARB keys (en / de / it):
  - `syncPartial`: "Completed with some errors" / "Mit Fehlern abgeschlossen" / "Completata con alcuni errori"
  - `syncNever`: "Not synced yet" / "Noch nicht synchronisiert" / "Non ancora sincronizzato"
  - `lastSyncSummary` (placeholders `time` String, `pushed` int, `pulled` int, `failed` int): "Last sync {time}: {pushed} sent, {pulled} received, {failed} failed" / "Letzte Synchronisierung {time}: {pushed} gesendet, {pulled} empfangen, {failed} fehlgeschlagen" / "Ultima sincronizzazione {time}: {pushed} inviati, {pulled} ricevuti, {failed} falliti"
  - `syncFailedItems`: "Failed items" / "Fehlgeschlagene Einträge" / "Elementi non riusciti"

- [ ] **Step 1: `lib/services/sync_report.dart`**

```dart
/// Medora - Result of one sync cycle.
library;

class SyncFailure {
  const SyncFailure(this.table, this.id, this.error);
  final String table;
  final String id;
  final String error;

  @override
  String toString() => '$table/$id: $error';
}

/// Counters are filled in while the cycle runs; read it through
/// `SyncService.lastReport` only after the cycle has finished.
class SyncReport {
  SyncReport({required this.startedAt});

  final DateTime startedAt;
  DateTime? finishedAt;
  int pushed = 0;
  int pulled = 0;
  int deleted = 0;
  final List<SyncFailure> failures = [];

  /// Set when the whole cycle aborted (not a per-row error).
  String? fatal;

  bool get hasFailures => failures.isNotEmpty;
  bool get isClean => fatal == null && failures.isEmpty;
}
```

- [ ] **Step 2: Tests (append group to `sync_service_test.dart`)**

```dart
  group('report', () {
    test('counts pushes and pulls and ends clean', () async {
      final h = Harness();
      await MedicationLocalDatasource().upsert(const MedicationModel(id: 'a', name: 'A', quantity: 1), syncStatus: SyncStatus.pendingCreate);
      h.treatments.table.seed(TreatmentModel(id: 't', name: 'T', startDate: DateTime(2026, 3, 1)).toJson());
      final report = await h.service.syncAll();
      expect(report, isNotNull);
      expect(report!.pushed, 1);
      expect(report.pulled, greaterThanOrEqualTo(2)); // 'a' comes back from the fake + 't'
      expect(report.failures, isEmpty);
      expect(report.finishedAt, isNotNull);
      expect(h.service.lastReport, same(report));
      expect(h.service.currentState, SyncState.success);
    });

    test('a failing row is recorded and the state is partial', () async {
      final h = Harness();
      final local = MedicationLocalDatasource();
      await local.upsert(const MedicationModel(id: 'ok', name: 'ok', quantity: 1), syncStatus: SyncStatus.pendingCreate);
      await local.upsert(const MedicationModel(id: 'bad', name: 'bad', quantity: 1), syncStatus: SyncStatus.pendingCreate);
      h.meds.table.failIds.add('bad');
      final report = (await h.service.syncAll())!;
      expect(report.pushed, 1);
      expect(report.failures.map((f) => f.id), ['bad']);
      expect(report.failures.single.table, 'medications');
      expect(h.service.currentState, SyncState.partial);
      expect((await localRow('medications', 'bad'))?['sync_status'], SyncStatus.pendingCreate);
    });

    test('tombstones are counted as deleted', () async {
      final h = Harness();
      h.meds.table.seed(const MedicationModel(id: 'z', name: 'z', quantity: 1).toJson());
      await h.service.syncAll();
      h.meds.table.tombstone('z');
      final report = (await h.service.syncAll())!;
      expect(report.deleted, 1);
    });
  });
```
Add `import 'package:medora/data/models/treatment_model.dart';`.

- [ ] **Step 3: Rewrite `lib/services/sync_service.dart`** (complete file; Task 4 and 5 make small additions to it — they are marked):

```dart
/// Medora - Sync Service
///
/// Bidirectional sync between local SQLite and Supabase.
/// Offline-first; last-write-wins by `updated_at` for locally pending rows;
/// remote tombstones (`deleted_at`) always win and become local hard deletes.
/// Every cycle produces a [SyncReport]; per-row failures never abort the
/// cycle.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:medora/core/supabase_config.dart';
import 'package:medora/data/datasources/dose_log_local_datasource.dart';
import 'package:medora/data/datasources/dose_log_remote_datasource.dart';
import 'package:medora/data/datasources/family_local_datasource.dart';
import 'package:medora/data/datasources/family_remote_datasource.dart';
import 'package:medora/data/datasources/medication_local_datasource.dart';
import 'package:medora/data/datasources/medication_remote_datasource.dart';
import 'package:medora/data/datasources/prescription_local_datasource.dart';
import 'package:medora/data/datasources/prescription_remote_datasource.dart';
import 'package:medora/data/datasources/treatment_local_datasource.dart';
import 'package:medora/data/datasources/treatment_remote_datasource.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/models/dose_log_model.dart';
import 'package:medora/data/models/family_member_model.dart';
import 'package:medora/data/models/family_model.dart';
import 'package:medora/data/models/medication_model.dart';
import 'package:medora/data/models/prescription_model.dart';
import 'package:medora/data/models/treatment_model.dart';
import 'package:medora/services/connectivity_service.dart';
import 'package:medora/services/sync_cursor_store.dart';
import 'package:medora/services/sync_report.dart';

export 'package:medora/services/sync_report.dart';

/// Current state of the sync process.
enum SyncState { idle, syncing, success, partial, error }

class SyncService {
  SyncService({
    required this.medicationLocal,
    required this.medicationRemote,
    required this.treatmentLocal,
    required this.treatmentRemote,
    required this.prescriptionLocal,
    required this.prescriptionRemote,
    required this.doseLogLocal,
    required this.doseLogRemote,
    required this.familyLocal,
    required this.familyRemote,
    SyncCursorStore? cursors,
    bool Function()? isOnline,
    String? Function()? currentUserId,
    Stream<bool>? onlineStream,
    DateTime Function()? now,
  })  : _cursors = cursors ?? SyncCursorStore.inMemory(),
        _isOnline = isOnline ?? (() => ConnectivityService.instance.isOnline),
        _currentUserId = currentUserId ?? (() => SupabaseConfig.currentUserId),
        _onlineStream = onlineStream ?? ConnectivityService.instance.onlineStream,
        _now = now ?? DateTime.now;

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

  final SyncCursorStore _cursors;
  final bool Function() _isOnline;
  final String? Function() _currentUserId;
  final Stream<bool> _onlineStream;
  final DateTime Function() _now;

  /// True when every remote datasource exists (cloud mode, configured build).
  bool get isAvailable =>
      medicationRemote != null &&
      treatmentRemote != null &&
      prescriptionRemote != null &&
      doseLogRemote != null &&
      familyRemote != null;

  final _stateController = StreamController<SyncState>.broadcast();
  Stream<SyncState> get stateStream => _stateController.stream;
  SyncState _currentState = SyncState.idle;
  SyncState get currentState => _currentState;

  SyncReport? _lastReport;
  SyncReport? get lastReport => _lastReport;
  DateTime? get lastSyncTime => _lastReport?.finishedAt;

  // ── Auto-sync on reconnect (Task 6 wires the provider) ─────

  StreamSubscription<bool>? _onlineSub;
  Timer? _reconnectTimer;
  bool _wasOnline = true;

  /// Sync once, [debounce] after connectivity comes back. Idempotent.
  void startAutoSync({Duration debounce = const Duration(seconds: 2)}) {
    if (_onlineSub != null) return;
    _wasOnline = _isOnline();
    _onlineSub = _onlineStream.listen((online) {
      final cameOnline = online && !_wasOnline;
      _wasOnline = online;
      if (!cameOnline) return;
      _reconnectTimer?.cancel();
      _reconnectTimer = Timer(debounce, () => unawaited(syncAll()));
    });
  }

  void stopAutoSync() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _onlineSub?.cancel();
    _onlineSub = null;
  }

  // ── Entry points ───────────────────────────────────────────

  /// Push pending local changes, then pull remote changes. Returns the report,
  /// or null when the cycle was skipped (local-only, offline, signed out, or
  /// already syncing).
  Future<SyncReport?> syncAll() => _run('sync', (report) async {
        await _pushPendingChanges(report);
        await _pullAll(report, force: false);
      });

  /// Push ALL local rows regardless of sync_status.
  Future<SyncReport?> forcePush() =>
      _run('force push', (report) => _pushPendingChanges(report, forceAll: true));

  /// Wipe local rows and pull everything again.
  Future<SyncReport?> forcePull() => _run('force pull', (report) async {
        await _cursors.clear();
        await AppDatabase.instance.clearAllData();
        await _pullAll(report, force: true);
      });

  Future<SyncReport?> _run(String label, Future<void> Function(SyncReport) body) async {
    if (!isAvailable) {
      debugPrint('Sync: $label skipped (local-only mode)');
      return null;
    }
    if (_currentState == SyncState.syncing) return null;
    if (!_isOnline()) {
      debugPrint('Sync: $label skipped (offline)');
      return null;
    }
    if (_currentUserId() == null) {
      debugPrint('Sync: $label skipped (unauthenticated)');
      return null;
    }

    _setState(SyncState.syncing);
    final report = SyncReport(startedAt: _now());
    try {
      await body(report);
    } catch (e, st) {
      debugPrint('Sync: fatal error during $label: $e\n$st');
      report.fatal = '$e';
    }
    report.finishedAt = _now();
    _lastReport = report;
    debugPrint('Sync: $label done — pushed ${report.pushed}, pulled ${report.pulled}, '
        'deleted ${report.deleted}, failed ${report.failures.length}');
    _setState(report.fatal != null
        ? SyncState.error
        : report.hasFailures
            ? SyncState.partial
            : SyncState.success);
    _returnToIdleLater();
    return report;
  }

  void _returnToIdleLater() {
    Future<void>.delayed(const Duration(seconds: 2), () {
      if (_currentState == SyncState.success || _currentState == SyncState.partial) {
        _setState(SyncState.idle);
      }
    });
  }

  // ── Push ───────────────────────────────────────────────────

  Future<void> _pushPendingChanges(SyncReport report, {bool forceAll = false}) async {
    final db = await AppDatabase.instance.database;
    final userId = _currentUserId();
    if (userId == null) return;

    final where = forceAll ? null : 'sync_status != ?';
    final whereArgs = forceAll ? null : [SyncStatus.synced];

    // FK order: Families -> Medications -> Treatments -> Prescriptions -> DoseLogs
    await _pushBatch('families', report, where, whereArgs, (row) async {
      if (row['sync_status'] == SyncStatus.pendingDelete) return false; // Task 5
      final model = FamilyModel.fromJson(row);
      await familyRemote!.upsertFamily(model);
      await db.update('families', {'sync_status': SyncStatus.synced},
          where: 'id = ?', whereArgs: [model.id]);
      return true;
    });

    // Task 5 inserts the family_members batch here.

    await _pushBatch('medications', report, where, whereArgs, (row) async {
      final model = MedicationModel.fromLocalMap({...row, 'user_id': userId});
      if (row['sync_status'] == SyncStatus.pendingDelete) {
        await medicationRemote!.deleteMedication(model.id);
        await medicationLocal.hardDelete(model.id);
      } else {
        await medicationRemote!.upsertMedication(model);
        await medicationLocal.markSynced(model.id);
      }
      return true;
    });

    await _pushBatch('treatments', report, where, whereArgs, (row) async {
      final model = TreatmentModel.fromLocalMap({...row, 'user_id': userId});
      if (row['sync_status'] == SyncStatus.pendingDelete) {
        await treatmentRemote!.deleteTreatment(model.id);
        await treatmentLocal.hardDelete(model.id);
      } else {
        await treatmentRemote!.upsertTreatment(model);
        await treatmentLocal.markSynced(model.id);
      }
      return true;
    });

    await _pushBatch('prescriptions', report, where, whereArgs, (row) async {
      final model = PrescriptionModel.fromLocalMap(row);
      if (row['sync_status'] == SyncStatus.pendingDelete) {
        await prescriptionRemote!.deletePrescription(model.id);
        await prescriptionLocal.hardDelete(model.id);
      } else {
        await prescriptionRemote!.upsertPrescription(model);
        await prescriptionLocal.markSynced(model.id);
      }
      return true;
    });

    await _pushBatch('dose_logs', report, where, whereArgs, (row) async {
      final model = DoseLogModel.fromLocalMap(row);
      if (row['sync_status'] == SyncStatus.pendingDelete) {
        await doseLogRemote!.deleteDoseLog(model.id);
        await doseLogLocal.hardDelete(model.id);
      } else {
        await doseLogRemote!.upsertDoseLog(model);
        await doseLogLocal.markSynced(model.id);
      }
      return true;
    });
  }

  /// Runs [processRow] per row; a thrown error becomes a [SyncFailure] and the
  /// batch continues. [processRow] returns false when the row was skipped
  /// (not counted).
  Future<void> _pushBatch(
    String table,
    SyncReport report,
    String? where,
    List<dynamic>? whereArgs,
    Future<bool> Function(Map<String, dynamic>) processRow,
  ) async {
    final db = await AppDatabase.instance.database;
    final rows = await db.query(table, where: where, whereArgs: whereArgs);
    for (var i = 0; i < rows.length; i++) {
      final row = rows[i];
      try {
        if (await processRow(row)) report.pushed++;
      } catch (e) {
        report.failures.add(SyncFailure(table, '${row['id']}', 'push: $e'));
      }
      // Yield to the UI every few rows.
      if (i % 5 == 2) await Future<void>.delayed(Duration.zero);
    }
  }

  // ── Pull ───────────────────────────────────────────────────

  Future<void> _pullAll(SyncReport report, {required bool force}) async {
    await _pullFamilies(report);
    await Future.wait([
      _pullTable<MedicationModel>(
        table: 'medications',
        report: report,
        force: force,
        fetch: (since) => medicationRemote!.getMedicationsSince(since),
        idOf: (m) => m.id,
        updatedAtOf: (m) => m.updatedAt,
        deletedAtOf: (m) => m.deletedAt,
        delete: medicationLocal.hardDelete,
        upsert: (m) => _safeUpsertMedication(m, force: force),
      ),
      _pullTable<TreatmentModel>(
        table: 'treatments',
        report: report,
        force: force,
        fetch: (since) => treatmentRemote!.getTreatmentsSince(since),
        idOf: (t) => t.id,
        updatedAtOf: (t) => t.updatedAt,
        deletedAtOf: (t) => t.deletedAt,
        delete: treatmentLocal.hardDelete,
        upsert: (t) => _safeUpsertTreatment(t, force: force),
      ),
    ]);
    await _pullTable<PrescriptionModel>(
      table: 'prescriptions',
      report: report,
      force: force,
      fetch: (since) => prescriptionRemote!.getPrescriptionsSince(since),
      idOf: (p) => p.id,
      updatedAtOf: (p) => p.updatedAt,
      deletedAtOf: (p) => p.deletedAt,
      delete: prescriptionLocal.hardDelete,
      upsert: (p) => _safeUpsertPrescription(p, force: force),
    );
    await _pullTable<DoseLogModel>(
      table: 'dose_logs',
      report: report,
      force: force,
      fetch: (since) => doseLogRemote!.getDoseLogsSince(since),
      idOf: (d) => d.id,
      updatedAtOf: (d) => d.updatedAt,
      deletedAtOf: (d) => d.deletedAt,
      delete: doseLogLocal.hardDelete,
      upsert: (d) => force
          ? doseLogLocal.upsert(d, syncStatus: SyncStatus.synced)
          : doseLogLocal.upsertIfSynced(d),
    );
  }

  /// Delta pull for one table (Task 4 switches [fetch] from full to `since`;
  /// in this task pass `since` through — the cursor is simply null until then).
  Future<void> _pullTable<T>({
    required String table,
    required SyncReport report,
    required bool force,
    required Future<List<T>> Function(DateTime? since) fetch,
    required String Function(T) idOf,
    required DateTime? Function(T) updatedAtOf,
    required DateTime? Function(T) deletedAtOf,
    required Future<void> Function(String id) delete,
    required Future<void> Function(T row) upsert,
  }) async {
    final since = force ? null : await _cursors.lastPullAt(table);
    final List<T> rows;
    try {
      rows = await fetch(since);
    } catch (e) {
      report.failures.add(SyncFailure(table, '*', 'pull: $e'));
      return;
    }
    DateTime? newest;
    for (final row in rows) {
      try {
        if (deletedAtOf(row) != null) {
          await delete(idOf(row));
          report.deleted++;
        } else {
          await upsert(row);
        }
        report.pulled++;
      } catch (e) {
        report.failures.add(SyncFailure(table, idOf(row), 'apply: $e'));
      }
      final u = updatedAtOf(row)?.toUtc();
      if (u != null && (newest == null || u.isAfter(newest))) newest = u;
    }
    if (newest != null) {
      await _cursors.setLastPullAt(table, newest.subtract(const Duration(seconds: 1)));
    }
  }

  Future<void> _pullFamilies(SyncReport report) async {
    try {
      final membership = await familyRemote!.getCurrentMembership();
      if (membership == null) return;
      final family = await familyRemote!.getFamilyById(membership.familyId);
      if (family == null) return;
      await familyLocal.upsertFamily(family, syncStatus: SyncStatus.synced);
      report.pulled++;
      final members = await familyRemote!.getMembers(family.id);
      for (final m in members) {
        await familyLocal.upsertMember(m, syncStatus: SyncStatus.synced);
        report.pulled++;
      }
      // Task 5: remove local synced members missing remotely.
    } catch (e) {
      report.failures.add(SyncFailure('families', '*', 'pull: $e'));
    }
  }

  // ── Merge helpers (last-write-wins for locally pending rows) ──

  Future<void> _safeUpsertMedication(MedicationModel m, {bool force = false}) async {
    if (!force && await _localPendingIsNewer('medications', m.id, m.updatedAt)) return;
    await medicationLocal.upsert(m, syncStatus: SyncStatus.synced);
  }

  Future<void> _safeUpsertTreatment(TreatmentModel t, {bool force = false}) async {
    if (!force && await _localPendingIsNewer('treatments', t.id, t.updatedAt)) return;
    await treatmentLocal.upsert(t, syncStatus: SyncStatus.synced);
  }

  Future<void> _safeUpsertPrescription(PrescriptionModel p, {bool force = false}) async {
    if (!force && await _localPendingIsNewer('prescriptions', p.id, p.updatedAt)) return;
    await prescriptionLocal.upsert(p, syncStatus: SyncStatus.synced);
  }

  /// True when the local row has unpushed changes that are at least as new as
  /// the remote row (so the remote row must not overwrite it).
  Future<bool> _localPendingIsNewer(String table, String id, DateTime? remoteUpdatedAt) async {
    final db = await AppDatabase.instance.database;
    final rows = await db.query(table,
        columns: ['updated_at'],
        where: 'id = ? AND sync_status != ?',
        whereArgs: [id, SyncStatus.synced]);
    if (rows.isEmpty) return false;
    final localRaw = rows.first['updated_at'] as String?;
    final local = localRaw == null ? null : DateTime.tryParse(localRaw);
    if (local == null || remoteUpdatedAt == null) return true; // keep local when unsure
    return !remoteUpdatedAt.toUtc().isAfter(local.toUtc());
  }

  void _setState(SyncState state) {
    if (_stateController.isClosed) return;
    _currentState = state;
    _stateController.add(state);
  }

  void dispose() {
    stopAutoSync();
    if (!_stateController.isClosed) _stateController.close();
  }

  @visibleForTesting
  void debugSetStateForTest(SyncState state) => _setState(state);
}
```

Notes: `_localPendingIsNewer` keeps the old semantics (local pending only overwritten by strictly newer remote) with one fix: previously a missing timestamp kept local; keep that. The `FamilyMemberModel` import is used by Task 5 — if the analyzer flags it unused in this task, remove it and re-add in Task 5. `getXSince(null)` returns everything, so behaviour equals the old full pull until Task 4 starts persisting cursors (it already does here, via `_cursors` — with `SyncCursorStore(prefs)` wired in Task 1 the delta is effectively live after this task; Task 4 adds the tests and cursor invalidation rules).

- [ ] **Step 4: Providers.** In `sync_providers.dart` add (import `providers.dart`? No — `providers.dart` imports `sync_providers.dart`; to avoid a cycle put `syncLastReportProvider` in `providers.dart` next to `syncStateStreamProvider`):
```dart
/// The report of the most recent sync cycle; re-evaluated on every state change.
final syncLastReportProvider = Provider<SyncReport?>((ref) {
  ref.watch(syncStateStreamProvider);
  return ref.watch(syncServiceProvider).lastReport;
});
```
In `syncStateStreamProvider` refresh the lists on `SyncState.success` **or** `SyncState.partial`.

- [ ] **Step 5: UI.** `settings_screen.dart`: make the three `switch`es exhaustive with `SyncState.partial => Icons.warning_amber_rounded` / `context.medora.warning` / `l10n.syncPartial`. Under the "Sync now" tile add:
```dart
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.history),
                  title: Text(_lastSyncText(context, l10n, lastReport)),
                  trailing: (lastReport?.hasFailures ?? false) ? const Icon(Icons.chevron_right) : null,
                  onTap: (lastReport?.hasFailures ?? false)
                      ? () => _showSyncFailures(context, l10n, lastReport!)
                      : null,
                ),
```
with `final lastReport = ref.watch(syncLastReportProvider);` in `build`, and:
```dart
  String _lastSyncText(BuildContext context, AppLocalizations l10n, SyncReport? r) {
    final finished = r?.finishedAt;
    if (r == null || finished == null) return l10n.syncNever;
    final time = DateFormat.yMd(Localizations.localeOf(context).toString()).add_Hm().format(finished);
    return l10n.lastSyncSummary(time, r.pushed, r.pulled, r.failures.length);
  }

  void _showSyncFailures(BuildContext context, AppLocalizations l10n, SyncReport r) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.syncFailedItems),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView(
            shrinkWrap: true,
            children: [for (final f in r.failures) ListTile(dense: true, title: Text('${f.table} · ${f.id}'), subtitle: Text(f.error))],
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: Text(l10n.ok))],
      ),
    );
  }
```
(`l10n.ok` — verify the key exists; if not use `l10n.close` or add `ok` en/de/it "OK"/"OK"/"OK".) `sync_status_chip.dart`: `partial` → `Icons.warning_amber_rounded` in `context.medora.warning`, label `l10n.syncPartial`; `error` unchanged.

- [ ] **Step 6: Chip widget test** `test/presentation/widgets/sync_status_chip_test.dart`:
```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/presentation/providers/app_mode_provider.dart';
import 'package:medora/presentation/providers/providers.dart';
import 'package:medora/presentation/providers/settings_providers.dart';
import 'package:medora/presentation/widgets/sync_status_chip.dart';
import 'package:medora/services/sync_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/pump_app.dart';

class _CloudMode extends AppModeNotifier {
  @override
  AppMode build() => AppMode.cloud;
}

void main() {
  Future<List<Override>> overrides(SyncState state) async => [
        sharedPreferencesProvider.overrideWithValue(await SharedPreferences.getInstance()),
        appModeProvider.overrideWith(_CloudMode.new),
        syncStateStreamProvider.overrideWith((ref) => Stream.value(state)),
      ];

  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('partial state shows the warning label', (tester) async {
    await pumpMedoraApp(tester, const Scaffold(body: SyncStatusChip()), overrides: await overrides(SyncState.partial));
    await tester.pumpAndSettle();
    expect(find.text('Completed with some errors'), findsOneWidget);
    expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
  });

  testWidgets('idle state offers Sync Now', (tester) async {
    await pumpMedoraApp(tester, const Scaffold(body: SyncStatusChip()), overrides: await overrides(SyncState.idle));
    await tester.pumpAndSettle();
    expect(find.text('Sync Now'), findsOneWidget);
  });
}
```

- [ ] **Step 7: ARB + gen-l10n; run tests; analyze; full suite. Green.**

- [ ] **Step 8: Commit** — `feat(sync): SyncReport with per-row failures, partial state, last-sync tile in Settings`

---

### Task 4: Delta pull — cursors persisted, overlap, invalidation on force pull

**Files:**
- Modify: `lib/services/local_data_wiper.dart` (clear cursor keys), `lib/services/sync_service.dart` (none expected beyond Task 3 — verify `forcePull` clears cursors)
- Test: `test/services/sync_service_test.dart` (+group), `test/services/local_data_wiper_test.dart` (+test)

**Interfaces:**
- Consumes: `FakeRemoteTable.sinceCalls`, `SyncCursorStore`.

- [ ] **Step 1: Tests**

```dart
  group('delta pull', () {
    test('first pull is full, second pull asks since the newest updated_at minus 1s', () async {
      final h = Harness();
      h.meds.table.seed(const MedicationModel(id: 'a', name: 'A', quantity: 1).toJson());
      await h.service.syncAll();
      expect(h.meds.table.sinceCalls, [null]);
      final cursor = await h.cursors.lastPullAt('medications');
      expect(cursor, h.clock.now().toUtc().subtract(const Duration(seconds: 1)));

      h.clock.advance(const Duration(minutes: 5));
      h.meds.table.seed(const MedicationModel(id: 'b', name: 'B', quantity: 1).toJson());
      h.service.debugSetStateForTest(SyncState.idle);
      final report = (await h.service.syncAll())!;
      expect(h.meds.table.sinceCalls.last, cursor);
      // Only 'b' is newer than the cursor ('a' sits exactly 1 s inside the overlap window
      // only if it was stamped within that second — here it is 5 min old).
      expect(report.pulled, 1);
      expect((await localRow('medications', 'b'))?['name'], 'B');
    });

    test('force pull clears cursors and pulls everything again', () async {
      final h = Harness();
      h.meds.table.seed(const MedicationModel(id: 'a', name: 'A', quantity: 1).toJson());
      await h.service.syncAll();
      h.service.debugSetStateForTest(SyncState.idle);
      await h.service.forcePull();
      expect(h.meds.table.sinceCalls.last, isNull);
      expect((await localRow('medications', 'a'))?['name'], 'A');
    });

    test('a pull error keeps the cursor unchanged', () async {
      final h = Harness();
      h.meds.table.seed(const MedicationModel(id: 'a', name: 'A', quantity: 1).toJson());
      await h.service.syncAll();
      final before = await h.cursors.lastPullAt('medications');
      h.service.debugSetStateForTest(SyncState.idle);
      // Make apply fail for a new row: seed a row whose JSON breaks fromJson.
      h.meds.table.rows['broken'] = {'id': 'broken', 'updated_at': h.clock.now().add(const Duration(minutes: 1)).toUtc().toIso8601String()};
      final report = (await h.service.syncAll())!;
      expect(report.failures.where((f) => f.table == 'medications'), isNotEmpty);
      expect(await h.cursors.lastPullAt('medications'), before);
    });
  });
```
Note on the third test: `MedicationModel.fromJson` throws inside `fetch` (mapping happens in the fake before rows reach `_pullTable`), so the failure is recorded as `pull: …` with id `*` and the cursor is untouched — that is the documented behaviour: a fetch failure never advances the cursor. If the fake maps lazily so the error surfaces per row instead, adjust the expectation to `apply:` — either way the cursor must not move past a failed row. **Implement the stricter rule:** in `_pullTable`, only advance the cursor when the loop recorded no `apply` failure for that table (track a `bool anyFailure`).

The `syncAll` state guard needs `debugSetStateForTest(SyncState.idle)` between cycles because `_returnToIdleLater` waits 2 s of real time; keep that helper.

`local_data_wiper_test.dart`: add a test that `wipe()` removes `sync.last_pull_at.*` keys from prefs (seed one via `SharedPreferences.setMockInitialValues({'sync.last_pull_at.medications': '2026-01-01T00:00:00.000Z', 'theme_mode': 'dark'})`, wipe, expect the cursor key gone and `theme_mode` kept).

- [ ] **Step 2: Implement** the `anyFailure` rule in `_pullTable`; in `LocalDataWiper.wipe()` add, after `_prefs.reload()`:
```dart
    for (final key in _prefs.getKeys().where((k) => k.startsWith(SyncCursorStore.keyPrefix)).toList()) {
      await _prefs.remove(key);
    }
```
(import `package:medora/services/sync_cursor_store.dart`).

- [ ] **Step 3: Run tests, analyze, full suite. Commit** — `feat(sync): delta pull with persisted per-table cursors`

---

### Task 5: Family sync — push members, pending leave/remove, stale member cleanup, RPC join

**Files:**
- Modify: `lib/data/datasources/family_local_datasource.dart`, `lib/data/repositories/family_repository_impl.dart`, `lib/services/sync_service.dart`
- Test: `test/data/repositories/family_repository_test.dart` (new), `test/services/sync_service_test.dart` (+group)

**Interfaces:**
- Produces on `FamilyLocalDatasource`: `markMemberDeleted(String id)`, `hardDeleteMember(String id)`, `markFamilyDeleted(String id)`, `deleteMembersNotIn(String familyId, Set<String> keepIds)` (deletes only rows with `sync_status = 'synced'`).
- Repository: `removeMember` and `leaveFamily` become pending operations (local mark + background push when online; the next `syncAll` pushes otherwise); `joinFamily` uses `remote.joinFamily(...)`.

- [ ] **Step 1: Repository test** `test/data/repositories/family_repository_test.dart`:
```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/data/datasources/family_local_datasource.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/models/family_member_model.dart';
import 'package:medora/data/models/family_model.dart';
import 'package:medora/data/repositories/family_repository_impl.dart';

import '../../helpers/fake_remotes.dart';
import '../../helpers/test_database.dart';

void main() {
  setUp(setUpTestDatabase);
  tearDown(tearDownTestDatabase);

  Future<void> seedLocalFamily(FamilyLocalDatasource local) async {
    await local.upsertFamily(const FamilyModel(id: 'f1', name: 'Smith', inviteCode: 'ABC123', ownerId: 'owner'), syncStatus: SyncStatus.synced);
    await local.upsertMember(const FamilyMemberModel(id: 'me', familyId: 'f1', userId: 'user-a', role: 'member'), syncStatus: SyncStatus.synced);
    await local.upsertMember(const FamilyMemberModel(id: 'other', familyId: 'f1', userId: 'user-b', role: 'member'), syncStatus: SyncStatus.synced);
  }

  test('removeMember marks the row pending_delete while offline', () async {
    final local = FamilyLocalDatasource();
    await seedLocalFamily(local);
    final repo = FamilyRepositoryImpl(localDatasource: local, remoteDatasource: FakeFamilyRemote(DateTime.now), isOnline: () => false);
    expect((await repo.removeMember('other')).isSuccess, isTrue);
    expect((await local.getMembers('f1')).map((m) => m.id), ['me']);
    final db = await AppDatabase.instance.database;
    final row = (await db.query('family_members', where: 'id = ?', whereArgs: ['other'])).single;
    expect(row['sync_status'], SyncStatus.pendingDelete);
  });

  test('leaveFamily marks membership and family pending_delete; getCurrentFamily is null', () async {
    final local = FamilyLocalDatasource();
    await seedLocalFamily(local);
    final repo = FamilyRepositoryImpl(localDatasource: local, remoteDatasource: FakeFamilyRemote(DateTime.now), isOnline: () => false);
    await repo.leaveFamily('f1');
    expect((await repo.getCurrentFamily()).dataOrNull, isNull);
    final db = await AppDatabase.instance.database;
    expect((await db.query('families', where: 'id = ?', whereArgs: ['f1'])).single['sync_status'], SyncStatus.pendingDelete);
  });

  test('joinFamily goes through the RPC and stores family + member locally', () async {
    final local = FamilyLocalDatasource();
    final remote = FakeFamilyRemote(DateTime.now, currentUserId: 'user-a');
    remote.families.seed(const FamilyModel(id: 'f9', name: 'Rossi', inviteCode: 'JOINME', ownerId: 'owner').toJson());
    final repo = FamilyRepositoryImpl(localDatasource: local, remoteDatasource: remote, isOnline: () => true);
    final result = await repo.joinFamily('JOINME', 'Ben');
    expect(result.isSuccess, isTrue, reason: result.toString());
    expect((await local.getFirstFamily())?.id, 'f9');
    expect((await local.getCurrentMembership())?.userId, 'user-a');
  });
}
```
`FamilyRepositoryImpl` gains an optional `bool Function()? isOnline` constructor seam (default `ConnectivityService.instance.isOnline`) used in place of the direct singleton reads. Local-only mode: with `remoteDatasource == null`, `removeMember`/`leaveFamily` hard-delete locally as before (no pending rows to push).

- [ ] **Step 2: Sync test (append group)**

```dart
  group('family sync', () {
    test('pushes pending members and removes pending_delete members remotely', () async {
      final h = Harness();
      final local = FamilyLocalDatasource();
      await local.upsertFamily(const FamilyModel(id: 'f1', name: 'S', inviteCode: 'X', ownerId: 'user-a'), syncStatus: SyncStatus.pendingCreate);
      await local.upsertMember(const FamilyMemberModel(id: 'me', familyId: 'f1', userId: 'user-a', role: 'owner'), syncStatus: SyncStatus.pendingCreate);
      await local.upsertMember(const FamilyMemberModel(id: 'gone', familyId: 'f1', userId: 'user-b', role: 'member'), syncStatus: SyncStatus.synced);
      h.family.members.seed(const FamilyMemberModel(id: 'gone', familyId: 'f1', userId: 'user-b', role: 'member').toJson());
      await local.markMemberDeleted('gone');
      await h.service.syncAll();
      expect(h.family.families.rows['f1'], isNotNull);
      expect(h.family.members.rows['me'], isNotNull);
      expect(h.family.members.rows['gone'], isNull);
      expect(await localRow('family_members', 'gone'), isNull);
    });

    test('pull removes local synced members that no longer exist remotely', () async {
      final h = Harness();
      h.family.families.seed(const FamilyModel(id: 'f1', name: 'S', inviteCode: 'X', ownerId: 'user-a').toJson());
      h.family.members.seed(const FamilyMemberModel(id: 'me', familyId: 'f1', userId: 'user-a', role: 'owner').toJson());
      await FamilyLocalDatasource().upsertMember(const FamilyMemberModel(id: 'stale', familyId: 'f1', userId: 'user-z', role: 'member'), syncStatus: SyncStatus.synced);
      await FamilyLocalDatasource().upsertFamily(const FamilyModel(id: 'f1', name: 'S', inviteCode: 'X', ownerId: 'user-a'), syncStatus: SyncStatus.synced);
      await h.service.syncAll();
      expect(await localRow('family_members', 'stale'), isNull);
      expect(await localRow('family_members', 'me'), isNotNull);
    });

    test('a pending_delete family is dropped locally after its members are pushed', () async {
      final h = Harness();
      final local = FamilyLocalDatasource();
      await local.upsertFamily(const FamilyModel(id: 'f1', name: 'S', inviteCode: 'X', ownerId: 'owner'), syncStatus: SyncStatus.synced);
      await local.upsertMember(const FamilyMemberModel(id: 'me', familyId: 'f1', userId: 'user-a', role: 'member'), syncStatus: SyncStatus.synced);
      h.family.members.seed(const FamilyMemberModel(id: 'me', familyId: 'f1', userId: 'user-a', role: 'member').toJson());
      await local.markMemberDeleted('me');
      await local.markFamilyDeleted('f1');
      await h.service.syncAll();
      expect(h.family.members.rows['me'], isNull);
      expect(await localRow('families', 'f1'), isNull);
      expect(await localRow('family_members', 'me'), isNull);
    });
  });
```
Add imports for `FamilyModel`, `FamilyMemberModel`, `FamilyLocalDatasource`.

- [ ] **Step 3: Implement**

`FamilyLocalDatasource` additions:
```dart
  Future<void> markMemberDeleted(String memberId) async {
    final db = await _db;
    await db.update('family_members', {'sync_status': SyncStatus.pendingDelete},
        where: 'id = ?', whereArgs: [memberId]);
  }

  Future<void> hardDeleteMember(String memberId) async {
    final db = await _db;
    await db.delete('family_members', where: 'id = ?', whereArgs: [memberId]);
  }

  Future<void> markFamilyDeleted(String familyId) async {
    final db = await _db;
    await db.update('families', {'sync_status': SyncStatus.pendingDelete},
        where: 'id = ?', whereArgs: [familyId]);
  }

  /// Removes synced members of [familyId] whose ids are not in [keepIds]
  /// (pending rows are left for the push phase).
  Future<void> deleteMembersNotIn(String familyId, Set<String> keepIds) async {
    final db = await _db;
    final rows = await db.query('family_members',
        columns: ['id'], where: 'family_id = ? AND sync_status = ?', whereArgs: [familyId, SyncStatus.synced]);
    for (final row in rows) {
      final id = row['id'] as String;
      if (!keepIds.contains(id)) {
        await db.delete('family_members', where: 'id = ?', whereArgs: [id]);
      }
    }
  }
```
`removeMember` keeps its hard-delete behaviour (used by the local-only path).

`FamilyRepositoryImpl`:
```dart
  FamilyRepositoryImpl({
    required this.localDatasource,
    required this.remoteDatasource,
    bool Function()? isOnline,
  }) : _isOnline = isOnline ?? (() => ConnectivityService.instance.isOnline);

  final bool Function() _isOnline;
```
- `joinFamily`: replace the `getFamilyByInviteCode` + `addMember` sequence with `final joined = await remote.joinFamily(inviteCode, displayName);` then upsert `joined.family` and `joined.member` locally as synced.
- `leaveFamily`:
```dart
      final membership = await localDatasource.getCurrentMembership();
      final remote = remoteDatasource;
      if (remote == null) {
        if (membership != null) await localDatasource.removeMember(membership.id);
        await localDatasource.deleteFamily(familyId);
        return const Result.success(null);
      }
      if (membership != null) await localDatasource.markMemberDeleted(membership.id);
      await localDatasource.markFamilyDeleted(familyId);
      if (_isOnline() && membership != null) {
        try {
          await remote.removeMember(membership.id);
          await localDatasource.hardDeleteMember(membership.id);
          await localDatasource.deleteFamily(familyId);
        } catch (_) {
          // Left pending; the next sync pushes it.
        }
      }
      return const Result.success(null);
```
- `removeMember`: same pattern (`markMemberDeleted` → if online try `remote.removeMember` then `hardDeleteMember`; local-only → `removeMember`).
- Replace the other `ConnectivityService.instance.isOnline` reads in this file with `_isOnline()`.

`SyncService._pushPendingChanges`: after the families batch insert
```dart
    await _pushBatch('family_members', report, where, whereArgs, (row) async {
      final model = FamilyMemberModel.fromJson(row);
      if (row['sync_status'] == SyncStatus.pendingDelete) {
        await familyRemote!.removeMember(model.id);
        await familyLocal.hardDeleteMember(model.id);
      } else {
        await familyRemote!.upsertMember(model);
        await db.update('family_members', {'sync_status': SyncStatus.synced},
            where: 'id = ?', whereArgs: [model.id]);
      }
      return true;
    });

    // Families the user left: drop locally once their member rows are gone.
    await _pushBatch('families', report, 'sync_status = ?', [SyncStatus.pendingDelete], (row) async {
      final id = row['id'] as String;
      final remaining = await db.query('family_members', columns: ['id'],
          where: 'family_id = ? AND sync_status = ?', whereArgs: [id, SyncStatus.pendingDelete]);
      if (remaining.isNotEmpty) return false; // member removal still pending
      await familyLocal.deleteFamily(id);
      return true;
    });
```
`FamilyMemberModel.fromJson(row)` must accept the local row (`joined_at` ISO string) — verify. In `_pullFamilies`, after upserting members: `await familyLocal.deleteMembersNotIn(family.id, members.map((m) => m.id).toSet());`. Also, when `getCurrentMembership()` returns null remotely but a local synced family exists, leave local data alone (the user may be offline-joined; out of scope).

- [ ] **Step 4: Run tests, analyze, full suite. Commit** — `feat(sync): family members push/pull, pending leave/remove, RPC join`

---

### Task 6: Auto-sync on reconnect + "turn on cloud sync" upload marking + provider wiring

**Files:**
- Create: `lib/services/local_upload_marker.dart`, `test/services/local_upload_marker_test.dart`
- Modify: `lib/presentation/providers/sync_providers.dart` (+`localUploadMarkerProvider`), `lib/presentation/providers/app_mode_provider.dart` (`set(cloud)` marks for upload), `lib/presentation/providers/providers.dart` (`syncServiceProvider` starts/stops auto-sync)
- Test: `test/services/sync_service_test.dart` (+group), `test/presentation/providers/app_mode_provider_test.dart` (new)

**Interfaces:**
- Produces: `LocalUploadMarker({required AppDatabase database, required SyncCursorStore cursors})` with `Future<int> markAllForUpload()` returning the number of rows flipped from `synced` to `pending_update` across `families`, `family_members`, `medications`, `treatments`, `prescriptions`, `dose_logs`, and clearing cursors.

- [ ] **Step 1: Tests**

`test/services/local_upload_marker_test.dart`:
```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/services/local_upload_marker.dart';
import 'package:medora/services/sync_cursor_store.dart';

import '../helpers/seed.dart';
import '../helpers/test_database.dart';

void main() {
  setUp(setUpTestDatabase);
  tearDown(tearDownTestDatabase);

  test('flips every synced row to pending_update and clears cursors', () async {
    final db = await AppDatabase.instance.database;
    final seeded = await seedPrescription(db);
    await seedDoseLog(db, seeded.prescriptionId, DateTime(2026, 3, 1, 8));
    final cursors = SyncCursorStore.inMemory();
    await cursors.setLastPullAt('medications', DateTime.utc(2026));

    final marker = LocalUploadMarker(database: AppDatabase.instance, cursors: cursors);
    final n = await marker.markAllForUpload();

    expect(n, 4);
    for (final table in ['medications', 'treatments', 'prescriptions', 'dose_logs']) {
      final rows = await db.query(table, columns: ['sync_status']);
      expect(rows.map((r) => r['sync_status']), everyElement(SyncStatus.pendingUpdate), reason: table);
    }
    expect(await cursors.lastPullAt('medications'), isNull);
  });

  test('pending_delete rows are left alone', () async {
    final db = await AppDatabase.instance.database;
    final seeded = await seedPrescription(db);
    await db.update('medications', {'sync_status': SyncStatus.pendingDelete}, where: 'id = ?', whereArgs: [seeded.medicationId]);
    final marker = LocalUploadMarker(database: AppDatabase.instance, cursors: SyncCursorStore.inMemory());
    await marker.markAllForUpload();
    final row = (await db.query('medications', where: 'id = ?', whereArgs: [seeded.medicationId])).single;
    expect(row['sync_status'], SyncStatus.pendingDelete);
  });
}
```

Auto-sync group in `sync_service_test.dart` — the harness needs a controllable stream; add an optional `StreamController<bool>? online` to `Harness` and pass `onlineStream: online?.stream ?? const Stream.empty()`:
```dart
  group('auto-sync', () {
    test('syncs once after an offline→online transition, not on repeated online events', () async {
      final controller = StreamController<bool>.broadcast();
      final h = Harness(online: controller);
      h.meds.table.seed(const MedicationModel(id: 'a', name: 'A', quantity: 1).toJson());
      h.service.startAutoSync(debounce: Duration.zero);

      controller.add(true); // already online → no transition
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(h.meds.table.sinceCalls, isEmpty);

      h.online = false;
      controller.add(false);
      h.online = true;
      controller.add(true);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(h.meds.table.sinceCalls.length, 1);

      h.service.stopAutoSync();
      h.online = false;
      controller.add(false);
      h.online = true;
      controller.add(true);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(h.meds.table.sinceCalls.length, 1);
      await controller.close();
    });
  });
```
Add `import 'dart:async';`.

`test/presentation/providers/app_mode_provider_test.dart`:
```dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/presentation/providers/app_mode_provider.dart';
import 'package:medora/presentation/providers/settings_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/seed.dart';
import '../../helpers/test_database.dart';

void main() {
  setUp(() async {
    await setUpTestDatabase();
    SharedPreferences.setMockInitialValues({'sync.last_pull_at.medications': '2026-01-01T00:00:00.000Z'});
  });
  tearDown(tearDownTestDatabase);

  test('switching to cloud marks local rows for upload and clears cursors', () async {
    final db = await AppDatabase.instance.database;
    await seedPrescription(db);
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(overrides: [sharedPreferencesProvider.overrideWithValue(prefs)]);
    addTearDown(container.dispose);

    expect(container.read(appModeProvider), AppMode.localOnly);
    await container.read(appModeProvider.notifier).set(AppMode.cloud);

    expect(container.read(appModeProvider), AppMode.cloud);
    expect(prefs.getString('app_mode'), 'cloud');
    expect(prefs.getString('sync.last_pull_at.medications'), isNull);
    final rows = await db.query('medications', columns: ['sync_status']);
    expect(rows.single['sync_status'], SyncStatus.pendingUpdate);
  });
}
```

- [ ] **Step 2: Implement**

`lib/services/local_upload_marker.dart`:
```dart
/// Medora - Prepares local data for a fresh cloud account.
///
/// When the user turns cloud sync on, everything already on the device must
/// be uploaded: every synced row becomes pending_update and the pull cursors
/// are cleared so the first cycle is a full pull. Rows pending deletion are
/// left as they are.
library;

import 'package:medora/data/local/app_database.dart';
import 'package:medora/services/sync_cursor_store.dart';

class LocalUploadMarker {
  LocalUploadMarker({required AppDatabase database, required SyncCursorStore cursors})
      : _database = database,
        _cursors = cursors;

  final AppDatabase _database;
  final SyncCursorStore _cursors;

  static const tables = ['families', 'family_members', 'medications', 'treatments', 'prescriptions', 'dose_logs'];

  Future<int> markAllForUpload() async {
    final db = await _database.database;
    var count = 0;
    for (final table in tables) {
      count += await db.update(
        table,
        {'sync_status': SyncStatus.pendingUpdate},
        where: 'sync_status = ?',
        whereArgs: [SyncStatus.synced],
      );
    }
    await _cursors.clear();
    return count;
  }
}
```
`sync_providers.dart`:
```dart
final localUploadMarkerProvider = Provider<LocalUploadMarker>(
  (ref) => LocalUploadMarker(database: AppDatabase.instance, cursors: ref.watch(syncCursorStoreProvider)),
);
```
`app_mode_provider.dart` — `set`:
```dart
  Future<void> set(AppMode mode) async {
    if (mode == AppMode.cloud && state != AppMode.cloud) {
      await ref.read(localUploadMarkerProvider).markAllForUpload();
    }
    state = mode;
    await ref.read(sharedPreferencesProvider).setString(_kAppMode, mode.name);
  }
```
`providers.dart` — `syncServiceProvider`: after constructing, `if (service.isAvailable) service.startAutoSync();` and keep `ref.onDispose(service.dispose)` (dispose stops the subscription). Pass `cursors: ref.watch(syncCursorStoreProvider)`.

- [ ] **Step 3: Run tests, analyze, full suite. Commit** — `feat(sync): auto-sync on reconnect; mark local data for upload when cloud sync is turned on`

---

### Task 7: Integration test against local Supabase, manual CI job, Supabase CLI config, README

**Files:**
- Create: `test/integration/sync_convergence_test.dart`, `supabase/config.toml`, `supabase/.gitignore`
- Modify: `.github/workflows/ci.yml` (+ `integration` job), `README.md`

**Constraints:**
- The integration test is **skipped** (not failed) when `SUPABASE_URL` / `SUPABASE_ANON_KEY` dart-defines are empty, so the default `flutter test` stays green with no Supabase. It uses a plain `SupabaseClient(url, key)` from `package:supabase_flutter` (re-exports `supabase`), never `Supabase.initialize` (plugin channels are unavailable in tests).
- The CI job runs only on `workflow_dispatch` or a PR labelled `integration`. It is not part of the required `test` job. It cannot be verified locally in this environment (no Supabase CLI); write it carefully and say so in the report.

- [ ] **Step 1: `test/integration/sync_convergence_test.dart`**

```dart
/// Convergence test against a local Supabase (`supabase start`).
/// Run: fvm flutter test test/integration --dart-define=SUPABASE_URL=http://127.0.0.1:54321 --dart-define=SUPABASE_ANON_KEY=<anon key>
/// Skipped automatically when the defines are absent.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:medora/data/datasources/dose_log_local_datasource.dart';
import 'package:medora/data/datasources/dose_log_remote_datasource.dart';
import 'package:medora/data/datasources/family_local_datasource.dart';
import 'package:medora/data/datasources/family_remote_datasource.dart';
import 'package:medora/data/datasources/medication_local_datasource.dart';
import 'package:medora/data/datasources/medication_remote_datasource.dart';
import 'package:medora/data/datasources/prescription_local_datasource.dart';
import 'package:medora/data/datasources/prescription_remote_datasource.dart';
import 'package:medora/data/datasources/treatment_local_datasource.dart';
import 'package:medora/data/datasources/treatment_remote_datasource.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/models/medication_model.dart';
import 'package:medora/services/sync_cursor_store.dart';
import 'package:medora/services/sync_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../helpers/test_database.dart';

const _url = String.fromEnvironment('SUPABASE_URL');
const _key = String.fromEnvironment('SUPABASE_ANON_KEY');

void main() {
  final configured = _url.isNotEmpty && _key.isNotEmpty;

  late SupabaseClient client;
  late String userId;

  setUpAll(() async {
    if (!configured) return;
    client = SupabaseClient(_url, _key);
    final email = 'it-${const Uuid().v4()}@example.com';
    final res = await client.auth.signUp(email: email, password: 'password-123');
    userId = res.user!.id;
    expect(client.auth.currentSession, isNotNull, reason: 'local Supabase must auto-confirm sign-ups');
  });

  /// A "device": fresh in-memory local DB + its own cursors, same account.
  Future<SyncService> device() async {
    await AppDatabase.instance.reset();
    AppDatabase.debugPathOverride = inMemoryDatabasePath;
    return SyncService(
      medicationLocal: MedicationLocalDatasource(),
      medicationRemote: MedicationRemoteDatasource(client),
      treatmentLocal: TreatmentLocalDatasource(),
      treatmentRemote: TreatmentRemoteDatasource(client),
      prescriptionLocal: PrescriptionLocalDatasource(),
      prescriptionRemote: PrescriptionRemoteDatasource(client),
      doseLogLocal: DoseLogLocalDatasource(),
      doseLogRemote: DoseLogRemoteDatasource(client),
      familyLocal: FamilyLocalDatasource(),
      familyRemote: FamilyRemoteDatasource(client),
      cursors: SyncCursorStore.inMemory(),
      isOnline: () => true,
      currentUserId: () => userId,
      onlineStream: const Stream.empty(),
    );
  }

  setUp(setUpTestDatabase);
  tearDown(tearDownTestDatabase);

  test('create on A, pull on B, delete on B, gone on A', () async {
    final id = const Uuid().v4();

    // Device A creates and pushes.
    final a = await device();
    await MedicationLocalDatasource().upsert(MedicationModel(id: id, name: 'Convergence', quantity: 1), syncStatus: SyncStatus.pendingCreate);
    final r1 = (await a.syncAll())!;
    expect(r1.isClean, isTrue, reason: r1.failures.join('\n'));

    // Device B pulls, deletes, pushes the tombstone.
    final b = await device();
    final r2 = (await b.syncAll())!;
    expect(r2.isClean, isTrue, reason: r2.failures.join('\n'));
    expect(await MedicationLocalDatasource().getMedicationById(id), isNotNull);
    await MedicationLocalDatasource().markDeleted(id);
    final r3 = (await b.syncAll())!;
    expect(r3.isClean, isTrue, reason: r3.failures.join('\n'));

    // Device A (fresh state again) pulls: tombstone applied.
    final a2 = await device();
    final r4 = (await a2.syncAll())!;
    expect(r4.isClean, isTrue, reason: r4.failures.join('\n'));
    expect(await MedicationLocalDatasource().getMedicationById(id), isNull);
  }, skip: configured ? false : 'Set SUPABASE_URL and SUPABASE_ANON_KEY dart-defines to run against a local Supabase');
}
```
`AppDatabase.debugPathOverride` and `inMemoryDatabasePath` are what `test/helpers/test_database.dart` uses — import them the same way. If `MedicationLocalDatasource().getMedicationById` filters out `pending_delete` rows, use a raw `db.query` for the "isNull" assertion.

- [ ] **Step 2: `supabase/config.toml`** (minimal; the CLI fills defaults):
```toml
project_id = "medora"

[api]
enabled = true
port = 54321
schemas = ["public"]

[db]
port = 54322
major_version = 15

[auth]
enabled = true
site_url = "http://127.0.0.1:3000"
enable_signup = true

[auth.email]
enable_signup = true
enable_confirmations = false
```
`supabase/.gitignore`: `.branches\n.temp\n`.

- [ ] **Step 3: CI job** — append to `.github/workflows/ci.yml` (also add `workflow_dispatch:` under `on:` and `types: [opened, synchronize, labeled]` to `pull_request`):
```yaml
  integration:
    # Manual (workflow_dispatch) or PRs labelled "integration": runs the sync
    # convergence test against a local Supabase started with the CLI.
    if: github.event_name == 'workflow_dispatch' || contains(github.event.pull_request.labels.*.name, 'integration')
    runs-on: ubuntu-latest
    needs: test
    steps:
      - uses: actions/checkout@v4
      - uses: subosito/flutter-action@v2
        with:
          flutter-version-file: .fvmrc
          cache: true
      - uses: supabase/setup-cli@v1
        with:
          version: latest
      - run: supabase start
      - name: Export local credentials
        run: |
          supabase status -o env >> "$GITHUB_ENV"
      - run: flutter pub get
      - run: flutter test test/integration --dart-define=SUPABASE_URL=$API_URL --dart-define=SUPABASE_ANON_KEY=$ANON_KEY
      - if: always()
        run: supabase stop
```
`supabase status -o env` prints `API_URL=…` and `ANON_KEY=…` (verify the variable names in the CLI docs while implementing; adjust if they differ). `supabase start` applies every file in `supabase/migrations/` in name order — that is why the initial schema moved there.

- [ ] **Step 4: README** — in "Optional: cloud sync with Supabase": step 1 becomes "apply the SQL files in `supabase/migrations/` in order (SQL editor, or `supabase db push` with the CLI)"; add a short "How sync works" list: offline-first; push pending, then delta pull by `updated_at`; deletes are tombstones (`deleted_at`) applied on every device; last-write-wins for rows edited on two devices; Settings shows the last sync report; Force pull wipes local rows; turning cloud sync on uploads what is already on the device. Add a "Integration test" paragraph with the `supabase start` + `flutter test test/integration --dart-define…` command and the CI label.

- [ ] **Step 5: Verify** `fvm flutter test` (integration test reports as skipped), `fvm flutter analyze --fatal-infos`, `fvm flutter gen-l10n` no diff. **Commit** — `test(sync): convergence test against local Supabase, manual CI job, docs`

---

## Phase 3 exit criteria

- [ ] Deleting a medication/treatment/prescription/dose on one device removes it on another after both sync (unit-tested with fakes; integration test when a local Supabase is available).
- [ ] Second and later pulls request only rows newer than the stored cursor; force pull resets cursors.
- [ ] Settings shows the last sync summary and lists failed items; the Home chip shows the partial state.
- [ ] Family members are pushed; leaving/removing works offline and is pushed later; joining uses the RPC.
- [ ] Coming back online triggers exactly one sync; turning cloud sync on uploads existing local data.
- [ ] Local-only behaviour unchanged; `fvm flutter analyze --fatal-infos` clean; `fvm flutter test` green; CI green.
