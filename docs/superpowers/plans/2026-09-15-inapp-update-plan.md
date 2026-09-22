# In-app Updates from GitHub Releases — Implementation Plan

> **Status: a record, not a checklist.** The work in this plan has shipped.
> The `- [ ]` boxes below were never ticked as it went and are not a progress
> record — they are the plan's original step markers, left as written. What
> actually landed is in the git history for the files each step names, and in
> `docs/architecture.md` for the shape it settled into.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Tagged releases produce signed, predictably named APKs on GitHub Releases, and the Android app can find, download, verify and install the newest one from Settings or a Home banner.

**Architecture:** A pure-Dart `AppUpdateService` over `package:http` (testable with `MockClient`) does the GitHub API call, version comparison, asset choice, streamed download and SHA-256 verification; `OpenFilex` hands the APK to the Android installer. An `AppUpdateNotifier` holds the sealed `UpdateStatus`; `AppStartupTasks` gets an optional throttled `updateCheck` step; Settings and Home render the state. CI gains a tag-triggered `release.yml`; `tools/release.sh` cuts tags.

**Tech Stack:** Flutter 3.44.6 (`fvm`, Dart 3.12), flutter_riverpod 3, `http` (present), `package_info_plus` (present), `path_provider` (present), new: `device_info_plus`, `open_filex`, `crypto` (sha256 — check if transitively available; add as a direct dep). GitHub Actions + `gh` CLI.

## Global Constraints

- Design: `docs/superpowers/specs/2026-09-15-inapp-update-design.md` (assumptions §7 are decisions).
- Flutter via `fvm` (`fvm dart format`, never bare `dart`); curated lints + `dart format --set-exit-if-changed .` gate; `fvm flutter analyze --fatal-infos` clean; `fvm flutter test` green (baseline 223 + 2 skipped after the follow-ups branch; goldens unchanged unless a task says so); guards `theme_sweep`, `l10n_sweep`, `clock_sweep` stay green (no `DateTime.now()` in presentation — use `nowProvider`; services may use the injected `now` seam).
- Package imports only; theme tokens only; ARB en/de/it + `fvm flutter gen-l10n`, commit generated, `untranslated.txt` = `{}`.
- Asset naming exactly: `medora-<version>-<build>-<abi>.apk` (`abi` ∈ `arm64-v8a`, `armeabi-v7a`, `x86_64`, `universal`), `medora-<version>-<build>.aab`, `SHA256SUMS.txt`. Tag `v<version>+<build>`.
- The release workflow never signs with the debug key: it fails if `ANDROID_KEYSTORE_BASE64` is empty.
- Network code lives only in `lib/services/app_update_service.dart`; nothing in presentation calls `http`.
- Commits end with the two attribution lines from the session's system reminder.

---

## File structure

| Path | Responsibility |
|---|---|
| `.github/workflows/release.yml` (new) | Tag-triggered signed build + GitHub Release with named assets + `SHA256SUMS.txt`. |
| `tools/release.sh` (new) | Bump `pubspec.yaml`, commit, tag, push. |
| `lib/core/app_config.dart` | `updateRepo` from `--dart-define=UPDATE_REPO` (default `13/medora`). |
| `lib/core/platform_capabilities.dart` | `hasInAppUpdates` (Android only). |
| `lib/services/app_update_service.dart` (new) | `ReleaseVersion`, `ReleaseInfo`, `ReleaseAsset`, `AppUpdateService` (check, pick, download, verify, install). |
| `lib/services/app_startup_tasks.dart` | optional `updateCheck` step. |
| `lib/presentation/providers/app_update_provider.dart` (new) | `UpdateStatus` sealed class, `AppUpdateNotifier`, throttle prefs, dismissed tag. |
| `lib/presentation/widgets/update_sheet.dart` (new), `update_banner.dart` (new) | Update UI. |
| `lib/presentation/screens/settings/settings_screen.dart`, `home/home_screen.dart` | Tile + banner. |
| `android/app/src/main/AndroidManifest.xml` | `REQUEST_INSTALL_PACKAGES`. |
| `docs/release.md`, `README.md` | Cutting a release; how updates work; Play note. |
| `test/services/app_update_service_test.dart`, `test/presentation/providers/app_update_provider_test.dart`, `test/presentation/widgets/update_sheet_test.dart`, `test/presentation/screens/settings_update_tile_test.dart` | Tests. |

