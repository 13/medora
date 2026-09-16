# Dashboard fixes (expired medications, clipped stat tile, dashboard test coverage) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make expired medications visible and visually distinct on the Home dashboard, stop the stat tile labels clipping in en/de/it on a 360 dp phone, and put the dashboard, its providers and the app's main flows under tests that assert real behaviour.

**Architecture:** The two bugs are one provider line and one widget's layout, so they land first and separately: `expiringSoonProvider` stops excluding past dates twice and starts sorting most-urgent-first (Task 1), then `_ExpiringSoonCard` renders the already-existing `ExpiryBadge` in its trailing slot so the dashboard agrees with the medication list and detail screens (Task 2), then `_StatTile` cancels the theme's card margin and degrades to an ellipsis instead of a hard clip (Task 3). Test work follows the fixes rather than racing them: dashboard states and cards (Task 4), locale/width/scale/dark rendering (Task 5), and a thin set of router-level smoke tests through the main flows (Task 6). Every test reuses the existing helpers — `pumpMedoraApp`, `seedPrescription`/`seedDoseLog`, `FakePort`, `setUpTestDatabase`, `loadAppFonts`, `contrastRatio` — and no new test infrastructure is introduced.

**Tech Stack:** Flutter 3.44.6 / Dart 3.12.2 via `fvm` (never bare `dart`/`flutter`), flutter_riverpod 3.4, go_router 18, sqflite + `sqflite_common_ffi` in tests, ARB localisation in en/de/it via `flutter gen-l10n`, golden tests with committed PNGs under `test/goldens/`.

## Global Constraints

- `fvm dart format --set-exit-if-changed .` clean.
- `fvm flutter analyze --fatal-infos` clean.
- `fvm flutter test` green.
- `flutter gen-l10n` produces no diff and `untranslated.txt` is `{}`.
- Guard tests stay green: theme sweep (`test/presentation/theme_sweep_test.dart`, no hardcoded colors), l10n sweep (`test/presentation/l10n_sweep_test.dart`), clock sweep (`test/presentation/clock_sweep_test.dart`: no `DateTime.now()` in `lib/presentation` or `lib/domain` — take the time from `nowProvider`).
- Golden PNGs change only in a task that explicitly re-records them and says why.
- No new pub dependencies unless a task names and justifies it.
- Commits end with the two lines `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>` and `Claude-Session: https://claude.ai/code/session_01BAjdzp9JhksW2XbhM6CPBS`.

**Baseline measured on `dashboard-fixes` at v0.2.4+16:** `fvm flutter test` = **841 passed, 2 skipped** (the two Supabase integration tests), exit 0. Eight golden PNGs under `test/goldens/`.

---

## ⚠️ Read this before starting

**Briefs in the previous plan (`2026-09-16-improvements-plan.md`) repeatedly contained snippets that did not match the code.** Every code block below was read out of the working tree on `dashboard-fixes` at v0.2.4+16, but you must still verify before you edit: open the file, confirm the surrounding lines match what this plan quotes, and if they do not, **implement the intent against the real code and report the deviation in your task summary**. Do not silently adapt and do not paste a block that no longer applies. The same rule covers line numbers: they are accurate at v0.2.4+16 and will drift as earlier tasks land.

**A test must assert real behaviour.** Two traps specific to this work:

1. **Clipped text throws nothing.** Flutter's default `TextOverflow.clip` paints a label past its line box in silence — no exception, no red box. `expect(tester.takeException(), isNull)` therefore **cannot** catch Bug 2, and `test/presentation/screens/add_medication_layout_test.dart:53` (the existing 360 dp × {en, de, it} loop) is exactly that shape and is blind to it. A clipping test must assert **geometry**: lay out a `TextPainter` with the label's own style and compare its natural width against the box the widget actually gave the text (`RenderParagraph.constraints.maxWidth`), or read `RenderParagraph.didExceedMaxLines`. Note that `didExceedMaxLines` alone is **not** sufficient once `maxLines: 2` is set: a single unbreakable word that does not fit is ellipsized on line 1, so it stays `false`. The width comparison is the assertion that actually bites.
2. **Text measurement needs real fonts.** `flutter_test` renders every glyph as a 1-em box unless fonts are registered, which makes a 12 sp label roughly three times as wide as on a device (see the comment in `test/helpers/fonts.dart:1-7`). `loadAppFonts()` is currently called only from `test/goldens/flutter_test_config.dart`, which is scoped to `test/goldens/`. **Any new test under `test/presentation/` that measures text must call `await loadAppFonts();` itself** (`setUpAll(loadAppFonts)`), or it will measure fiction and fail for the wrong reason.

---

## Findings that change the scope

Checked against the working tree before planning. Three of these add small production changes that were not in the original request; each is named in the task that makes it.

1. **The cards' `Retry` button cannot recover.** `_ExpiringSoonCard`, `_LowStockCard` and `_ActiveTreatmentsCard` pass `onRetry: () async => ref.invalidate(expiringSoonProvider)` and friends (`home_screen.dart:527,610,692`). Those are *derived* providers: they `await ref.watch(medicationListProvider.future)`. When the error came from `medicationListProvider` — which is the only place a cabinet read can fail — invalidating the derived provider re-awaits the still-failed source and renders the same error. Retry is a no-op for the case it exists to handle. **Task 4 fixes it** by invalidating the source list as well, and the test asserts recovery rather than asserting the broken behaviour.
2. **Pull-to-refresh does not refresh the cabinet.** `RefreshIndicator.onRefresh` (`home_screen.dart:57-62`) invalidates `expiringSoonProvider`, `lowStockProvider`, `activeTreatmentsProvider` and `todaysDoseLogsProvider`. The first three only re-derive from the cached `medicationListProvider` / `treatmentListProvider`, so a medication written to SQLite by anything else (a sync pull, another tab) never appears on a pull. Only the doses actually re-read. **Task 4 fixes it** by invalidating the two source lists and awaiting them, so the spinner also stops for an honest reason.
3. **The goldens lock Bug 1 in.** `test/goldens/golden_config.dart:47-54` already seeds `m3` "Bentelan" with `expiryDate: DateTime(2025, 12)` against `goldenNow = DateTime(2026, 3, 4, 15)` — an expired medication that appears nowhere in `home_light.png` / `home_dark.png`. Tasks 2 and 3 each re-record both PNGs, for the reasons stated in those tasks.

**The test that encodes the current wrong behaviour and must be updated:** `test/presentation/providers/medication_providers_test.dart:31-66`, `'expiringSoonProvider lists only unexpired items within 30 days'`. It seeds a medication named `Expired` at `today - 1` and asserts `soon.map((m) => m.name)` equals `['Soon']` exactly. That is the bug, asserted. **Task 1 rewrites it.** It is not a regression when it changes.

**Already covered, and deliberately not duplicated.** `test/presentation/screens/home_screen_test.dart` already tests the Now card's next-due dose, its **overdue** badge (`:75`), the Take → snackbar → Undo round trip (`:85-95`), the failed-write path via `FailingTakeRepo` (`:98-137`), and the no-doses empty state (`:139-148`). Tasks 4-6 do not re-test those; Task 6 re-asserts overdue and Take/Undo only because it is the first test to drive them through the real router. `test/presentation/widgets/expiry_badge_test.dart` covers `ExpiryBadge`'s three branches in isolation, which is why Task 2 asserts only that Home *reaches* the expired branch.

**Do not "fix" the dead parallel implementation.** `getExpiringSoon` exists on the repository (`lib/domain/repositories/medication_repository.dart:20`, `lib/data/repositories/medication_repository_impl.dart:56-63`) and the datasource (`lib/data/datasources/medication_local_datasource.dart:99-115`) with SQL `expiry_date >= today AND expiry_date <= today+30`, and it calls `DateTime.now()` directly. **Nothing in `lib/presentation` calls it** — Home filters `medicationListProvider` in memory. Changing the SQL would fix nothing and is out of scope for this plan.

---

## Decision: expired joins the Expiring Soon card, sorted first

**Expired medications join the existing "Expiring Soon" card as its most-urgent rows rather than getting their own fourth section.** The root cause is a single provider whose window starts at *today*; widening that window to `(-∞, +30]` makes one list that already feeds both the "Expiring" stat tile (`home_screen.dart:358`) and the card (`:521`), so the count includes expired items and the `allMedicationsWithinDate` empty state stops lying — both for free, with no second bucket to keep in sync. The rows stay visually distinct because `ExpiryBadge` (`lib/presentation/widgets/shared_widgets.dart:36-58`) already encodes exactly the three-way decision needed — red `dangerContainer` + "Expired" below zero, amber `warningContainer` + "Expires in N days" up to 30 — and is already used on the medication list and detail screens, so reusing it in the card's trailing slot makes the dashboard *agree* with the rest of the app instead of inventing a fourth visual language for the same state. A separate section would mean a new provider, a new section header with a new ARB key in three locales, a fourth card, empty-state logic that has to consider two buckets at once, a bigger golden diff, and more dashboard scrolling before the user reaches Low Stock — all for the same one-line root cause and no extra information. Sorting most-urgent-first also protects the card's `.take(3)` truncation: the longest-expired box can never be pushed off the card by three merely-expiring ones.

