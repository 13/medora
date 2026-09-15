# Medora — architecture overview

Offline-first Flutter app: everything works with no network and no account, and
Supabase sync is an optional layer on top. This file is the map; the design
rationale lives in `docs/superpowers/specs/`.

## Layers

`lib/` is split by responsibility, dependencies pointing inwards only:

| Directory | Responsibility |
|---|---|
| `lib/core/` | Constants, theme + `MedoraColors` extension, `AppConfig` (dart-defines), `Result`, the `Now` clock, platform capabilities. |
| `lib/domain/` | Entities (`medication`, `treatment`, `prescription`, `dose_log`, `family`, `family_member`) and repository interfaces. No Flutter, no SQL. |
| `lib/data/` | `local/` (sqflite + migration ledger), `datasources/` (one local and one remote per aggregate), `models/`, `repositories/`. |
| `lib/services/` | Sync, reminders, dose maintenance, export, backup, photos, AIFA cache, connectivity, biometrics, updates. |
| `lib/presentation/` | Riverpod providers, go_router routes, screens and widgets. |
| `lib/l10n/` | `app_en.arb`/`app_de.arb`/`app_it.arb` plus generated delegates. |

## Provider layout

`providers.dart` is the wiring file — datasources, repositories, services,
startup tasks. Around it are two kinds of file.

**Leaves** never import `providers.dart`, so anything that needs one of them
can be tested without standing up the wiring: `now_provider.dart`
(`nowProvider`, the one clock seam, alone because nearly every screen needs it
and nothing else), `settings_providers.dart` (prefs, theme/locale/colour,
reminders, biometrics, grace period, `BuildInfo`, cloud credentials, the
connection probe), `app_config_`, `app_mode_`, `sync_`, `auth_`,
`onboarding_` and `app_update_provider.dart`.

**Aggregate files** — `dose_`, `medication_`, `treatment_`, `family_` and
`prescription_providers.dart` — do import `providers.dart`, for the
repositories they build their lists and actions on, and `providers.dart`
imports several of them back for the startup tasks. That mutual import is
accepted: Dart resolves it, and the alternative is a third file that does
nothing but hold the repository providers. What is not accepted is a leaf
growing an import of `providers.dart` — that is the edge the layering
depends on.

## App modes

`AppMode { localOnly, cloud }` is persisted in `SharedPreferences`; cloud mode
also needs usable credentials. `SupabaseConfig.resolve` picks them **Settings >
dart-defines > none** — a pair entered in Settings (`cloud.supabase_url`,
`cloud.supabase_anon_key`) beats the `SUPABASE_URL`/`SUPABASE_ANON_KEY` baked
into the build — and without either the remote datasources are never built.
`Supabase.initialize` runs once per process, so credentials saved while it is
already running set `pendingRestart`; the anon key lives only in
`SharedPreferences`, is never logged and never shown again. Repositories always
write locally first — local-only is the base case, not a degraded mode — and
`debugSetConfiguredForTest` flips `isConfigured` without creating a client, so
widget tests can render a configured build.

## Local data: schema, backup and restore

`lib/data/local/migrations.dart` is an append-only ledger of `Migration`
(version + function); `kSchemaVersion` is **13** and must equal the last entry,
and existing migrations are never edited: v11 added tombstone columns, v12 bare
photo filenames, v13 naive-local dose timestamps so string ranges line up with
local day boundaries. `BackupService` writes the database and photo folder into one versioned JSON
envelope (`format: "medora-backup"`, `version`, `schemaVersion`, `createdAt`,
`appVersion`, `tables`, base64 `photos`); rows go out exactly as stored, minus
`sync_status`. `inspect` validates it first, so a backup from a newer build is
refused rather than half-applied, and `restore` applies the file in one
transaction in foreign-key order: one that cannot be applied in full leaves the
device as it was. `replace` clears the tables first; `merge`
upserts by id, and the backup must be **strictly** newer by `updated_at` to win.
Restored rows are stamped `synced`, or `pending_update` under `markPending`
(cloud) — except `family_members`, since RLS only accepts the user's own row.
Settings covers the run with an un-dismissable "Restoring…" dialog, then resets
the reminders and invalidates the caches. The whole envelope is held in memory,
so the export unticks photos above `largePhotoBytes` (150 MB).

## Reminders, doses and expiry

