# Phase 4 — Quality & Release Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Leave the codebase in a maintainable, releasable state: stricter lints and formatting enforced by CI, no static mutable state, an injectable clock everywhere the UI depends on "now", current dependencies, a real Android release signing path with documentation, a consolidated README, and the small correctness leftovers deferred from Phases 2–3 closed.

**Architecture:** No new subsystems. Each task is a bounded cleanup with its own tests and a green CI gate: (1) format + curated lints + CI gates, (2) static state and clock injection, (3) deferred correctness fixes, (4) dependency upgrades with the lockfile committed, (5) release signing + repo hygiene + docs.

**Tech Stack:** Flutter 3.44.6 (`fvm`), Dart 3.11, flutter_lints + curated rules, `dart format`, GitHub Actions, Gradle Kotlin DSL (`android/app/build.gradle.kts`).

## Global Constraints

- Spec: `docs/superpowers/specs/2026-09-14-medora-offline-first-overhaul-design.md` §2.3 (R2, R4, R5), §2.5 (Q2, Q4, Q5), §5 Phase 4. The two "Optional" items (mobile_scanner barcode scanning, Android notification actions) are **out of scope** for this plan.
- Flutter runs via `fvm` (`fvm flutter ...`). Package imports only. Every task ends with `fvm flutter analyze --fatal-infos` clean, `dart format --set-exit-if-changed .` clean (from Task 1 on), and `fvm flutter test` green (baseline after Phase 3: 183 tests + 1 skipped integration test; goldens under `test/goldens/` must still match — regenerate only when a task deliberately changes rendering, view the PNG, and say so in the report).
- Behaviour-preserving unless a task says otherwise. Local-only mode untouched.
- ARB en/de/it for every new user-facing string; `fvm flutter gen-l10n`; commit `lib/l10n/generated/`; `untranslated.txt` = `{}`.
- Secrets never enter git: `android/key.properties` and `*.jks` stay ignored; CI builds sign with debug when no keystore secrets are configured.
- Commits end with the two attribution lines from the session's system reminder.

---

## File structure

| Path | Responsibility |
|---|---|
| `analysis_options.yaml` | Curated lint set. |
| `.github/workflows/ci.yml` | Adds `dart format` gate; release-signing env for the Android build. |
| `lib/core/clock.dart` (new) | `typedef Now = DateTime Function();` and a `SystemClock` default — the single "now" type used by entities and providers. |
| `lib/domain/entities/medication.dart`, `dose_log.dart` | Expiry/overdue helpers take an explicit `DateTime now` (default `DateTime.now()`). |
| `lib/presentation/widgets/shared_widgets.dart` | `ExpiryBadge` without static caches. |
| `lib/services/reminder_service.dart`, `lib/main.dart`, `lib/presentation/router/app_router.dart` | Notification tap navigates through a `GlobalKey<NavigatorState>`/router instance instead of a stored `BuildContext`. |
| `lib/services/export_service.dart`, `reminder_service.dart` | Localized status values / unit labels. |
| `lib/presentation/screens/settings/settings_screen.dart` | Awaited mode switch with error feedback. |
| `pubspec.yaml`, `pubspec.lock`, `.gitignore` | Upgraded deps; lockfile committed; codegen dev-deps dropped. |
| `android/app/build.gradle.kts`, `android/key.properties.example` (new), `docs/release.md` (new) | Release signing from `key.properties` with debug fallback; how-to. |
| `README.md`, `docs/architecture.md` (new) | Consolidated docs. |
| `.idea/` | Removed from git. |

---

### Task 1: Formatting + curated lints + CI gates

**Files:**
- Modify: `analysis_options.yaml`, `.github/workflows/ci.yml`, every Dart file touched by `dart format` and by the new lints.
- Test: none new (the gates are the test).

**Interfaces:** none.

- [ ] **Step 1: Format the repo in its own commit**

```bash
fvm dart format .
fvm flutter test          # must stay green — formatting is behaviour-neutral
git add -A && git commit -m "style: dart format the repository"
```
If `dart format` changes any golden test file it does not change rendering; goldens must still pass without regeneration.

- [ ] **Step 2: Curated lints**