---

### Task 1: Release workflow + `tools/release.sh` + docs

**Files:**
- Create: `.github/workflows/release.yml`, `tools/release.sh`
- Modify: `docs/release.md` (new section "Cutting a release"), `README.md` (one paragraph "Updates")

- [ ] **Step 1: `tools/release.sh`**

```bash
#!/usr/bin/env bash
# tools/release.sh <major.minor.patch>+<build>
# Bumps pubspec.yaml, commits, tags v<version>+<build>, pushes commit + tag.
# The tag triggers .github/workflows/release.yml.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
NEW="${1:-}"
[[ "$NEW" =~ ^[0-9]+\.[0-9]+\.[0-9]+\+[0-9]+$ ]] || { echo "usage: tools/release.sh <major.minor.patch>+<build>" >&2; exit 2; }
[ "$(git branch --show-current)" = "main" ] || { echo "release from main only" >&2; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "working tree not clean" >&2; exit 1; }
CUR="$(sed -n 's/^version: //p' pubspec.yaml)"
CUR_BUILD="${CUR##*+}"; NEW_BUILD="${NEW##*+}"
[ "$NEW_BUILD" -gt "$CUR_BUILD" ] || { echo "build number must increase ($CUR -> $NEW)" >&2; exit 1; }
git tag -l "v$NEW" | grep -q . && { echo "tag v$NEW exists" >&2; exit 1; }
sed -i "s/^version: .*/version: $NEW/" pubspec.yaml
git add pubspec.yaml
git commit -q -m "chore(release): v$NEW"
git tag -a "v$NEW" -m "Medora $NEW"
git push origin main "v$NEW"
echo "tagged v$NEW — watch: gh run list --workflow Release"
```
`chmod +x tools/release.sh`.

- [ ] **Step 2: `.github/workflows/release.yml`**