`ReminderScheduler` is the single owner of "which notifications exist": each
`reconcile` loads the pending doses inside a **7-day** horizon, earliest first,
capped at **60** platform notifications — **2** per dose, so **30** doses — and
after the first run applies only the delta against the previous snapshot of id +
scheduled time, so a dose whose time moved is re-scheduled.
`DoseMaintenanceService.markOverdueAsMissed` flips pending doses older than a
grace period to *missed* (**120 min** by default, from 30/60/120/240).
Expiry is a **date**, so comparisons round to whole calendar days through
`calendarDaysBetween`: a medication stamped "expires today" is good for all of
today, `expiredAt(now)` is true only once `daysUntilExpiry` goes negative — the
rule `ExpiryBadge` and the Home countdown already used — and `isExpiringSoon` is
the 30-day window before it.

## In-app updates (Android)

`AppUpdateService` is pure Dart over `package:http`: read `/releases/latest` for
`AppConfig.updateRepo`, compare the tag with the running build, pick the APK for
the device's ABI (else universal), stream it into `<support dir>/updates/` while
hashing, verify size and `SHA256SUMS.txt`, hand it over — any failure deletes
the partial file. `AppUpdateNotifier` owns the states (`Unknown →
Checking → Available → Downloading → Ready`) and the gates: Android, a configured
repo, a connection, a 24 h throttle. **Cancelling:** `download` takes
an `isCancelled` seam asked once per chunk. Each download holds a generation
number; `cancelDownload()` burns it and puts the state back to
`UpdateAvailable`, and a download whose generation is spent — cancelled, or
replaced by a newer one — reports nothing and keeps no APK, so a re-download
started while the first is still unwinding is the only one that can reach the
state. **Installing:** Android never reports back, so `install()` writes the
tag first (`update.installing_tag`) and the next `build()`/`check()` settles
it — running this release means it worked (`clearDownloads`, pref cleared),
otherwise the APK still on disk becomes `UpdateReady` and Install, explained
beforehand because Android asks to allow installs, is offered again. That tag
records one opened installer, not a verdict: a `check` still asks GitHub, and
a release newer than the pending APK clears both the pref and the file and is
offered as usual — as does "Later" on it. Only a check that finds nothing
newer, is throttled, or cannot run at all leaves the pending install standing.

## Sync

`SyncService` runs a cycle as push, then pull. **Push** uploads pending rows; one
that throws becomes a `SyncFailure` and the batch continues, and a row that keeps
failing is skipped until `min(2^count minutes, 6 h)` after its last attempt.
**Pull** is a delta per table: only rows newer than the stored cursor, tombstones
(`deleted_at`) applied as hard local deletes, and the cursor advanced to the
newest `updated_at` seen minus **1 second** of overlap, only when the whole table
applied cleanly. **Conflicts** resolve **last write wins by
`updated_at`** on both sides: the push reads the remote value first and leaves a
row it would clobber for the pull to overwrite, while the pull keeps a locally
pending row at least as new as the remote copy and never resurrects a row a
local tombstone has deleted. `forcePush` skips that comparison; **force pull**
wipes local rows and re-downloads, aborting if a table cannot be fetched
afterwards. Families are pulled separately, through the `join_family`
security-definer RPC. Each cycle fills a `SyncReport` that Settings renders,
offering `discardFailedRow` per failed row; auto-sync fires **2 s** after
connectivity returns, and a mid-cycle `syncAll()` is queued. Schema, RLS and
triggers live in `supabase/migrations/`.

## Theme and localization rules

Colors come from the Material 3 scheme plus the `MedoraColors` theme extension
(`lib/core/theme_extensions.dart`), reached via `context.medora`. Three sweeps
keep this from eroding: `theme_sweep_test.dart` fails on any `Colors.*` (except
`transparent`/`black`) or legacy `AppTheme.*Color` under `lib/presentation`;
`l10n_sweep_test.dart` on a capitalised literal in a `Text`/`label`/`title`/
`tooltip` position under `lib/presentation` or `lib/services` without `l10n.` or
`// l10n-exempt`; `clock_sweep_test.dart` on `DateTime.now()` outside
`lib/core/clock.dart`. Every semantic colour pair clears 3.0 contrast in both
themes, every string exists in all three ARBs, and the committed `gen-l10n`
output must not drift from the ARBs.

## Testing layout

`test/core|domain|data|services` hold unit tests over an in-memory sqflite
database (`test/helpers/test_database.dart`) and fake remotes;
`test/presentation` the widget tests and the three sweeps; `test/goldens` Home,
add-medication and doses (twice: an ordinary day and the two-due "Take all due"
bar) in light and dark, regenerated deliberately with `fvm flutter test
--update-goldens test/goldens/`; `test/integration` the two-device convergence
test, skipped without the `SUPABASE_URL`/`SUPABASE_ANON_KEY` defines. CI
(`.github/workflows/ci.yml`) runs the gen-l10n drift check, `dart format`,
`flutter analyze --fatal-infos` and the tests, then builds web and an Android
APK; the integration job is manual or label-triggered.
