# Settings polish, JSON backup, runtime cloud configuration — Implementation Plan

> **Status: a record, not a checklist.** The work in this plan has shipped.
> The `- [ ]` boxes below were never ticked as it went and are not a progress
> record — they are the plan's original step markers, left as written. What
> actually landed is in the git history for the files each step names, and in
> `docs/architecture.md` for the shape it settled into.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Four user-visible fixes: (1) About shows version, build number, build date, commit and channel; (2) the AIFA database tile no longer wraps its long title into a narrow column; (3) full JSON backup export/import for the local database (+ photos); (4) cloud sync becomes usable in builds without baked-in Supabase configuration by entering the project URL and anon key in Settings.

**Architecture:** Build metadata arrives via `--dart-define` (`BUILD_DATE`, `GIT_SHA`, `BUILD_CHANNEL`) set by both workflows and read by `AppConfig`. The AIFA tile is re-laid out (short title, descriptive subtitle, action below). `BackupService` (pure Dart over `AppDatabase` + `PhotoStorage`) writes/reads a versioned JSON envelope; Settings → Data gets Backup/Restore tiles; the export screen's share pattern is reused; `file_picker` handles import. `SupabaseConfig.initialize` accepts a runtime `CloudCredentials` from SharedPreferences (`cloud.supabase_url`, `cloud.supabase_anon_key`) that fall back to the dart-defines; a Settings sheet edits them; first configuration initialises Supabase immediately, later changes ask for a restart.

**Tech Stack:** Flutter 3.44.6 (`fvm`, Dart 3.12), flutter_riverpod 3, sqflite, `share_plus` (present), `file_picker` (new), `path_provider`, `package_info_plus`, supabase_flutter.

## Global Constraints

- Flutter via `fvm` (always `fvm dart format`, never bare `dart`); curated lints + `dart format --set-exit-if-changed .`; `fvm flutter analyze --fatal-infos` clean; `fvm flutter test` green (baseline 328 + 2 skipped); guards `theme_sweep`, `l10n_sweep`, `clock_sweep` (no `DateTime.now()` in presentation/domain — use `nowProvider`); 6 goldens unchanged (Settings/About are not golden screens).
- Package imports only; theme tokens only; ARB en/de/it for every string + `fvm flutter gen-l10n`, commit generated, `untranslated.txt` = `{}`.
- Secrets never in git; the anon key is public by design but is still stored only in SharedPreferences, never logged.
- Backup format is versioned (`format: "medora-backup"`, `version: 1`, `schemaVersion: kSchemaVersion`); import refuses a newer `version`/`schemaVersion` with a clear error; import never runs partially — wrap in a DB transaction.
- Commits end with the two attribution lines from the session's system reminder.

---

### Task 1: About build info + AIFA tile layout

**Files:**
- Modify: `lib/core/app_config.dart` (`buildDate`, `gitSha`, `buildChannel`), `.github/workflows/ci.yml` and `release.yml` (pass `--dart-define=BUILD_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ) --dart-define=GIT_SHA=${GITHUB_SHA::7} --dart-define=BUILD_CHANNEL=release|ci` to every `flutter build`), `tools/release.sh` (no change; local builds get `dev` channel + `unknown` date), `lib/presentation/screens/settings/settings_screen.dart` (About tiles; `_AifaDatabaseTile` layout), `lib/presentation/providers/settings_providers.dart` (`buildInfoProvider`), ARB.
- Test: `test/core/app_config_test.dart` (+ build fields), `test/presentation/screens/settings_screen_test.dart` (+ About shows version/build/date/commit rows; AIFA tile renders its title on one line at 360 px width — assert no `RenderFlex` overflow and that the title `Text` has `maxLines == 1`… simpler: pump at `tester.view.physicalSize = Size(360, 800)` and expect `tester.takeException()` null and `find.text('AIFA-Datenbank')` under locale `de`).