Replace `analysis_options.yaml` with:
```yaml
include: package:flutter_lints/flutter.yaml

analyzer:
  exclude:
    - lib/l10n/generated/**
  language:
    strict-casts: true
    strict-inference: true

linter:
  rules:
    always_use_package_imports: true
    avoid_print: true
    avoid_redundant_argument_values: true
    avoid_void_async: true
    cancel_subscriptions: true
    close_sinks: true
    directives_ordering: true
    prefer_const_constructors: true
    prefer_const_declarations: true
    prefer_final_locals: true
    prefer_single_quotes: true
    sort_pub_dependencies: true
    unawaited_futures: true
    unnecessary_lambdas: true
    unnecessary_parenthesis: true
    use_super_parameters: true
```
Run `fvm flutter analyze --fatal-infos` and fix every finding. Rules of engagement: `unawaited_futures` findings are fixed with `await` where the caller is already async and the result matters, otherwise `unawaited(...)` with a one-line reason comment; `avoid_void_async` findings become `Future<void>`; never add `// ignore` lines except for a documented false positive (list each one in the report). Do not weaken the list to get green — if a rule produces >150 mechanical findings, fix them; if it produces a genuine false-positive class, drop that single rule and say why.

- [ ] **Step 3: CI gates**

In `.github/workflows/ci.yml`, in the `test` job after `flutter pub get`:
```yaml
      - run: dart format --set-exit-if-changed .
```
(before `flutter analyze`). Keep the existing gen-l10n diff gate.

- [ ] **Step 4: Verify** `fvm flutter analyze --fatal-infos`, `fvm dart format --set-exit-if-changed .`, `fvm flutter test` green. **Commit** — `chore(lints): curated lint set and format gate` (the format commit from Step 1 stays separate).

---

### Task 2: No static mutable state; injectable clock for expiry/overdue

**Files:**
- Create: `lib/core/clock.dart`
- Modify: `lib/domain/entities/medication.dart`, `lib/domain/entities/dose_log.dart`, `lib/presentation/widgets/shared_widgets.dart` (`ExpiryBadge`), `lib/presentation/providers/medication_providers.dart` (`expiringSoonProvider`, `lowStockProvider` if it reads now), `lib/presentation/screens/home/home_screen.dart:~491`, `medication_list_screen.dart:~264`, `dose_history_screen.dart`, `export_screen.dart`, `prescription_sheet.dart`, `add_treatment_screen.dart`, `date_picker_field.dart`, `settings_screen.dart`, `dose_providers.dart` (every `DateTime.now()` in `lib/presentation` and `lib/domain` — 17 sites; see `grep -rn 'DateTime.now()' lib/presentation lib/domain`), `lib/services/reminder_service.dart`, `lib/main.dart`, `lib/presentation/router/app_router.dart`, `test/goldens/golden_config.dart` (+ regenerated Home goldens)
- Test: `test/domain/entities/medication_test.dart` (new or extend), `test/presentation/widgets/expiry_badge_test.dart` (new), `test/services/reminder_navigation_test.dart` (new), goldens

**Interfaces:**
- Produces: `lib/core/clock.dart`:
```dart
/// Medora - Injectable clock.
library;

typedef Now = DateTime Function();

DateTime systemNow() => DateTime.now();
```
  `nowProvider` (already `Provider<DateTime Function()>`) keeps its type; callers use `ref.watch(nowProvider)()`.
- Produces: `Medication.isExpiringSoon({int days = 30, DateTime? now})`, `Medication.isExpired({DateTime? now})` → keep `isExpired` as a getter for source compatibility AND add `bool expiredAt(DateTime now)`; `daysUntilExpiry(DateTime now)`; `DoseLog.isOverdueAt(DateTime now)` alongside the existing getter.
- Produces: `ReminderService.navigate` uses `GoRouter` from a `static GoRouter? router` set once in `main.dart` (`ReminderService.router = ref.read(appRouterProvider)`) — no `BuildContext` stored. Justify: a router reference is not widget-lifecycle-bound; a `BuildContext` is.

- [ ] **Step 1: Entity tests**