```yaml
name: Release

on:
  push:
    tags: ['v*']

permissions:
  contents: write

jobs:
  release:
    runs-on: ubuntu-latest
    env:
      ANDROID_KEYSTORE_BASE64: ${{ secrets.ANDROID_KEYSTORE_BASE64 }}
      ANDROID_STORE_PASSWORD: ${{ secrets.ANDROID_STORE_PASSWORD }}
      ANDROID_KEY_ALIAS: ${{ secrets.ANDROID_KEY_ALIAS }}
      ANDROID_KEY_PASSWORD: ${{ secrets.ANDROID_KEY_PASSWORD }}
      SUPABASE_URL: ${{ secrets.SUPABASE_URL }}
      SUPABASE_ANON_KEY: ${{ secrets.SUPABASE_ANON_KEY }}
    steps:
      - uses: actions/checkout@v4
      - name: Check tag matches pubspec version
        id: ver
        run: |
          TAG="${GITHUB_REF_NAME#v}"
          PUB="$(sed -n 's/^version: //p' pubspec.yaml)"
          test "$TAG" = "$PUB" || { echo "tag $TAG != pubspec $PUB"; exit 1; }
          echo "version=${TAG%%+*}" >> "$GITHUB_OUTPUT"
          echo "build=${TAG##*+}" >> "$GITHUB_OUTPUT"
      - name: Require release signing secrets
        run: test -n "$ANDROID_KEYSTORE_BASE64" || { echo "ANDROID_KEYSTORE_BASE64 secret missing"; exit 1; }
      - uses: actions/setup-java@v4
        with: { distribution: temurin, java-version: '17' }
      - uses: subosito/flutter-action@v2
        with: { flutter-version-file: .fvmrc, cache: true }
      - name: Configure release signing
        run: |
          mkdir -p android/keystore
          echo "$ANDROID_KEYSTORE_BASE64" | base64 -d > android/keystore/medora-release.jks
          printf 'storeFile=../keystore/medora-release.jks\nstorePassword=%s\nkeyAlias=%s\nkeyPassword=%s\n' "$ANDROID_STORE_PASSWORD" "$ANDROID_KEY_ALIAS" "$ANDROID_KEY_PASSWORD" > android/key.properties
      - run: flutter pub get
      - name: Build APKs and bundle
        run: |
          DEFINES="--dart-define=SUPABASE_URL=$SUPABASE_URL --dart-define=SUPABASE_ANON_KEY=$SUPABASE_ANON_KEY"
          flutter build apk --release --split-per-abi $DEFINES
          flutter build apk --release $DEFINES
          flutter build appbundle --release $DEFINES
      - name: Name assets
        env: { V: "${{ steps.ver.outputs.version }}", B: "${{ steps.ver.outputs.build }}" }
        run: |
          mkdir -p dist
          for abi in arm64-v8a armeabi-v7a x86_64; do
            cp "build/app/outputs/flutter-apk/app-$abi-release.apk" "dist/medora-$V-$B-$abi.apk"
          done
          cp build/app/outputs/flutter-apk/app-release.apk "dist/medora-$V-$B-universal.apk"
          cp build/app/outputs/bundle/release/app-release.aab "dist/medora-$V-$B.aab"
          (cd dist && sha256sum *.apk *.aab > SHA256SUMS.txt && cat SHA256SUMS.txt)
      - name: Create GitHub release
        env: { GH_TOKEN: "${{ github.token }}", V: "${{ steps.ver.outputs.version }}", B: "${{ steps.ver.outputs.build }}" }
        run: |
          gh release create "$GITHUB_REF_NAME" dist/* --title "Medora $V ($B)" --generate-notes
```
Note the debug-key fallback in `build.gradle.kts` cannot trigger here because the secret check runs first and `key.properties` is written before the build.

- [ ] **Step 3: Docs** — `docs/release.md` "Cutting a release": `tools/release.sh 0.1.0+10` → what CI produces (asset names) → where to download → note that in-app updates read `releases/latest` so pre-releases are ignored; Play builds: `--dart-define=UPDATE_REPO=` (empty). README "Updates" paragraph: Android builds from GitHub check for updates once a day and in Settings → About.

- [ ] **Step 4: Verify** `bash -n tools/release.sh`; `actionlint` if available (`gh extension`/`npx actionlint`) else careful YAML review; format/analyze/tests untouched. **Commit** — `ci(release): tag-triggered signed APK/AAB release with named assets`

---

### Task 2: `AppUpdateService` + config + capabilities (pure Dart, fully tested)

**Files:**
- Create: `lib/services/app_update_service.dart`, `test/services/app_update_service_test.dart`
- Modify: `lib/core/app_config.dart` (`updateRepo`), `lib/core/platform_capabilities.dart` (`hasInAppUpdates`), `pubspec.yaml` (`crypto`, `device_info_plus`, `open_filex`)

