# Medora — Offline-First Overhaul: Audit & Design

Date: 2026-09-14
Status: APPROVED 2026-09-14 (open questions resolved, see §8)
Codebase: Flutter 3.44 / Dart 3.11, Riverpod 3, go_router, sqflite, Supabase (optional)

---

## 1. Goal

Make Medora a fully functional, zero-configuration, offline-first medicine cabinet app that:

1. Builds and runs with **no `.env`, no Supabase project, no network** — on Android, iOS, Linux, Windows, and Web.
2. Treats cloud sync (Supabase) as an **optional add-on** the user can turn on later from Settings, without losing local data.
3. Fixes the functional bugs found in the audit (reminders, dose status, sync semantics, migrations).
4. Gets a coherent, theme-aware, modern Material 3 UI with fewer taps for the core daily loop ("what do I take now?").
5. Has a real test suite and CI so regressions are caught.

## 2. Audit findings

Severity: **P0** = app broken / data loss / store rejection · **P1** = feature does not work as designed · **P2** = UX / quality · **P3** = hygiene.

### 2.1 Build & offline blockers

| # | Sev | Finding | Where |
|---|-----|---------|-------|
| B1 | P0 | `.env` is declared as a Flutter asset but is git-ignored. A fresh clone cannot build: `flutter test` fails with `No file or variants found for asset: .env.` | `pubspec.yaml:91` |
| B2 | P0 | Without `.env`, `Supabase.initialize` is skipped, but `SupabaseConfig.client` (`Supabase.instance`) throws. `authStateProvider` errors → every launch lands on the Auth screen; the user must tap "Use offline mode" each time because `isOfflineModeProvider` is in-memory only. | `core/supabase_config.dart`, `providers/auth_providers.dart`, `router/app_router.dart` |
| B3 | P0 | Every remote datasource and the family screen touch `SupabaseConfig.client` unguarded. Any code path that reaches them in local-only mode throws `StateError`. | `data/datasources/*_remote_datasource.dart`, `family_remote_datasource.dart:11` |
| B4 | P1 | `google_fonts` fetches Inter over HTTP at runtime. Offline cold start silently falls back to the platform font, so typography differs between online and offline sessions. | `core/theme.dart` |
| B5 | P1 | Local SQLite schema is at `version: 10` but `_onUpgrade` is empty. Any future column change breaks existing installs; there is no migration history. | `data/local/app_database.dart` |
| B6 | P1 | "Continue as guest" requires network (Supabase anonymous sign-in). There is no true local-only account path besides the hidden "offline mode" text button. | `screens/auth/auth_screen.dart` |
| B7 | P1 | AIFA barcode lookup: if the local cache was never synced, `BarcodeLookupDatasource.search` downloads the entire AIFA CSV (tens of MB) **per lookup** and parses it in memory. Offline it simply fails with "not found". | `services/aifa_cache_service.dart`, `data/datasources/barcode_lookup_datasource.dart` |
| B8 | P1 | `medication_detail_screen.dart` imports `dart:io` and calls `File(...).existsSync()` unguarded → runtime error on Web when a medication has an `imagePath`. | `screens/medication/medication_detail_screen.dart:718` |
| B9 | P1 | Scanner uses `camera` + `google_mlkit_text_recognition` (OCR, mobile only). README/README_TECH still describe `mobile_scanner` barcode scanning. Scanner route is reachable on Web/desktop where ML Kit does not exist. | `screens/scanner/barcode_scanner_screen.dart`, `README.md` |

### 2.2 Functional bugs