`test/domain/entities/medication_test.dart` (create if missing; otherwise append):
```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/domain/entities/medication.dart';

void main() {
  final now = DateTime(2026, 3, 4, 15);

  test('isExpiringSoon and expiredAt use the injected clock', () {
    final soon = Medication(id: 'a', name: 'a', quantity: 1, expiryDate: DateTime(2026, 3, 20));
    final far = Medication(id: 'b', name: 'b', quantity: 1, expiryDate: DateTime(2027, 1, 1));
    final past = Medication(id: 'c', name: 'c', quantity: 1, expiryDate: DateTime(2026, 3, 1));

    expect(soon.isExpiringSoon(now: now), isTrue);
    expect(far.isExpiringSoon(now: now), isFalse);
    expect(past.isExpiringSoon(now: now), isFalse);
    expect(past.expiredAt(now), isTrue);
    expect(soon.expiredAt(now), isFalse);
    expect(soon.daysUntilExpiry(now), 16);
  });

  test('defaults keep working without a clock', () {
    final far = Medication(id: 'b', name: 'b', quantity: 1, expiryDate: DateTime(2099, 1, 1));
    expect(far.isExpiringSoon(), isFalse);
    expect(far.isExpired, isFalse);
  });
}
```

- [ ] **Step 2: Implement entity clock parameters** (`Medication`: `isExpiringSoon({int days = 30, DateTime? now})` computes with `final ref = now ?? DateTime.now();`; `bool get isExpired => expiredAt(DateTime.now());`; `bool expiredAt(DateTime now)`; `int? daysUntilExpiry(DateTime now)` = `expiryDate == null ? null : DateTime(expiryDate.y, m, d).difference(DateTime(now.y, m, d)).inDays`. `DoseLog`: `bool isOverdueAt(DateTime now)`; the existing `isOverdue` getter delegates.)

- [ ] **Step 3: Presentation call sites** — replace every `DateTime.now()` in `lib/presentation` with `ref.watch(nowProvider)()` (widgets with `WidgetRef`) or a `now` parameter passed down from the nearest `Consumer` (e.g. `ExpiryBadge(expiryDate: ..., now: now)`). `expiringSoonProvider` reads `ref.watch(nowProvider)()` and passes it to `isExpiringSoon(now:)`/`expiredAt`. `ExpiryBadge` loses `_lastNowCache/_lastNow/_getCachedNow` entirely (the cache existed to avoid `DateTime.now()` per build; with an injected `now` it is unnecessary). Date pickers (`date_picker_field.dart`, `add_treatment_screen.dart`, `prescription_sheet.dart`) use `now` for `initialDate`/`firstDate` defaults. Export/history screens use `now` for default ranges.

- [ ] **Step 4: ExpiryBadge widget test** `test/presentation/widgets/expiry_badge_test.dart`: pump `ExpiryBadge` with `expiryDate: DateTime(2026, 3, 10)` and `now: DateTime(2026, 3, 4)` → shows the "6 days" wording from l10n (read the exact key in `shared_widgets.dart`); with `now` after the date → the expired wording.

- [ ] **Step 5: Reminder navigation without BuildContext** — in `reminder_service.dart` replace `static BuildContext? _navigationContext` + `setNavigationContext(context)` with `static GoRouter? router;` and `router?.go('/doses')` in the notification-tap handler; in `main.dart` replace `ReminderService.setNavigationContext(context)` with `ReminderService.router = ref.read(appRouterProvider)` (do it where the router provider is read for `MaterialApp.router`). Test `test/services/reminder_navigation_test.dart`: create a `GoRouter` with a `/doses` route and a `/` route, assign it, call the public method that handles a notification tap (find its name; if it is private, expose `@visibleForTesting void handleNotificationTap(String? payload)`), and assert `router.state.uri.path == '/doses'` (or `routerDelegate.currentConfiguration`).

- [ ] **Step 6: Goldens** — `test/goldens/golden_config.dart`: with the clock now injected, give `m2` an expiry inside the 30-day window again (`DateTime(2026, 3, 20)` — 16 days from the golden clock) and add a comment; regenerate the two Home goldens with `fvm flutter test --update-goldens test/goldens/home_golden_test.dart`, open both PNGs and confirm the Expiring Soon card now lists Moment 200 with a stable day count. Doses/Add Medication goldens must not change.

- [ ] **Step 7: Verify** analyze (incl. the static-state check: `grep -rn 'static DateTime\|static BuildContext' lib/` returns nothing), format, full tests. **Commit** — `refactor: injectable clock for expiry/overdue; no static mutable state`

---

### Task 3: Deferred correctness fixes