**Interfaces (produced):**
```dart
class ReleaseVersion implements Comparable<ReleaseVersion> {
  const ReleaseVersion(this.major, this.minor, this.patch, this.build);
  static ReleaseVersion? parse(String tagOrVersion); // accepts 'v0.1.0+10', '0.1.0+10', '0.1.0' (build 0)
  bool isNewerThan(ReleaseVersion other); // build first, then semver
  String get label; // '0.1.0 (10)'
}
class ReleaseAsset { final String name; final int size; final Uri url; }
class ReleaseInfo { final String tag; final ReleaseVersion version; final String title; final String notes; final DateTime? publishedAt; final List<ReleaseAsset> assets; ReleaseAsset? get checksums; }
enum UpdateErrorKind { network, parse, noAsset, checksum, io }
class UpdateException implements Exception { final UpdateErrorKind kind; final String message; }
class AppUpdateService {
  AppUpdateService({required String repo, http.Client? client, Future<List<String>> Function()? supportedAbis, Future<void> Function(String path)? installer});
  Future<ReleaseInfo> checkLatest();
  ReleaseAsset? pickAsset(ReleaseInfo release, List<String> abis); // '-<abi>.apk' in abi order, else '-universal.apk'
  Future<File> download(ReleaseInfo release, ReleaseAsset asset, Directory dir, {void Function(double progress)? onProgress}); // streams, size check, sha256 vs SHA256SUMS.txt when present
  Future<void> install(File apk); // OpenFilex.open(..., type: 'application/vnd.android.package-archive') via the injected installer
}
```
`AppConfig.updateRepo` (`String.fromEnvironment('UPDATE_REPO', defaultValue: '13/medora')`), `bool get hasInAppUpdates => updateRepo.trim().isNotEmpty`.

- [ ] **Step 1: Tests first** — with `MockClient` (`package:http/testing.dart`): (a) parse/compare table incl. `v1.2.3+4` vs `1.2.3+5` (newer), `1.3.0+4` vs `1.2.9+4` (newer by semver when builds equal), `garbage` → null; (b) `checkLatest` parses a realistic `/releases/latest` JSON fixture (put it in `test/fixtures/github_release.json`) and sends `Accept`/`User-Agent` headers; 404 → `UpdateException(network)`; malformed JSON → `parse`; (c) `pickAsset` with `['arm64-v8a','armeabi-v7a']` → arm64 asset; `['x86']` → universal; no APKs → null; (d) `download` writes the file, reports progress reaching 1.0, verifies sha256 from a `SHA256SUMS.txt` served by the mock (both match and mismatch → file deleted + `checksum` error), size mismatch → `io` error; older files in `updates/` removed; (e) `install` calls the injected installer with the path.
- [ ] **Step 2: Implement** per the interfaces; `download` uses `client.send(http.Request('GET', url))` and `response.stream` with a running `sha256` (`package:crypto` `Sha256().startChunkedConversion`) so the digest costs no second pass.
- [ ] **Step 3: Verify** format/analyze/tests. **Commit** — `feat(update): AppUpdateService for GitHub releases (check, pick, download, verify, install)`

---

### Task 3: Provider, startup check, Settings tile, update sheet, Home banner, manifest

**Files:**
- Create: `lib/presentation/providers/app_update_provider.dart`, `lib/presentation/widgets/update_sheet.dart`, `lib/presentation/widgets/update_banner.dart`, tests listed above
- Modify: `lib/services/app_startup_tasks.dart` (+`updateCheck` step, optional, after sync, own throttle: `Duration minUpdateCheckInterval = 24h`, uses the injected `now`), `lib/presentation/providers/providers.dart` (`appUpdateServiceProvider`, wire the step), `settings_screen.dart` (About group tile), `home_screen.dart` (banner above the Now card), `AndroidManifest.xml`, ARB en/de/it

