# Releasing Medora

Everything here assumes Flutter through FVM (`fvm flutter ...`, pinned in
`.fvmrc`) and a working tree that already passes `fvm flutter analyze
--fatal-infos`, `fvm dart format --set-exit-if-changed .` and `fvm flutter test`.

## Versioning

The version lives in one place — `version:` in `pubspec.yaml`
(`0.2.3+15` at the time of writing). `flutter build` feeds the part before `+`
to `versionName` and the part after it to `versionCode`
(`android/app/build.gradle.kts`).

**Google Play rejects an upload whose `versionCode` is not strictly greater
than every bundle already uploaded**, so the `+build` number must increase on
every Play upload, even for a re-upload of the same marketing version. Bump
`version:` and commit it as part of the release.

## App icon

Edit `assets/icon/medora_pill.svg`, run `tools/gen_icons.sh`, then run `fvm dart run flutter_launcher_icons` to regenerate every platform's icons from it.

## Android

### 1. Create a keystore (once, and never lose it)

A Play listing is bound to the key that signed its first upload — if you lose
the keystore you cannot ship an update to that listing. Keep a backup
somewhere that is not this repository.

```bash
keytool -genkeypair -v \
  -keystore medora-release.jks \
  -alias medora -keyalg RSA -keysize 2048 -validity 10000
```

Put the file at `android/keystore/medora-release.jks`. Both `*.jks` and
`**/android/key.properties` are in `.gitignore`; keep it that way.

### 2. Point the build at it

Copy the template and fill in the real values:

```bash
cp android/key.properties.example android/key.properties
```

```properties
storeFile=../keystore/medora-release.jks
storePassword=…
keyAlias=medora
keyPassword=…
```

`storeFile` is resolved relative to `android/app/`, so `../keystore/…` means
`android/keystore/…`.

`android/app/build.gradle.kts` loads this file if it exists and signs `release`
with it. **If the file is absent the release build falls back to the debug
key**, so a fresh clone can still run `flutter run --release` — but a
debug-signed artifact must never be uploaded to Play. Check what you built:

```bash
$ANDROID_HOME/build-tools/<version>/apksigner verify --print-certs \
  build/app/outputs/flutter-apk/app-release.apk
# or, for an .aab:
jarsigner -verify -verbose:summary build/app/outputs/bundle/release/app-release.aab
```

`Signer #1 certificate DN: C=US, O=Android, CN=Android Debug` means the
fallback was used and `key.properties` is missing or wrong.

### 3. Build

```bash
# Play upload (preferred)
fvm flutter build appbundle --release --dart-define-from-file=dart_defines.json
# → build/app/outputs/bundle/release/app-release.aab

# Sideload / direct distribution
fvm flutter build apk --release --dart-define-from-file=dart_defines.json
# → build/app/outputs/flutter-apk/app-release.apk
```

### Artifact size

A plain `build apk` is a **fat APK**: it carries the Flutter engine and the
compiled Dart for every ABI (`armeabi-v7a`, `arm64-v8a`, `x86_64`) even though
a given phone runs exactly one. For sideloading, split it:

```bash
fvm flutter build apk --release --split-per-abi --dart-define-from-file=dart_defines.json
# → app-armeabi-v7a-release.apk, app-arm64-v8a-release.apk, app-x86_64-release.apk
```

Each file is roughly a third of the fat APK; hand users the `arm64-v8a` one
unless you know they need otherwise. **The App Bundle already does this** —
Play generates a per-device split from the `.aab`, so `--split-per-abi` is
irrelevant to the Play upload and `build appbundle` stays the way to ship.

The ML Kit plugins bundle their models instead of downloading them on first
use: `google_mlkit_barcode_scanning` adds roughly 2–3 MB per ABI on top of text
recognition. Measured `arm64-v8a` release APK: **48.8 MB for 0.2.3** (text
recognition plus barcode scanning), up from 42.9 MB for 0.2.2. Both figures
are snapshots of the version they name, not a current measurement — re-run
the command above at each release rather than trusting the number here.

To see where the bytes go:

```bash
fvm flutter build apk --release --analyze-size --target-platform android-arm64
```

