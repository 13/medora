# <img src="assets/icon/medora_icon_pill.png" width="30" height="30" /> Medora — Home Medicine Cabinet Manager

A Flutter app for the medicine cabinet at home: what you own, what expires
when, which treatment it belongs to, and when the next dose is due. It works
completely offline — no account, no network — and can optionally sync across
devices through Supabase.

<p align="center">
  <img src="assets/screenshots/screenshot1.png" width="200" />
  <img src="assets/screenshots/screenshot2.png" width="200" />
  <img src="assets/screenshots/screenshot3.png" width="200" />
</p>

## Features

- **Medication inventory** — name, active ingredient, category, quantity, expiry date, barcode, storage location, photo and notes.
- **Expiry & stock alerts** — flags medications expiring within 30 days and anything at or below the low-stock threshold. Expiry is a date, not a moment: something stamped "expires today" is good for the whole of that day.
- **AIC code scanner** — photograph an Italian package (or pick a photo from the gallery); on-device ML Kit reads the text and barcodes, highlights every AIC, supplement, EAN and other code on the photo, and the code you tap is looked up in the AIFA database (cached locally after a one-time download) or in your own cabinet.
- **Food supplement register** — supplement codes ("COD MINSAN") are looked up offline in the Italian Ministry of Health register of notified supplements (downloaded once from Settings → Data or on the first scan, refreshed monthly), prefilling name, company and category.
- **Treatments** — illness/treatment plans with symptoms, start and end dates, and notes.
- **Prescriptions** — attach a medication to a treatment with dosage, interval and duration.
- **Dose schedule** — auto-generated dose entries with pending / taken / skipped / missed status; stale pending doses become "missed" after a configurable grace period.
- **Reminders** — local notifications for upcoming doses.
- **Dashboard** — today's doses, expiring medications, low stock, active treatments.
- **Export** — CSV and PDF of medications, treatments and dose history.
- **Backup** — the whole cabinet (and its photos) as one JSON file, restored by replacing or merging.
- **Family sharing** — optional, on top of cloud sync: join a family by invite code and share the cabinet.
- **English, German and Italian**, light and dark themes, biometric lock.

## Platforms

| Platform | Status |
|---|---|
| Android (`minSdk 28`) | Full functionality. |
| iOS | Full functionality. |
| Web | Installable PWA; no OCR scanning, photo capture or scheduled notifications. |
| Linux / Windows | Full local functionality; the desktop plugins cannot schedule notifications. |

## Quick start

Medora needs Flutter 3.44.6 / Dart 3.12 or newer (it uses private named
parameters), which is why every command below goes through `fvm`.

```bash
fvm install                 # Flutter is pinned in .fvmrc (see https://fvm.app)
fvm flutter pub get
fvm flutter run             # pick a device: Android, iOS, Linux, Windows, Chrome
```

That is the whole setup. Medora runs local-only by default: everything lives in
a SQLite database on the device, nothing is uploaded, and no configuration file
is needed.

## Optional: cloud sync with Supabase