| # | Sev | Finding | Where |
|---|-----|---------|-------|
| F1 | P1 | **Reminder toggle is decorative.** `remindersEnabledProvider` is never read by scheduling code. Turning it off calls `cancelAllReminders()` then `ref.invalidate(todaysDoseLogsProvider)`, whose `build()` immediately re-schedules every pending dose. | `providers/dose_providers.dart`, `screens/settings/settings_screen.dart:143` |
| F2 | P1 | **Reminders only exist for today.** Notifications are scheduled from `todaysDoseLogsProvider.build()`; if the app is not opened on a given day, no reminder fires that day. | `providers/dose_providers.dart` |
| F3 | P1 | **Undo taken keeps `taken_time`.** `updateStatus` only writes `taken_time` when non-null, so `markDosePending` cannot clear it. Dose then shows "taken at HH:MM" while pending. | `data/datasources/dose_log_local_datasource.dart:924` |
| F4 | P1 | **Overdue doses never become "missed".** No job marks past-due pending doses; yesterday's pending doses stay pending forever in history. | (missing) |
| F5 | P1 | **`updated_at` is overwritten with `now()` on every local write, including rows pulled from remote.** Last-write-wins comparison in `SyncService` is therefore meaningless; dose_logs never write `updated_at` at all. | `*_local_datasource.dart` `_toRow`, `prescription_model.toLocalMap` |
| F6 | P1 | **Auto-sync on reconnect is never started.** `SyncService.startAutoSync()` has no callers; the only automatic sync is a 2-second post-frame timer in `MainShellScreen`. | `services/sync_service.dart`, `screens/main_shell_screen.dart` |
| F7 | P1 | Remote deletions never reach other devices (pull is upsert-only; no tombstones). Family members are never pushed; family rows only `createFamily`. Per-row push errors are swallowed (`catch (_) {}`), so the UI shows "success" on partial failure. | `services/sync_service.dart` |
| F8 | P2 | `markDoseTaken/Skipped/Missed/Pending` return a fabricated `DoseLog` with `prescriptionId: ''` and `scheduledTime: now`. Callers ignore it today, but it is a trap. | `data/repositories/dose_log_repository_impl.dart` |
| F9 | P2 | `expiringSoonProvider` (Home) includes already-expired medications (no lower bound), while `getExpiringSoon` in the datasource excludes them. Home shows negative "days". | `providers/medication_providers.dart:121` |
| F10 | P2 | Medication photos are stored by **absolute path** in the app documents directory. iOS changes the container path on app update → all photos disappear. | `screens/medication/add_medication_screen.dart:864` |
| F11 | P2 | `AuthGuard` is instantiated per route and registers a `WidgetsBindingObserver` each time. Deep navigation stacks can trigger multiple biometric prompts on resume. `biometricOnly: true` locks out users whose device has only a PIN. | `router/app_router.dart` |
| F12 | P2 | "Delete all data" clears SQLite but not scheduled notifications or photo files. Sign-out does not clear local data, so the next account on the same device sees the previous user's cabinet. | `screens/settings/settings_screen.dart`, `providers/auth_providers.dart` |
| F13 | P2 | `AppConstants.appVersion = '1.0.0'` while `pubspec.yaml` is `0.0.9+9`. | `core/constants.dart` |
| F14 | P2 | Every list mutation calls `refresh()` which sets `AsyncLoading` → the whole list flashes a spinner after each quantity tap / archive / delete. | `providers/*_providers.dart` |

### 2.3 Platform & release

| # | Sev | Finding | Where |
|---|-----|---------|-------|
| R1 | P0 | iOS `Info.plist` lacks `NSCameraUsageDescription`, `NSPhotoLibraryUsageDescription`, `NSFaceIDUsageDescription`. Camera/photo/biometric access crashes on iOS and the build is rejected by App Store review. | `ios/Runner/Info.plist` |
| R2 | P1 | Android release build is signed with the **debug** keystore (`signingConfig = debug`) with minify on. Not installable as an update over a properly signed build. | `android/app/build.gradle.kts` |
| R3 | P2 | Web `manifest.json` still says "A new Flutter project", `theme_color: #0175C2`; no `flutter_local_notifications_web` (notifications silently no-op on web, which is acceptable but undocumented). | `web/manifest.json` |
| R4 | P2 | Supabase `anonKey` parameter is deprecated (`flutter analyze` info). | `core/supabase_config.dart:23` |
| R5 | P3 | 12 direct dependencies have newer majors (`go_router 18`, `flutter_local_notifications 22`, `local_auth 3`, `share_plus 13`, `package_info_plus 10`, `csv 8`). | `pubspec.yaml` |

### 2.4 UX / UI