**Files:**
- Modify: `lib/services/reminder_service.dart` (notification body unit label), `lib/services/export_service.dart` (localized status values in PDF/CSV), `lib/presentation/screens/settings/settings_screen.dart` (awaited `set(AppMode.cloud)` with error snackbar), `lib/services/reminder_scheduler.dart` (`_reconcileOnce` failure reporting), `test/helpers/pump_app.dart` + `test/goldens/golden_config.dart` (restore `Intl.defaultLocale` in `addTearDown`)
- Test: `test/services/reminder_service_body_test.dart` (new; pure function), `test/services/export_service_test.dart` (new or extend), `test/presentation/screens/settings_screen_test.dart` (extend)

**Interfaces:**
- Produces: `String reminderBody(AppLocalizations l10n, DoseLog dose)` — a top-level function in `lib/services/reminder_text.dart` (new) that builds the body with `AppConstants.unitLabel(l10n, unit)` when `dosageAmount`/`medicationUnit` are set and falls back to the stored `dosage`; `reminder_service.dart` uses it. `lib/presentation/formatters.dart`'s `dosageLabel` delegates to the same function so both stay identical (services must not import presentation; presentation may import services).

- [ ] **Step 1: Tests**

`test/services/reminder_service_body_test.dart`:
```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/domain/entities/dose_log.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/services/reminder_text.dart';

void main() {
  test('reminder body localizes the unit in Italian', () {
    final l10n = lookupAppLocalizations(const Locale('it'));
    final dose = DoseLog(id: 'd', prescriptionId: 'p', scheduledTime: DateTime(2026, 3, 4, 8), dosageAmount: 1, medicationUnit: 'tablets');
    final body = reminderBody(l10n, dose);
    expect(body, isNot(contains('tablets')));
    expect(body, contains(l10n.unitTablets)); // use the actual unit key name from app_en.arb
  });
}
```
(`import 'package:flutter/widgets.dart';` for `Locale`.) Export test: `ExportService` CSV/PDF row status uses `l10n.doseStatusTaken` etc. — find the existing status keys (`grep -n '"taken"\|"skipped"\|"missed"\|"pending"' lib/l10n/app_en.arb`); assert an Italian export contains the Italian word and not `taken`. Settings test: override `appModeProvider` with a notifier whose `set` throws; tap "Turn on"; expect a SnackBar with `l10n.errorWithDetails(...)` text prefix and the mode still local-only.

- [ ] **Step 2: Implement** — `reminder_text.dart`; `reminder_service.dart:141` uses `reminderBody(l10n, dose)` when `l10n != null` (keep the English fallback otherwise); `export_service.dart` maps `DoseStatus` → l10n string (it already receives `l10n` for headers — verify); `settings_screen.dart` "Turn on": `onPressed: () async { try { await ref.read(appModeProvider.notifier).set(AppMode.cloud); } catch (e) { if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.errorWithDetails('$e')))); } }`; `reminder_scheduler.dart` `_reconcileOnce`: on failure, `debugPrint` and return `-1`? No — keep the count contract; instead expose `Object? lastError` set on failure and cleared on success (tested: failing port → `lastError` non-null). Tests: `Intl.defaultLocale` — in `pumpMedoraApp` and `pumpGolden`, capture the previous value and restore it in `addTearDown`.

- [ ] **Step 3: Verify** analyze, format, tests; `untranslated.txt` `{}`. **Commit** — `fix: localized reminder bodies and export statuses; surfaced cloud-switch errors`

---

### Task 4: Dependency upgrades, lockfile, codegen dev-deps removed

**Files:**
- Modify: `pubspec.yaml`, `pubspec.lock` (now committed), `.gitignore`, any call sites broken by majors.
- Test: existing suite + CI `build-web` / `build-android`.

**Interfaces:** none.

- [ ] **Step 1: Commit the lockfile** — in `.gitignore` add after `*.lock`: `!pubspec.lock`; `git add pubspec.lock`; commit `chore: track pubspec.lock`. (An application must build reproducibly; CI currently re-resolves on every run.)

- [ ] **Step 2: Remove unused codegen** — `grep -rn "freezed\|json_annotation\|riverpod_annotation\|JsonSerializable\|@riverpod\|part '.*\.g\.dart'" lib/ test/` must be empty (it is today). Remove `freezed_annotation`, `json_annotation`, `riverpod_annotation` from `dependencies` and `build_runner`, `freezed`, `json_serializable`, `riverpod_generator` from `dev_dependencies`; also remove `*.g.dart`/`*.freezed.dart` from `.gitignore` if present. `fvm flutter pub get`, analyze, test. Commit `chore(deps): drop unused code generation packages`.