It prints the top contributors and writes a JSON snapshot under
`~/.flutter-devtools/` that `dart devtools --appSizeBase=<file>` opens as a
treemap. Assets are the part worth watching: everything under `flutter:
assets:` in `pubspec.yaml` is bundled verbatim, so an asset that is only used
by the README (the screenshots) must never be listed there, and text fonts are
**not** tree-shaken the way the Material icon font is — each declared Inter
weight costs its full file.

Drop `--dart-define-from-file` to ship a local-only build: without
`SUPABASE_URL` and `SUPABASE_ANON_KEY` the app runs entirely offline and the
cloud-sync section of settings says so. `dart_defines.json` is git-ignored;
`dart_defines.example.json` is the template.

The release build type has `isMinifyEnabled = true` with
`proguard-android-optimize.txt` plus `android/app/proguard-rules.pro`.

### 4. CI

`.github/workflows/ci.yml` → job `build-android` always builds the debug APK.
When the keystore secrets exist **and** the run is on `main` or a tag, it also
writes the keystore, builds `appbundle --release` and uploads it as the
`medora-release-aab` artifact:

| Secret | Value |
|---|---|
| `ANDROID_KEYSTORE_BASE64` | `base64 -w0 medora-release.jks` |
| `ANDROID_STORE_PASSWORD` | keystore password |
| `ANDROID_KEY_ALIAS` | `medora` |
| `ANDROID_KEY_PASSWORD` | key password |
| `SUPABASE_URL` | project URL — same value as `dart_defines.json` |
| `SUPABASE_ANON_KEY` | anon/publishable key — same value as `dart_defines.json` |

The last two are passed to the release build as
`--dart-define=SUPABASE_URL=… --dart-define=SUPABASE_ANON_KEY=…`.
**Without them the CI artifact is a local-only build and must not be uploaded
to Play**: an empty define is exactly how `AppConfig` recognises "no cloud
configuration", so the app would ship with cloud sync permanently unavailable.
The four keystore secrets and these two are independent — CI will happily
produce a correctly signed, cloud-less bundle if you configure only the first
four.

The gates are `env.ANDROID_KEYSTORE_BASE64 != ''` (the secrets are mapped into
the job's `env:` because the `secrets` context is not usable in a step-level
`if:`) and `github.ref == 'refs/heads/main' || startsWith(github.ref,
'refs/tags/')`, so a feature branch never uploads a production-signed bundle.
With no secrets configured all three release steps are skipped and the job is
still green — that is the expected state for this repository today. Nothing in
CI is needed to keep local release builds working.

## Cutting a release

Releases are cut from `main` by pushing a tag; `.github/workflows/release.yml`
does the rest.

```bash
tools/release.sh 0.1.0+10
```

This bumps `version:` in `pubspec.yaml`, commits `chore(release): v0.1.0+10`,
tags `v0.1.0+10` and pushes both to `origin main`. It refuses to run off
`main`, with a dirty working tree, or with a `+build` that does not increase
over the current `pubspec.yaml` version.

### If a release run fails

`tools/release.sh` commits, tags and only then pushes, so between the tag and
the push the release exists **only locally** — and the `tag v<version> exists`
guard at the top of the script then refuses to re-run. The script undoes both
itself if the notes step or the push fails (the push is `--atomic`, so a
partial push is not a possible outcome), and prints
`rolled back the local release commit and tag`. If it is interrupted some
other way — Ctrl-C, a closed terminal — undo the same two things by hand
before re-running:

```bash
git tag -d v<version>        # e.g. git tag -d v0.2.4+16
git reset --hard HEAD~1      # drops the chore(release) commit
```

Check first that neither was pushed (`git ls-remote --tags origin 'v*'`); if
the tag *is* on origin the workflow has already run, and the fix is a new
build number, not a rewrite.

### Checking the changelog generator

`tools/release_notes.sh` turns the conventional-commit subjects since the
previous `v*` tag into the release body. `tools/test_release_notes.sh` checks
it against a throwaway repository in a temp dir — it never touches this
repository, its tags or its remote — and pins the cases that used to be
mangled silently: a subject carrying a second `): `, and subjects carrying
markdown characters (`user_id`, `*.dart`). Its in-app counterpart is
`test/services/release_notes_test.dart`, which renders those same subjects the
way the update sheet does; change one side and run both.

The pushed tag triggers the `Release` workflow, which:

1. Checks the tag matches `version:` in `pubspec.yaml` (`tools/release.sh`
   guarantees this, but the workflow re-checks in case a tag is pushed by
   hand) and fails immediately if the four `ANDROID_*` signing secrets are not
   configured — it never falls back to the debug key.
2. Builds `flutter build apk --release --split-per-abi`, the universal APK and
   the `.aab`, all signed, with `SUPABASE_URL`/`SUPABASE_ANON_KEY` defines when
   those secrets are configured (empty defines build the same local-only
   artifact described above).
3. Copies the outputs to `dist/` under predictable names and writes a
   checksum file:

   - `medora-<version>-<build>-arm64-v8a.apk`
   - `medora-<version>-<build>-armeabi-v7a.apk`
   - `medora-<version>-<build>-x86_64.apk`
   - `medora-<version>-<build>-universal.apk`
   - `medora-<version>-<build>.aab`
   - `SHA256SUMS.txt`

4. Publishes a GitHub release on the tag (`gh release create`, title
   `Medora <version> (<build>)`) with those files attached. The body is
   **not** GitHub's auto-generated one: the workflow runs
   `tools/release_notes.sh` on the pushed tag, which is the same command
   `tools/release.sh` ran locally, so the published changelog is exactly the
   text that was reviewable before the push.

Download the assets from the repository's **Releases** page. The in-app
update check reads the `releases/latest` API endpoint, which GitHub only
populates from full releases — a pre-release (tag containing `-beta`/`-rc`) is
never offered to users as an in-app update.

If this repository is ever distributed through Google Play instead of GitHub
Releases, build with `--dart-define=UPDATE_REPO=` (empty) so the Play build
never checks GitHub for updates — Play does not allow apps to self-update.

## iOS

Signing is handled by Xcode, not by this repo: open `ios/Runner.xcworkspace`,
set the team and bundle identifier under *Signing & Capabilities*, then

```bash
fvm flutter build ipa --release --dart-define-from-file=dart_defines.json
```

and upload the `.ipa` with Transporter or `xcrun altool`. The camera, photo
library and Face ID usage strings are already in `ios/Runner/Info.plist`, so no
privacy-string work is needed at release time.

## Web

```bash
fvm flutter build web --release --dart-define-from-file=dart_defines.json
# → build/web/
```

Serve `build/web/` as static files. The PWA manifest is
`web/manifest.json` (name, icons, theme color) — update it when the app name
or icon changes. OCR scanning, photo capture and scheduled notifications are
unavailable in the browser and the UI hides them.

## Food supplement register data

The scanner looks up food-supplement notification codes ("COD MINSAN") in the
Italian Ministry of Health register of notified supplements. The Ministry
publishes it as a ~4,100-page PDF and refreshes it on the 1st of each month.
`tools/build_supplements_data.py` turns that PDF into `integratori.csv.gz`
(`code,product,company`, ~114,000 rows, ~1.8 MB) and `integratori.meta.json`
(`rows`, `sourceUpdated` from the PDF's "aggiornato al" date, `builtAt`,
`source`, `columns`). Both live on the GitHub **pre-release** `data-integratori`
— a pre-release, so `releases/latest` (the in-app updater) keeps returning the
app release. The app downloads them from Settings → Data or the first time a
supplement code is scanned, and shows `sourceUpdated` in the tile.

The Ministry site blocks non-browser and non-Italian traffic (a GitHub-hosted
runner receives an HTML challenge page instead of the PDF), so there is no CI
workflow: refresh the data **monthly, from a machine in Italy**, with Python 3,
`poppler-utils` (`pdftotext`) and an authenticated `gh`:

```bash
tools/build_supplements_data.py --publish            # default repo 13/medora
tools/build_supplements_data.py --publish --repo OWNER/NAME
tools/build_supplements_data.py --pdf register.pdf   # convert a local PDF only
tools/build_supplements_data.py --self-test          # offline self-checks
```

`--self-test` runs the script's doctests (for example `_pick_latest`, which
picks the register PDF with the highest numeric suffix, so `_10` beats `_9`)
without network access or `pdftotext`; run it after editing the script.

`--publish` uploads both files with `gh release upload data-integratori …
--clobber` and creates the pre-release if it is missing. The script refuses to
publish when the download is not a PDF (the site blocked the request) or when
fewer than `--min-rows` (default 50,000) rows were parsed (layout change). Do
not commit the generated files.