**Interfaces:**
```dart
// AppConfig
final String buildDate;     // ISO-8601 UTC or '' (dev)
final String gitSha;        // 7+ chars or ''
final String buildChannel;  // 'release' | 'ci' | 'dev'
// settings_providers.dart
class BuildInfo { final String version; final String buildNumber; final String buildDate; final String gitSha; final String channel; final String dartVersion; }
final buildInfoProvider = FutureProvider<BuildInfo>(...); // PackageInfo + AppConfig + Platform.version (first token)
```
- [ ] **Step 1: Tests** as above; ARB keys: `buildNumber` ("Build"), `buildDate` ("Built"), `buildCommit` ("Commit"), `buildChannel` ("Channel"), `channelRelease` ("Release"), `channelCi` ("CI"), `channelDev` ("Development build"), `copiedToClipboard` ("Copied"), `aifaDatabaseHint` (short: "Italian medication database for code lookup" — de: "Italienische Medikamentendatenbank für die Code-Suche", it: "Banca dati italiana dei farmaci per la ricerca per codice").
- [ ] **Step 2: About group** — rows: App version `1.0.0 (11)`; Built `2026-09-15 20:14 UTC` (locale-formatted via the extension; "—" when empty); Commit `abc1234`; Channel; Dart `3.12.2`. A long-press on any row copies `Medora <version> (<build>) · <date> · <sha> · <channel>` via `Clipboard.setData` and shows `copiedToClipboard`.
- [ ] **Step 3: AIFA tile** — `ListTile(leading: storage icon, title: Text(l10n.aifaDatabase), subtitle: Column[ Text(l10n.aifaDatabaseHint), Text(status) ], isThreeLine: true, trailing: null)` and the action as a full-width row under it: `Align(right, TextButton.icon(Icons.download, l10n.syncAifaDatabase))` or a `FilledButton.tonal` inside the tile's `subtitle` bottom — pick the one that keeps the button reachable and never squeezes the text; replace the hand-rolled `_formatDate` with the locale extension.
- [ ] **Step 4: Verify** gates; screenshot-style widget test at 360 px in `de`. **Commit** — `feat(settings): build info in About; readable AIFA database tile`

---

### Task 2: JSON backup export/import

**Files:**
- Create: `lib/services/backup_service.dart`, `test/services/backup_service_test.dart`, `lib/presentation/widgets/restore_dialog.dart` (mode chooser + confirm)
- Modify: `pubspec.yaml` (`file_picker`), `lib/presentation/screens/settings/settings_screen.dart` (Data group: "Back up data" / "Restore from backup"), `lib/presentation/providers/providers.dart` (`backupServiceProvider`), `docs/architecture.md` (Backup section), README (one line), ARB.
- Test: service round-trip; widget test for the Data tiles.

**Interfaces:**
```dart
class BackupManifest { final int version; final int schemaVersion; final DateTime createdAt; final String appVersion; final Map<String,int> rowCounts; final int photoCount; }
enum RestoreMode { replace, merge }
class BackupService {
  BackupService({required AppDatabase database, required PhotoStorage photos, required DateTime Function() now, required String appVersion});
  static const tables = ['medications','treatments','prescriptions','dose_logs','families','family_members'];
  Future<File> exportToFile(Directory dir, {bool includePhotos = true}); // writes medora-backup-<yyyyMMdd-HHmm>.json
  Future<BackupManifest> inspect(File file);          // validates envelope, throws BackupException(kind)
  Future<BackupManifest> restore(File file, {required RestoreMode mode}); // transaction; replace = clearAllData first; merge = upsert by id keeping the newer updated_at; photos written via PhotoStorage
}
enum BackupErrorKind { notABackup, newerFormat, newerSchema, corrupt, io }
```
Envelope:
```json
{"format":"medora-backup","version":1,"schemaVersion":13,"createdAt":"…Z","appVersion":"0.1.1+11",
 "tables":{"medications":[{…row as stored, minus sync_status…}],"treatments":[…],"prescriptions":[…],"dose_logs":[…],"families":[…],"family_members":[…]},
 "photos":{"<filename>":"<base64 png/jpg>"}}
```
Rows are exported exactly as stored (naive-local timestamps, `deleted_at`), `sync_status` stripped; on restore rows get `sync_status = 'pending_update'` when `appModeProvider == cloud` (caller passes `markPending: bool`) else `'synced'`. FK order on insert: families → family_members → medications → treatments → prescriptions → dose_logs. After restore the caller: `ReminderScheduler.reset()` + `reconcile()`, `invalidateDoseData`, refresh medication/treatment lists, `LocalUploadMarker.markAllForUpload` when cloud.

