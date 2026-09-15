# Medora — architecture overview

Offline-first Flutter app: everything works with no network and no account, and
Supabase sync is an optional layer on top. This file is the map; the full design
rationale lives in `docs/superpowers/specs/`.

## Layers

`lib/` is split by responsibility, dependencies pointing inwards only:

| Directory | Responsibility |
|---|---|
| `lib/core/` | Constants, theme + `MedoraColors` theme extension, `AppConfig` (dart-defines), `Result`, `Now` clock, platform capabilities. |
| `lib/domain/` | Entities (`medication`, `treatment`, `prescription`, `dose_log`, `family`, `family_member`) and repository interfaces. No Flutter, no SQL. |
| `lib/data/` | `local/` (sqflite database + migration ledger), `datasources/` (one local and one remote datasource per aggregate), `models/` (JSON/row mapping), `repositories/` (interface implementations). |
| `lib/services/` | Cross-cutting behaviour: sync, reminders, dose maintenance, export, photo storage, AIFA cache, connectivity, biometrics. |
| `lib/presentation/` | Riverpod providers, go_router routes, screens and widgets. |
| `lib/l10n/` | `app_en.arb` / `app_de.arb` / `app_it.arb` plus generated delegates. |

## App modes

`AppMode { localOnly, cloud }` (`lib/presentation/providers/app_mode_provider.dart:10`)
is persisted in `SharedPreferences`. Cloud mode also needs a build carrying
`SUPABASE_URL` and `SUPABASE_ANON_KEY` (`AppConfig.isCloudAvailable`,
`lib/core/app_config.dart:22`); without them the remote datasources are never
constructed and settings says cloud sync is unavailable. Repositories always
write locally first, so local-only is not a degraded mode — it is the base case.

## Local database and migrations

`lib/data/local/migrations.dart` holds an append-only ledger: a `Migration`
carries a version number and a function. `kSchemaVersion` is **13**
(`migrations.dart:17`) and must equal the last entry; existing migrations are never
edited. The ledger holds v11 tombstone columns, v12 photos stored as bare
filenames, and v13 dose timestamps normalised to naive local ISO strings so string
range comparisons line up with local day boundaries.

## Reminders

`ReminderScheduler` (`lib/services/reminder_scheduler.dart`) is the single owner of
"which notifications exist". Each `reconcile` loads the pending doses inside a **7-day**
horizon (`horizon`, line 25), earliest first, capped at **60** pending platform
notifications (`maxNotifications`, line 26) — **2** per dose (`notificationsPerDose`,
line 27), so **30** doses (line 96). The first run cancels everything and schedules the
desired set; later runs diff against the previous run's snapshot of id + scheduled time
and only cancel/schedule the delta, so a dose whose time moved (say after a cloud pull)
is re-scheduled. With reminders disabled it cancels everything and schedules nothing.
`ReminderService` is the platform adapter (`flutter_local_notifications`) and routes a
notification tap through the router, not a stored `BuildContext`.

## Dose maintenance

`DoseMaintenanceService.markOverdueAsMissed` (`lib/services/dose_maintenance_service.dart:17`)
flips pending doses older than a grace period to *missed* so history and stats
stay honest. The grace period is a setting — **120 minutes (2 h)** by default
(`lib/presentation/providers/settings_providers.dart:170`), chosen from 30/60/120/240
minutes (`settings_providers.dart:159`).

## Sync

`SyncService` (`lib/services/sync_service.dart`) runs a cycle as push, then pull:

- **Push** uploads rows whose `sync_status` is pending; a row that throws becomes
  a `SyncFailure` and the batch continues.
- **Pull** is a delta per table: it asks the remote only for rows newer than the
  stored cursor, applies tombstones (`deleted_at`) as hard local deletes, and
  advances the cursor to the newest `updated_at` it saw minus **1 second** of
  overlap (`sync_service.dart:469`), so a row written in the same second is not
  missed. The cursor advances only when the whole table applied cleanly.
- **Conflicts** resolve **last write wins by `updated_at`**, enforced on both
  sides. Before upserting a `pending_update` row the push reads the remote
  row's `updated_at` (`getUpdatedAt` on each remote datasource) and, if the
  remote copy is strictly newer, skips the push and leaves the row pending so
  the pull phase overwrites it — counted in `SyncReport.skippedStale`, not as a
  failure. `pending_create` rows and `pending_delete` tombstones push
  unconditionally, and `forcePush` skips the comparison. On the pull side
  `_localPendingIsNewer` keeps a locally pending row that is at least as new as
  the remote copy, and a local tombstone waiting to be pushed always beats a
  live remote row — a pull must never resurrect a deleted row.
- **Reporting**: each cycle fills a `SyncReport` (`lib/services/sync_report.dart`)
  — pushed/pulled/deleted counters, per-row `SyncFailure`s, and a `fatal` field
  for an aborted cycle. Settings renders the last report.
- **Force push** uploads every local row regardless of status; **force pull** wipes
  local rows and re-downloads, and a table that cannot be fetched after the wipe
  aborts the cycle instead of reporting a partial success.
- **Families** are pulled separately. Joining goes through the `join_family`
  security-definer RPC (`lib/data/datasources/family_remote_datasource.dart:37`)
  so a non-owner can join without a SELECT policy on `families`.
- Auto-sync fires once, **2 s** after connectivity returns (`sync_service.dart:121`).
- Server-side schema, RLS policies and the tombstone cascade triggers live in
  `supabase/migrations/`.

## Theme and localization rules

Colors come from the Material 3 scheme plus the `MedoraColors` theme extension
(`lib/core/theme_extensions.dart`), reached via `context.medora`. Two guard tests
keep this from eroding:

- `test/presentation/theme_sweep_test.dart` fails on any `Colors.*` (except
  `transparent`/`black`) or legacy `AppTheme.*Color` reference under
  `lib/presentation`.
- `test/presentation/l10n_sweep_test.dart` fails on a capitalised literal
  string in a `Text`/`label`/`title`/`tooltip` position under
  `lib/presentation` or `lib/services` unless the line uses `l10n.` or carries
  `// l10n-exempt`.

`test/core/theme_extensions_test.dart` asserts every semantic foreground/background
pair clears a 3.0 contrast ratio in both themes, and `test/core/theme_test.dart`
that the bundled Inter family is used (no runtime font download). Every
user-facing string exists in all three ARBs; the `fvm flutter gen-l10n` output
is committed and CI fails if it drifts.

## Testing layout

| Path | What lives there |
|---|---|
| `test/core`, `test/domain`, `test/data`, `test/services` | Unit tests, including an in-memory sqflite database (`test/helpers/test_database.dart`) and fake remotes. |
| `test/presentation` | Widget tests for screens, providers and the router, plus the theme and l10n sweeps. |
| `test/goldens` | Home, doses and add-medication screens in light and dark. Regenerate deliberately with `fvm flutter test --update-goldens test/goldens/`. |
| `test/integration` | `sync_convergence_test.dart` — two simulated devices against a real Supabase; skipped without `SUPABASE_URL`/`SUPABASE_ANON_KEY` defines. |

CI (`.github/workflows/ci.yml`) runs the gen-l10n drift check, `dart format`,
`flutter analyze --fatal-infos` and the tests, then builds web and an Android APK;
the integration job is manual or label-triggered.