| # | Sev | Finding |
|---|-----|---------|
| U1 | P2 | **Color scheme setting is only half applied.** Screens use the static `AppTheme.primaryColor` (teal) for the Home gradient card, avatars, chips, section titles and buttons instead of `Theme.of(context).colorScheme.primary`. Choosing "Purple" changes the nav bar and FAB but not the content. |
| U2 | P2 | **Dark mode contrast.** Hardcoded `Colors.grey[600]`, `Colors.red[50]`, `Colors.orange[50]`, `Colors.grey[100]` (family invite code box) do not adapt; several are unreadable on dark surfaces. |
| U3 | P2 | **AppBar clutter.** All four tabs repeat Scan / Sync / Settings / (Web) Logout icons. Sync icon shows even in local-only mode. |
| U4 | P2 | **28 hardcoded English strings** remain: "Dashboard", "Unlock Medora", "Fingerprint Unlock", "Security", "Account", "Force Push/Pull" dialogs, "Undo Taken", "Date"/"Today"/"Yesterday" in the dose sheet, "Cancel", "Continue", "Error: …". `DateFormat('MMM dd, yyyy')` is created without a locale, so months are always English in DE/IT. |
| U5 | P2 | **Add Medication form** is a single 15-field scroll (1,097 lines). No grouping, no "quick add" path, no scan-first flow. Storage location dropdown silently drops custom values from older data. |
| U6 | P2 | **Prescription editor** offers only four fixed times (08/12/18/22); no custom time picker; "times per day" silently rewrites `intervalHours`. Editing a prescription's medication is disabled without explanation. |
| U7 | P2 | **Doses tab only shows today.** No way to see tomorrow, no week strip, no "take all due now", no undo snackbar after "Take". Overdue doses are only a tiny red label. |
| U8 | P2 | **Raw errors in UI** (`Text('Error: $e')` on Home cards, family screen) instead of a friendly retry state. |
| U9 | P2 | **Destructive swipe actions** (delete medication / treatment) have a confirm dialog but archive has none and no undo. Treatment list "Archive" for ended treatments actually **deletes** (`deleteTreatment`). |
| U10 | P2 | Settings mixes account, appearance, AIFA, notifications, sync, features, danger zone in one flat list with inconsistent section styling; Force Push/Pull are exposed at the same level as language selection. |
| U11 | P3 | No onboarding / first-run explanation of the medication → treatment → prescription → dose model. Empty states exist but do not explain that model. |
| U12 | P3 | Icons: `Icons.healing` for treatments, generic `Icons.medication` avatar for every medication regardless of `form`; category badge is a grey pill. Visual hierarchy relies on bold text sizes rather than the type scale. |

### 2.5 Code quality & tests

| # | Sev | Finding |
|---|-----|---------|
| Q1 | P1 | Single placeholder test (`expect(1 + 1, 2)`). Pure logic with real bug surface (`Prescription.scheduledDoseTimes`, dose generation, sync merge, LWW) has zero coverage. No CI. |
| Q2 | P2 | `_TagInputField` and `_FilterChip` are duplicated verbatim across screens. Unit lists (pieces/pills/…) duplicated in two screens. |
| Q3 | P2 | `family_providers.dart` re-declares `familyLocalDatasourceProvider` / `familyRemoteDatasourceProvider` already declared in `providers.dart` (two instances of each datasource). |
| Q4 | P2 | Static mutable state: `TodaysDoseLogsNotifier._startupCheckDone`, `ExpiryBadge._lastNow` caches, `ReminderService._navigationContext`. Hard to test, leaks across ProviderScope resets. |
| Q5 | P3 | `flutter_lints` defaults only; no `prefer_const_constructors`, `always_use_package_imports`, `unawaited_futures`, etc. `.idea/` committed. `README_TECH.md` duplicates `README.md` and both are stale (mobile_scanner, `supabase/migrations/001…` paths do not exist). |

## 3. Decisions and assumptions

These are the calls made for this design. Each is reversible; flag any you disagree with.

1. **Keep Supabase, make it optional.** The app has a clear *local-only* mode and an opt-in *cloud sync* mode. Local-only is the default and needs no configuration. Reason: the existing sync code is substantial and the TODO says auth for Supabase is wanted.
2. **Supabase credentials move from a bundled `.env` asset to `--dart-define`** (`SUPABASE_URL`, `SUPABASE_ANON_KEY`), with an optional runtime override entered in Settings for self-hosters. The `.env` asset entry is removed. Reason: fixes B1 and keeps secrets out of the asset bundle.
3. **Keep the Clean Architecture layout** (domain / data / presentation / services) and Riverpod 3. Reason: it is consistent and works; the problems are in specific units, not the shape.
4. **Keep sqflite** (with `sqflite_common_ffi` / `_web`). Do not migrate to Drift. Reason: migration risk is not justified; what is missing is a migration ledger, not an ORM.
5. **Keep OCR-based AIFA lookup** as the scanner, but gate it by platform capability and make the AIFA cache download an explicit, one-time, size-labelled action. A real barcode scanner (`mobile_scanner`) is deferred to a later phase.
6. **Dates use the active locale** everywhere via `DateFormat.yMMMd(locale)` style factories. No custom format strings.
7. **Scope is decomposed into five phases**, each its own implementation plan. Phase 0 is small and unblocks everything. Later phases can be re-ordered.

