# Medora — Home Medicine Cabinet Manager

A production-ready Flutter mobile application for managing your home medicine cabinet, tracking medication expiration dates, creating treatment plans, managing dose schedules, and receiving medication reminders.

---

## Features

- **Medication Inventory** — Add, edit, delete, and view medications with full details (name, active ingredient, category, quantity, expiry date, barcode, storage location, notes).
- **Expiry & Stock Alerts** — Automatically detects medications expiring within 30 days and medications with low stock.
- **Barcode Scanner** — Scan medication package barcodes using the device camera (`mobile_scanner`). Barcodes are stored with each medication.
- **Treatment / Illness Tracking** — Create treatment plans with symptoms, start/end dates, and notes.
- **Prescription Plans** — Attach medication prescriptions to treatments with dosage, interval, and duration.
- **Dose Scheduling** — Auto-generated dose log entries with pending/taken/skipped/missed status.
- **Reminders** — Local push notifications for each scheduled dose (`flutter_local_notifications`).
- **Dashboard** — Home screen with summary cards: today's doses, expiring meds, low stock, active treatments.
- **Settings** — Notification controls, sync status, and future feature placeholders.

---

## Tech Stack

| Layer               | Technology                        |
|---------------------|-----------------------------------|
| **Frontend**        | Flutter (Dart)                    |
| **State Management**| Riverpod                          |
| **Backend**         | Supabase                          |
| **Database**        | PostgreSQL (Supabase-managed)     |
| **Notifications**   | flutter_local_notifications       |
| **Barcode Scanning**| mobile_scanner                    |
| **Routing**         | go_router                         |
| **Architecture**    | Clean Architecture                |
| **Version Manager** | FVM                               |

---

## Architecture

```
lib/
├── core/                    # Constants, theme, errors, result type, extensions
│   ├── constants.dart
│   ├── errors.dart
│   ├── extensions.dart
│   ├── result.dart
│   ├── supabase_config.dart
│   └── theme.dart
├── domain/                  # Business logic (framework-independent)
│   ├── entities/            # Pure Dart domain entities
│   │   ├── medication.dart
│   │   ├── treatment.dart
│   │   ├── prescription.dart
│   │   └── dose_log.dart
│   └── repositories/       # Abstract repository contracts
│       ├── medication_repository.dart
│       ├── treatment_repository.dart
│       ├── prescription_repository.dart
│       └── dose_log_repository.dart
├── data/                    # Data layer (Supabase integration)
│   ├── models/              # JSON-serializable data models
│   │   ├── medication_model.dart
│   │   ├── treatment_model.dart
│   │   ├── prescription_model.dart
│   │   └── dose_log_model.dart
│   ├── datasources/         # Remote data sources (Supabase API calls)
│   │   ├── medication_remote_datasource.dart
│   │   ├── treatment_remote_datasource.dart
│   │   ├── prescription_remote_datasource.dart
│   │   └── dose_log_remote_datasource.dart
│   └── repositories/        # Concrete repository implementations
│       ├── medication_repository_impl.dart
│       ├── treatment_repository_impl.dart
│       ├── prescription_repository_impl.dart
│       └── dose_log_repository_impl.dart
├── services/                # App services
│   └── reminder_service.dart
├── presentation/            # UI layer
│   ├── providers/           # Riverpod providers
│   │   ├── providers.dart           # DI wiring
│   │   ├── medication_providers.dart
│   │   ├── treatment_providers.dart
│   │   ├── prescription_providers.dart
│   │   └── dose_providers.dart
│   ├── router/
│   │   └── app_router.dart          # GoRouter configuration
│   ├── screens/
│   │   ├── home/
│   │   │   └── home_screen.dart
│   │   ├── medication/
│   │   │   ├── medication_list_screen.dart
│   │   │   ├── medication_detail_screen.dart
│   │   │   └── add_medication_screen.dart
│   │   ├── treatment/
│   │   │   ├── treatment_list_screen.dart
│   │   │   ├── treatment_detail_screen.dart
│   │   │   └── add_treatment_screen.dart
│   │   ├── dose/
│   │   │   └── dose_schedule_screen.dart
│   │   ├── scanner/
│   │   │   └── barcode_scanner_screen.dart
│   │   └── settings/
│   │       └── settings_screen.dart
│   └── widgets/
│       └── shared_widgets.dart
└── main.dart
```