1. Apply the SQL files in `supabase/migrations/` in order. With the [Supabase CLI](https://supabase.com/docs/guides/cli):
   - **Fresh project** (nothing applied yet): `supabase db push` applies all three migrations.
   - **Existing install** that ran `20260901000000_initial_schema.sql` by hand: the migration history is empty, so `supabase db push` would try to replay the initial schema. Tell Supabase it is already applied first, then push:

     ```bash
     supabase migration repair --status applied 20260901000000
     supabase db push
     ```

   - Or skip the CLI entirely and paste the newer files in order (`20260914000000_tombstones_and_family.sql`, then `20260916000000_medication_ean.sql`) into the SQL editor. They are written to be re-runnable (`IF NOT EXISTS`, `CREATE OR REPLACE`, `DROP POLICY IF EXISTS`). `20260916000000_medication_ean.sql` adds the `ean` column that a client on local schema v14 uploads with every medication, so apply it before syncing from an updated app.
2. Copy `dart_defines.example.json` to `dart_defines.json` and fill in your project URL and anon/publishable key.
3. Run or build with the defines:

```bash
fvm flutter run --dart-define-from-file=dart_defines.json
fvm flutter build apk --release --dart-define-from-file=dart_defines.json
```

Then open **Settings → Cloud sync → Turn on** and sign in. Without defines the app runs local-only and the cloud section says so.

### Configure cloud sync at runtime

A build without those defines can still reach a project: open **Settings → Cloud
sync → Configure cloud sync**, paste the project URL and the anon/publishable
key, and use **Test connection** to check them before saving — it tells a
rejected key apart from a project it could not reach at all. The pair is stored
in `SharedPreferences` on that device only (keys `cloud.supabase_url` and
`cloud.supabase_anon_key`), never logged, and the key is masked once saved —
replace it rather than read it back. Settings values take precedence over the
`--dart-define` values. Configuring a build that started local-only turns cloud
sync on immediately; changing or clearing the values in a build that already
initialised Supabase needs a restart, and Settings says so. **Clear** forgets the
credentials and, in cloud mode, first asks what to do with the local data.

### How sync works

- Offline-first: every change is written to the local database first and works with no network.
- Each cycle pushes the pending local changes, then pulls only what changed since the last pull (delta by `updated_at`).
- Deletes are tombstones (`deleted_at`), so a deletion made on one device is applied on every other device.
- A row edited on two devices resolves **last write wins by `updated_at`** — the newer edit wins, whichever device syncs last. Before uploading an edited row the push reads the server row's `updated_at` and stands down if the server copy is newer, leaving the row for the pull to overwrite (the report counts these as skipped, not failed); the pull side keeps a local edit that is newer than the server copy. Newly created rows and tombstones upload unconditionally, and a tombstone always wins over a live row.
- Settings shows the last sync report — what was pushed, pulled and deleted, and any rows that failed.
- A row that keeps failing to upload is retried with an exponential backoff (2 minutes, doubling, up to 6 hours) instead of failing every cycle. Tapping the report lists those rows, and **Discard local change** gives up on one: the device accepts the server's copy on the next pull.
- **Force pull** wipes the local rows and re-downloads everything from the server. Local changes that have not been uploaded yet are lost. If a table cannot be fetched after the wipe, the cycle reports an error rather than a partial success.
- Signing in uploads the data already on the device instead of discarding it. If that data was saved under a *different* account, the app asks whether to merge it into the new account or delete it, rather than uploading one person's records into someone else's.

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
fvm flutter analyze --fatal-infos          # CI gate
fvm dart format --set-exit-if-changed .    # CI gate — always the bundled Dart
fvm flutter test                           # unit, widget and golden tests
fvm flutter gen-l10n                       # after editing lib/l10n/*.arb; commit the generated output
fvm flutter test --update-goldens test/goldens/   # only for a deliberate UI change; review the PNGs
```

Always drive Dart through `fvm` — a standalone `dart` from PATH may format
differently from the pinned SDK and will fail the CI format gate. Every
user-facing string goes into all three ARBs (`app_en`, `app_de`, `app_it`); two
sweep tests fail the build on hardcoded strings and on raw `Colors.*` in the
presentation layer.

### Updates

Android builds distributed from GitHub Releases check once a day for a newer
release, and on demand from **Settings → About**. The sheet shows the release
notes and downloads the APK for the device's ABI, verifying its size and
`SHA256SUMS.txt` entry before offering to install it; a download in progress can
be cancelled, which deletes the partial file. Installing explains Android's
"allow this app to install apps" prompt first, and because Android never reports
back, the app records the release it handed over and settles it on the next
launch: installed, or still installable and offered again. See
[`docs/release.md`](docs/release.md#cutting-a-release) for how a release is cut
and named.

## Documentation

- [`docs/architecture.md`](docs/architecture.md) — layers, the provider graph, app modes, the local schema ledger, backup, reminders, expiry, updates, sync, theming and the test layout.
- [`docs/release.md`](docs/release.md) — keystore setup, signed Android/iOS/web builds, CI secrets, versioning.
- [`docs/superpowers/specs/`](docs/superpowers/specs/) — design specs; [`docs/superpowers/plans/`](docs/superpowers/plans/) — implementation plans.

## License

Private project. All rights reserved.
