# <img src="assets/icon/medora_icon_pill.png" width="30" height="30" /> Medora — Home Medicine Cabinet Manager

A production-ready Flutter mobile application for managing your home medicine cabinet, tracking medication expiration dates, creating treatment plans, managing dose schedules, and receiving medication reminders.

<p align="center">
  <img src="assets/screenshots/screenshot1.png" width="200" />
  <img src="assets/screenshots/screenshot2.png" width="200" />
  <img src="assets/screenshots/screenshot3.png" width="200" />
</p>

## Features

- **Medication Inventory** — Add, edit, delete, and view medications with full details (name, active ingredient, category, quantity, expiry date, barcode, storage location, notes).
- **Expiry & Stock Alerts** — Automatically detects medications expiring within 30 days and medications with low stock.
- **AIC Code Scanner** — Point the camera at an Italian medication package; on-device OCR (ML Kit) reads the AIC code and looks it up in the AIFA database (cached locally after a one-time download).
- **Treatment / Illness Tracking** — Create treatment plans with symptoms, start/end dates, and notes.
- **Prescription Plans** — Attach medication prescriptions to treatments with dosage, interval, and duration.
- **Dose Scheduling** — Auto-generated dose log entries with pending/taken/skipped/missed status.
- **Reminders** — Local push notifications for each scheduled dose (`flutter_local_notifications`).
- **Dashboard** — Home screen with summary cards: today's doses, expiring meds, low stock, active treatments.
- **Settings** — Notification controls, sync status, and future feature placeholders.

---

## Prerequisites

- **FVM** — Flutter Version Manager ([install guide](https://fvm.app/documentation/getting-started/installation))
- **Flutter stable** (3.44+) — managed via FVM (`.fvmrc`)
- Android Studio / Xcode for device builds (optional for Linux/Web)

## Run it (no configuration needed)

```bash
fvm install
fvm flutter pub get
fvm flutter run            # pick a device: Android, iOS, Linux, Windows, Chrome
```

Medora works completely offline. All data lives in a local SQLite database on the device.

## Optional: cloud sync with Supabase

1. Create a Supabase project and apply the SQL files in `supabase/migrations/` in order — paste them into the SQL editor one by one, or run `supabase db push` with the [Supabase CLI](https://supabase.com/docs/guides/cli).
2. Copy `dart_defines.example.json` to `dart_defines.json` and fill in your project URL and anon/publishable key.
3. Run or build with the defines:

```bash
fvm flutter run --dart-define-from-file=dart_defines.json
fvm flutter build apk --release --dart-define-from-file=dart_defines.json
```

Then open **Settings → Cloud sync → Turn on** and sign in. Without defines the app runs local-only and the cloud section says so.

### How sync works

- Offline-first: every change is written to the local database first and works with no network.
- Each cycle pushes the pending local changes, then pulls only what changed since the last pull (delta by `updated_at`).
- Deletes are tombstones (`deleted_at`), so a deletion made on one device is applied on every other device.
- A row edited on two devices resolves last-write-wins by `updated_at`; a tombstone always wins.
- Settings shows the last sync report — what was pushed, pulled and deleted, and any rows that failed.
- **Force pull** wipes the local rows and re-downloads everything from the server.
- Turning cloud sync on uploads the data already on the device instead of discarding it.

### Integration test

A convergence test drives two simulated devices against a real Supabase. Start one locally and run it with the defines:

```bash
supabase start
fvm flutter test test/integration \
  --dart-define=SUPABASE_URL=http://127.0.0.1:54321 \
  --dart-define=SUPABASE_ANON_KEY=<anon key from `supabase status`>
```

Without those defines the test is skipped, so a plain `fvm flutter test` needs no Supabase. In CI the same test runs in the `integration` job, which is triggered manually (**Run workflow**) or by adding the `integration` label to a pull request.

## Development

```bash
fvm flutter analyze
fvm flutter test
fvm flutter gen-l10n       # after editing lib/l10n/*.arb
```

Architecture: Clean Architecture (`lib/domain`, `lib/data`, `lib/presentation`, `lib/services`) with Riverpod 3 for state, go_router for navigation, sqflite for local storage, optional Supabase for sync. Design docs live in `docs/superpowers/specs/`.

## Platform notes

- Android: `minSdk 28`. Release builds need your own keystore (see `android/app/build.gradle.kts`).
- iOS: camera, photo library and Face ID usage strings are in `ios/Runner/Info.plist`.
- Web: installable PWA; OCR scanning, photos and notifications are not available in the browser.
- Linux/Windows: full local functionality; scheduled notifications are not supported by the desktop plugins.

## License

Private project. All rights reserved.