---

## File structure

| Path | Change | Responsibility |
|---|---|---|
| `lib/presentation/providers/medication_providers.dart` | modify (Task 1) | `expiringSoonProvider` keeps expired items, uses `AppConstants.expiryWarningDays`, sorts most-urgent-first. |
| `lib/presentation/screens/home/home_screen.dart` | modify (Tasks 2, 3, 4) | `_ExpiringSoonCard` trailing slot → `ExpiryBadge` + expired icon colour; `_StatTile` layout; `onRetry` / `onRefresh` invalidation. |
| `test/presentation/providers/medication_providers_test.dart` | modify (Tasks 1, 4) | Rewrite the test that pins the bug; add expiry-ordering, archived-exclusion and `lowStockProvider` cases. |
| `test/presentation/screens/home_expiry_test.dart` | create (Task 2) | Expired is on the dashboard, distinct, counted; the empty state tells the truth. |
| `test/presentation/screens/home_stat_tile_layout_test.dart` | create (Task 3) | Stat tile labels fit at 360 dp in en/de/it and degrade to an ellipsis at large text scales. |
| `test/presentation/screens/home_dashboard_test.dart` | create (Task 4) | Low stock, active treatments, today progress, >3 truncation, error + retry, pull-to-refresh. |
| `test/presentation/screens/home_locale_test.dart` | create (Task 5) | The whole dashboard in de and it, at 360 dp, at a large text scale, and in dark. |
| `test/presentation/screens/app_smoke_test.dart` | create (Task 6) | Router-level smoke tests: add a medication, take and undo a dose, open settings, the scanner return-only route. |
| `test/goldens/home_light.png`, `test/goldens/home_dark.png` | re-record (Tasks 2, 3) | Only in those two tasks, for the reasons they state. |

No new ARB keys are needed: `expired` ("Expired" / "Abgelaufen" / "Scaduto") already exists in all three locales (`lib/l10n/app_en.arb:113`, `app_de.arb:82`, `app_it.arb:82`) and is rendered by `ExpiryBadge`. No new pub dependencies.

## Task order, and why

Task 1 is the root cause and everything else about Bug 1 depends on its output, so it lands alone and first — the provider change alone already makes the stat tile count expired items. Task 2 renders what Task 1 now returns. Task 3 is an independent layout bug that touches a different widget in the same file; it goes third so the two goldens it shifts are re-recorded on top of Task 2's content change rather than underneath it. Tasks 4 and 5 are the broad dashboard coverage the user asked for and must run against the fixed screen, or they would encode the bugs. Task 6 is the thin end-to-end layer and goes last because it is the only task that pumps the real router, so it is the one most likely to need a second pass.

---

### Task 1: `expiringSoonProvider` stops dropping the past

The decisive line is `lib/presentation/providers/medication_providers.dart:148`, which excludes past dates twice over: `m.isExpiringSoon(now: now)` already floors at `remaining >= 0` (`lib/domain/entities/medication.dart:83`), and `!m.expiredAt(now)` (`:93-96`) drops them again. The new provider asks `daysUntilExpiry` directly, keeps everything at or below the 30-day threshold however far in the past, and sorts most-urgent-first. It also starts using `AppConstants.expiryWarningDays` (`lib/core/constants.dart:23`) instead of `isExpiringSoon`'s independent default of 30 — two constants that happen to agree today and need not tomorrow.

**Files:**
- Modify: `lib/presentation/providers/medication_providers.dart:139-151`
- Test: `test/presentation/providers/medication_providers_test.dart:31-66` (**rewrite** — this test asserts the bug)

**Interfaces:**
- Consumes: `medicationListProvider` (existing `AsyncNotifierProvider<MedicationListNotifier, List<Medication>>`); `nowProvider` (`Provider<Now>`, `lib/presentation/providers/now_provider.dart:15`); `Medication.daysUntilExpiry(DateTime now) → int?` and `Medication.expiredAt(DateTime now) → bool` (`lib/domain/entities/medication.dart:72,93`); `AppConstants.expiryWarningDays` (`= 30`).
- Produces — unchanged type, changed contract; Tasks 2, 4 and 5 rely on it:
```dart
/// Medications that need attention on the expiry axis: everything already
/// expired, plus everything expiring within [AppConstants.expiryWarningDays].
/// Archived medications and medications with no expiry date are excluded.
/// Sorted by [Medication.daysUntilExpiry] ascending — most urgent (longest
/// expired) first.
final expiringSoonProvider = FutureProvider<List<Medication>>((ref) async { ... });
```

- [ ] **Step 1: Rewrite the test that pins the bug**

In `test/presentation/providers/medication_providers_test.dart`, add the clock import alongside the existing ones (the `directives_ordering` lint wants it sorted — it goes after `medication_providers.dart` and before `providers.dart`):

```dart
import 'package:medora/presentation/providers/now_provider.dart';
```

Give the `make()` helper an injectable clock so the expiry cases are not hostage to the wall clock. Replace the existing helper (lines 22-29) with:

```dart
  Future<ProviderContainer> make({DateTime? now}) async {
    final prefs = await SharedPreferences.getInstance();
    final c = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        if (now != null) nowProvider.overrideWithValue(() => now),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }
```

Now replace the whole `'expiringSoonProvider lists only unexpired items within 30 days'` test (lines 31-66) with these two:

```dart
  test(
    'expiringSoonProvider keeps expired items and sorts most urgent first',
    () async {
      final now = DateTime(2026, 3, 4, 15);
      final c = await make(now: now);
      final notifier = c.read(medicationListProvider.notifier);
      await c.read(medicationListProvider.future);

      Future<void> add(String name, int days, {bool archived = false}) =>
          notifier.addMedication(
            Medication(
              id: name,
              name: name,
              quantity: 1,
              isArchived: archived,
              expiryDate: DateTime(2026, 3, 4).add(Duration(days: days)),
            ),
          );

      await add('LongExpired', -40);
      await add('Expired', -1);
      await add('Today', 0);
      await add('Soon', 10);
      await add('Edge', 30);
      await add('Far', 31);
      await add('ArchivedExpired', -5, archived: true);
      await notifier.addMedication(
        const Medication(id: 'NoDate', name: 'NoDate', quantity: 1),
      );

      final soon = await c.read(expiringSoonProvider.future);
      expect(soon.map((m) => m.name).toList(), [
        'LongExpired',
        'Expired',
        'Today',
        'Soon',
        'Edge',
      ]);
    },
  );

  test('one expired medication is not an empty expiry list', () async {
    // The dashboard's "All medications are within date" empty state keys off
    // this list being empty. With an expired box in the cabinet it must not
    // be, or the empty state is an actively false statement.
    final now = DateTime(2026, 3, 4, 15);
    final c = await make(now: now);
    final notifier = c.read(medicationListProvider.notifier);
    await c.read(medicationListProvider.future);
    await notifier.addMedication(
      Medication(
        id: 'a',
        name: 'Bentelan',
        quantity: 8,
        expiryDate: DateTime(2025, 12),
      ),
    );

    final soon = await c.read(expiringSoonProvider.future);
    expect(soon.single.name, 'Bentelan');
    expect(soon.single.expiredAt(now), isTrue);
  });
```

Expected values, worked out: `daysUntilExpiry` is `calendarDaysBetween` (`lib/core/clock.dart:18-22`), date-based, so against `now = 2026-03-04 15:00` the seeds are `-40, -1, 0, +10, +30, +31, -5, null`. `Far` (+31) exceeds the 30-day threshold, `ArchivedExpired` is archived, `NoDate` has no expiry — the other five come back ascending.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `fvm flutter test test/presentation/providers/medication_providers_test.dart`
Expected: both new tests FAIL. The first fails with `Expected: ['LongExpired', 'Expired', 'Today', 'Soon', 'Edge'] Actual: ['Today', 'Soon', 'Edge']` (order may differ — the current provider does not sort); the second fails with `Bad state: No element` on `soon.single`, because the expired medication is filtered out.

- [ ] **Step 3: Write the implementation**

In `lib/presentation/providers/medication_providers.dart`, add the constants import (sorted after `flutter_riverpod`, before `medora/domain`):

```dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:medora/core/constants.dart';
import 'package:medora/domain/entities/medication.dart';
```

Replace the provider at lines 139-151 with:

```dart
/// Medications that need attention on the expiry axis: everything already
/// expired, plus everything expiring within [AppConstants.expiryWarningDays].
///
/// Expired items are deliberately kept. The old window started at *today*
/// (`isExpiringSoon` floors at `remaining >= 0`, and the filter then asked
/// `!expiredAt(now)` a second time), so a medication that expired yesterday
/// was invisible on the dashboard while the card's empty state claimed every
/// medication was within date — in a medicine cabinet, the most urgent row
/// there is.
///
/// Sorted most urgent (longest expired) first, so the card's `.take(3)`
/// cannot hide an expired box behind three merely expiring ones.
final expiringSoonProvider = FutureProvider<List<Medication>>((ref) async {
  // Watch the medication list to trigger updates
  final meds = await ref.watch(medicationListProvider.future);

  final now = ref.watch(nowProvider)();

  final matches = <Medication>[];
  for (final m in meds) {
    if (m.isArchived) continue;
    final days = m.daysUntilExpiry(now);
    if (days == null || days > AppConstants.expiryWarningDays) continue;
    matches.add(m);
  }
  matches.sort(
    (a, b) => a.daysUntilExpiry(now)!.compareTo(b.daysUntilExpiry(now)!),
  );
  return matches;
});
```