## 4. Target architecture changes

### 4.1 App mode

```
enum AppMode { localOnly, cloud }
```

- `appModeProvider` — `Notifier<AppMode>`, persisted in SharedPreferences (`app_mode`). Default `localOnly`.
- `SupabaseConfig.isConfigured` — true only when both dart-defines (or runtime overrides) are non-empty **and** `Supabase.initialize` succeeded.
- `SupabaseConfig.clientOrNull` — returns `null` when not configured. Remote datasources take the client via constructor and are only constructed when `appMode == cloud && isConfigured`. Repositories receive `remoteDatasource: null` in local-only mode and skip all background sync.
- `authStateProvider` returns a constant "no session" stream when not configured; it never throws.
- Router: one `GoRouter.redirect` handles auth + mode:
  - `localOnly` → never redirect to `/auth`.
  - `cloud` and no session → `/auth`.
  - Biometric lock becomes a **single** overlay in a `ShellRoute` builder (one observer), not per-route.
- Auth screen gains a prominent primary action **"Use Medora on this device"** (local-only) above the sign-in form. Sign-in / sign-up are the cloud path. "Continue as guest" (anonymous Supabase) is removed as a top-level option; anonymous sessions cannot be recovered and confuse the model.
- Settings → "Cloud sync" section: shows mode, "Turn on cloud sync" (sign in; existing local rows are marked `pending_create` and pushed; `user_id` is stamped at push time), "Turn off cloud sync" (keeps local data, signs out), and the manual Sync / Force Push / Force Pull under an "Advanced" expander.

### 4.2 Configuration

- `lib/core/app_config.dart`: reads `String.fromEnvironment('SUPABASE_URL')` / `SUPABASE_ANON_KEY`, then SharedPreferences overrides (`supabase_url`, `supabase_key`). Exposes `isCloudAvailable`.
- Remove `flutter_dotenv` and the `.env` asset. Keep `.env.example` renamed to `dart_defines.example.json` with a documented `--dart-define-from-file` invocation.

### 4.3 Local database migrations

- `AppDatabase` keeps `version` and implements `_onUpgrade` with an ordered list of `Migration(int toVersion, Future<void> Function(Database))`. A `schema_migrations` table records applied versions.
- Migration 11 (Phase 0): add `deleted_at TEXT` tombstone column to the four synced tables. Migration 12 (Phase 1): `dose_logs.updated_at` writes, `photo_file TEXT` (relative filename) alongside `image_path`, backfilled from the `image_path` basename.
- `_toRow` functions stop overwriting `updated_at`; the **repository** sets `updatedAt = now()` on user mutations, and pulls keep the remote `updated_at`.

### 4.4 Reminders

- New `ReminderScheduler` (replaces ad-hoc scheduling in `TodaysDoseLogsNotifier`):
  - `reconcile()` — cancels all pending notifications and re-schedules pending doses for the next **7 days**, capped at 60 notifications (iOS limit is 64), earliest first. Called on app start, after any dose/prescription mutation, on reminders toggle, and from a lightweight `WorkManager`-free approach: on every foreground resume.
  - Reads `remindersEnabledProvider`; when disabled, `reconcile()` only cancels.
  - Uses a stable notification id derived from `dose.id` (FNV-1a 31-bit), not `String.hashCode`.
  - Deep-links to `/doses?date=YYYY-MM-DD` and opens the dose sheet for the payload id.
- Notification actions "Take" / "Skip" on Android (background-capable) are **Phase 3**.

### 4.5 Dose maintenance

- `DoseMaintenanceService.markOverdueAsMissed()` — on app start and resume, mark pending doses whose `scheduled_time < now - graceMinutes` (default 120, user-configurable in Settings → Notifications) as `missed`. Runs locally, marks rows `pending_update`.
- `Prescription.scheduledDoseTimes` gains explicit unit tests (fixed interval, times-per-day, DST boundary, 1000 cap).