### Periodic refresh on a developer machine

`tools/refresh_supplements_data.sh` runs `tools/build_supplements_data.py
--publish --out <tmp dir>/integratori.csv.gz` (the generated files are
written to a temp dir that is removed on exit, never to the repo root), logs
to both `~/.local/state/medora/refresh-supplements.log` **and** stderr (so
`journalctl`, below, shows the real failure reason and not just an exit
code), and exits non-zero when `pdftotext`, `gh`, `curl` or connectivity is
missing, when the download or the row guard fails, or when the checkout it
would publish from is not the released one.

That last guard is three checks, because the register it uploads overwrites
the data every installed app downloads: the working tree must be clean, the
checkout must be on `main`, and after `git fetch origin main`, `HEAD` must be
neither ahead of nor behind `origin/main`. A clean tree alone is not enough —
a committed work-in-progress parser on a feature branch is not "dirty", and
the timer fires unattended on whatever happens to be checked out.

A `flock` on `~/.local/state/medora/.refresh.lock` stops two refreshes from
racing (the timer and a manual `systemctl --user start`, below). The log is
truncated to its last 1000 lines once it passes 2000, and that rotation runs
*under* the lock — done before it, a second invocation truncated the log of
the run already in progress.

`tools/systemd/` holds a **user** service and timer for it. The timer fires
three times a month — the 4th, 11th and 18th at 06:00, `Persistent=true` so
a machine that was off catches up — instead of once: `gh release upload
--clobber` is idempotent, so an extra run only re-uploads identical or newer
data, and this bounds a transient failure (network blip, Ministry site down
for maintenance) to about a week of staleness instead of a whole month
before the in-app 45-day warning would otherwise have time to fire from a
pipeline problem rather than a genuinely stale register. No `OnFailure=`
notification unit is set up (nothing in this repo's tooling sends
notifications yet); the wider schedule was judged sufficient on its own,
and the log file plus `journalctl` are still there for whoever installs the
timer to check in on it. The service unit does not use
`After=network-online.target` — that target does not exist for the per-user
systemd manager, so it would be inert — the script instead waits for
`https://www.salute.gov.it/` to answer, up to 10 attempts 30 seconds apart,
before downloading anything:

```bash
mkdir -p ~/.config/systemd/user
install -m 0644 ~/repo/medora/tools/systemd/medora-supplements.service ~/.config/systemd/user/
install -m 0644 ~/repo/medora/tools/systemd/medora-supplements.timer   ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now medora-supplements.timer
systemctl --user list-timers medora-supplements.timer   # check the next run
systemctl --user start medora-supplements.service       # run it once now
journalctl --user -u medora-supplements.service -n 50   # or the log file above
```

Copies, not symlinks: a symlink into the working tree means checking out a
branch silently changes the installed unit. Re-run the two `install` commands
(and `systemctl --user daemon-reload`) after editing either file.

The units assume the repository is at `~/repo/medora`; edit `ExecStart` if it
is elsewhere. Uninstall:

```bash
systemctl --user disable --now medora-supplements.timer
rm ~/.config/systemd/user/medora-supplements.{service,timer}
systemctl --user daemon-reload
```

Enable lingering (`sudo loginctl enable-linger $USER`) if the timer should
run while nobody is logged in. The app warns when the register it holds is
45 days old or older (Settings → Data, and on the scan review).

## Dependency deferrals

Two direct dependencies stay one patch behind on purpose: `intl` (0.20.2,
latest 0.20.3) and `material_color_utilities` (0.13.0, latest 0.13.1) are
pinned by the SDK through `flutter_localizations` and `flutter_test`
(`fvm flutter pub outdated` shows both as not resolvable). They move when the
Flutter pin in `.fvmrc` moves, not before.

## Release checklist

1. `fvm flutter analyze --fatal-infos`, `fvm dart format --set-exit-if-changed .`,
   `fvm flutter test` — all clean.
2. Bump `version:` in `pubspec.yaml` (the `+build` must increase for Play).
3. Build the artifact for the target platform.
4. For Android, verify the signer certificate is *not* `CN=Android Debug`.
5. Tag the commit and upload.