The `!` on `daysUntilExpiry` inside the comparator is safe: the loop above admits only medications whose value is non-null.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `fvm flutter test test/presentation/providers/medication_providers_test.dart`
Expected: PASS, 5 tests (the three untouched ones plus the two new).

- [ ] **Step 5: Run the full suite and the gates**

Run: `fvm flutter test`
Expected: the two Home goldens (`home light`, `home dark`) now FAIL — the expired fixture medication "Bentelan" starts rendering on the Expiring Soon card. **Do not re-record them here**; Task 2 changes the same card's rendering again and re-records once, afterwards. Note the failure in your task summary and carry on. Every other test passes.

Run: `fvm dart format --set-exit-if-changed .` and `fvm flutter analyze --fatal-infos`
Expected: both clean.

- [ ] **Step 6: Commit**

```bash
git add lib/presentation/providers/medication_providers.dart test/presentation/providers/medication_providers_test.dart
git commit -m "$(cat <<'EOF'
fix(dashboard): keep expired medications in the expiry list

The window started at today twice over — isExpiringSoon floors at zero and
the filter then asked !expiredAt as well — so a medication that expired
yesterday was dropped and the dashboard had no bucket that could hold it.
Widen the window to everything at or below the 30-day threshold, take that
threshold from AppConstants, and sort most urgent first.

The provider test asserted the old behaviour; it is rewritten, not
regressed. The two Home goldens now fail and are re-recorded in the
follow-up that changes the card's rendering.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01BAjdzp9JhksW2XbhM6CPBS
EOF
)"
```

---

### Task 2: the dashboard shows expired medications, distinctly

Task 1 put expired medications into the list. This renders them as their own thing. The card's trailing slot currently builds a hand-rolled `'${days ?? 0}'` + `l10n.daysLabel` column (`home_screen.dart:567-587`) which would read "-3 / Days" for an expired item; `ExpiryBadge` already makes exactly the right three-way colour and label decision and is what the medication list and detail screens show, so the card reuses it. The "Expiring" stat tile (`home_screen.dart:358`) and the `allMedicationsWithinDate` empty state (`:529-535`) need **no change at all** — both already read the same provider, so Task 1 fixed the count and the empty state, and this task's test proves it.