### 4.6 Sync (Phase 3)

- Tombstones: `deleteX` sets `deleted_at` + `pending_delete`; pull applies remote `deleted_at` rows as local hard-deletes. Supabase schema gets `deleted_at TIMESTAMPTZ` and a `sync_delete` policy; hard purge happens server-side later.
- Pull uses `updated_at > last_pull_at` (delta) instead of full table scans; `last_pull_at` per table in SharedPreferences.
- Per-row push errors are collected into a `SyncReport { pushed, pulled, failed: List<(table,id,error)> }` exposed via `syncStateStreamProvider`; Settings shows the last report.
- Family: push members; `leaveFamily`/`removeMember` become pending operations.

### 4.7 Presentation

- **Design tokens**: `AppTheme` exposes only `ColorScheme`-derived colors plus a small semantic set (`success`, `warning`, `danger`, `dosePending`) built with `ColorScheme.fromSeed` harmonization, each with a dark variant. No `Colors.grey[…]` in screens. `AppTheme.primaryColor` is deleted; call sites use `colorScheme.primary`.
- **Fonts**: bundle Inter (Regular/Medium/SemiBold/Bold) under `assets/fonts/`, remove `google_fonts`.
- **Shell**: `NavigationBar` unchanged in structure; AppBar actions reduced to one contextual action per tab (Medications: search; Doses: history; Home: settings). Sync status becomes a small status chip in the Home header only in cloud mode.
- **Home**: "Now" card (next due dose with Take button, or "all done"), then compact stat tiles (Expiring · Low stock · Active treatments), then lists. Uses `colorScheme.primaryContainer` instead of a hardcoded gradient.
- **Doses**: horizontal 7-day date strip (today centered), day grouped into Morning / Afternoon / Evening / Night, "Take all due" button when ≥2 overdue, undo `SnackBar` after every status change, overdue rows tinted with `errorContainer`.
- **Medication form**: three collapsible sections — *Basics* (name, form, quantity+unit, expiry), *Stock* (min stock, storage, purchase date, barcode/scan), *Details* (ingredients, symptoms, patients, manufacturer, ATC, photo, notes). Scan and AIFA search sit at the top as chips. Shared `TagInputField`, `DatePickerField`, `UnitDropdown` widgets move to `presentation/widgets/forms/`.
- **Prescription sheet**: times-per-day gets an editable chip list with a `showTimePicker` "+" chip; interval mode shows a computed preview ("08:00, 16:00, 00:00"); medication change is allowed in edit mode with a confirmation that pending doses will be regenerated.
- **Lists**: archive via swipe gets an undo snackbar; treatment "Archive" is renamed/behaves as "Delete" with confirm, or is removed.
- **Errors**: shared `AsyncValueView` widget renders loading / error(retry) / data consistently; no raw `$e` in UI (message in a "details" expander only).
- **Localization**: all 28 strings moved to ARB; `DateTimeExtensions` take `Locale` from context (`context.l10n.localeName`).
- **Onboarding**: three-card first-run sheet (Cabinet → Treatments → Doses) shown once; empty states reuse the same copy.

### 4.8 Platform

- iOS `Info.plist`: add camera, photo library, Face ID usage strings.
- Android: document keystore setup (`key.properties`), signing config reads it when present, falls back to debug only in debug builds.
- Web: `manifest.json` name/colors/description fixed; scanner and photo capture hidden on web/desktop via a `PlatformCapabilities` provider (`hasCamera`, `hasLocalNotifications`, `hasFileShare`).
- Desktop (Linux/Windows): `flutter_local_notifications_linux` is already a transitive dep; enable Linux notifications instead of early-returning.

## 5. Phases

Each phase becomes one implementation plan and one PR. Order is dependency-driven; Phases 2 and 3 are independent of each other.