**Interfaces:**
```dart
sealed class UpdateStatus { const UpdateStatus(); }
class UpdateUnknown extends UpdateStatus {}
class UpdateChecking extends UpdateStatus {}
class UpdateUpToDate extends UpdateStatus { final ReleaseVersion current; }
class UpdateAvailable extends UpdateStatus { final ReleaseInfo release; final ReleaseAsset asset; }
class UpdateDownloading extends UpdateStatus { final ReleaseInfo release; final double progress; }
class UpdateReady extends UpdateStatus { final ReleaseInfo release; final File file; }
class UpdateFailed extends UpdateStatus { final UpdateException error; }

final appUpdateProvider = AsyncNotifierProvider<AppUpdateNotifier, UpdateStatus>(AppUpdateNotifier.new);
class AppUpdateNotifier extends AsyncNotifier<UpdateStatus> {
  Future<void> check({bool force = false}); // force ignores the 24 h throttle; writes update.last_check_at
  Future<void> download();
  Future<void> install();
  Future<void> dismiss(); // writes update.dismissed_tag
  bool get isDismissed;
}
```
Prefs keys: `update.last_check_at` (ISO UTC), `update.dismissed_tag`. Current version from `package_info_plus` (`version` + `buildNumber`). Gating: `caps.hasInAppUpdates && AppConfig.hasInAppUpdates && online`; otherwise `check` resolves to `UpdateUnknown` without network.

- [ ] **Step 1: Tests** — notifier with a fake `AppUpdateService` (subclass overriding methods) and mock prefs: throttle (second `check()` within 24 h does no network call; `force: true` does), `available` when newer, `upToDate` when not, `download` progress stream → `UpdateReady`, `install` calls service, `dismiss` persists tag; startup task order `maintenance, reminders, sync, updateCheck` and throttle test in `app_startup_tasks_test.dart`. Widget tests: Settings tile subtitle per state (`checkForUpdates`, `upToDate`, `updateAvailable(version)`); `UpdateSheet` Download → Install buttons; `UpdateBanner` visible for `UpdateAvailable` and gone after dismiss. ARB keys: `checkForUpdates`, `checkingForUpdates`, `upToDate`, `updateAvailable` ({version}), `updateDownload`, `updateInstall`, `updateLater`, `updateReleaseNotes`, `updateBannerTitle` ({version}), `updateView`, `updateFailed`, `updateChecksumFailed`, `updateNoAsset` (en/de/it).
- [ ] **Step 2: Implement**; manifest permission; `PlatformCapabilities.mobile.hasInAppUpdates` true only when `Platform.isAndroid` (keep the preset structure — add a field and set it in `detect()`).
- [ ] **Step 3: Verify** format/analyze/full tests/goldens (Home golden must not change: the banner is hidden for `UpdateUnknown`, which is what goldens see — assert in the golden config that `appUpdateProvider` is overridden to `UpdateUnknown`). **Commit** — `feat(update): in-app update check, download and install from GitHub releases`

---

### Task 4: End-to-end: cut the first real release and verify from the API

- [ ] **Step 1:** Merge the feature branch to `main` (controller does this), then run `tools/release.sh 0.1.0+10` (from `0.0.9+9`).
- [ ] **Step 2:** `gh run watch` the Release workflow; then `gh release view v0.1.0+10 --json assets --jq '.assets[].name'` must list exactly `medora-0.1.0-10-arm64-v8a.apk`, `medora-0.1.0-10-armeabi-v7a.apk`, `medora-0.1.0-10-x86_64.apk`, `medora-0.1.0-10-universal.apk`, `medora-0.1.0-10.aab`, `SHA256SUMS.txt`.
- [ ] **Step 3:** `dart run` a throwaway script (scratchpad) using `AppUpdateService(repo: '13/medora')` with a real `http.Client`: `checkLatest()` returns build 10; `pickAsset(['arm64-v8a'])` → the arm64 asset; `download` into a temp dir verifies the checksum. Record the output in the report.
- [ ] **Step 4:** Download the arm64 APK and `jarsigner -verify` → CN=Ben (release key). Optionally install on the connected device/emulator if one is attached (`adb devices`).

## Exit criteria

- [ ] A pushed tag produces a GitHub Release with the six named assets, signed with the release key.
- [ ] On Android, Settings → About shows "Check for updates"; with a newer release it downloads, verifies and opens the installer; Home shows a dismissable banner.
- [ ] Startup check at most once per 24 h, never offline, never on non-Android, never when `UPDATE_REPO` is empty.
- [ ] All gates green; goldens unchanged; l10n complete.