---

## Prerequisites

- **FVM** — Flutter Version Manager ([install guide](https://fvm.app/documentation/getting-started/installation))
- **Flutter 3.41+ (stable)** — managed via FVM
- **Supabase account** — [supabase.com](https://supabase.com)
- **Android Studio / Xcode** — for device emulators

---

## Setup Instructions

### 1. Clone and install Flutter via FVM

```bash
cd medora
fvm install        # installs the pinned Flutter version
fvm use stable     # already configured
```

### 2. Configure Supabase

1. Create a new Supabase project at [supabase.com](https://supabase.com).

2. **Run the SQL schema** — go to your Supabase dashboard → **SQL Editor** → **New Query**, paste the contents of `supabase/migrations/001_initial_schema.sql` and click **Run**.

3. **Run the RLS policies** — open a second **New Query**, paste `supabase/migrations/002_rls_policies.sql` and click **Run**.

   > **Important:** The MVP uses permissive RLS (`USING (true)`) so no authentication is required. All four tables (`medications`, `treatments`, `prescriptions`, `dose_logs`) must exist before running the app.

4. Copy `.env.example` to `.env` and fill in your credentials from the Supabase dashboard → **Project Settings → API**:
   ```bash
   cp .env.example .env
   ```
   ```
   SUPABASE_URL=https://your-project.supabase.co
   SUPABASE_ANON_KEY=your-anon-key-here
   ```

### 3. Install dependencies

```bash
fvm flutter pub get
```

### 4. Run the app

```bash
# Android
fvm flutter run

# iOS (macOS only)
fvm flutter run --device-id=<ios-device-or-simulator>
```

> **Note:** The project requires **minSdk 28** (Android 9.0+) due to `mobile_scanner` and `supabase_flutter`. Core library desugaring is already configured in `android/app/build.gradle.kts` for `flutter_local_notifications`.

### 5. (Optional) Run code generation

If you add Freezed/json_serializable models:

```bash
fvm dart run build_runner build --delete-conflicting-outputs
```

---

## Database Schema

| Table           | Description                                  |
|-----------------|----------------------------------------------|
| `users`         | User profiles (extends Supabase auth.users)  |
| `medications`   | Medication inventory                         |
| `treatments`    | Illness/treatment plans                      |
| `prescriptions` | Medication prescriptions within treatments   |
| `dose_logs`     | Individual dose tracking entries              |

All tables include:
- UUID primary keys
- Foreign key constraints with CASCADE deletes
- Row Level Security (RLS) policies for per-user data isolation
- Auto-updating `updated_at` triggers

---

## Reminder System

The `ReminderService` (`lib/services/reminder_service.dart`) provides:

| Method                          | Description                              |
|---------------------------------|------------------------------------------|
| `scheduleDoseReminder()`        | Schedule a single notification           |
| `scheduleRepeatingReminders()`  | Generate notifications for a full prescription |
| `cancelReminder()`              | Cancel a single notification by ID       |
| `cancelPrescriptionReminders()` | Cancel all notifications for a prescription |
| `rescheduleReminder()`          | Cancel + re-schedule for a prescription  |
| `cancelAllReminders()`          | Cancel everything                        |
| `requestPermissions()`          | Request notification permissions (Android 13+ / iOS) |

---

## Future Expansion

The architecture is designed to support:

- **Multi-user family support** — `family_id` column already present in `users` table
- **Cloud sync** — Supabase real-time subscriptions can be added to datasources
- **Offline mode** — Repository interfaces allow drop-in local database (e.g., Drift/SQLite)
- **Push notifications** — Supabase Edge Functions + FCM can replace local notifications
- **Medicine database integration** — `BarcodeApiDatasource` can query OpenFDA or similar APIs
- **Authentication** — Supabase Auth with RLS policies already configured

---

## License

Private project. All rights reserved.
