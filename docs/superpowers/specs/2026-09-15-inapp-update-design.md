# In-app updates from GitHub Releases — design

**Date:** 2026-09-15. **Status:** approved by default per the user's "plan … then add" instruction; assumptions listed in §7.

## 1. Goal

Medora is distributed outside Google Play (GitHub Releases). Android users should learn about a new version inside the app and update with two taps, without a store. Releases are produced by CI from a git tag, signed with the project keystore, and named predictably: app name + version number + ABI.

## 2. Release artifacts (CI)

- Trigger: push of a tag `v<major>.<minor>.<patch>+<build>` (e.g. `v0.1.0+10`). The workflow refuses to run if the tag does not equal `version:` in `pubspec.yaml`.
- Build: `flutter build apk --release --split-per-abi` (arm64-v8a, armeabi-v7a, x86_64) and `flutter build apk --release` (universal) and `flutter build appbundle --release`, all signed from the four `ANDROID_*` secrets (required — the job fails without them, never falls back to debug), with `SUPABASE_URL`/`SUPABASE_ANON_KEY` defines when those secrets exist.
- Asset names (`+` avoided in file names):
  - `medora-<version>-<build>-arm64-v8a.apk`, `…-armeabi-v7a.apk`, `…-x86_64.apk`, `…-universal.apk`
  - `medora-<version>-<build>.aab`
  - `SHA256SUMS.txt` (sha256sum format, one line per asset)
- Release: created with `gh release create` on the tag, title `Medora <version> (<build>)`, auto-generated notes. Pre-release when the tag contains `-beta`/`-rc` (not used yet).
- `tools/release.sh <version>+<build>`: validates format, bumps `pubspec.yaml`, commits `chore(release): v<version>+<build>`, tags `v<version>+<build>`, pushes commit and tag. Refuses on a dirty tree or off `main`.

## 3. In-app update (Android only)

- `AppConfig.updateRepo` (`--dart-define=UPDATE_REPO`, default `13/medora`; empty disables the feature — Play builds must pass an empty value, Play forbids self-updating APKs).
- `AppUpdateService` (`lib/services/app_update_service.dart`), pure Dart over `package:http`:
  - `checkLatest()` → GET `https://api.github.com/repos/<repo>/releases/latest` (headers `Accept: application/vnd.github+json`, `User-Agent: medora`); parses `tag_name`, `name`, `body`, `published_at`, `assets[] {name, size, browser_download_url}`; ignores drafts/pre-releases (the `/latest` endpoint already does).
  - `ReleaseVersion.parse('v0.1.0+10')` → semver + build; `isNewerThan(current)` compares build number first, then semver.
  - `pickAsset(assets, supportedAbis)` → first asset whose name ends with `-<abi>.apk` for the device's ABIs in order, else `-universal.apk`, else null.
  - `download(asset, dir, onProgress)` streams to `<dir>/updates/<asset.name>` (deletes older files in `updates/`), then verifies size and, when `SHA256SUMS.txt` is among the assets, the sha256 line for that name; mismatch → delete + `UpdateError.checksum`.
  - `install(file)` → `OpenFilex.open(path, type: 'application/vnd.android.package-archive')`; Android then shows the system installer (first time it asks to allow installs from Medora).
- Device ABIs from `device_info_plus` (`AndroidDeviceInfo.supportedAbis`).
- Manifest: `<uses-permission android:name="android.permission.REQUEST_INSTALL_PACKAGES"/>`; `open_filex` provides the FileProvider.
- `PlatformCapabilities.hasInAppUpdates`: true on Android only.

## 4. When it checks

- Startup: `AppStartupTasks` gains an optional `updateCheck` step after sync, throttled to once per 24 h (pref `update.last_check_at`), skipped when offline, when `hasInAppUpdates` is false, or when `updateRepo` is empty. Result cached in `appUpdateProvider`.
- Manual: Settings → About → "Check for updates" (always allowed; shows "Up to date" / "Update available vX" / error).
- Home shows a dismissable banner when an update is known and not dismissed for that tag (pref `update.dismissed_tag`).

## 5. UI

- `appUpdateProvider` = `AsyncNotifierProvider<AppUpdateNotifier, UpdateStatus>`; `UpdateStatus` is a sealed state: `unknown`, `upToDate(current)`, `available(release, asset)`, `downloading(progress 0..1)`, `readyToInstall(file)`, `failed(error)`.
- Settings About group: existing version tile + `ListTile` "Check for updates" (subtitle = status text; trailing spinner while checking/downloading; tap = check, or open the update sheet when available).
- Update sheet (`UpdateSheet`): version, published date, release notes (plain text, scrollable), buttons Download → progress bar → Install; "Later" dismisses for this tag.
- Home banner: one line "Medora vX is available" with "View" (opens the sheet) and "×" (dismiss for this tag).
- All strings en/de/it; theme tokens only.

## 6. Testing

- Unit: version parse/compare (build number wins, semver fallback, malformed → null), asset selection (abi order, universal fallback, none), release JSON parsing (drafts absent, missing assets), download+checksum with a fake `http.Client` (`MockClient` from `package:http/testing.dart`), throttle (24 h using the injected clock), startup step gating.
- Widget: Settings tile states with a fake notifier; Home banner shows/dismisses; update sheet Download→Install transitions with a fake service.
- Manual acceptance (Task 4): cut `v0.1.0+10` for real; verify the release assets and names on GitHub; verify `checkLatest()` against the live API with a tiny Dart script picks `arm64-v8a`.

## 7. Assumptions (decided without asking)

1. Naming `medora-<version>-<build>-<abi>.apk` with `+` replaced by `-` in file names; tag keeps `+`.
2. Per-ABI APKs plus a universal fallback (smaller downloads for users; universal for unknown ABIs).
3. Build number (`+N`) is the authority for "newer"; it must increase every release (`tools/release.sh` enforces `> current`).
4. Play distribution, if ever, uses `UPDATE_REPO=""`; documented in `docs/release.md`.
5. No delta updates, no background download, no auto-install — the user always taps Install.
6. iOS/desktop/web: feature hidden; About shows only the version.
