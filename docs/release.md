# Releasing Medora

Everything here assumes Flutter through FVM (`fvm flutter ...`, pinned in
`.fvmrc`) and a working tree that already passes `fvm flutter analyze
--fatal-infos`, `fvm dart format --set-exit-if-changed .` and `fvm flutter test`.

## Versioning

The version lives in one place — `version:` in `pubspec.yaml`
(`0.0.9+9` at the time of writing). `flutter build` feeds the part before `+`
to `versionName` and the part after it to `versionCode`
(`android/app/build.gradle.kts`).

**Google Play rejects an upload whose `versionCode` is not strictly greater
than every bundle already uploaded**, so the `+build` number must increase on
every Play upload, even for a re-upload of the same marketing version. Bump
`version:` and commit it as part of the release.

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

## Release checklist

1. `fvm flutter analyze --fatal-infos`, `fvm dart format --set-exit-if-changed .`,
   `fvm flutter test` — all clean.
2. Bump `version:` in `pubspec.yaml` (the `+build` must increase for Play).
3. Build the artifact for the target platform.
4. For Android, verify the signer certificate is *not* `CN=Android Debug`.
5. Tag the commit and upload.