- [ ] **Step 3: Upgrade majors one package per commit**, in this order, each followed by `fvm flutter pub get`, `fvm flutter analyze --fatal-infos`, `fvm flutter test`, and a fix of any breaking API:
  1. `flutter_riverpod: ^3.4.3` (minor; also bumps `riverpod`).
  2. `go_router: ^18.0.0` — read the 18.0 changelog (`fvm flutter pub outdated --json` gives the version; changelog at pub.dev); typical breaks: `GoRouterState` API renames, `redirect` signature. Router tests must pass.
  3. `flutter_local_notifications: ^22.0.0` — check `AndroidNotificationDetails`, `zonedSchedule` `androidScheduleMode` param changes, `flutter_local_notifications_linux`/`windows` platform packages; `ReminderService` compiles; `reminder_scheduler_test` green (it uses a fake port, so behaviour is unaffected).
  4. `local_auth: ^3.0.0` — `authenticate(options: AuthenticationOptions(...))` changes; biometrics gated by capabilities so tests are unaffected; verify `auth`/settings code compiles.
  5. `share_plus: ^13.0.0` — `Share.shareXFiles` → `SharePlus.instance.share(ShareParams(...))`; update `export_screen.dart`/`export_service.dart`.
  6. `package_info_plus: ^10.0.0` — API unchanged in practice; verify `appVersionProvider`.
  7. `csv: ^8.0.0` — `ListToCsvConverter` unchanged; verify export test.
  8. `google_mlkit_text_recognition: ^0.17.0` — scanner compiles.
  9. `pdf: ^3.13.0`, `intl: ^0.20.3` (minor).
  Each commit: `chore(deps): upgrade <package> to <version>`. If a major upgrade requires more than ~30 lines of adaptation or breaks a platform build in CI, revert that single package to its previous constraint, note it in the report as deferred, and continue.

- [ ] **Step 4: Verify** `fvm flutter pub outdated` shows no remaining upgradable direct majors except any deliberately deferred; analyze, format, tests green; push the branch and confirm CI `build-web` and `build-android` pass before moving on (dependency changes are the most likely thing to break a platform build).

---

### Task 5: Android release signing, repo hygiene, docs

**Files:**
- Modify: `android/app/build.gradle.kts`, `.gitignore` (already ignores `**/android/key.properties` and `*.jks` — verify), `.github/workflows/ci.yml` (`build-android` job builds `appbundle --release` when secrets exist, else `apk --debug`), `README.md`
- Create: `android/key.properties.example`, `docs/release.md`, `docs/architecture.md`
- Delete from git: `.idea/` (11 tracked files)
- Test: none new (CI build + `flutter build apk --debug` locally)

- [ ] **Step 1: Signing config**

`android/key.properties.example`:
```properties
storeFile=../keystore/medora-release.jks
storePassword=CHANGE_ME
keyAlias=medora
keyPassword=CHANGE_ME
```
`android/app/build.gradle.kts` — before `android {`:
```kotlin
import java.util.Properties
import java.io.FileInputStream

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
val hasReleaseKeystore = keystorePropertiesFile.exists()
if (hasReleaseKeystore) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}
```
inside `android { ... }`:
```kotlin
    signingConfigs {
        if (hasReleaseKeystore) {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }
    buildTypes {
        release {
            // Signed with the release keystore when android/key.properties exists,
            // otherwise with the debug key so `flutter run --release` still works.
            signingConfig = if (hasReleaseKeystore) signingConfigs.getByName("release") else signingConfigs.getByName("debug")
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }
```
(keep whatever `isMinifyEnabled`/proguard lines already exist; do not add proguard rules that are not there). Verify locally: `fvm flutter build apk --debug` succeeds and, with a throwaway keystore (`keytool -genkeypair ...` into a temp dir, `key.properties` pointing at it), `fvm flutter build apk --release` signs with it (`apksigner verify --print-certs` or `jarsigner -verify`); delete the temp keystore and `key.properties` afterwards and confirm `git status` shows neither.