### Phase 0 — Build & local-only foundation (unblocks everything)
- Remove `.env` asset and `flutter_dotenv`; add `AppConfig` with dart-defines. (B1, B2)
- `AppMode` provider, `SupabaseConfig.clientOrNull`, null-safe remote datasources, router redirect, single biometric overlay. (B2, B3, F11)
- Auth screen: "Use on this device" primary path. (B6)
- Bundle Inter; remove `google_fonts`. (B4)
- Migration ledger + migration 11. (B5)
- iOS usage strings; Web manifest; `PlatformCapabilities` provider and gating of scanner/photo/export. (R1, R3, B8, B9)
- Fix `appVersion`, deprecated `anonKey`. (F13, R4)
- Test harness: `ProviderContainer` factory with in-memory sqflite (`sqflite_common_ffi`), first unit tests for `Prescription.scheduledDoseTimes` and `AppDatabase` migrations. CI workflow: `flutter analyze`, `flutter test`, `flutter build web`.

**Exit criteria:** fresh clone → `flutter run` on Linux and Android with no config → add medication, create treatment, add prescription, take dose, restart app, still there. `flutter test` green in CI.

### Phase 1 — Correctness
- `ReminderScheduler` with 7-day horizon and toggle respected. (F1, F2)
- `DoseMaintenanceService` overdue → missed with grace period. (F4)
- `updateStatus` clears `taken_time` on pending; repositories return real rows. (F3, F8)
- `updated_at` semantics fixed; dose_logs write it. (F5)
- Relative photo paths + backfill. (F10)
- `expiringSoonProvider` excludes expired; "Needs attention" filter unified. (F9)
- Mutations update state in place (`AsyncData(previous)`) instead of `AsyncLoading`. (F14)
- Delete-all cancels notifications and deletes photos; sign-out in cloud mode offers "keep local copy / wipe". (F12)
- Tests for each fix.

### Phase 2 — UI/UX modernization
- Design tokens and dark-mode audit (U1, U2); AppBar cleanup (U3); localization sweep and locale-aware dates (U4).
- Home redesign; Doses date strip + grouping + take-all + undo (U7).
- Medication form sections and shared form widgets (U5, Q2); prescription sheet improvements (U6).
- Consistent `AsyncValueView`, empty states, onboarding (U8, U11); swipe-action undo and treatment archive fix (U9); Settings regrouping (U10).
- Golden tests for Home / Doses / Medication form in light and dark.

### Phase 3 — Sync robustness (cloud mode only)
- Tombstones, delta pull, `SyncReport`, family member push, auto-sync on reconnect. (F6, F7)
- "Turn on cloud sync" migration of existing local rows.
- Supabase schema migration script under `supabase/migrations/002_tombstones.sql`; README updated.
- Integration tests against a local Supabase (`supabase start`) in CI, gated behind a label.

### Phase 4 — Quality & release
- Stricter lints (`very_good_analysis` or a curated set), remove duplicated providers (Q3), remove static mutable state (Q4), dependency upgrades (R5), Android release signing docs (R2), README consolidation, `.idea/` removal (Q5).
- Optional: `mobile_scanner` real barcode scanning alongside OCR; Android notification actions.

## 6. Testing strategy

- **Unit**: entities (`Prescription`, `Medication`), `ReminderScheduler` id derivation and horizon, `DoseMaintenanceService`, `SyncService` merge (with fake datasources), `AppDatabase` migrations (open v10 fixture → upgrade → assert columns).
- **Widget**: `AuthScreen` local-only path, `DoseScheduleScreen` take/undo, `AddMedicationScreen` validation, `SettingsScreen` reminders toggle actually cancels.
- **Golden**: key screens light/dark at 360×800 and 412×915.
- **Integration (Phase 3)**: two `ProviderContainer`s sharing one local Supabase, assert convergence after push/pull including deletes.
- **CI**: GitHub Actions, `subosito/flutter-action` pinned to `.fvmrc`, jobs: analyze, test, build-web, build-apk (debug).

## 7. Out of scope (for now)

- Replacing sqflite with Drift or Isar.
- Push notifications via FCM / Supabase Edge Functions.
- Non-Italian medication databases (OpenFDA, DIMDI). Category/ingredient data stays free-text tags.
- Multi-patient profiles as first-class entities (patient tags remain).
- Wear OS / widgets / Live Activities.

## 8. Resolved questions

1. **"Continue as guest" (Supabase anonymous auth) is removed entirely.** Local-only mode is the no-account path.
2. **Missed-dose grace period:** 2 hours after scheduled time, applied on app start and resume. User-configurable in Settings → Notifications.
3. **Reminder horizon:** 7 days ahead, capped at 60 pending notifications.
4. **AIFA remains the primary lookup source.** The user is in Italy; AIC codes on packaging are the target. Other national databases stay out of scope.