- [ ] **Step 1: Service tests** (in-memory DB via `setUpTestDatabase`, temp dir `PhotoStorage`): export → file contains counts; restore replace into an empty DB → identical rows (compare maps minus `sync_status`); restore merge keeps the newer local row; photo round-trip (write a small PNG into `PhotoStorage`, export, wipe, restore → file exists with same bytes); `inspect` on garbage → `notABackup`; `version: 2` → `newerFormat`; a failing row (violate FK by dropping a treatment from the file) → `corrupt` and DB unchanged (transaction rolled back).
- [ ] **Step 2: Implement** service; `file_picker` (`FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['json'], withData: true)`); Settings tiles under Data: "Back up data" (`l10n.backupData` / hint "Save everything as a JSON file") → export to temp then `SharePlus.instance.share(ShareParams(files: [XFile(path)]))` (same as export screen; on desktop `file_selector`-less builds the share sheet still works via share_plus); "Restore from backup" (`l10n.restoreBackup`) → pick → `inspect` → dialog showing created date, app version, row counts, photos, radio Replace/Merge with the warning text for Replace → progress → snackbar with counts; errors via `errorWithDetails`. Gate tiles on `caps.hasFileShare`.
- [ ] **Step 3: Verify** gates; ARB en/de/it (`backupData`, `backupDataHint`, `restoreBackup`, `restoreBackupHint`, `restoreReplace`, `restoreMerge`, `restoreReplaceWarning`, `restoreSummary` {created,rows,photos}, `restoreDone` {rows}, `backupNotABackup`, `backupNewerVersion`, `backupCorrupt`). **Commit** — `feat(backup): JSON export and restore of the local database and photos`

---

### Task 3: Runtime Supabase configuration

**Files:**
- Modify: `lib/core/supabase_config.dart` (`initialize(AppConfig, {CloudCredentials? override})`, `isConfigured`, new `configuredFrom` = `defines | settings | none`), `lib/core/app_config.dart` (`CloudCredentials` value type), `lib/main.dart` (read prefs before init), `lib/presentation/providers/settings_providers.dart` (`cloudCredentialsProvider` Notifier over prefs `cloud.supabase_url`/`cloud.supabase_anon_key`), `lib/presentation/screens/settings/settings_screen.dart` (Cloud sync group: "Configure cloud" tile + sheet), `lib/presentation/widgets/cloud_config_sheet.dart` (new), `docs/release.md`/README (how to configure), ARB.
- Test: `test/core/supabase_config_test.dart` (precedence: settings override defines; empty settings fall back; validation), `test/presentation/screens/settings_screen_test.dart` (tile visible in an unconfigured build; sheet validates URL `https://<ref>.supabase.co` and a non-empty key; saving stores prefs).

**Behaviour:**
- Precedence: Settings values (if both non-empty) > dart-defines > none.
- Sheet fields: Project URL, anon/publishable key (obscured, paste button), "Test connection" (GET `<url>/auth/v1/settings` with `apikey` header via `http`, 200 → ok), Save, Clear. Saving when Supabase is not yet initialised calls `SupabaseConfig.initialize(...)` immediately and the Cloud tile switches to "Off — turn on"; saving when already initialised shows "Restart Medora to apply" (and `SupabaseConfig.pendingRestart = true` so the tile says so). Clearing when in cloud mode first runs the existing turn-off flow.
- The Cloud tile's unavailable copy becomes actionable: `cloudSyncUnavailable` → "Not configured — tap Configure" with a `Configure` button; when configured from Settings show "Configured on this device" as a subtitle.
- Never log the key; the sheet never shows it after save (shows `••••` + "Replace").

- [ ] **Step 1: Tests**, **Step 2: Implement**, **Step 3: Verify** gates. **Commit** — `feat(cloud): configure Supabase URL and key at runtime in Settings`

---

### Task 4: Release

- [ ] Merge to `main`, push, CI green; `tools/release.sh 0.2.0+12`; confirm release assets; note in the report that About now shows build date/commit for that build.

## Exit criteria
- [ ] About lists version, build, built date, commit, channel, Dart; long-press copies.
- [ ] AIFA tile readable at 360 px in German; no overflow.
- [ ] Backup JSON exports and restores (replace/merge) incl. photos; corrupt/newer files are refused without touching data.
- [ ] A build with no dart-defines can enable cloud sync after entering URL + key in Settings; values persist; precedence documented.
- [ ] Gates green; goldens unchanged; l10n complete; release `v0.2.0+12` published.