**Files:**
- Modify: `lib/presentation/screens/home/home_screen.dart:536-594` (`_ExpiringSoonCard`'s `data` builder only)
- Create: `test/presentation/screens/home_expiry_test.dart`
- Re-record: `test/goldens/home_light.png`, `test/goldens/home_dark.png`

**Interfaces:**
- Consumes: `expiringSoonProvider` sorted most-urgent-first (Task 1); `ExpiryBadge({Key? key, required DateTime? expiryDate, required DateTime now})` (`lib/presentation/widgets/shared_widgets.dart:16-17`, already imported by `home_screen.dart:23`); `context.medora.danger` / `.warning` (`lib/core/theme_extensions.dart:29-30`); `Medication.expiredAt(DateTime) → bool`.
- Produces: no new public API. Later tasks rely on these rendered facts: an expired row shows the text `l10n.expired` and the icon `Icons.error_outline`; an expiring row shows `l10n.expiresInDaysShort(days)` and `Icons.warning_amber_rounded`.

- [ ] **Step 1: Write the failing test**

Create `test/presentation/screens/home_expiry_test.dart`:

```dart
/// The dashboard has to show a medication that has already expired. The
/// expiry window used to start at today, so an expired box appeared nowhere
/// on Home while the card claimed every medication was within date.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/core/platform_capabilities.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/presentation/providers/now_provider.dart';
import 'package:medora/presentation/providers/providers.dart';
import 'package:medora/presentation/providers/settings_providers.dart';
import 'package:medora/presentation/screens/home/home_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/fake_reminder_port.dart';
import '../../helpers/pump_app.dart';
import '../../helpers/test_database.dart';

void main() {
  // A fixed clock: these tests assert expiry arithmetic, not doses, so
  // nothing here depends on the real wall clock.
  final now = DateTime(2026, 3, 4, 15);

  setUp(() async {
    await setUpTestDatabase();
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(tearDownTestDatabase);

  Future<List<Override>> overrides() async => [
    sharedPreferencesProvider.overrideWithValue(
      await SharedPreferences.getInstance(),
    ),
    syncStartupDelayProvider.overrideWithValue(Duration.zero),
    reminderPortProvider.overrideWithValue(FakePort()),
    platformCapabilitiesProvider.overrideWithValue(
      PlatformCapabilities.desktop,
    ),
    nowProvider.overrideWithValue(() => now),
  ];

  /// Home is a long ListView; a tall viewport puts every section on screen
  /// so the assertions do not have to scroll.
  void useTallPhone(WidgetTester tester) {
    tester.view.physicalSize = const Size(412, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  testWidgets('an expired medication is on the dashboard, above an expiring '
      'one, and marked expired', (tester) async {
    useTallPhone(tester);
    final db = await AppDatabase.instance.database;
    await db.insert('medications', {
      'id': 'soon',
      'name': 'Moment 200',
      'quantity': 5,
      'expiry_date': '2026-03-20',
    });
    await db.insert('medications', {
      'id': 'exp',
      'name': 'Bentelan',
      'quantity': 8,
      'expiry_date': '2025-12-01',
    });

    await pumpMedoraApp(
      tester,
      const HomeScreen(),
      overrides: await overrides(),
    );
    await tester.pumpAndSettle();

    // Both are on the card, expired first (the provider sorts by urgency,
    // and `.take(3)` must never drop the expired one).
    expect(find.text('Bentelan'), findsOneWidget);
    expect(find.text('Moment 200'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Bentelan')).dy,
      lessThan(tester.getTopLeft(find.text('Moment 200')).dy),
      reason: 'the expired medication must head the card',
    );

    // Visually distinct from "expiring soon": its own label and its own icon.
    // ExpiryBadge's colours are covered by expiry_badge_test.dart; what this
    // test pins is that Home reaches the expired branch at all.
    expect(find.text('Expired'), findsOneWidget);
    expect(find.text('Expires in 16 days'), findsOneWidget);
    expect(find.byIcon(Icons.error_outline), findsOneWidget);
    expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);

    // The empty state must stop lying.
    expect(find.text('All medications are within date'), findsNothing);

    // And the stat tile counts both.
    final tile = find
        .ancestor(of: find.text('Expiring'), matching: find.byType(InkWell))
        .first;
    expect(
      find.descendant(of: tile, matching: find.text('2')),
      findsOneWidget,
    );
  });

  testWidgets('with nothing expired or expiring the card says so', (
    tester,
  ) async {
    useTallPhone(tester);
    final db = await AppDatabase.instance.database;
    await db.insert('medications', {
      'id': 'ok',
      'name': 'Aspirina',
      'quantity': 5,
      'expiry_date': '2027-01-01',
    });

    await pumpMedoraApp(
      tester,
      const HomeScreen(),
      overrides: await overrides(),
    );
    await tester.pumpAndSettle();

    expect(find.text('All medications are within date'), findsOneWidget);
    expect(find.text('Expired'), findsNothing);
    final tile = find
        .ancestor(of: find.text('Expiring'), matching: find.byType(InkWell))
        .first;
    expect(
      find.descendant(of: tile, matching: find.text('0')),
      findsOneWidget,
    );
  });
}
```

`'2026-03-20'` minus `2026-03-04` is 16 calendar days, which is why the expiring row reads exactly `Expires in 16 days` (`expiresInDaysShort`, `lib/l10n/app_en.arb:114`).

- [ ] **Step 2: Run the test to verify it fails**

Run: `fvm flutter test test/presentation/screens/home_expiry_test.dart`
Expected: the first test FAILS at `expect(find.text('Expired'), findsOneWidget)` with `Found 0 widgets` — after Task 1 the expired row is on the card, but its trailing slot still renders the raw day count (`-93`) and the amber warning icon, so there is no "Expired" label and `findsOneWidget` for `Icons.warning_amber_rounded` finds two. The second test passes already.

- [ ] **Step 3: Write the implementation**

In `lib/presentation/screens/home/home_screen.dart`, replace the `data:` builder of `_ExpiringSoonCard` (lines 536-594) with:

```dart
      data: (meds) {
        return Card(
          child: Column(
            children: meds.take(3).map((med) {
              final expired = med.expiredAt(now);
              return ListTile(
                leading: Icon(
                  expired ? Icons.error_outline : Icons.warning_amber_rounded,
                  color: expired
                      ? context.medora.danger
                      : context.medora.warning,
                ),
                title: Text(med.name),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (med.expiryDate != null)
                      Text(
                        med.expiryDate!.formatted,
                        style: const TextStyle(fontSize: 12),
                      ),
                    if (med.patientTags.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Wrap(
                        spacing: 4,
                        runSpacing: 4,
                        children: med.patientTags
                            .map((t) => TagChip(label: t, fontSize: 10))
                            .toList(),
                      ),
                    ],
                  ],
                ),
                // The badge the medication list and the detail screen already
                // show: red "Expired" below zero, amber "Expires in N days"
                // up to the threshold. The old hand-rolled day column would
                // have read "-93 Days" for an expired box.
                trailing: ExpiryBadge(expiryDate: med.expiryDate, now: now),
                dense: true,
                onTap: () => context.push('/medications/${med.id}'),
              );
            }).toList(),
          ),
        );
      },
```

Note the `final days = med.daysUntilExpiry(now);` local at line 540 is gone — nothing uses it now, and leaving it would fail `fvm flutter analyze --fatal-infos`. `ExpiryBadge` and `TagChip` both already come from the `shared_widgets.dart` import at line 23; `context.medora` from `theme_extensions.dart` at line 10. No import changes.

- [ ] **Step 4: Run the test to verify it passes**

Run: `fvm flutter test test/presentation/screens/home_expiry_test.dart`
Expected: PASS, 2 tests.

**If the badge overflows the `ListTile` trailing slot on a narrow phone** (a `RenderFlex overflowed` exception in Task 5's 360 dp de/it tests, where the badge reads "Läuft in 16 Tagen ab"), the minimal fix is to let the title give way: change `title: Text(med.name)` to `title: Text(med.name, overflow: TextOverflow.ellipsis)`. Apply it only if a test actually shows the overflow, and **report the deviation**.

- [ ] **Step 5: Re-record the two Home goldens**

They must change: the golden fixture's `m3` "Bentelan" (`test/goldens/golden_config.dart:47-54`, expired against `goldenNow`) now renders as a row on the Expiring Soon card where it was invisible before, and every row on that card swapped its trailing day-count column for `ExpiryBadge`.

Run: `fvm flutter test --update-goldens test/goldens/home_golden_test.dart`
Then: `fvm flutter test test/goldens/`
Expected: all golden tests pass. Open `test/goldens/home_light.png` and confirm by eye that "Bentelan" appears on the Expiring Soon card with a red "Expired" badge; if it does not, stop and report rather than committing the PNG.

- [ ] **Step 6: Run the full suite and the gates**

Run: `fvm flutter test`
Expected: all green (843 passed, 2 skipped).
Run: `fvm dart format --set-exit-if-changed .` and `fvm flutter analyze --fatal-infos`
Expected: both clean.

- [ ] **Step 7: Commit**

```bash
git add lib/presentation/screens/home/home_screen.dart test/presentation/screens/home_expiry_test.dart test/goldens/home_light.png test/goldens/home_dark.png
git commit -m "$(cat <<'EOF'
fix(dashboard): show expired medications as expired

The Expiring Soon card rendered a raw day count, which reads "-93 Days"
for an expired box. Show ExpiryBadge instead — the same red "Expired" the
medication list and the detail screen already show — and colour the row's
icon to match. The stat tile count and the empty state needed no change:
both read the provider that now includes expired items.

Both Home goldens re-recorded: the fixture's expired "Bentelan" now
renders on the card, and every row's trailing slot changed.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01BAjdzp9JhksW2XbhM6CPBS
EOF
)"
```

---

### Task 3: stat tile labels stop clipping

`_StatTile`'s label `Text` (`home_screen.dart:423-429`) has no `maxLines`, no `overflow` and no `Flexible`. Flutter's default is `TextOverflow.clip`, and a single word with no break opportunity cannot wrap, so it silently overruns its line box — "Behandlungen" paints as "Behandlun|gen". The easily-missed term in the width budget is the theme's card margin, `CardThemeData(margin: EdgeInsets.symmetric(horizontal: 12, vertical: 4))` (`lib/core/theme.dart:43` light, `:108` dark): each of the three tiles silently loses 24 dp. At 360 dp the label box is `(360 − 32 ListView padding − 24 gaps) / 3 − 24 margin − 16 padding = 61.3 dp`; "Treatments" needs ~73 dp and "Behandlungen" ~89 dp.

**Files:**
- Modify: `lib/presentation/screens/home/home_screen.dart:402-436` (`_StatTile.build`), and possibly `:362-384` (`_StatTiles`' two gap `SizedBox`es — contingency only)
- Create: `test/presentation/screens/home_stat_tile_layout_test.dart`
- Re-record: `test/goldens/home_light.png`, `test/goldens/home_dark.png`

**Interfaces:**
- Consumes: `HomeScreen`; `pumpMedoraApp(..., {Locale locale})` (`test/helpers/pump_app.dart:14-20`); `loadAppFonts()` (`test/helpers/fonts.dart:17`).
- Produces: no API change. The rendered contract later tasks rely on: at a 1.0× text scale and 360 dp width, each stat tile's label lays out at its natural width in en, de and it.

- [ ] **Step 1: Write the failing test**

Create `test/presentation/screens/home_stat_tile_layout_test.dart`:

```dart
/// The dashboard's three stat tiles each hold a single label under a number.
/// "Behandlungen" and "Trattamenti" are one long word with no break
/// opportunity, so they cannot wrap: without an explicit overflow they are
/// painted straight past the tile and clipped, and nothing throws.
///
/// These tests therefore assert geometry, never `takeException`. Real fonts
/// are mandatory: in the test font a 12 sp label is about three times as
/// wide as on a device (see test/helpers/fonts.dart).
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/core/platform_capabilities.dart';
import 'package:medora/presentation/providers/now_provider.dart';
import 'package:medora/presentation/providers/providers.dart';
import 'package:medora/presentation/providers/settings_providers.dart';
import 'package:medora/presentation/screens/home/home_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/fake_reminder_port.dart';
import '../../helpers/fonts.dart';
import '../../helpers/pump_app.dart';
import '../../helpers/test_database.dart';

void main() {
  final now = DateTime(2026, 3, 4, 15);

  setUpAll(loadAppFonts);

  setUp(() async {
    await setUpTestDatabase();
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(tearDownTestDatabase);

  Future<List<Override>> overrides() async => [
    sharedPreferencesProvider.overrideWithValue(
      await SharedPreferences.getInstance(),
    ),
    syncStartupDelayProvider.overrideWithValue(Duration.zero),
    reminderPortProvider.overrideWithValue(FakePort()),
    platformCapabilitiesProvider.overrideWithValue(
      PlatformCapabilities.desktop,
    ),
    nowProvider.overrideWithValue(() => now),
  ];

  /// The width the label would need if nothing constrained it, measured with
  /// the label's own style and the ambient text scale.
  double naturalWidth(WidgetTester tester, Finder label) {
    final widget = tester.widget<Text>(label);
    final context = tester.element(label);
    final painter = TextPainter(
      text: TextSpan(text: widget.data, style: widget.style),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
    )..layout();
    return painter.width;
  }

  const labels = <String, List<String>>{
    'en': ['Expiring', 'Low stock', 'Treatments'],
    'de': ['Läuft ab', 'Wenig Vorrat', 'Behandlungen'],
    'it': ['In scadenza', 'Scorte basse', 'Trattamenti'],
  };

  for (final entry in labels.entries) {
    testWidgets('stat tile labels fit a 360 dp phone in ${entry.key}', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await pumpMedoraApp(
        tester,
        const HomeScreen(),
        overrides: await overrides(),
        locale: Locale(entry.key),
      );
      await tester.pumpAndSettle();

      for (final label in entry.value) {
        // "In scadenza" is both a stat label and a section header in it, so
        // scope to the tile row by taking the one inside an InkWell.
        final finder = find
            .descendant(
              of: find.byType(InkWell),
              matching: find.text(label),
            )
            .first;
        expect(finder, findsOneWidget, reason: 'missing stat label $label');

        final paragraph = tester.renderObject<RenderParagraph>(finder);
        final box = paragraph.constraints.maxWidth;
        expect(
          naturalWidth(tester, finder),
          lessThanOrEqualTo(box + 0.5),
          reason:
              '"$label" needs more width than the tile gives it at 360 dp, '
              'so it is clipped or ellipsized',
        );
        expect(
          paragraph.didExceedMaxLines,
          isFalse,
          reason: '"$label" spilled past its line budget at 360 dp',
        );
      }
    });
  }

  for (final scale in const [1.5, 2.0]) {
    testWidgets('stat tile labels give way at a ${scale}x text scale', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await pumpMedoraApp(
        tester,
        MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(scale)),
          child: const HomeScreen(),
        ),
        overrides: await overrides(),
        locale: const Locale('de'),
      );
      await tester.pumpAndSettle();

      // At this size the longest label cannot fit, and that is fine: it must
      // ellipsize inside its box rather than paint past it or overflow.
      final finder = find
          .descendant(
            of: find.byType(InkWell),
            matching: find.text('Behandlungen'),
          )
          .first;
      final paragraph = tester.renderObject<RenderParagraph>(finder);
      expect(
        paragraph.size.width,
        lessThanOrEqualTo(paragraph.constraints.maxWidth + 0.5),
        reason: 'the label painted outside its tile at ${scale}x',
      );
      expect(tester.takeException(), isNull);
    });
  }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `fvm flutter test test/presentation/screens/home_stat_tile_layout_test.dart`
Expected: the three 360 dp tests FAIL on the natural-width assertion — en on "Treatments", de on "Behandlungen", it on "Trattamenti" — each reporting a natural width well above the ~61 dp box. The failure message prints both numbers; **write them down**, they tell you whether Step 3's budget is enough.

- [ ] **Step 3: Write the implementation**

In `lib/presentation/screens/home/home_screen.dart`, replace `_StatTile.build`'s returned widget (lines 405-435) with:

```dart
    return Expanded(
      child: Card(
        // The card theme adds 12 dp of margin either side (theme.dart:43,
        // :108) — 24 dp off a tile that is only ~101 dp wide on a 360 dp
        // phone, which is what pushed the single-word labels past their box.
        // The Row's SizedBox gaps already space the three tiles apart.
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '$value',
                  style: context.text.headlineMedium?.copyWith(
                    color: numberColor,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  label,
                  textAlign: TextAlign.center,
                  // A longer future label, or any text scale above 1.0,
                  // degrades to an ellipsis instead of a hard clip.
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: context.text.labelMedium?.copyWith(
                    color: context.colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
```

That takes the 360 dp label box from 61.3 dp to `(360 − 32 − 24) / 3 − 0 − 8 = 93.3 dp`.

- [ ] **Step 4: Run the test to verify it passes**

Run: `fvm flutter test test/presentation/screens/home_stat_tile_layout_test.dart`
Expected: PASS, 5 tests.

**Contingency, if the de case still fails by a few dp** (measured Inter advance widths are close to the new 93.3 dp budget for "Behandlungen"): narrow the two gaps in `_StatTiles` (`home_screen.dart:370,377`) from `const SizedBox(width: 12)` to `const SizedBox(width: 8)`, which returns ~2.7 dp per tile, and re-run. Do **not** reach for `FittedBox(fit: BoxFit.scaleDown)` — it shrinks the label below the accessibility floor, which is why the ellipsis is preferred. If it still fails, stop and report the measured numbers rather than shrinking text.

- [ ] **Step 5: Re-record the two Home goldens**

They must change: removing 24 dp of card margin per tile and trimming the tile padding from 8 to 4 moves every stat tile's geometry.

Run: `fvm flutter test --update-goldens test/goldens/home_golden_test.dart`
Then: `fvm flutter test test/goldens/`
Expected: all golden tests pass. Confirm by eye that the three tiles now sit flush against the 16 dp page margin with even 12 dp gaps.

- [ ] **Step 6: Run the full suite and the gates**

Run: `fvm flutter test`
Expected: all green (848 passed, 2 skipped).
Run: `fvm dart format --set-exit-if-changed .` and `fvm flutter analyze --fatal-infos`
Expected: both clean.

- [ ] **Step 7: Commit**

```bash
git add lib/presentation/screens/home/home_screen.dart test/presentation/screens/home_stat_tile_layout_test.dart test/goldens/home_light.png test/goldens/home_dark.png
git commit -m "$(cat <<'EOF'
fix(dashboard): stop the stat tile labels clipping

The card theme's 12 dp side margins cost each of the three tiles 24 dp, so
on a 360 dp phone the label had 61 dp for a word that needs 73 ("Treatments")
to 89 ("Behandlungen"). A single word cannot wrap, so it was painted past
its box and clipped — in silence, which is why no test caught it. Cancel the
margin, trim the padding, and cap the label at two lines with an ellipsis so
a longer label or a large text scale degrades instead of clipping.

Tested by geometry, not by takeException: clipped text throws nothing. Both
Home goldens re-recorded — the tile geometry moved.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01BAjdzp9JhksW2XbhM6CPBS
EOF
)"
```

---

### Task 4: the rest of the dashboard's states, and two invalidation fixes

Covers what the investigation listed as untested: the Low Stock card's rows and empty state, the Active Treatments card, the today-progress bar, the silent `.take(3)` truncation, the card error/retry path and pull-to-refresh. Writing the last two honestly exposes the two bugs in Findings 1 and 2, so this task fixes them: the plan will not have a test assert that Retry does nothing.

**Files:**
- Modify: `lib/presentation/screens/home/home_screen.dart:56-62` (`onRefresh`), `:527`, `:610`, `:692` (the three `onRetry`s)
- Modify: `test/presentation/providers/medication_providers_test.dart` (append `lowStockProvider` cases)
- Create: `test/presentation/screens/home_dashboard_test.dart`

**Interfaces:**
- Consumes: `medicationListProvider`, `treatmentListProvider` (`lib/presentation/providers/treatment_providers.dart:9`), `todaysDoseLogsProvider` (`lib/presentation/providers/dose_providers.dart:211`), `lowStockProvider`, `activeTreatmentsProvider`; `seedPrescription(Database)`, `seedDoseLog(Database, String, DateTime, {String status})`, `recentToday(DateTime, {int minutes})` (`test/helpers/seed.dart:18,74,100`); `MedicationListNotifier` (subclassed in the test to fail once).
- Produces:
```dart
// home_screen.dart — RefreshIndicator.onRefresh now re-reads the sources,
// not just the derived lists, and only stops the spinner once they land.
Future<void> onRefresh();
```

- [ ] **Step 1: Write the failing tests**

Create `test/presentation/screens/home_dashboard_test.dart`:

```dart
/// Dashboard states other than the Now card: the Low Stock and Active
/// Treatments cards, the progress bar, the silent three-item truncation,
/// the error/retry path and pull-to-refresh.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/core/platform_capabilities.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/domain/entities/medication.dart';
import 'package:medora/presentation/providers/medication_providers.dart';
import 'package:medora/presentation/providers/now_provider.dart';
import 'package:medora/presentation/providers/providers.dart';
import 'package:medora/presentation/providers/settings_providers.dart';
import 'package:medora/presentation/screens/home/home_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/fake_reminder_port.dart';
import '../../helpers/pump_app.dart';
import '../../helpers/seed.dart';
import '../../helpers/test_database.dart';

/// How many times the overridden cabinet has been built this test.
int _medBuilds = 0;

/// A cabinet that fails its first read and serves one low-stock medication
/// afterwards — the shape of a transient database error behind Retry.
class _FailsOnceMedications extends MedicationListNotifier {
  @override
  Future<List<Medication>> build() async {
    _medBuilds++;
    if (_medBuilds == 1) throw Exception('db down');
    return const [Medication(id: 'a', name: 'Alpha', quantity: 0)];
  }
}

void main() {
  final now = DateTime(2026, 3, 4, 15);

  setUp(() async {
    _medBuilds = 0;
    await setUpTestDatabase();
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(tearDownTestDatabase);

  Future<List<Override>> overrides() async => [
    sharedPreferencesProvider.overrideWithValue(
      await SharedPreferences.getInstance(),
    ),
    syncStartupDelayProvider.overrideWithValue(Duration.zero),
    reminderPortProvider.overrideWithValue(FakePort()),
    platformCapabilitiesProvider.overrideWithValue(
      PlatformCapabilities.desktop,
    ),
    nowProvider.overrideWithValue(() => now),
  ];

  void useTallPhone(WidgetTester tester) {
    tester.view.physicalSize = const Size(412, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  testWidgets('the Low Stock card lists its rows and the tile counts them', (
    tester,
  ) async {
    useTallPhone(tester);
    final db = await AppDatabase.instance.database;
    await db.insert('medications', {
      'id': 'a',
      'name': 'Alpha',
      'quantity': 0,
      'minimum_stock_level': 0,
    });
    await db.insert('medications', {
      'id': 'b',
      'name': 'Beta',
      'quantity': 2,
      'minimum_stock_level': 5,
    });
    await db.insert('medications', {
      'id': 'c',
      'name': 'Gamma',
      'quantity': 9,
      'minimum_stock_level': 1,
    });

    await pumpMedoraApp(
      tester,
      const HomeScreen(),
      overrides: await overrides(),
    );
    await tester.pumpAndSettle();

    expect(find.text('Alpha'), findsOneWidget);
    expect(find.text('Beta'), findsOneWidget);
    expect(find.text('Gamma'), findsNothing);
    expect(find.text('All medications are well stocked'), findsNothing);

    final tile = find
        .ancestor(of: find.text('Low stock'), matching: find.byType(InkWell))
        .first;
    expect(find.descendant(of: tile, matching: find.text('2')), findsOneWidget);
  });

  testWidgets('an empty cabinet says both cards are fine', (tester) async {
    useTallPhone(tester);
    await pumpMedoraApp(
      tester,
      const HomeScreen(),
      overrides: await overrides(),
    );
    await tester.pumpAndSettle();

    expect(find.text('All medications are well stocked'), findsOneWidget);
    expect(find.text('All medications are within date'), findsOneWidget);
    expect(find.text('No active treatments'), findsOneWidget);
    expect(find.text('No doses scheduled for today'), findsOneWidget);
  });

  testWidgets('the Active Treatments card lists the active treatment', (
    tester,
  ) async {
    useTallPhone(tester);
    final db = await AppDatabase.instance.database;
    await seedPrescription(db);

    await pumpMedoraApp(
      tester,
      const HomeScreen(),
      overrides: await overrides(),
    );
    await tester.pumpAndSettle();

    // seedPrescription inserts an active treatment named 'Flu'.
    expect(find.text('Flu'), findsOneWidget);
    expect(find.text('No active treatments'), findsNothing);
    final tile = find
        .ancestor(of: find.text('Treatments'), matching: find.byType(InkWell))
        .first;
    expect(find.descendant(of: tile, matching: find.text('1')), findsOneWidget);
  });

  testWidgets('the progress bar counts today\'s doses', (tester) async {
    useTallPhone(tester);
    // getTodaysDoseLogs keys off the real wall clock by design, not
    // nowProvider, so these seeds are placed relative to the real now.
    final real = DateTime.now();
    final db = await AppDatabase.instance.database;
    final s = await seedPrescription(db);
    await seedDoseLog(
      db,
      s.prescriptionId,
      recentToday(real, minutes: 30),
      status: 'taken',
    );
    await seedDoseLog(db, s.prescriptionId, laterToday(real, minutes: 60));
    await seedDoseLog(db, s.prescriptionId, laterToday(real, minutes: 120));

    await pumpMedoraApp(
      tester,
      const HomeScreen(),
      overrides: await overrides(),
    );
    await tester.pumpAndSettle();

    expect(find.text('1 of 3 taken · 2 pending'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
  });

  testWidgets('a fourth low-stock medication is silently dropped', (
    tester,
  ) async {
    useTallPhone(tester);
    final db = await AppDatabase.instance.database;
    for (var i = 1; i <= 5; i++) {
      await db.insert('medications', {
        'id': 'ls$i',
        'name': 'LS$i',
        'quantity': 0,
        'minimum_stock_level': 0,
      });
    }

    await pumpMedoraApp(
      tester,
      const HomeScreen(),
      overrides: await overrides(),
    );
    await tester.pumpAndSettle();

    // The card takes three and offers no "+N more" affordance; the tile is
    // the only place the other two are represented at all.
    final shown = ['LS1', 'LS2', 'LS3', 'LS4', 'LS5']
        .where((n) => find.text(n).evaluate().isNotEmpty)
        .length;
    expect(shown, 3, reason: 'the card shows exactly three of the five');

    final tile = find
        .ancestor(of: find.text('Low stock'), matching: find.byType(InkWell))
        .first;
    expect(find.descendant(of: tile, matching: find.text('5')), findsOneWidget);
  });

  testWidgets('a failed cabinet read offers a Retry that actually recovers', (
    tester,
  ) async {
    useTallPhone(tester);
    await pumpMedoraApp(
      tester,
      const HomeScreen(),
      overrides: [
        ...await overrides(),
        medicationListProvider.overrideWith(_FailsOnceMedications.new),
      ],
    );
    await tester.pumpAndSettle();

    // Both medication cards render the error shell.
    expect(find.text('Something went wrong'), findsNWidgets(2));
    expect(find.widgetWithText(FilledButton, 'Retry'), findsNWidgets(2));

    await tester.tap(find.widgetWithText(FilledButton, 'Retry').first);
    await tester.pumpAndSettle();

    // Retry must re-read the cabinet, not just the derived list: otherwise
    // it re-awaits the same failure and nothing ever recovers.
    expect(find.text('Something went wrong'), findsNothing);
    expect(find.text('Alpha'), findsOneWidget);
  });

  testWidgets('pull to refresh re-reads the cabinet', (tester) async {
    useTallPhone(tester);
    final db = await AppDatabase.instance.database;
    await db.insert('medications', {
      'id': 'a',
      'name': 'Alpha',
      'quantity': 0,
      'minimum_stock_level': 0,
    });

    await pumpMedoraApp(
      tester,
      const HomeScreen(),
      overrides: await overrides(),
    );
    await tester.pumpAndSettle();
    expect(find.text('Alpha'), findsOneWidget);
    expect(find.text('Beta'), findsNothing);

    // Written underneath the notifier, the way a sync pull writes a row.
    await db.insert('medications', {
      'id': 'b',
      'name': 'Beta',
      'quantity': 0,
      'minimum_stock_level': 0,
    });

    await tester.fling(find.byType(ListView), const Offset(0, 400), 1000);
    await tester.pumpAndSettle();

    expect(find.text('Beta'), findsOneWidget);
    final tile = find
        .ancestor(of: find.text('Low stock'), matching: find.byType(InkWell))
        .first;
    expect(find.descendant(of: tile, matching: find.text('2')), findsOneWidget);
  });
}
```

Add `laterToday` to the `seed.dart` import usage — it already exists (`test/helpers/seed.dart:110`) and comes in with the same import.

Then append to `test/presentation/providers/medication_providers_test.dart`:

```dart
  test('lowStockProvider takes quantity at or below the minimum', () async {
    final c = await make();
    final notifier = c.read(medicationListProvider.notifier);
    await c.read(medicationListProvider.future);
    await notifier.addMedication(
      const Medication(id: 'at', name: 'At', quantity: 2, minimumStockLevel: 2),
    );
    await notifier.addMedication(
      const Medication(
        id: 'below',
        name: 'Below',
        quantity: 1,
        minimumStockLevel: 2,
      ),
    );
    await notifier.addMedication(
      const Medication(
        id: 'above',
        name: 'Above',
        quantity: 3,
        minimumStockLevel: 2,
      ),
    );
    await notifier.addMedication(
      const Medication(
        id: 'archived',
        name: 'Archived',
        quantity: 0,
        minimumStockLevel: 2,
        isArchived: true,
      ),
    );

    final low = await c.read(lowStockProvider.future);
    expect(low.map((m) => m.name).toSet(), {'At', 'Below'});
  });
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `fvm flutter test test/presentation/screens/home_dashboard_test.dart test/presentation/providers/medication_providers_test.dart`
Expected: the `lowStockProvider` test and the first five widget tests PASS (they describe behaviour that already works and was simply untested). Two FAIL:
- `'a failed cabinet read offers a Retry that actually recovers'` — after the tap, `Something went wrong` is still on screen, because `onRetry` invalidates only the derived provider.
- `'pull to refresh re-reads the cabinet'` — `find.text('Beta')` finds nothing, because `onRefresh` never invalidates `medicationListProvider`.

- [ ] **Step 3: Write the implementation**

In `lib/presentation/screens/home/home_screen.dart`, replace the `RefreshIndicator`'s `onRefresh` (lines 57-62) with:

```dart
        onRefresh: () async {
          // The derived lists only re-filter what the source providers
          // already hold, so invalidating them alone never re-read the
          // database: a row written by a sync pull stayed invisible until
          // the next cold start. Invalidate the sources; the derived lists
          // follow.
          ref.invalidate(medicationListProvider);
          ref.invalidate(treatmentListProvider);
          ref.invalidate(todaysDoseLogsProvider);
          try {
            await Future.wait<Object>([
              ref.read(medicationListProvider.future),
              ref.read(treatmentListProvider.future),
              ref.read(todaysDoseLogsProvider.future),
            ]);
          } catch (_) {
            // The cards render the failure themselves; here it only has to
            // stop the spinner instead of escaping as an unhandled error.
          }
        },
```

Replace the three `onRetry` callbacks the same way — each has to re-read the source it actually derives from:

`_ExpiringSoonCard` (line 527):
```dart
      onRetry: () async {
        ref.invalidate(medicationListProvider);
        ref.invalidate(expiringSoonProvider);
      },
```

`_LowStockCard` (line 610):
```dart
      onRetry: () async {
        ref.invalidate(medicationListProvider);
        ref.invalidate(lowStockProvider);
      },
```

`_ActiveTreatmentsCard` (line 692):
```dart
      onRetry: () async {
        ref.invalidate(treatmentListProvider);
        ref.invalidate(activeTreatmentsProvider);
      },
```

`treatmentListProvider` and `todaysDoseLogsProvider` are already imported (`home_screen.dart:19,16`); `medicationListProvider` at `:17`. No import changes.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `fvm flutter test test/presentation/screens/home_dashboard_test.dart test/presentation/providers/medication_providers_test.dart`
Expected: PASS, 7 widget tests + 6 provider tests.

- [ ] **Step 5: Run the full suite and the gates**

Run: `fvm flutter test`
Expected: all green, goldens included — none of these changes alter a painted pixel on the golden fixture, which renders no error state and is never pulled. If a golden fails, stop and report: something in Step 3 changed layout that should not have.
Run: `fvm dart format --set-exit-if-changed .` and `fvm flutter analyze --fatal-infos`
Expected: both clean.

- [ ] **Step 6: Commit**

```bash
git add lib/presentation/screens/home/home_screen.dart test/presentation/screens/home_dashboard_test.dart test/presentation/providers/medication_providers_test.dart
git commit -m "$(cat <<'EOF'
test(dashboard): cover the cards, and make retry and refresh work

Covers the Low Stock and Active Treatments cards, their empty states, the
progress bar, the silent three-item truncation, the error path and pull to
refresh. Writing the last two honestly showed both were broken: Retry and
onRefresh invalidated only the derived providers, which re-filter a cached
list, so Retry re-awaited the same failure and a pull never re-read the
database. Both now invalidate the source lists, and the refresh waits for
them before the spinner retracts.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01BAjdzp9JhksW2XbhM6CPBS
EOF
)"
```

---

### Task 5: the dashboard in de, it, dark, narrow and large

Every Home test in the suite is `Locale('en')` at a comfortable width, and dark mode is covered only by a golden PNG. This renders the whole populated dashboard in the two other locales at 360 dp, at a large text scale, and in dark, and asserts what those configurations are actually for: the translated strings appear, nothing overflows, and the dark palette keeps the expired badge legible.

**Files:**
- Create: `test/presentation/screens/home_locale_test.dart`

**Interfaces:**
- Consumes: `pumpMedoraApp(..., {Brightness brightness, Locale locale})`; `contrastRatio(Color, Color)` (`test/helpers/contrast.dart:4`); `MedoraColors` (`lib/core/theme_extensions.dart:8`) reached through `Theme.of(context).extension<MedoraColors>()!`; `loadAppFonts()`.
- Produces: nothing. Pure coverage. Must not duplicate Task 3's stat-tile width assertions — this task asserts the cards and the overall layout.

- [ ] **Step 1: Write the test**

Create `test/presentation/screens/home_locale_test.dart`:

```dart
/// The dashboard outside its comfortable case: German and Italian, a 360 dp
/// phone, a large text scale, and dark. Every other Home test is English at
/// a wide viewport in light.
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/core/platform_capabilities.dart';
import 'package:medora/core/theme_extensions.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/presentation/providers/now_provider.dart';
import 'package:medora/presentation/providers/providers.dart';
import 'package:medora/presentation/providers/settings_providers.dart';
import 'package:medora/presentation/screens/home/home_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/contrast.dart';
import '../../helpers/fake_reminder_port.dart';
import '../../helpers/fonts.dart';
import '../../helpers/pump_app.dart';
import '../../helpers/seed.dart';
import '../../helpers/test_database.dart';

void main() {
  final now = DateTime(2026, 3, 4, 15);

  setUpAll(loadAppFonts);

  setUp(() async {
    await setUpTestDatabase();
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(tearDownTestDatabase);

  Future<List<Override>> overrides() async => [
    sharedPreferencesProvider.overrideWithValue(
      await SharedPreferences.getInstance(),
    ),
    syncStartupDelayProvider.overrideWithValue(Duration.zero),
    reminderPortProvider.overrideWithValue(FakePort()),
    platformCapabilitiesProvider.overrideWithValue(
      PlatformCapabilities.desktop,
    ),
    nowProvider.overrideWithValue(() => now),
  ];

  /// One expired medication, one low-stock medication and one active
  /// treatment: every card populated.
  Future<void> seedFullDashboard() async {
    final db = await AppDatabase.instance.database;
    await seedPrescription(db);
    await db.insert('medications', {
      'id': 'exp',
      'name': 'Bentelan',
      'quantity': 8,
      'expiry_date': '2025-12-01',
    });
    await db.insert('medications', {
      'id': 'low',
      'name': 'Moment 200',
      'quantity': 0,
      'minimum_stock_level': 0,
      'expiry_date': '2026-03-20',
    });
  }

  void useNarrowPhone(WidgetTester tester) {
    tester.view.physicalSize = const Size(360, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  const expiredLabel = {'de': 'Abgelaufen', 'it': 'Scaduto'};
  const wellStocked = {
    'de': 'Alle Medikamente sind vorrätig',
    'it': 'Tutti i farmaci sono ben forniti',
  };

  for (final lang in const ['de', 'it']) {
    testWidgets('the full dashboard lays out at 360 dp in $lang', (
      tester,
    ) async {
      useNarrowPhone(tester);
      await seedFullDashboard();

      await pumpMedoraApp(
        tester,
        const HomeScreen(),
        overrides: await overrides(),
        locale: Locale(lang),
      );
      await tester.pumpAndSettle();

      // The translated expiry badge is on screen, so the expired row
      // survives the narrow layout in this locale too.
      expect(find.text(expiredLabel[lang]!), findsOneWidget);
      expect(find.text(wellStocked[lang]!), findsNothing);
      expect(find.text('Bentelan'), findsOneWidget);
      expect(find.text('Moment 200'), findsWidgets);

      // No RenderFlex overflow anywhere on the page.
      expect(tester.takeException(), isNull);

      // And nothing paints outside the 360 dp viewport.
      for (final title in ['Bentelan', 'Flu']) {
        final rect = tester.getRect(find.text(title).first);
        expect(rect.left, greaterThanOrEqualTo(0));
        expect(rect.right, lessThanOrEqualTo(360));
      }
    });
  }

  testWidgets('the dashboard survives a 1.6x text scale at 360 dp', (
    tester,
  ) async {
    useNarrowPhone(tester);
    await seedFullDashboard();

    await pumpMedoraApp(
      tester,
      const MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(1.6)),
        child: HomeScreen(),
      ),
      overrides: await overrides(),
      locale: const Locale('de'),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Abgelaufen'), findsOneWidget);

    // Every card title still lays out inside the viewport rather than
    // running off the right edge.
    final rect = tester.getRect(find.text('Bentelan').first);
    expect(rect.right, lessThanOrEqualTo(360));
  });

  testWidgets('dark mode renders the same dashboard, legibly', (tester) async {
    useNarrowPhone(tester);
    await seedFullDashboard();

    await pumpMedoraApp(
      tester,
      const HomeScreen(),
      overrides: await overrides(),
      brightness: Brightness.dark,
    );
    await tester.pumpAndSettle();

    expect(find.text('Expired'), findsOneWidget);
    expect(find.text('Bentelan'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // The expired badge has to stay readable in the dark palette, not just
    // exist: WCAG AA for small text is 4.5:1.
    final medora = Theme.of(
      tester.element(find.text('Expired')),
    ).extension<MedoraColors>()!;
    expect(
      contrastRatio(medora.onDangerContainer, medora.dangerContainer),
      greaterThanOrEqualTo(4.5),
    );
  });
}
```

- [ ] **Step 2: Run the tests**

Run: `fvm flutter test test/presentation/screens/home_locale_test.dart`
Expected: PASS, 4 tests — this task adds coverage of behaviour Tasks 1-3 already made correct, so unlike the earlier tasks there is no red phase to see. **If any test fails, that is a real finding, not a test to relax.** The likely candidate is a `RenderFlex overflowed` in the de/it 360 dp cases, from the `ExpiryBadge` in the `ListTile` trailing slot; the fix is the one named in Task 2 Step 4 (`overflow: TextOverflow.ellipsis` on the card's `title`). Apply it there, re-run Task 2's tests too, and report the deviation.

- [ ] **Step 3: Run the full suite and the gates**

Run: `fvm flutter test`
Expected: all green.
Run: `fvm dart format --set-exit-if-changed .` and `fvm flutter analyze --fatal-infos`
Expected: both clean.

- [ ] **Step 4: Commit**

```bash
git add test/presentation/screens/home_locale_test.dart
git commit -m "$(cat <<'EOF'
test(dashboard): cover de, it, 360 dp, a large text scale and dark

Every other Home test was English at a wide viewport in light, and dark mode
was covered only by a golden PNG. Renders the fully populated dashboard in
both other locales on a 360 dp phone, at a 1.6x text scale, and in dark,
asserting the translated expiry badge, that nothing paints outside the
viewport, and that the dark expired badge clears WCAG AA.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01BAjdzp9JhksW2XbhM6CPBS
EOF
)"
```

---

### Task 6: end-to-end smoke tests through the main flows

A thin layer that would catch a screen broken badly enough that the app is unusable. These pump the **real router** (`appRouterProvider`), which nothing outside `test/presentation/router/app_router_widget_test.dart` currently does, so they also cover the route wiring itself — including `AppRoutes.scannerReturnOnly`, whose `returnOnly` query parameter is parsed at `lib/presentation/router/app_router.dart:160` and is today only ever exercised by a hand-rolled `GoRouter` inside tests.

Deliberately *not* duplicated here: the deep scanner behaviour (`test/presentation/screens/barcode_scanner_screen_test.dart`), the scan → Add Medication hand-off (`add_medication_scan_test.dart`), and the Undo-survives-a-tab-switch regression (`undo_after_tab_switch_test.dart`). Smoke tests assert the flow reaches the next screen; those files assert what the screen then does.

**Files:**
- Create: `test/presentation/screens/app_smoke_test.dart`

**Interfaces:**
- Consumes: `appRouterProvider` (`lib/presentation/router/app_router.dart`); `AppRoutes.scannerReturnOnly` (`:45`); `scannerOverrides({TextRecognitionPort? text, BarcodeScanPort? barcodes, CameraPort? camera, GalleryPort? gallery})` (`test/helpers/fake_scanner_ports.dart:163`); `seedPrescription`, `seedDoseLog`, `recentToday`; `BarcodeScannerScreen({Key? key, bool returnBarcodeOnly})` (`lib/presentation/screens/scanner/barcode_scanner_screen.dart:57`); `SettingsScreen`; `MedicationListScreen`.
- Produces: nothing.

- [ ] **Step 1: Write the tests**

Create `test/presentation/screens/app_smoke_test.dart`:

```dart
/// End-to-end smoke tests through the real router: enough of each main flow
/// to notice a screen that no longer works at all. The depth lives in the
/// per-screen tests; these only prove the flows connect.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/core/platform_capabilities.dart';
import 'package:medora/core/supabase_config.dart';
import 'package:medora/core/theme.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/presentation/providers/now_provider.dart';
import 'package:medora/presentation/providers/providers.dart';
import 'package:medora/presentation/providers/settings_providers.dart';
import 'package:medora/presentation/router/app_router.dart';
import 'package:medora/presentation/screens/medication/medication_list_screen.dart';
import 'package:medora/presentation/screens/scanner/barcode_scanner_screen.dart';
import 'package:medora/presentation/screens/settings/settings_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/fake_reminder_port.dart';
import '../../helpers/fake_scanner_ports.dart';
import '../../helpers/seed.dart';
import '../../helpers/test_database.dart';

void main() {
  final now = DateTime(2026, 3, 4, 15);

  setUp(() async {
    SupabaseConfig.resetForTest();
    await setUpTestDatabase();
  });
  tearDown(tearDownTestDatabase);

  /// Pumps the real app: the real router, a real database, fake ports.
  ///
  /// [caps] decides whether the scanner exists at all — the scanner route
  /// and Home's scanner button are both gated on `hasCamera`.
  Future<ProviderContainer> pumpApp(
    WidgetTester tester, {
    PlatformCapabilities caps = PlatformCapabilities.desktop,
    List<Override> extra = const [],
  }) async {
    tester.view.physicalSize = const Size(412, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    // 'onboarding_seen' keeps the first-run sheet out of these flows, and
    // 'biometrics_enabled' keeps the BiometricGate wrapping every shell
    // route (app_router.dart, ShellRoute) from locking the app: the gate
    // keys off this pref, not off PlatformCapabilities.hasBiometrics.
    SharedPreferences.setMockInitialValues({
      'app_mode': 'localOnly',
      'onboarding_seen': true,
      'biometrics_enabled': false,
    });
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        syncStartupDelayProvider.overrideWithValue(Duration.zero),
        reminderPortProvider.overrideWithValue(FakePort()),
        platformCapabilitiesProvider.overrideWithValue(caps),
        nowProvider.overrideWithValue(() => now),
        ...extra,
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: Consumer(
          builder: (context, ref, _) => MaterialApp.router(
            theme: AppTheme.lightThemeFrom(const Color(0xFF2E7D6F)),
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            routerConfig: ref.watch(appRouterProvider),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  testWidgets('add a medication and see it in the list and on the dashboard', (
    tester,
  ) async {
    await pumpApp(tester);

    // Medications tab → add.
    await tester.tap(find.byIcon(Icons.medication_outlined));
    await tester.pumpAndSettle();
    expect(find.byType(MedicationListScreen), findsOneWidget);

    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(TextFormField, 'Medication Name *').first,
      'Moment 200',
    );
    // Quantity defaults to 1; zero makes it low stock, which is what puts
    // it on the dashboard without a date picker.
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Quantity *').first,
      '0',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Add Medication'));
    await tester.pumpAndSettle();

    // The Add screen pops itself, so this is the list again.
    expect(find.byType(MedicationListScreen), findsOneWidget);
    expect(find.text('Moment 200'), findsWidgets);

    // And Home shows it under Low Stock.
    await tester.tap(find.byIcon(Icons.home_outlined));
    await tester.pumpAndSettle();
    expect(find.text('Moment 200'), findsOneWidget);
    final tile = find
        .ancestor(of: find.text('Low stock'), matching: find.byType(InkWell))
        .first;
    expect(find.descendant(of: tile, matching: find.text('1')), findsOneWidget);
  });

  testWidgets('mark a dose taken from Home and undo it', (tester) async {
    // getTodaysDoseLogs and DoseMaintenanceService key off the real wall
    // clock by design, so this seed is placed relative to the real now.
    final real = DateTime.now();
    final db = await AppDatabase.instance.database;
    final s = await seedPrescription(db);
    final doseId = await seedDoseLog(
      db,
      s.prescriptionId,
      recentToday(real, minutes: 10),
    );

    await pumpApp(tester);
    expect(find.text('Tachipirina'), findsOneWidget);
    // Seeded ten minutes ago, so the Now card is in its overdue state.
    expect(find.text('Overdue'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Take'));
    await tester.pumpAndSettle();
    expect(find.text('All doses done for today'), findsOneWidget);
    expect(
      (await db.query('dose_logs', where: 'id = ?', whereArgs: [doseId]))
          .single['status'],
      'taken',
    );

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(find.text('Next dose'), findsOneWidget);
    expect(
      (await db.query('dose_logs', where: 'id = ?', whereArgs: [doseId]))
          .single['status'],
      'pending',
    );
  });

  testWidgets('the settings button opens Settings', (tester) async {
    await pumpApp(tester);

    await tester.tap(find.byIcon(Icons.settings));
    await tester.pumpAndSettle();

    expect(find.byType(SettingsScreen), findsOneWidget);
    expect(find.text('Settings'), findsWidgets);
  });

  testWidgets('the return-only scanner route builds a return-only scanner', (
    tester,
  ) async {
    final container = await pumpApp(
      tester,
      caps: PlatformCapabilities.mobile,
      extra: scannerOverrides(camera: FakeCamera(opens: false)),
    );

    // The route AddMedicationScreen pushes for a code it will keep. Nothing
    // outside a hand-rolled test router has ever parsed this query string.
    container.read(appRouterProvider).push(AppRoutes.scannerReturnOnly);
    await tester.pumpAndSettle();

    final screen = tester.widget<BarcodeScannerScreen>(
      find.byType(BarcodeScannerScreen),
    );
    expect(screen.returnBarcodeOnly, isTrue);

    // And the plain scanner route is not return-only.
    container.read(appRouterProvider).pop();
    await tester.pumpAndSettle();
    container.read(appRouterProvider).push(AppRoutes.scanner);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<BarcodeScannerScreen>(find.byType(BarcodeScannerScreen))
          .returnBarcodeOnly,
      isFalse,
    );
  });
}
```

`FakeCamera(opens: false)` is deliberate: the scanner screen must build and report its no-camera state without any real plugin. If the screen throws instead of rendering, that is a genuine bug — report it rather than deleting the test.

- [ ] **Step 2: Run the tests**

Run: `fvm flutter test test/presentation/screens/app_smoke_test.dart`
Expected: PASS, 4 tests. Two known fragilities, both of which are findings rather than reasons to weaken an assertion:
- If the Add Medication screen does not return to the list after saving, check `_popIfPossible()` (`lib/presentation/screens/medication/add_medication_screen.dart:815`) — it calls `Navigator.of(context).maybePop()` — and report what it actually does.
- If `find.byIcon(Icons.settings)` matches more than one widget, scope it to the `AppBar` with `find.descendant(of: find.byType(AppBar), matching: find.byIcon(Icons.settings))`.

- [ ] **Step 3: Run the full suite and the gates**

Run: `fvm flutter test`
Expected: all green.
Run: `fvm dart format --set-exit-if-changed .` and `fvm flutter analyze --fatal-infos`
Expected: both clean.

- [ ] **Step 4: Verify the l10n gate explicitly**

No task in this plan adds or changes an ARB key, so this must be a no-op — run it to prove it.

Run: `fvm flutter gen-l10n && git diff --exit-code -- lib/l10n/generated && cat untranslated.txt`
Expected: no diff, and `untranslated.txt` contains `{}`.

- [ ] **Step 5: Commit**

```bash
git add test/presentation/screens/app_smoke_test.dart
git commit -m "$(cat <<'EOF'
test: smoke-test the main flows through the real router

Add a medication and find it in the list and on the dashboard, take a dose
and undo it, open Settings, and resolve the scanner's return-only route.
These pump the real appRouterProvider, so they also cover the returnOnly
query parameter the router parses — until now only hand-rolled test routers
ever exercised it.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01BAjdzp9JhksW2XbhM6CPBS
EOF
)"
```

---

## Done when

- An expired medication appears on Home, above the merely expiring ones, with the red "Expired" badge, counted by the "Expiring" stat tile, and the "All medications are within date" empty state appears only when nothing is expired or expiring.
- No stat tile label clips in en, de or it at 360 dp, and each degrades to an ellipsis rather than a clip at larger text scales — proven by geometry assertions, not by `takeException`.
- `fvm flutter test` is green with the dashboard covered in every state listed above, plus four router-level smoke tests.
- `fvm dart format --set-exit-if-changed .`, `fvm flutter analyze --fatal-infos`, the three guard tests and the l10n gate are all clean, and the only golden PNGs that changed are `home_light.png` and `home_dark.png`, re-recorded in Tasks 2 and 3 for the reasons those tasks state.