- [ ] **Step 2: CI** — `build-android` job: add
```yaml
      - name: Configure release signing (when secrets exist)
        if: ${{ secrets.ANDROID_KEYSTORE_BASE64 != '' }}
        run: |
          mkdir -p android/keystore
          echo "$ANDROID_KEYSTORE_BASE64" | base64 -d > android/keystore/medora-release.jks
          printf 'storeFile=../keystore/medora-release.jks\nstorePassword=%s\nkeyAlias=%s\nkeyPassword=%s\n' "$ANDROID_STORE_PASSWORD" "$ANDROID_KEY_ALIAS" "$ANDROID_KEY_PASSWORD" > android/key.properties
        env:
          ANDROID_KEYSTORE_BASE64: ${{ secrets.ANDROID_KEYSTORE_BASE64 }}
          ANDROID_STORE_PASSWORD: ${{ secrets.ANDROID_STORE_PASSWORD }}
          ANDROID_KEY_ALIAS: ${{ secrets.ANDROID_KEY_ALIAS }}
          ANDROID_KEY_PASSWORD: ${{ secrets.ANDROID_KEY_PASSWORD }}
      - run: flutter build apk --debug
      - name: Release bundle (when secrets exist)
        if: ${{ secrets.ANDROID_KEYSTORE_BASE64 != '' }}
        run: flutter build appbundle --release
      - if: ${{ secrets.ANDROID_KEYSTORE_BASE64 != '' }}
        uses: actions/upload-artifact@v4
        with:
          name: medora-release-aab
          path: build/app/outputs/bundle/release/*.aab
```
(GitHub evaluates `secrets.X != ''` in `if:` at the job/step level; if the runner rejects it, gate on a `vars.ANDROID_RELEASE_SIGNING == 'true'` repository variable instead and document it.)

- [ ] **Step 3: `.idea/` out of git** — `git rm -r --cached .idea` (the `.gitignore` already lists `.idea`); commit `chore: stop tracking .idea`.

- [ ] **Step 4: Docs**
  - `docs/release.md`: generating a keystore (`keytool -genkeypair -v -keystore medora-release.jks -alias medora -keyalg RSA -keysize 2048 -validity 10000`), placing `key.properties`, local release build commands (`fvm flutter build appbundle --release --dart-define-from-file=dart_defines.json`), the four GitHub secrets, versioning (`version:` in `pubspec.yaml`, `+build` must increase per Play upload), iOS note (signing via Xcode; `Info.plist` usage strings already present), web build (`flutter build web --release`, `manifest.json`).
  - `docs/architecture.md` (≤ 120 lines): layers (`core/domain/data/services/presentation`), app modes, local DB + migration ledger, reminders (scheduler diff, horizon 7 days / 60), dose maintenance (2 h grace), sync (push pending → delta pull, tombstones, LWW, `SyncReport`, cursors, family RPC), theme tokens + l10n rules and the guard tests, testing layout (unit / widget / goldens / integration).
  - `README.md`: keep it short — what Medora is, features (bullets), platforms, quick start (fvm, run), offline-first statement, cloud sync (link to the section already there), development commands (analyze, format, test, gen-l10n, goldens update, integration test), links to `docs/architecture.md`, `docs/release.md`, `docs/superpowers/specs/…`. Remove any stale statements (check for mentions of packages or paths that no longer exist).

- [ ] **Step 5: Verify** analyze, format, tests; push branch, CI green (`build-android` debug path). **Commit(s)** — `build(android): release signing from key.properties with debug fallback`, `docs: release guide, architecture overview, README consolidation`.

---

## Phase 4 exit criteria

- [ ] `fvm flutter analyze --fatal-infos`, `dart format --set-exit-if-changed .`, `fvm flutter test` all green locally and in CI; goldens regenerated only in Task 2 (Home) with the populated Expiring Soon card.
- [ ] `grep -rn 'DateTime.now()' lib/presentation lib/domain` returns nothing; `grep -rn 'static DateTime\|static BuildContext' lib/` returns nothing.
- [ ] DE/IT: notification bodies, export statuses and every screen show no raw unit keys or English.
- [ ] `pubspec.lock` tracked; no unused codegen packages; `fvm flutter pub outdated` shows no upgradable direct majors except those listed as deferred in the report.
- [ ] `android/key.properties` absent from git; release build signs with a keystore when present; `docs/release.md` explains it; `.idea/` untracked.
- [ ] README ≤ ~120 lines with working links; `docs/architecture.md` matches the code.
