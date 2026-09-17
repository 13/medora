# Sync v2 and the settings gear — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

> **Validation (probe, before this plan was written).**
> - **Full suite green at each task's end state:**
>   - Task 1–2 state: 1366 tests;
>   - Task 3: 1395;
>   - Task 4: 1408;
>   - Task 5: 1435;
>   - Tasks 6 and 7: UTC and Europe/Rome;
>   - Task 8: UTC, Europe/Rome and `MEDORA_FAKE_TRANSPORT=http`.
> - **What ran after the last test additions:**
>   - The final rebuild pass re-ran Tasks 1–2, 3 and 4 in full.
>   - The files added last were each run on their own, on both transports: the migration-stop test and the `stock changes` group in `sync_service_test`, and the restore-count test in `backup_service_test`.
>   - The Task 8 state passed the full suite over HTTP (1408 passed, 2 skipped).
> - **Not re-run after those last edits:**
>   - Tasks 5–7, and Task 8 in UTC and Europe/Rome. The earlier full runs of those states passed.
>   - A UTC run of the Task 8 state overlapped a rebuild that was rewriting the same tree, and its six load failures are not a result. Run the gates yourself before each commit, as every task says.

**Goal:** Put one settings gear at the top right of the four main tabs, fix the four small defects users can see, and close every open sync item through one Supabase migration (`20260918000000_sync_v2.sql`) and one local migration (v16). The sync items are:

- shifted dose times;
- stock lost between two devices;
- edits lost to a lost answer;
- whole-row last-writer-wins (I-1);
- generated doses invisible to pulls;
- dropped doses left pending on the server;
- "missed" never reaching the server.

**Architecture:**

- **Server (the migration).** Each synced row gets four columns:
  - `sync_xid` (the writing transaction), which a pull reads below a horizon from `medora_sync_state()`;
  - `row_version`, so a push is conditional;
  - `write_id`, so a device recognises its own write after a lost answer;
  - `edited_at`, where 1970 marks the app's own changes.

  Stock changes go through an idempotent `apply_stock_change()` backed by a ledger.
- **Client, data layer.** It keeps a merge base per row and merges column groups three ways: `lib/data/sync/row_merge.dart`, `table_sync.dart`, `sync_meta.dart` and `stock_sync.dart`. It sends only the changed columns, and it queues stock changes in a local outbox.
- **Client, orchestration.** `SyncService` keeps its queueing, timers and families, and only orchestrates.
- **Settings gear.** A shared `SettingsAction` widget.

**Tech Stack:**

- Flutter 3.44.6 / Dart ^3.12 through `fvm` (never bare `dart` or `flutter`);
- flutter_riverpod 3.4, go_router 18, sqflite (plus `sqflite_common_ffi` in tests), supabase_flutter 2.9 (postgrest 2.9.1), uuid 4.5, http 1.3 (`MockClient` in tests; already a dependency);
- Supabase Postgres 15 migrations, checked in a throwaway `postgres:15-alpine` container;
- ARB localisation in en/de/it;
- golden tests under `test/goldens/`.

## Global Constraints

- Format clean with `fvm dart format --set-exit-if-changed .`
- `fvm flutter analyze --fatal-infos` clean
- `fvm flutter test` green, also under `TZ=Europe/Rome`
- `flutter gen-l10n` no diff and `untranslated.txt` = `{}` (run it as `fvm flutter gen-l10n`)
- Guard tests stay green: theme sweep, l10n sweep, clock sweep — no `DateTime.now()` in `lib/presentation` or `lib/domain`
- Golden PNGs change only in a task that explicitly re-records them and says why
- Local schema changes only via a new ordered migration
- Every user-visible string in en/de/it
- No new pub dependencies unless named and justified (this plan adds none)
- Every synced write goes through `requestSync`, never a direct push
- The data layer never imports `lib/services/`
- Never touch a real Supabase project
- Agents work in their own scratch subfolder, never mutate the live tree for mutation checks, and remove worktrees when done
- Commits end with the two lines `Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>` and `Claude-Session: https://claude.ai/code/session_01BAjdzp9JhksW2XbhM6CPBS`

---

## Read this before starting

**The design is `docs/superpowers/specs/2026-09-16-sync-v2-design.md`.** Read §4 to §9 before Tasks 3 to 8.

**This plan was built once, task by task, in a throwaway worktree, before it was written.** Every code block and patch below is the probe's code at the end of its task, and the assembled patches were checked to apply. The probe passed these checks:

| Check | Result |
|---|---|
| Migration SQL in `postgres:15-alpine` (docker, and the `USE_DOCKER=0` CI path) | all assertions pass; horizon race passes; applied twice; three deliberate mutations caught |
| The five migrations on a local `supabase start` (CLI 2.117.0, isolated project id) | applied; the 0.4.0 integration suite (4 tests, S1 and stock included) passes; **the unchanged v0.3.0 integration suite passes against the migrated schema** |
| Full suite at the end of every task (Tasks 1–2, 3, 4, 5, 6, 7, 8) | green, with format and `analyze --fatal-infos` clean; Tasks 6–8 also under `TZ=Europe/Rome`; Task 8 also with `--dart-define=MEDORA_FAKE_TRANSPORT=http` |
| New engine tests (`row_merge_test` 11, `table_sync_test` 12, `row_settle_test` 4 then 5, `stock_sync_test` 4) | pass |
| Two-device scenarios (`multi_device_merge_test` 6 × 2 transports, `mixed_fleet_sync_test` 4 × 2) | pass |
| Existing `multi_device_dose_sync_test` (16 with the new PR5 test) and `multi_device_schedule_sync_test` (16) after the listed edits | pass |
| Every mutation check listed in Tasks 3–8 | the named tests fail, as stated |
| Gear tests (`settings_action_test` 7, `settings_gear_test` 21) | pass; the double-tap mutation is caught |
| Goldens | only the four Doses PNGs change; Home and add-medication are byte-identical |

**Still verify before you edit.** Earlier plans quoted code that no longer matched. Open each file and confirm that the surrounding lines match what this plan quotes. If they do not, implement the intent against the real code and report the deviation in your summary. Line numbers drift, so anchor on content.

**Findings from the probe that shape the order of the tasks:**

1. **Every local write must stamp `edited_at` (Task 4) before the cycle pushes automatic changes (Task 6).**
   - Without it, a take made on a device keeps the 1970 edit time it copied from the pulled generated row.
   - The take then loses to the other device's automatic "missed".
   - The probe hit exactly this.
2. **The switch to the new cycle is one task (Task 6).** A cycle that pulls the v2 way but pushes the v1 way needs its own intermediate tests and gains nothing, so Task 5 builds the engine beside the old cycle (new files only, its own tests), and Task 6 switches over and ports the suites in one go.
3. **Pulling generated doses (Task 6) breaks the precondition of two schedule tests.** They assumed B cannot see A's doses. Both are rewritten in Task 6.
4. **In local-only mode:**
   - a dose dropped by regeneration must still be hard-deleted, because no server will ever take a guarded delete: the rule is "no `sync_version` and no `sync_write_id` → delete here";
   - the overdue sweep must include doses left `pending_update` by an undo. Otherwise, without sync, they stay pending for ever; this is an existing defect, fixed in Task 6.
5. **The strict 360 dp / 1.6× layout test of Task 1 found two existing overflows,** both on empty tabs:
   - the Treatments filter chips: 121 px in German, 211 px in Italian, 76 px in English;
   - the Doses empty state: 112 px in German, 16 px in Italian.

   Task 1 fixes both.
6. **`stock_changes` follows the medication policies.** Family members have no access to data rows today (sync follow-up review), and the ledger inherits that.
7. **A test that seeded a server row without `sync_xid` passed by accident** (the fake threw on the missing column). Over HTTP the row is simply filtered out, so Task 6 seeds it through the fake's own insert.

**Applying a patch block.** Several steps give a unified diff. Save the block to a file in your scratch folder and run `git apply --check <file>` then `git apply <file>` from the repository root. If it does not apply, the surrounding code has drifted: make the same change by hand and report it.

**Toolchain and workspace:**

- Always `fvm flutter …` / `fvm dart …`.
- Work in `/tmp/claude-1000/-home-ben-repo-medora/09c9cf28-1ce3-499b-8e8b-d49627f3479c/scratchpad/sync-v2-<task>/`.
- Run mutation checks in a git worktree there, never in the live tree. Remove the worktree and run `git worktree prune` when done.
- Never run `--update-goldens` except in the one Task 1 step that says so.
- `fvm flutter analyze` and `fvm flutter test` resolve packages first; do not commit a `pubspec.lock` change.
- The SQL check needs Docker (`docker info` works on this machine). If Docker is unavailable, say so in your report; CI runs the same script.

**Commit command shape** (stage by name, never `git add -A`):

```bash
git add <paths…>
git commit -F - <<'EOF'
<type>(<scope>): <subject>

<body>

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01BAjdzp9JhksW2XbhM6CPBS
EOF
```

**Gate commands**, referred to below as "the gates":

```bash
fvm dart format --set-exit-if-changed .
fvm flutter analyze --fatal-infos
fvm flutter gen-l10n && git diff --exit-code -- lib/l10n/generated && cat untranslated.txt   # prints {}
fvm flutter test
TZ=Europe/Rome fvm flutter test
grep -rn "DateTime.now()" lib/presentation lib/domain                                        # no output
```

---

## File map

| File | Task | Responsibility |
|---|---|---|
| `lib/presentation/widgets/settings_action.dart` | 1 | The shared gear: icon, tooltip/label, route, double-tap guard |
| `supabase/migrations/20260918000000_sync_v2.sql` | 3 | Columns, stamp trigger, `updated_at` rule, horizon function, stock ledger and function, RLS, grants |
| `tools/check_supabase_sql.sh`, `tools/sql/auth_shim.sql`, `tools/sql/sync_v2_checks.sql` | 3 | Apply every migration to a throwaway Postgres 15 and assert the rules |
| `lib/data/datasources/sync_page.dart` | 3 | `PullKey(xid, id)` and `pullPage`; Task 6 deletes the old `pull_page.dart` |
| `lib/data/datasources/sync_table.dart` | 3 | `RemoteMeta`, the `SyncTable` interface, `PostgrestSyncTable` |
| `lib/data/datasources/stock_remote.dart` | 3 | `StockRemote`, `PostgrestStockRemote`, `StockChangeResult` |
| `lib/data/datasources/sync_state_remote_datasource.dart` | 3 | `medora_sync_state()`, migration detection |
| `lib/data/datasources/stock_outbox_local_datasource.dart` | 3 (pure part), 4 (table) | `StockOp`, `applyStockOps`, `StockOutboxLocalDatasource` |
| `test/helpers/fake_server.dart` | 3, 8 (transport switch) | `FakeServerCore` (the migration's rules), `FakeSyncTable`, `FakeStockRemote`, `FakeTransaction` |
| `lib/data/local/migrations.dart` | 4 | Migration 16 |
| `lib/data/sync/row_merge.dart` | 5, 7 (`quantity` server-owned) | Merge policies and the three-way merge (pure) |
| `lib/data/sync/sync_meta.dart` | 5 | Canonical wire copies, local row mapping, bookkeeping columns |
| `lib/data/sync/row_settle.dart` | 5, 7 (create delta) | Settle a written row against its server copy; replaces `push_settle.dart` (deleted in Task 6) |
| `lib/data/sync/table_sync.dart` | 5 | Per-row pull, merge, push, own-write recognition, guarded deletes |
| `lib/services/sync_service.dart` | 6, 7 | The cycle: migration check, push order, paged pull to the horizon, report |
| `lib/data/sync/stock_sync.dart` | 7 | Send one stock change and settle it |
| `test/helpers/fake_remotes.dart` | 3 (stubs), 6 (rewrite), 8 (transport) | The fake datasources as views of `FakeServerCore` |
| `test/helpers/fake_postgrest.dart` | 8 | `FakeServerCore` served over HTTP as PostgREST answers |
| `test/helpers/two_devices.dart` | 8 | Two devices, one fake server, Dart or HTTP transport |

---

## Task 1: The settings gear on the four main tabs

**Why first:** it is independent of every sync change and small.

**Files:**
- Create: `lib/presentation/widgets/settings_action.dart`
- Modify: `lib/presentation/screens/home/home_screen.dart` (the `AppBar.actions` of `_HomeScreenState.build`)
- Modify: `lib/presentation/screens/medication/medication_list_screen.dart` (the `AppBar.actions`)
- Modify: `lib/presentation/screens/treatment/treatment_list_screen.dart` (the `AppBar.actions`, and the filter-chip `Padding`)
- Modify: `lib/presentation/screens/dose/dose_schedule_screen.dart` (the `AppBar.actions`, and the empty state in `_buildDay`)
- Create: `test/presentation/widgets/settings_action_test.dart`
- Create: `test/presentation/screens/settings_gear_test.dart`
- Re-record: `test/goldens/doses_light.png`, `test/goldens/doses_dark.png`, `test/goldens/doses_take_all_light.png`, `test/goldens/doses_take_all_dark.png`

**Interfaces:**
- Consumes: `AppRoutes.settings` (`lib/presentation/router/app_router.dart`); `AppLocalizations.settings` (exists: "Settings" / "Einstellungen" / "Impostazioni").
- Produces:
  - `class SettingsAction extends StatefulWidget { const SettingsAction({super.key}); static const buttonKey = Key('settingsAction'); }`
  - It builds one `IconButton(icon: Icon(Icons.settings), tooltip: l10n.settings)` and pushes `AppRoutes.settings`, ignoring taps while its own push is open.

- [ ] **Step 1: Write the widget test**

Create `test/presentation/widgets/settings_action_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/presentation/router/app_router.dart';
import 'package:medora/presentation/widgets/settings_action.dart';

void main() {
  late int settingsBuilds;

  Future<void> pump(WidgetTester tester, {Locale locale = const Locale('en')}) {
    settingsBuilds = 0;
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => Scaffold(
            appBar: AppBar(
              title: const Text('Tab'),
              actions: const [SettingsAction()],
            ),
          ),
        ),
        GoRoute(
          path: AppRoutes.settings,
          builder: (_, _) {
            settingsBuilds++;
            return Scaffold(appBar: AppBar(title: const Text('settings page')));
          },
        ),
      ],
    );
    addTearDown(router.dispose);
    return tester.pumpWidget(
      MaterialApp.router(
        routerConfig: router,
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
      ),
    );
  }

  testWidgets('opens Settings', (tester) async {
    await pump(tester);
    await tester.tap(find.byKey(SettingsAction.buttonKey));
    await tester.pumpAndSettle();
    expect(find.text('settings page'), findsOneWidget);
  });

  testWidgets('a double tap opens Settings once', (tester) async {
    await pump(tester);
    await tester.tap(find.byKey(SettingsAction.buttonKey));
    await tester.tap(find.byKey(SettingsAction.buttonKey), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(find.text('settings page'), findsOneWidget);
    // Back lands on the tab, not on a second Settings.
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('settings page'), findsNothing);
    expect(find.text('Tab'), findsOneWidget);
  });

  testWidgets('can be used again after Settings was closed', (tester) async {
    await pump(tester);
    await tester.tap(find.byKey(SettingsAction.buttonKey));
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(SettingsAction.buttonKey));
    await tester.pumpAndSettle();
    expect(find.text('settings page'), findsOneWidget);
    expect(settingsBuilds, greaterThanOrEqualTo(2));
  });

  for (final (locale, label) in const [
    ('en', 'Settings'),
    ('de', 'Einstellungen'),
    ('it', 'Impostazioni'),
  ]) {
    testWidgets('is labelled "$label" for screen readers ($locale)', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      await pump(tester, locale: Locale(locale));
      expect(
        tester.getSemantics(find.byKey(SettingsAction.buttonKey)),
        isSemantics(tooltip: label, isButton: true, hasTapAction: true),
      );
      expect(find.byTooltip(label), findsOneWidget);
      semantics.dispose();
    });
  }

  testWidgets('keeps a 48 dp touch target and the settings icon', (
    tester,
  ) async {
    await pump(tester);
    final size = tester.getSize(find.byKey(SettingsAction.buttonKey));
    expect(size.width, greaterThanOrEqualTo(48));
    expect(size.height, greaterThanOrEqualTo(48));
    expect(
      find.descendant(
        of: find.byKey(SettingsAction.buttonKey),
        matching: find.byIcon(Icons.settings),
      ),
      findsOneWidget,
    );
  });
}
```

- [ ] **Step 2: Run it to see it fail**

Run: `fvm flutter test test/presentation/widgets/settings_action_test.dart`
Expected: FAIL to load, with `Error when reading 'lib/presentation/widgets/settings_action.dart'` / `Undefined name 'SettingsAction'`.

- [ ] **Step 3: Create the widget**

Create `lib/presentation/widgets/settings_action.dart`:

```dart
/// Medora - The settings gear of the four main tabs.
///
/// One widget so the four app bars cannot drift apart: same icon, same
/// tooltip (which is also the screen-reader label), same route. It belongs
/// at the end of `AppBar.actions` on Dashboard, Medications, Treatments and
/// Doses only. Forms, detail screens, sheets, dialogs and the scanner do not
/// get it: leaving a half-filled form for Settings would lose the input.
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/presentation/router/app_router.dart';

class SettingsAction extends StatefulWidget {
  const SettingsAction({super.key});

  /// The gear's own key, for tests.
  static const buttonKey = Key('settingsAction');

  @override
  State<SettingsAction> createState() => _SettingsActionState();
}

class _SettingsActionState extends State<SettingsAction> {
  /// True while the Settings route this gear pushed is open. A second tap
  /// in the same frame would otherwise stack a second Settings screen.
  bool _open = false;

  Future<void> _openSettings() async {
    if (_open) return;
    _open = true;
    try {
      await context.push<void>(AppRoutes.settings);
    } finally {
      _open = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return IconButton(
      key: SettingsAction.buttonKey,
      icon: const Icon(Icons.settings),
      tooltip: AppLocalizations.of(context).settings,
      onPressed: _openSettings,
    );
  }
}
```

- [ ] **Step 4: Run the widget test**

Run: `fvm flutter test test/presentation/widgets/settings_action_test.dart`
Expected: `+7: All tests passed!`

- [ ] **Step 5: Write the router-level test**

Create `test/presentation/screens/settings_gear_test.dart`:

```dart
/// The settings gear through the real router: on the four main tabs, last
/// in their app bar, and nowhere else.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:medora/core/platform_capabilities.dart';
import 'package:medora/core/provider_retry.dart';
import 'package:medora/core/supabase_config.dart';
import 'package:medora/core/theme.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/presentation/providers/providers.dart';
import 'package:medora/presentation/providers/settings_providers.dart';
import 'package:medora/presentation/router/app_router.dart';
import 'package:medora/presentation/screens/settings/settings_screen.dart';
import 'package:medora/presentation/widgets/settings_action.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/fake_reminder_port.dart';
import '../../helpers/fake_scanner_ports.dart';
import '../../helpers/seed.dart';
import '../../helpers/test_database.dart';

/// The four main tabs, in bottom-bar order.
const _tabs = ['Dashboard', 'Medications', 'Treatments', 'Doses'];

void main() {
  setUp(() async {
    SupabaseConfig.resetForTest();
    await setUpTestDatabase();
  });
  tearDown(tearDownTestDatabase);

  Future<ProviderContainer> pumpApp(
    WidgetTester tester, {
    Size size = const Size(412, 915),
    Locale locale = const Locale('en'),
    double textScale = 1.0,
    PlatformCapabilities caps = PlatformCapabilities.mobile,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final previousLocale = Intl.defaultLocale;
    Intl.defaultLocale = locale.languageCode;
    addTearDown(() => Intl.defaultLocale = previousLocale);
    SharedPreferences.setMockInitialValues({
      'app_mode': 'localOnly',
      'onboarding_seen': true,
      'biometrics_enabled': false,
    });
    final container = ProviderContainer(
      retry: medoraRetry,
      overrides: [
        sharedPreferencesProvider.overrideWithValue(
          await SharedPreferences.getInstance(),
        ),
        syncStartupDelayProvider.overrideWithValue(Duration.zero),
        reminderPortProvider.overrideWithValue(FakePort()),
        platformCapabilitiesProvider.overrideWithValue(caps),
        ...scannerOverrides(camera: FakeCamera(opens: false)),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: Consumer(
          builder: (context, ref, _) => MaterialApp.router(
            theme: AppTheme.lightThemeFrom(const Color(0xFF2E7D6F)),
            locale: locale,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(textScale)),
              child: child!,
            ),
            routerConfig: ref.watch(appRouterProvider),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  Future<void> openTab(WidgetTester tester, int index) async {
    await tester.tap(find.byType(NavigationDestination).at(index));
    await tester.pumpAndSettle();
  }

  /// Every tappable button in the visible app bar.
  List<Rect> actionRects(WidgetTester tester) {
    final bar = find.byType(AppBar).last;
    return [
      for (final type in [IconButton, ActionChip])
        for (final e
            in find.descendant(of: bar, matching: find.byType(type)).evaluate())
          tester.getRect(find.byElementPredicate((x) => x == e)),
    ];
  }

  for (final (index, tab) in _tabs.indexed) {
    testWidgets('$tab: the gear is last and opens Settings; back returns to '
        '$tab', (tester) async {
      await pumpApp(tester);
      await openTab(tester, index);

      final gear = find.byKey(SettingsAction.buttonKey);
      expect(gear, findsOneWidget);
      final gearRect = tester.getRect(gear);
      for (final other in actionRects(tester)) {
        if (other == gearRect) continue;
        expect(
          other.right,
          lessThanOrEqualTo(gearRect.left + 0.5),
          reason: 'an action sits right of the gear on $tab',
        );
      }

      await tester.tap(gear);
      await tester.pumpAndSettle();
      expect(find.byType(SettingsScreen), findsOneWidget);
      expect(find.byKey(SettingsAction.buttonKey), findsNothing);

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(SettingsScreen), findsNothing);
      final bar = tester.widget<NavigationBar>(find.byType(NavigationBar));
      expect(bar.selectedIndex, index);
    });
  }

  testWidgets('no gear on forms, detail screens and the scanner', (
    tester,
  ) async {
    final container = await pumpApp(tester);
    final db = await AppDatabase.instance.database;
    final seeded = await seedPrescription(db);
    final router = container.read(appRouterProvider);
    for (final route in [
      AppRoutes.addMedication,
      '/medications/${seeded.medicationId}',
      '/medications/${seeded.medicationId}/edit',
      AppRoutes.expiringMedications,
      AppRoutes.addTreatment,
      '/treatments/${seeded.treatmentId}',
      '/treatments/${seeded.treatmentId}/edit',
      AppRoutes.doseHistory,
      AppRoutes.scanner,
      AppRoutes.settings,
      AppRoutes.family,
    ]) {
      unawaited(router.push(route));
      await tester.pumpAndSettle();
      expect(
        find.byKey(SettingsAction.buttonKey),
        findsNothing,
        reason: 'a gear on $route',
      );
      router.pop();
      await tester.pumpAndSettle();
    }
  });

  for (final locale in const ['de', 'it', 'en']) {
    for (final (index, tab) in _tabs.indexed) {
      testWidgets('$tab at 360 dp, $locale, 1.6x text: nothing overflows and '
          'the gear is fully on screen', (tester) async {
        await pumpApp(
          tester,
          size: const Size(360, 800),
          locale: Locale(locale),
          textScale: 1.6,
        );
        await openTab(tester, index);
        expect(tester.takeException(), isNull);
        final gear = tester.getRect(find.byKey(SettingsAction.buttonKey));
        expect(gear.left, greaterThanOrEqualTo(0));
        expect(gear.right, lessThanOrEqualTo(360));
        expect(gear.width, greaterThanOrEqualTo(48));
        await tester.tap(find.byKey(SettingsAction.buttonKey));
        await tester.pumpAndSettle();
        expect(find.byType(SettingsScreen), findsOneWidget);
      });
    }
  }

  for (final (index, tab) in _tabs.indexed) {
    testWidgets('$tab at 360 dp, German, 2.0x text: the app bar keeps the '
        'gear on screen and tappable', (tester) async {
      // Some page bodies overflow at 2.0x already (outside this change, see
      // the design's deferred list); only the app bar is checked here.
      final errors = <String>[];
      final previous = FlutterError.onError;
      FlutterError.onError = (details) => errors.add(
        details.toStringShort() +
            (details.informationCollector?.call() ?? const [])
                .map((n) => n.toString())
                .join('\n'),
      );
      try {
        await pumpApp(
          tester,
          size: const Size(360, 800),
          locale: const Locale('de'),
          textScale: 2,
        );
        await openTab(tester, index);
        final gear = tester.getRect(find.byKey(SettingsAction.buttonKey));
        expect(gear.left, greaterThanOrEqualTo(0));
        expect(gear.right, lessThanOrEqualTo(360));
        await tester.tap(find.byKey(SettingsAction.buttonKey));
        await tester.pumpAndSettle();
        expect(find.byType(SettingsScreen), findsOneWidget);
      } finally {
        FlutterError.onError = previous;
      }
      expect(
        errors
            .map((e) => e.toString())
            .where(
              (text) =>
                  text.contains('AppBar') || text.contains('NavigationToolbar'),
            ),
        isEmpty,
      );
    });
  }
}
```

- [ ] **Step 6: Run it to see it fail**

Run: `fvm flutter test test/presentation/screens/settings_gear_test.dart`
Expected: FAIL:
- all four "gear is last" tests fail on `expect(gear, findsOneWidget)`: the Dashboard's old inline gear has the same icon but not the key;
- the 1.6× tests fail.

- [ ] **Step 7: Put the gear on the four tabs**

In `home_screen.dart`, replace the inline gear:

```dart
          const SyncStatusChip(),
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () => context.push(AppRoutes.settings),
          ),
        ],
```

with

```dart
          const SyncStatusChip(),
          const SettingsAction(),
        ],
```

In `medication_list_screen.dart` and `treatment_list_screen.dart`, append the gear after the search/close button:

```dart
        actions: [
          IconButton(
            icon: Icon(_isSearching ? Icons.close : Icons.search),
            onPressed: () {
              setState(() {
                _isSearching = !_isSearching;
                if (!_isSearching) _searchController.clear();
              });
            },
          ),
          const SettingsAction(),
        ],
```

In `dose_schedule_screen.dart`, append it after the history button:

```dart
        actions: [
          IconButton(
            icon: const Icon(Icons.history),
            tooltip: l10n.doseHistory,
            onPressed: () => context.push(AppRoutes.doseHistory),
          ),
          const SettingsAction(),
        ],
```

Add `import 'package:medora/presentation/widgets/settings_action.dart';` to all four files, directly **before** the `shared_widgets.dart` import, so `directives_ordering` stays satisfied. `context.push` and `AppRoutes` stay imported in `home_screen.dart`, because other widgets there use them.

- [ ] **Step 8: Run the router test again**

Run: `fvm flutter test test/presentation/screens/settings_gear_test.dart`
Expected:
- the four "gear is last" tests, the "no gear on forms…" test and the four 2.0× tests pass;
- `Treatments at 360 dp, de/it/en, 1.6x` and `Doses at 360 dp, de/it, 1.6x` still fail with `A RenderFlex overflowed by 121/211/76 pixels on the right` (Treatments) and `112/16 pixels on the bottom` (Doses).

These overflows exist without the gear too (probe: same numbers with the gear removed).

- [ ] **Step 9: Fix the two empty-tab overflows**

In `treatment_list_screen.dart`, make the chip row scroll, as the medications tab already does. Replace

```dart
          // Filter chips
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Row(
```

with

```dart
          // Filter chips. Scrollable, as on the medications tab: at a 1.6x
          // text scale the three chips are wider than a 360 dp screen.
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Row(
```

In `dose_schedule_screen.dart` (`_buildDay`, empty branch), replace

```dart
            SizedBox(
              height: MediaQuery.sizeOf(context).height * 0.6,
              child: EmptyStateWidget(
```

with

```dart
            // At least 60 % of the screen, so the message sits in the middle,
            // but never less than it needs: at a large text scale a fixed
            // height cut it off at the bottom.
            ConstrainedBox(
              constraints: BoxConstraints(
                minHeight: MediaQuery.sizeOf(context).height * 0.6,
              ),
              child: EmptyStateWidget(
```

Run: `fvm flutter test test/presentation/screens/settings_gear_test.dart test/presentation/screens/treatment_list_screen_test.dart test/presentation/screens/dose_schedule_screen_test.dart test/presentation/screens/app_smoke_test.dart`
Expected: all pass (`settings_gear_test`: `+21`).

- [ ] **Step 10: Goldens — re-record the Doses PNGs only, and say why**

Run: `sha256sum test/goldens/home_light.png test/goldens/home_dark.png test/goldens/add_medication_*.png > <scratch>/golden-before.txt`

Run: `fvm flutter test test/goldens/`
Expected: 4 failures (`doses light`, `doses dark`, `doses take all due light`, `doses take all due dark`). The Doses app bar now has the gear. Home and add-medication pass: Home's gear keeps its icon, size and place, and the tooltip is not painted.

Run: `fvm flutter test --update-goldens test/goldens/doses_golden_test.dart test/goldens/doses_take_all_golden_test.dart`

Open the four PNGs with the Read tool. The only change is a gear to the right of the history icon. Then:

Run: `sha256sum -c <scratch>/golden-before.txt && fvm flutter test test/goldens/`
Expected: every checksum `OK`, and `All tests passed!`.

- [ ] **Step 11: Mutation checks (scratch worktree)**

In `git worktree add <scratch>/wt HEAD` with this task's changes applied, try each mutant and confirm the named test fails, then restore:

1. Delete `if (_open) return;` → `a double tap opens Settings once` fails.
2. Move `const SettingsAction()` before the history button in `dose_schedule_screen.dart` → `Doses: the gear is last…` fails.
3. Remove `const SettingsAction()` from `treatment_list_screen.dart` → `Treatments: the gear is last…` fails.
4. Revert the chip row to `Padding` → `Treatments at 360 dp, it, 1.6x…` fails.

Then run `git worktree remove --force <scratch>/wt && git worktree prune`.

- [ ] **Step 12: Gates and commit**

Run the gates. Expected: format 0 changed, analyze clean, gen-l10n no diff and `{}`, both test runs green, grep empty.

Commit these files: `lib/presentation/widgets/settings_action.dart`, the four screens, the two new tests and the four Doses PNGs. Message:

```
feat(ui): a settings gear on the four main tabs

One shared SettingsAction (icon, tooltip and screen-reader label, route,
double-tap guard) ends the app-bar actions of Dashboard, Medications,
Treatments and Doses; forms, detail screens, sheets, dialogs and the scanner
keep their own actions. The dashboard's gear gains its missing label.

The 360 dp / 1.6x test found two overflows on empty tabs that predate the
gear: the Treatments filter chips now scroll, and the Doses empty state
grows instead of being cut off.

Goldens: doses_* and doses_take_all_* re-recorded because the Doses app bar
now shows the gear; the Home goldens are byte-identical.
```

---

## Task 2: Four small fixes users can see

**Files:**
- Modify: `lib/presentation/screens/treatment/prescription_sheet.dart` (initial `_durationController`)
- Modify: `lib/services/export_service.dart` (`EpisodeLabels.fromL10n`)
- Modify: `lib/presentation/screens/treatment/end_treatment_dialog.dart` (`confirmAndEndTreatment`, after the dialog)
- Modify: `lib/presentation/screens/home/home_screen.dart` (`_ExpiringSoonCard`, `_LowStockCard`, `_ActiveTreatmentsCard`, new `_MoreRow`)
- Modify: `lib/l10n/app_en.arb`, `app_de.arb`, `app_it.arb` (+ `fvm flutter gen-l10n` output)
- Test: `test/presentation/screens/prescription_sheet_test.dart`, `test/services/export_service_test.dart`, `test/presentation/screens/treatment_detail_screen_test.dart`, `test/presentation/screens/home_dashboard_test.dart`

**Interfaces:**
- Produces:
  - ARB keys `ongoingInline` ("ongoing" / "laufend" / "in corso") and `endTreatmentFailed` ("Could not end the treatment" / "Die Behandlung konnte nicht beendet werden" / "Impossibile terminare il trattamento");
  - the private `_MoreRow({required int count, required VoidCallback onTap})` with `key: Key('dashboardMoreRow')`.

- [ ] **Step 1: Change the tests first**

`prescription_sheet_test.dart`, test `switching back to a schedule starts it now, for a duration the user enters`:
- rename it to `switching back to a schedule starts it now, for a week unless the user enters another duration`;
- replace the block from `// The stored zero is no duration: the user has to enter one.` to the second `await tester.tap(find.widgetWithText(ElevatedButton, 'Update'));` with:

```dart
      // The stored zero is no duration: the field offers the usual week.
      expect(
        tester
            .widget<TextField>(
              find.descendant(
                of: find.byKey(const Key('durationDaysField')),
                matching: find.byType(TextField),
              ),
            )
            .controller!
            .text,
        '7',
      );
      await tester.tap(find.widgetWithText(ElevatedButton, 'Update'));
```

The expectations after it stay: `duration_days == 7` and 21 doses.

In `test/services/export_service_test.dart` and `test/presentation/screens/treatment_detail_screen_test.dart`, change every **mid-line** ongoing in expected share text and subjects, and nothing else:
- `– Laufend` → `– laufend`
- `– In corso` → `– in corso`
- `– Ongoing` → `– ongoing`

The detail block's standalone `find.text('Ongoing')` stays.

In `treatment_detail_screen_test.dart`, group `ending the treatment`, add before `cancelling changes nothing`:

```dart
    for (final locale in const ['en', 'de', 'it']) {
      testWidgets('a failed End says so and leaves the treatment running '
          '($locale)', (tester) async {
        await seedAndPump(
          tester,
          locale: Locale(locale),
          extraOverrides: [
            treatmentRepositoryProvider.overrideWithValue(
              _EndFails(localDatasource: TreatmentLocalDatasource()),
            ),
          ],
        );
        final l10n = lookupAppLocalizations(Locale(locale));
        await openEndDialog(tester, label: l10n.endTreatment);
        await confirm(tester, label: l10n.endTreatment);
        expect(
          find.descendant(
            of: find.byType(SnackBar),
            matching: find.text(l10n.endTreatmentFailed),
          ),
          findsOneWidget,
        );
        expect((await stored()).isActive, isTrue);
      });
    }
```

At the end of that file, add:

```dart
/// A treatment repository whose End always fails, as a full disk would.
class _EndFails extends TreatmentRepositoryImpl {
  _EndFails({required super.localDatasource});

  @override
  Future<Result<Treatment>> endTreatment(
    String id, {
    bool endSickLeave = false,
  }) async => const Result.failure('disk full');
}
```

Also add `import 'package:medora/data/repositories/treatment_repository_impl.dart';`.

In `home_dashboard_test.dart`:
- replace the test `a fourth low-stock medication is silently dropped` with the three tests below;
- add `import 'package:medora/presentation/screens/main_shell_screen.dart';`;
- change the library comment's "the silent three-item truncation" to "the "N more" row".

```dart
  testWidgets('five low-stock medications: three rows and "2 more", which '
      'opens the medications tab', (tester) async {
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
    int? switchedTo;
    await pumpMedoraApp(
      tester,
      MainShellScope(
        switchTab: (i) => switchedTo = i,
        child: const HomeScreen(),
      ),
      overrides: await overrides(),
    );
    await tester.pumpAndSettle();

    final shown = [
      'LS1',
      'LS2',
      'LS3',
      'LS4',
      'LS5',
    ].where((n) => find.text(n).evaluate().isNotEmpty).length;
    expect(shown, 3, reason: 'the card shows exactly three of the five');
    final more = find.widgetWithText(ListTile, '2 more');
    expect(more, findsOneWidget);

    final tile = find
        .ancestor(of: find.text('Low stock'), matching: find.byType(InkWell))
        .first;
    expect(find.descendant(of: tile, matching: find.text('5')), findsOneWidget);

    await tester.ensureVisible(more);
    await tester.tap(more);
    await tester.pumpAndSettle();
    expect(switchedTo, 1);
  });

  testWidgets('four active treatments: three rows and "1 more", which opens '
      'the treatments tab', (tester) async {
    useTallPhone(tester);
    final db = await AppDatabase.instance.database;
    for (var i = 1; i <= 4; i++) {
      await db.insert('treatments', {
        'id': 't$i',
        'name': 'Episode $i',
        'start_date': '2026-03-0$i',
        'is_active': 1,
      });
    }
    int? switchedTo;
    await pumpMedoraApp(
      tester,
      MainShellScope(
        switchTab: (i) => switchedTo = i,
        child: const HomeScreen(),
      ),
      overrides: await overrides(),
    );
    await tester.pumpAndSettle();

    final more = find.widgetWithText(ListTile, '1 more');
    expect(more, findsOneWidget);
    await tester.ensureVisible(more);
    await tester.tap(more);
    await tester.pumpAndSettle();
    expect(switchedTo, 2);
  });

  testWidgets('three low-stock medications have no "more" row', (tester) async {
    useTallPhone(tester);
    final db = await AppDatabase.instance.database;
    for (var i = 1; i <= 3; i++) {
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
    expect(find.byKey(const Key('dashboardMoreRow')), findsNothing);
  });
```

- [ ] **Step 2: Run them to see them fail**

Run: `fvm flutter test test/presentation/screens/prescription_sheet_test.dart test/services/export_service_test.dart test/presentation/screens/treatment_detail_screen_test.dart test/presentation/screens/home_dashboard_test.dart`
Expected: compile errors for `endTreatmentFailed`. Once the keys exist (Step 3), the failures are:
- the duration test: `'0'` against `'7'`;
- the lower-case expectations;
- the failed-End tests: no SnackBar;
- the "more" tests: no `2 more` / `1 more`.

- [ ] **Step 3: Add the strings**

**`app_en.arb`:**
- after `"ongoing": "Ongoing",`, add `"ongoingInline": "ongoing",`;
- after the `"@endTreatmentConfirm": {…}` block, add `"endTreatmentFailed": "Could not end the treatment",`.

**`app_de.arb`:**
- after `"ongoing": "Laufend",`, add `"ongoingInline": "laufend",`;
- after `"endTreatmentConfirm": …,`, add `"endTreatmentFailed": "Die Behandlung konnte nicht beendet werden",`.

**`app_it.arb`:**
- after `"ongoing": "In corso",`, add `"ongoingInline": "in corso",`;
- after `"endTreatmentConfirm": …,`, add `"endTreatmentFailed": "Impossibile terminare il trattamento",`.

Run: `fvm flutter gen-l10n && cat untranslated.txt`
Expected: `{}`

- [ ] **Step 4: Implement the four fixes**

**`prescription_sheet.dart`.** Replace

```dart
    _durationController = TextEditingController(
      text: (existing?.durationDays ?? 7).toString(),
    );
```

with

```dart
    // An as-needed prescription is stored with no duration (0). Switching it
    // back to a schedule starts from the usual week, not from a 0 the form
    // would refuse.
    final storedDays = existing?.durationDays ?? 0;
    _durationController = TextEditingController(
      text: (storedDays > 0 ? storedDays : 7).toString(),
    );
```

**`export_service.dart`** (`EpisodeLabels.fromL10n`). Replace `ongoing: l10n.ongoing,` with

```dart
      // Mid-line ("2. März 2026 – laufend"), so lower case.
      ongoing: l10n.ongoingInline,
```

**`end_treatment_dialog.dart`.** Replace

```dart
  if (confirmed != true || !context.mounted) return false;
  await ref
      .read(treatmentListProvider.notifier)
      .endTreatment(treatment.id, endSickLeave: endSickLeave);
  return true;
```

with

```dart
  if (confirmed != true || !context.mounted) return false;
  final messenger = ScaffoldMessenger.of(context);
  try {
    await ref
        .read(treatmentListProvider.notifier)
        .endTreatment(treatment.id, endSickLeave: endSickLeave);
  } catch (e) {
    debugPrint('⚠ Ending treatment ${treatment.id} failed: $e');
    messenger.showSnackBar(SnackBar(content: Text(l10n.endTreatmentFailed)));
    return false;
  }
  return true;
```

**`home_screen.dart`.**

In `_ExpiringSoonCard`, replace the inline "more" `ListTile` with:

```dart
              if (hidden > 0)
                _MoreRow(
                  count: hidden,
                  onTap: () => context.push(AppRoutes.expiringMedications),
                ),
```

In `_LowStockCard`, change the `data:` builder to:

```dart
      data: (meds) {
        final hidden = meds.length - 3;
        return Card(
          child: Column(
            children: [
              ...meds.take(3).map((med) {
                return ListTile(
                  // … the existing tile, unchanged …
                );
              }),
              // As on the expiry card: the stat tile counts every one of
              // them, so the card says how many it does not show.
              if (hidden > 0)
                _MoreRow(
                  count: hidden,
                  onTap: () => MainShellScope.of(context)?.switchTab(1),
                ),
            ],
          ),
        );
      },
```

In `_ActiveTreatmentsCard`, change the `data:` builder to:

```dart
      data: (treatments) {
        final hidden = treatments.length - 3;
        return Card(
          child: Column(
            children: [
              for (final t in treatments.take(3))
                _ActiveTreatmentTile(treatment: t, now: now),
              if (hidden > 0)
                _MoreRow(
                  count: hidden,
                  onTap: () => MainShellScope.of(context)?.switchTab(2),
                ),
            ],
          ),
        );
      },
```

Add before `class _ActiveTreatmentTile`:

```dart
/// The last row of a dashboard card that shows three of more rows.
class _MoreRow extends StatelessWidget {
  const _MoreRow({required this.count, required this.onTap});

  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      key: const Key('dashboardMoreRow'),
      dense: true,
      leading: const Icon(Icons.more_horiz),
      title: Text(AppLocalizations.of(context).moreCount(count)),
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
    );
  }
}
```

- [ ] **Step 5: Run the tests and the Home goldens**

Run: `fvm flutter test test/presentation/screens/prescription_sheet_test.dart test/services/export_service_test.dart test/presentation/screens/treatment_detail_screen_test.dart test/presentation/screens/home_dashboard_test.dart test/presentation/screens/home_screen_test.dart test/presentation/screens/home_locale_test.dart test/goldens/home_golden_test.dart`
Expected: all pass. The Home goldens pass unchanged: the golden fixture has fewer than four low-stock medications and active treatments, and the expiry card's row renders exactly as before.

- [ ] **Step 6: Mutation checks (scratch worktree)**

1. `storedDays > 0 ? storedDays : 7` → `storedDays` → the duration test fails.
2. `l10n.ongoingInline` → `l10n.ongoing` → the export tests fail.
3. Remove the `try`/`catch` → the failed-End tests fail with an uncaught exception.
4. `if (hidden > 0)` → `if (hidden > 1)` in `_ActiveTreatmentsCard` → `four active treatments…` fails.

Remove the worktree.

- [ ] **Step 7: Gates and commits**

Run the gates, then make four commits, staging each fix's files (the ARB and generated files go with the fix that uses them):
- `fix(treatments): switching back from as-needed offers a week, not 0 days`
- `fix(l10n): "ongoing" in the middle of the shared text is lower case`
- `fix(treatments): a failed End says so`
- `fix(home): Low Stock and Active Treatments say how many rows they hide`

---

## Task 3: The server contract — migration, SQL checks, v2 datasources, fake server

**What this task delivers:**
- the migration;
- a script that proves it against Postgres 15;
- the client classes that speak to it;
- a Dart fake that keeps its rules.

The app does not use the new classes yet. The four remote datasources gain `rows` (and `stock`) next to their current methods, and the sync cycle is unchanged.

**Files:**
- Create: `supabase/migrations/20260918000000_sync_v2.sql`
- Create: `tools/check_supabase_sql.sh` (executable), `tools/sql/auth_shim.sql`, `tools/sql/sync_v2_checks.sql`
- Modify: `.github/workflows/ci.yml` (new job `supabase-sql`)
- Create: `lib/data/datasources/sync_page.dart`, `lib/data/datasources/sync_table.dart`, `lib/data/datasources/stock_remote.dart`, `lib/data/datasources/sync_state_remote_datasource.dart`
- Create: `lib/data/datasources/stock_outbox_local_datasource.dart` (pure part: `StockOp`, `maxStock`, `applyStockOps`; Task 4 adds the table class)
- Modify: `lib/data/datasources/schema_errors.dart` (append `MissingMigrationException`)
- Modify: `lib/data/datasources/medication_remote_datasource.dart`, `treatment_remote_datasource.dart`, `prescription_remote_datasource.dart`, `dose_log_remote_datasource.dart` (constructor + `rows`, plus `stock` for medications)
- Create: `test/helpers/fake_server.dart`, `test/helpers/fake_server_test.dart`
- Create: `test/data/datasources/sync_table_test.dart`, `test/data/datasources/stock_outbox_local_datasource_test.dart`
- Modify: `README.md` (the migrations list)

**Interfaces:**
- Produces:
  - `class PullKey { const PullKey(int xid, [String? id]); static PullKey? fromStorage(String?); String toStorage(); }`
  - `const pullPageSize = 1000;`
  - `pullPage(query, {required PullKey? after, required int horizon, int limit})` in `sync_page.dart`.
  - `class RemoteMeta { factory RemoteMeta.fromJson(Map<String, dynamic>); int syncXid; int rowVersion; String? writeId; DateTime? editedAt; DateTime? updatedAt; DateTime? deletedAt; DateTime? get effectiveEditedAt; }`
  - `abstract interface class SyncTable`:
    - `Future<List<Map<String, dynamic>>> page({required PullKey? after, required int horizon})`
    - `Future<Map<String, dynamic>?> fetch(String id)`
    - `Future<List<Map<String, dynamic>>> fetchMany(List<String> ids)`
    - `Future<Map<String, dynamic>?> patch(String id, Map<String, Object?> changes, {int? ifVersion, String? ifStatus, bool ifLive = false})`
    - `Future<void> insertIfAbsent(List<Map<String, Object?>> rows)`
  - `class PostgrestSyncTable implements SyncTable { PostgrestSyncTable(SupabaseClient, String table, {String select = '*', String? migration, String? fallbackColumn}); }`
  - `enum StockChangeStatus { applied, duplicate, gone, missing }`
  - `class StockChangeResult { StockChangeStatus status; int? quantity; int? rowVersion; }`
  - `abstract interface class StockRemote { Future<StockChangeResult> apply(StockOp op); }`
  - `class PostgrestStockRemote implements StockRemote`
  - `class StockOp { opId, medicationId, int? delta, int? setTo, DateTime createdAt; toRow(); StockOp.fromRow(); }`
  - `const maxStock = 999999;`
  - `int applyStockOps(int quantity, Iterable<StockOp> ops)`
  - `const syncV2Migration = 'supabase/migrations/20260918000000_sync_v2.sql';`
  - `const requiredSyncSchema = 2;`
  - `class SyncServerState { int schema; int horizon; }`
  - `class SyncStateRemoteDatasource { SyncStateRemoteDatasource(SupabaseClient); Future<SyncServerState> read(); }` (throws `MissingMigrationException`)
  - `bool isMissingFunction(PostgrestException)`
  - `SyncServerState parseSyncState(Object? raw)`
  - `class MissingMigrationException implements Exception { const MissingMigrationException({required String migration, Object? cause}); }`
  - `MedicationRemoteDatasource.rows` (`SyncTable`), `MedicationRemoteDatasource.stock` (`StockRemote`), `TreatmentRemoteDatasource.rows`, `PrescriptionRemoteDatasource.rows`, `DoseLogRemoteDatasource.rows`
  - Test helpers:
    - `class FakeServerCore`: `rowsOf`, `horizon`, `begin()`, `insertIfAbsent`, `patch`, `legacyUpsert`, `page`, `fetch`, `applyStockChange`, `syncState`, `ledger`, `requests`, `rowCap`.
    - `class FakeSyncTable implements SyncTable` (`failIds`, `failGetIds`, `throwOnFetch`, `beforeCall`, `loseAnswerFor`, `pageCalls`, `sinceCalls`, `onPage`, `insertBatches`, `rows`, `seed`, `editFromOtherDevice`, `get`).
    - `extension FakeSyncTableLegacy` (`upsert`, `tombstone`, `hardDelete`, `all`, `live`, `updatedAt`).
    - `class FakeStockRemote implements StockRemote` (`loseNextAnswers`).
    - `class FakeTransaction` (`insert`, `commit`).

- [ ] **Step 1: The migration**

Create `supabase/migrations/20260918000000_sync_v2.sql` with exactly this content (it is the file quoted in design §5):

```sql
-- ============================================================
-- Medora - Sync v2: a change cursor the server assigns, row versions,
-- write ids, edit times and idempotent stock changes.
--
-- Apply after 20260917000000_treatment_sick_leave.sql and BEFORE any
-- device runs Medora 0.4.0. Medora 0.3.0 keeps working against it:
-- every new column has a default or is set by a trigger, no existing
-- column changes meaning for a client that does not send the new ones,
-- and `updated_at` still moves on every change such a client can see.
--
-- No backfill UPDATE: every new column is added with a constant default
-- (no table rewrite, no trigger fires), so no row changes `updated_at`
-- and no 0.3.0 device sees its pending edit turn stale.
-- ============================================================

-- 1. Columns ---------------------------------------------------------------
--
-- sync_xid     the id of the transaction that last wrote the row. Pulls
--              read rows with sync_xid below a horizon every older
--              transaction has finished by (medora_sync_state), so a row
--              committed late is never skipped. 0 = written before this
--              migration.
-- row_version  1 on insert, +1 on every update. A client updates only
--              the version it last saw.
-- write_id     the id a 0.4.0+ client gives each write attempt, so it can
--              recognise its own write when the answer never arrived.
--              NULL for a write from a client that does not send one.
-- edited_at    when the change was made on the device, never later than
--              the server received it. 1970-01-01 marks a change the app
--              made on its own (an overdue dose marked missed, a dose time
--              corrected, a dose dropped from a changed schedule).

alter table public.medications
  add column if not exists sync_xid    bigint not null default 0,
  add column if not exists row_version bigint not null default 1,
  add column if not exists write_id    uuid,
  add column if not exists edited_at   timestamptz;

alter table public.treatments
  add column if not exists sync_xid    bigint not null default 0,
  add column if not exists row_version bigint not null default 1,
  add column if not exists write_id    uuid,
  add column if not exists edited_at   timestamptz;

alter table public.prescriptions
  add column if not exists sync_xid    bigint not null default 0,
  add column if not exists row_version bigint not null default 1,
  add column if not exists write_id    uuid,
  add column if not exists edited_at   timestamptz;

alter table public.dose_logs
  add column if not exists sync_xid    bigint not null default 0,
  add column if not exists row_version bigint not null default 1,
  add column if not exists write_id    uuid,
  add column if not exists edited_at   timestamptz;

-- 2. Pull indexes (keyset: sync_xid, then id) -----------------------------

create index if not exists idx_med_sync   on public.medications   (user_id, sync_xid, id);
create index if not exists idx_treat_sync on public.treatments    (user_id, sync_xid, id);
create index if not exists idx_presc_sync on public.prescriptions (sync_xid, id);
create index if not exists idx_dose_sync  on public.dose_logs     (sync_xid, id);

-- 3. The stamp trigger ------------------------------------------------------
--
-- Runs BEFORE the `<table>_updated_at` trigger: Postgres fires BEFORE
-- triggers of one event in name order, and `_sync_stamp` sorts before
-- `_updated_at`. update_updated_at() below relies on that order.

create or replace function public.medora_sync_stamp()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  new.sync_xid := pg_current_xact_id()::text::bigint;
  if tg_op = 'INSERT' then
    new.row_version := 1;
    new.edited_at := coalesce(new.edited_at, new.updated_at, now());
  else
    new.row_version := old.row_version + 1;
    if new.write_id is null or new.write_id is not distinct from old.write_id then
      -- A writer that sends no write id: Medora 0.3.0 and older, the
      -- tombstone cascade. Its change counts as made when it arrived.
      new.write_id := null;
      new.edited_at := now();
    elsif new.edited_at is null then
      new.edited_at := coalesce(old.updated_at, now());
    end if;
  end if;
  if new.edited_at < timestamptz '1970-01-02 00:00:00+00' then
    new.edited_at := timestamptz '1970-01-01 00:00:00+00';
  else
    new.edited_at := least(new.edited_at, now());
    if tg_op = 'INSERT' then
      -- A row a person created is stamped on arrival, so a device whose
      -- updated_at cursor passed its creation time while it was offline
      -- still pulls it (Medora 0.3.0 pulls by updated_at). A generated
      -- row keeps its 1970 stamp and stays invisible to those cursors.
      new.updated_at := now();
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists medications_sync_stamp on public.medications;
create trigger medications_sync_stamp
  before insert or update on public.medications
  for each row execute function public.medora_sync_stamp();

drop trigger if exists treatments_sync_stamp on public.treatments;
create trigger treatments_sync_stamp
  before insert or update on public.treatments
  for each row execute function public.medora_sync_stamp();

drop trigger if exists prescriptions_sync_stamp on public.prescriptions;
create trigger prescriptions_sync_stamp
  before insert or update on public.prescriptions
  for each row execute function public.medora_sync_stamp();

drop trigger if exists dose_logs_sync_stamp on public.dose_logs;
create trigger dose_logs_sync_stamp
  before insert or update on public.dose_logs
  for each row execute function public.medora_sync_stamp();

-- 4. updated_at: an automatic change keeps the old stamp ------------------
--
-- Medora 0.3.0 pulls by updated_at and skips its own pending edit when the
-- server's updated_at is newer. A change the app made on its own must lose
-- to that edit, so it leaves updated_at alone (0.3.0 neither pulls it nor
-- counts it as newer). Every other update is stamped now(), as before.

create or replace function public.update_updated_at()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if new.write_id is not null
     and new.edited_at = timestamptz '1970-01-01 00:00:00+00' then
    new.updated_at := old.updated_at;
  else
    new.updated_at := now();
  end if;
  return new;
end;
$$;

-- 5. The pull horizon -------------------------------------------------------
--
-- Every transaction with an id below `horizon` has finished, so every row
-- a pull can ever see with `sync_xid < horizon` is visible now. A pull
-- reads [its stored key, horizon) and stores the horizon as its next
-- start. `schema` lets the app tell a project without this migration.

create or replace function public.medora_sync_state()
returns jsonb
language sql
stable
security invoker
set search_path = public, pg_temp
as $$
  select jsonb_build_object(
    'schema', 2,
    'horizon', pg_snapshot_xmin(pg_current_snapshot())::text::bigint
  )
$$;

revoke all on function public.medora_sync_state() from public, anon;
grant execute on function public.medora_sync_state() to authenticated;

-- 6. Stock changes ----------------------------------------------------------
--
-- A stock change is sent as a change (a delta, or a counted quantity),
-- never as the new total. Each carries an id the device chose; the ledger
-- remembers every id it applied, so a retry after a lost answer is not
-- counted twice, and changes from two devices both apply.

create table if not exists public.stock_changes (
  op_id          uuid primary key,
  medication_id  text not null references public.medications(id) on delete cascade,
  user_id        uuid not null default auth.uid() references auth.users(id) on delete cascade,
  delta          integer,
  set_to         integer,
  quantity_after integer not null,
  applied_at     timestamptz not null default now(),
  constraint stock_changes_one_kind check ((delta is null) <> (set_to is null)),
  constraint stock_changes_delta_range check (delta is null or delta between -999999 and 999999),
  constraint stock_changes_set_to_range check (set_to is null or set_to between 0 and 999999)
);

create index if not exists idx_stock_changes_med on public.stock_changes (medication_id);

alter table public.stock_changes enable row level security;

-- The ledger follows the medication: whoever may see the medication row
-- (the owner today; the medications policies decide) may read and add its
-- changes. The subquery runs under the caller's own policies. No update
-- or delete policy: clients only append.
drop policy if exists "stock_changes_select" on public.stock_changes;
create policy "stock_changes_select" on public.stock_changes
  for select using (
    user_id = auth.uid()
    and exists (select 1 from public.medications m where m.id = medication_id)
  );

drop policy if exists "stock_changes_insert" on public.stock_changes;
create policy "stock_changes_insert" on public.stock_changes
  for insert with check (
    user_id = auth.uid()
    and exists (select 1 from public.medications m where m.id = medication_id)
  );

revoke all on public.stock_changes from anon;
grant select, insert on public.stock_changes to authenticated;

-- Applies one stock change once. Returns
--   {"status":"applied",   "quantity":q, "row_version":v}
--   {"status":"duplicate", "quantity":q}   (this op_id was applied before)
--   {"status":"gone"}      (the medication is deleted: drop the change)
--   {"status":"missing"}   (no such medication yet: keep the change)
-- Runs with the caller's rights, so row-level security applies throughout.
create or replace function public.apply_stock_change(
  p_op_id         uuid,
  p_medication_id text,
  p_delta         integer default null,
  p_set_to        integer default null
)
returns jsonb
language plpgsql
security invoker
set search_path = public, pg_temp
as $$
declare
  v_after   integer;
  v_qty     integer;
  v_version bigint;
begin
  if auth.uid() is null then
    raise exception 'not authenticated' using errcode = '28000';
  end if;
  if (p_delta is null) = (p_set_to is null) then
    raise exception 'pass exactly one of p_delta and p_set_to'
      using errcode = '22023';
  end if;

  -- Two attempts with one op id (a retry racing the original) run one
  -- after the other.
  perform pg_advisory_xact_lock(hashtextextended(p_op_id::text, 0));

  select quantity_after into v_after
    from public.stock_changes where op_id = p_op_id;
  if found then
    return jsonb_build_object('status', 'duplicate', 'quantity', v_after);
  end if;

  update public.medications m
     set quantity = case
           when p_set_to is not null then greatest(0, least(999999, p_set_to))
           else greatest(0, least(999999, m.quantity + p_delta))
         end,
         write_id = p_op_id
   where m.id = p_medication_id
     and m.deleted_at is null
  returning m.quantity, m.row_version into v_qty, v_version;

  if not found then
    if exists (select 1 from public.medications m where m.id = p_medication_id) then
      return jsonb_build_object('status', 'gone');
    end if;
    return jsonb_build_object('status', 'missing');
  end if;

  insert into public.stock_changes (op_id, medication_id, delta, set_to, quantity_after)
    values (p_op_id, p_medication_id, p_delta, p_set_to, v_qty);

  return jsonb_build_object(
    'status', 'applied', 'quantity', v_qty, 'row_version', v_version
  );
end;
$$;

revoke all on function public.apply_stock_change(uuid, text, integer, integer) from public, anon;
grant execute on function public.apply_stock_change(uuid, text, integer, integer) to authenticated;
```

- [ ] **Step 2: The SQL checks**

Create `tools/sql/auth_shim.sql`:

```sql
-- Stand-in for the parts of a Supabase database the migrations use.
do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then create role anon nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then create role authenticated nologin; end if;
end $$;
create schema if not exists auth;
create table if not exists auth.users (id uuid primary key);
create or replace function auth.uid() returns uuid language sql stable as $$
  select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid
$$;
grant usage on schema auth to anon, authenticated;
grant usage on schema public to anon, authenticated;
grant execute on function auth.uid() to anon, authenticated;
alter default privileges in schema public grant all on tables to anon, authenticated;
alter default privileges in schema public grant all on functions to anon, authenticated;
alter default privileges in schema public grant all on sequences to anon, authenticated;
```

Create `tools/sql/sync_v2_checks.sql`:

```sql
-- Checks for supabase/migrations/20260918000000_sync_v2.sql.
-- Run by tools/check_supabase_sql.sh against a throwaway Postgres 15 with
-- tools/sql/auth_shim.sql and every migration applied. Any failed ASSERT
-- stops the script with a non-zero exit.
\set ON_ERROR_STOP on

insert into auth.users values
  ('00000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-00000000000b');

-- A row written before the migration keeps the defaults.
do $$ begin
  assert (select sync_xid = 0 and row_version = 1 and write_id is null and edited_at is null
            from medications where id = 'pre-migration'),
    'a row from before the migration keeps sync_xid 0, row_version 1';
end $$;

set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', false);

do $$
declare r medications%rowtype; n int;
begin
  -- 0.3.0 insert: no write id, no edit time.
  insert into medications (id, user_id, name, quantity, updated_at)
    values ('m1', auth.uid(), 'Ibuprofen', 10, '2026-09-01T08:00:00Z');
  select * into r from medications where id = 'm1';
  assert r.row_version = 1, 'insert: version 1';
  assert r.write_id is null, 'insert: no write id';
  assert r.edited_at = timestamptz '2026-09-01T08:00:00Z', 'insert: edited_at falls back to updated_at';
  assert r.updated_at = now(), 'insert: a created row is stamped on arrival';
  assert r.sync_xid > 0, 'insert: sync_xid set';

  -- 0.3.0 upsert (ON CONFLICT DO UPDATE with the payload columns only).
  insert into medications (id, user_id, name, quantity, updated_at)
    values ('m1', auth.uid(), 'Ibuprofen 400', 10, '2026-09-01T09:00:00Z')
    on conflict (id) do update
      set name = excluded.name, quantity = excluded.quantity, updated_at = excluded.updated_at;
  select * into r from medications where id = 'm1';
  assert r.row_version = 2, 'upsert: version 2';
  assert r.write_id is null, 'upsert: legacy write has no write id';
  assert r.edited_at = now(), 'upsert: a legacy edit counts as made on arrival';
  assert r.updated_at = now(), 'upsert: updated_at still moves for 0.3.0';

  -- 0.4.0 conditional update.
  update medications set notes = 'after food',
         write_id = '11111111-1111-1111-1111-111111111111', edited_at = '2026-09-16T10:00:00Z'
   where id = 'm1' and row_version = 2;
  get diagnostics n = row_count;
  assert n = 1, 'conditional update on the current version applies';
  select * into r from medications where id = 'm1';
  assert r.row_version = 3 and r.write_id = '11111111-1111-1111-1111-111111111111'
     and r.edited_at = timestamptz '2026-09-16T10:00:00Z', 'conditional update: version, write id, edit time';

  -- The same attempt again (its answer was lost): no row matches.
  update medications set notes = 'after food', write_id = '11111111-1111-1111-1111-111111111111'
   where id = 'm1' and row_version = 2;
  get diagnostics n = row_count;
  assert n = 0, 'a replayed attempt matches nothing';

  -- A clock in the future is capped.
  update medications set notes = 'x', write_id = '22222222-2222-2222-2222-222222222222',
         edited_at = '2099-01-01T00:00:00Z' where id = 'm1';
  assert (select edited_at = now() from medications where id = 'm1'), 'future edit time capped at now()';

  -- An update that repeats the stored write id is a legacy write.
  update medications set notes = 'legacy', write_id = '22222222-2222-2222-2222-222222222222' where id = 'm1';
  assert (select write_id is null from medications where id = 'm1'), 'repeated write id is cleared';

  -- Doses: a generated insert and an automatic change keep updated_at.
  insert into treatments (id, user_id, name, start_date) values ('t1', auth.uid(), 'Flu', '2026-09-10');
  insert into prescriptions (id, treatment_id, medication_id, dosage, start_time)
    values ('p1', 't1', 'm1', '1', '2026-09-10T08:00:00');
  insert into dose_logs (id, prescription_id, scheduled_time, status, updated_at, write_id, edited_at)
    values ('d1', 'p1', '2026-09-10T08:00:00Z', 'pending', '1970-01-01T00:00:00Z',
            '33333333-3333-3333-3333-333333333333', '1970-01-01T00:00:00Z');
  assert (select updated_at = timestamptz '1970-01-01T00:00:00Z' from dose_logs where id = 'd1'),
    'generated insert keeps its 1970 stamp';
  update dose_logs set status = 'missed', write_id = '44444444-4444-4444-4444-444444444444',
         edited_at = '1970-01-01T00:00:00.001Z' where id = 'd1' and row_version = 1;
  assert (select status = 'missed' and row_version = 2
              and updated_at = timestamptz '1970-01-01T00:00:00Z'
              and edited_at = timestamptz '1970-01-01T00:00:00Z'
            from dose_logs where id = 'd1'), 'automatic change: updated_at kept, edit time normalised';
  update dose_logs set status = 'taken', taken_time = now(),
         write_id = '55555555-5555-5555-5555-555555555555', edited_at = now() - interval '1 minute'
   where id = 'd1' and row_version = 2;
  assert (select status = 'taken' and updated_at = now() and row_version = 3
            from dose_logs where id = 'd1'), 'real change: updated_at moves';

  -- A guarded tombstone does not touch a taken dose.
  update dose_logs set deleted_at = now(), write_id = '66666666-6666-6666-6666-666666666666',
         edited_at = '1970-01-01T00:00:00Z'
   where id = 'd1' and status = 'pending' and deleted_at is null;
  get diagnostics n = row_count;
  assert n = 0, 'guarded tombstone skips a taken dose';
end $$;

-- The horizon, read in a transaction of its own (as PostgREST does), is
-- above every finished write. Inside the writing transaction it would not
-- be: a transaction's own rows are not finished yet.
do $$ begin
  assert (medora_sync_state()->>'schema')::int = 2, 'schema 2';
  assert (medora_sync_state()->>'horizon')::bigint > (select max(sync_xid) from dose_logs),
    'horizon above finished writes';
end $$;

-- Stock changes.
do $$
declare j jsonb;
begin
  j := apply_stock_change('aaaaaaaa-0000-0000-0000-000000000001', 'm1', -3, null);
  assert j->>'status' = 'applied' and (j->>'quantity')::int = 7, 'stock: applied ' || j;
  j := apply_stock_change('aaaaaaaa-0000-0000-0000-000000000001', 'm1', -3, null);
  assert j->>'status' = 'duplicate' and (j->>'quantity')::int = 7, 'stock: duplicate ' || j;
  assert (select quantity from medications where id = 'm1') = 7, 'stock: a retry is not counted twice';
  j := apply_stock_change('aaaaaaaa-0000-0000-0000-000000000002', 'm1', -100, null);
  assert (j->>'quantity')::int = 0, 'stock: never below zero';
  j := apply_stock_change('aaaaaaaa-0000-0000-0000-000000000003', 'm1', null, 20);
  assert (j->>'quantity')::int = 20, 'stock: counted quantity';
  j := apply_stock_change('aaaaaaaa-0000-0000-0000-000000000004', 'nope', -1, null);
  assert j->>'status' = 'missing', 'stock: unknown medication is missing';
  assert (select count(*) from stock_changes) = 3, 'stock: ledger holds the three applied changes';
  begin
    perform apply_stock_change('aaaaaaaa-0000-0000-0000-000000000006', 'm1', -1, 1);
    assert false, 'stock: both kinds must be refused';
  exception when sqlstate '22023' then null;
  end;
  update medications set deleted_at = now(), write_id = '77777777-7777-7777-7777-777777777777' where id = 'm1';
  j := apply_stock_change('aaaaaaaa-0000-0000-0000-000000000005', 'm1', -1, null);
  assert j->>'status' = 'gone', 'stock: deleted medication is gone';

  insert into medications (id, user_id, name, quantity) values ('m2', auth.uid(), 'Paracetamol', 5);
end $$;

-- Row-level security: user B.
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000b', false);
do $$
declare j jsonb;
begin
  assert (select count(*) from stock_changes) = 0, 'rls: B sees none of A''s ledger';
  j := apply_stock_change('bbbbbbbb-0000-0000-0000-000000000001', 'm2', -1, null);
  assert j->>'status' = 'missing', 'rls: B cannot change A''s stock';
  begin
    insert into stock_changes (op_id, medication_id, delta, quantity_after)
      values ('bbbbbbbb-0000-0000-0000-000000000002', 'm2', -1, 0);
    assert false, 'rls: B must not append to A''s ledger';
  exception when insufficient_privilege then null;
  end;
end $$;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', false);
do $$ begin
  assert (select quantity from medications where id = 'm2') = 5, 'rls: A''s stock untouched';
  -- The tombstone cascade still runs and counts as a real change.
  update treatments set deleted_at = now(), write_id = '88888888-8888-8888-8888-888888888888',
         edited_at = now() where id = 't1';
  assert (select deleted_at is not null and write_id is null and row_version = 2
            from prescriptions where id = 'p1'), 'cascade: child tombstoned as a legacy write';
end $$;

-- anon may call neither function.
reset role;
set role anon;
do $$ begin
  begin
    perform medora_sync_state();
    assert false, 'anon must not read the sync state';
  exception when insufficient_privilege then null;
  end;
  begin
    perform apply_stock_change('cccccccc-0000-0000-0000-000000000001', 'm2', -1, null);
    assert false, 'anon must not change stock';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;
select 'sync_v2 checks passed' as result;
```

Create `tools/check_supabase_sql.sh`, then run `chmod +x tools/check_supabase_sql.sh`:

```bash
#!/usr/bin/env bash
# Applies every migration in supabase/migrations to a throwaway Postgres 15
# (with a stand-in for Supabase's auth schema) and runs the SQL checks in
# tools/sql/. Needs either Docker (default) or PGHOST/PGUSER/PGPASSWORD
# pointing at an empty scratch database (CI sets them; USE_DOCKER=0).
# Never point it at a real Supabase project.
set -euo pipefail
cd "$(dirname "$0")/.."

use_docker="${USE_DOCKER:-1}"
container=""
cleanup() { [[ -n "$container" ]] && docker stop "$container" >/dev/null 2>&1 || true; }
trap cleanup EXIT

if [[ "$use_docker" == 1 ]]; then
  container="medora-sql-check-$$"
  docker run -d --rm --name "$container" -e POSTGRES_PASSWORD=check postgres:15-alpine >/dev/null
  for _ in $(seq 1 60); do
    docker exec "$container" pg_isready -U postgres >/dev/null 2>&1 && break
    sleep 1
  done
  sleep 1
  psql_run() { docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -q "$@"; }
else
  psql_run() { psql -v ON_ERROR_STOP=1 -q "$@"; }
fi

{
  cat tools/sql/auth_shim.sql
  for f in supabase/migrations/2026090100*.sql supabase/migrations/2026091400*.sql \
           supabase/migrations/2026091600*.sql supabase/migrations/2026091700*.sql; do
    cat "$f"
  done
  # A row from before sync v2.
  echo "insert into auth.users values ('00000000-0000-0000-0000-0000000000cc');"
  echo "insert into medications (id, user_id, name) values ('pre-migration', '00000000-0000-0000-0000-0000000000cc', 'Old');"
  cat supabase/migrations/20260918000000_sync_v2.sql
  # Re-runnable: apply it a second time.
  cat supabase/migrations/20260918000000_sync_v2.sql
} | psql_run >/dev/null

psql_run < tools/sql/sync_v2_checks.sql

# The horizon holds back a row whose transaction is still open.
psql_run -c "insert into medications (id, user_id, name) values ('slow-owner', '00000000-0000-0000-0000-00000000000a', 'x');" >/dev/null
if [[ "$use_docker" == 1 ]]; then
  docker exec -d "$container" psql -U postgres -c "begin; insert into medications (id, user_id, name) values ('slow', '00000000-0000-0000-0000-00000000000a', 'Slow'); select pg_sleep(4); commit;"
else
  psql -q -c "begin; insert into medications (id, user_id, name) values ('slow', '00000000-0000-0000-0000-00000000000a', 'Slow'); select pg_sleep(4); commit;" >/dev/null &
fi
sleep 1.5
psql_run -c "insert into medications (id, user_id, name) values ('fast', '00000000-0000-0000-0000-00000000000a', 'Fast');" >/dev/null
during=$(psql_run -At -c "select count(*) from medications where id in ('slow','fast') and sync_xid < (medora_sync_state()->>'horizon')::bigint;")
sleep 4
after=$(psql_run -At -c "select count(*) from medications where id in ('slow','fast') and sync_xid < (medora_sync_state()->>'horizon')::bigint;")
wait || true
if [[ "$during" != 0 || "$after" != 2 ]]; then
  echo "horizon check failed: during=$during (want 0), after=$after (want 2)" >&2
  exit 1
fi
echo "horizon check passed"
```

- [ ] **Step 3: Run the checks, then prove they bite**

Run: `tools/check_supabase_sql.sh`
Expected output ends with:

```
 sync_v2 checks passed
horizon check passed
```

Mutations: work on a copy in your scratch folder, never the committed file. Copy the repository into `<scratch>/sqlcheck/` (`git worktree add`), edit the migration there, and run the script from there:
1. In `update_updated_at()`, change `new.updated_at := old.updated_at;` to `new.updated_at := now();` → `ERROR:  automatic change: updated_at kept, edit time normalised`.
2. In `medora_sync_stamp()`, change `if new.write_id is null or new.write_id is not distinct from old.write_id then` to `if new.write_id is null then` → `ERROR:  repeated write id is cleared`.
3. In `medora_sync_stamp()`, in the inner `if tg_op = 'INSERT' then` (the one under the comment "A row a person created is stamped on arrival"), change the condition to `if false then` → `ERROR:  insert: a created row is stamped on arrival`.

Remove the worktree.

- [ ] **Step 4: Run the checks in CI**

In `.github/workflows/ci.yml`, add this job next to `test`:

```yaml
  supabase-sql:
    runs-on: ubuntu-latest
    services:
      postgres:
        image: postgres:15-alpine
        env:
          POSTGRES_PASSWORD: check
        ports:
          - 5432:5432
        options: >-
          --health-cmd "pg_isready -U postgres"
          --health-interval 5s
          --health-timeout 5s
          --health-retries 12
    env:
      USE_DOCKER: '0'
      PGHOST: localhost
      PGUSER: postgres
      PGPASSWORD: check
    steps:
      - uses: actions/checkout@v4
      - run: psql --version
      - run: tools/check_supabase_sql.sh
```

Check that the YAML parses: `python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/ci.yml'))"`. The probe ran this exact path (`USE_DOCKER=0` against a port-mapped `postgres:15-alpine`) and it passed.

- [ ] **Step 5: Write the Dart tests first**

Create `test/data/datasources/sync_table_test.dart`. The expected URLs are the ones postgrest-dart 2.9.1 really sends; the probe captured them.

```dart
/// The requests the sync v2 datasources send, read off a stub HTTP client:
/// no network, no real project.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:medora/data/datasources/schema_errors.dart';
import 'package:medora/data/datasources/stock_outbox_local_datasource.dart';
import 'package:medora/data/datasources/stock_remote.dart';
import 'package:medora/data/datasources/sync_page.dart';
import 'package:medora/data/datasources/sync_state_remote_datasource.dart';
import 'package:medora/data/datasources/sync_table.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  late List<http.Request> seen;

  SupabaseClient answering(Object? body, {int status = 200}) {
    seen = [];
    final client = SupabaseClient(
      'http://supabase.test',
      'anon-key',
      httpClient: MockClient((request) async {
        seen.add(request);
        return http.Response(
          jsonEncode(body),
          status,
          request: request,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    addTearDown(client.dispose);
    return client;
  }

  String sent(int i) => Uri.decodeComponent(seen[i].url.toString());

  const doseSelect = 'select=*,prescriptions(id,medications(name))';
  const order = 'order=sync_xid.asc.nullslast,id.asc.nullslast&limit=1000';

  group('PostgrestSyncTable', () {
    PostgrestSyncTable doses(SupabaseClient c) => PostgrestSyncTable(
      c,
      'dose_logs',
      select: '*, prescriptions(id, medications(name))',
    );

    test('a first page asks for everything below the horizon', () async {
      await doses(answering([])).page(after: null, horizon: 900);
      expect(
        sent(0),
        'http://supabase.test/rest/v1/dose_logs?$doseSelect'
        '&sync_xid=lt.900&$order',
      );
    });

    test('a page after a finished pull starts at the stored horizon', () async {
      await doses(answering([])).page(after: const PullKey(812), horizon: 900);
      expect(
        sent(0),
        'http://supabase.test/rest/v1/dose_logs?$doseSelect'
        '&sync_xid=lt.900&sync_xid=gte.812&$order',
      );
    });

    test(
      'a later page continues after its last row; the id is quoted',
      () async {
        await doses(
          answering([]),
        ).page(after: const PullKey(812, 'a"b'), horizon: 900);
        expect(
          sent(0),
          'http://supabase.test/rest/v1/dose_logs?$doseSelect&sync_xid=lt.900'
          r'&or=(sync_xid.gt.812,and(sync_xid.eq.812,id.gt."a\"b"))'
          '&$order',
        );
      },
    );

    test(
      'a conditional update names the version and asks for the row',
      () async {
        final row = await doses(
          answering([
            {'id': 'd1', 'row_version': 4},
          ]),
        ).patch('d1', {'status': 'taken'}, ifVersion: 3);
        expect(seen.single.method, 'PATCH');
        expect(
          sent(0),
          'http://supabase.test/rest/v1/dose_logs?id=eq.d1&row_version=eq.3'
          '&$doseSelect',
        );
        expect(seen.single.headers['Prefer'], 'return=representation');
        expect(jsonDecode(seen.single.body), {'status': 'taken'});
        expect(row, {'id': 'd1', 'row_version': 4});
      },
    );

    test('a conditional update that matched nothing answers null', () async {
      expect(
        await doses(
          answering([]),
        ).patch('d1', {'status': 'taken'}, ifVersion: 3),
        isNull,
      );
    });

    test('a guarded delete filters on the status and on being live', () async {
      await doses(answering([])).patch(
        'd1',
        {'deleted_at': '2026-03-05T12:00:00.000Z'},
        ifStatus: 'pending',
        ifLive: true,
      );
      expect(
        sent(0),
        'http://supabase.test/rest/v1/dose_logs?id=eq.d1&status=eq.pending'
        '&deleted_at=is.null&$doseSelect',
      );
    });

    test('an insert leaves existing ids alone', () async {
      await doses(answering(null, status: 201)).insertIfAbsent([
        {'id': 'd1'},
      ]);
      expect(seen.single.method, 'POST');
      expect(
        sent(0),
        'http://supabase.test/rest/v1/dose_logs?on_conflict=id&columns="id"',
      );
      expect(seen.single.headers['Prefer'], 'resolution=ignore-duplicates');
    });

    test('fetch and fetchMany read by id', () async {
      final table = doses(answering([]));
      await table.fetch('d1');
      await table.fetchMany(['d1', 'd2']);
      expect(
        sent(0),
        'http://supabase.test/rest/v1/dose_logs?$doseSelect&id=eq.d1',
      );
      expect(
        sent(1),
        'http://supabase.test/rest/v1/dose_logs?$doseSelect&id=in.("d1","d2")',
      );
    });

    test('a write to a project without a column names the migration', () async {
      final table = PostgrestSyncTable(
        answering({
          'code': 'PGRST204',
          'message': "Could not find the 'doctor' column of 'treatments'",
        }, status: 400),
        'treatments',
        migration: 'supabase/migrations/x.sql',
        fallbackColumn: 'sick_leave_from',
      );
      await expectLater(
        table.patch('t1', {'doctor': 'Dr. Rossi'}, ifVersion: 1),
        throwsA(
          isA<MissingColumnException>()
              .having((e) => e.column, 'column', 'doctor')
              .having(
                (e) => e.migration,
                'migration',
                'supabase/migrations/x.sql',
              ),
        ),
      );
    });
  });

  group('RemoteMeta', () {
    test('reads the bookkeeping of a row', () {
      final meta = RemoteMeta.fromJson({
        'sync_xid': 812,
        'row_version': 3,
        'write_id': 'w1',
        'edited_at': '2026-03-05T09:00:00+00:00',
        'updated_at': '2026-03-05T09:00:01+00:00',
      });
      expect(meta.syncXid, 812);
      expect(meta.rowVersion, 3);
      expect(meta.writeId, 'w1');
      expect(meta.editedAt, DateTime.utc(2026, 3, 5, 9));
      expect(meta.effectiveEditedAt, DateTime.utc(2026, 3, 5, 9));
    });

    test('a row from before the migration falls back to updated_at', () {
      final meta = RemoteMeta.fromJson({
        'sync_xid': 0,
        'row_version': 1,
        'updated_at': '2026-01-01T00:00:00+00:00',
      });
      expect(meta.editedAt, isNull);
      expect(meta.effectiveEditedAt, DateTime.utc(2026));
    });
  });

  group('PullKey', () {
    test('round-trips through storage', () {
      expect(
        PullKey.fromStorage(const PullKey(812, 'a|b').toStorage()),
        const PullKey(812, 'a|b'),
      );
      expect(
        PullKey.fromStorage(const PullKey(900).toStorage()),
        const PullKey(900),
      );
      expect(PullKey.fromStorage('2026-03-05T09:00:00.000Z'), isNull);
      expect(PullKey.fromStorage(null), isNull);
    });
  });

  group('SyncStateRemoteDatasource', () {
    test('reads the horizon', () async {
      final state = await SyncStateRemoteDatasource(
        answering({'schema': 2, 'horizon': 4711}),
      ).read();
      expect(state.schema, 2);
      expect(state.horizon, 4711);
      expect(seen.single.method, 'POST');
      expect(sent(0), 'http://supabase.test/rest/v1/rpc/medora_sync_state');
    });

    for (final code in ['PGRST202', '42883']) {
      test('a missing function ($code) names the migration', () async {
        await expectLater(
          SyncStateRemoteDatasource(
            answering({
              'code': code,
              'message': 'no such function',
            }, status: 404),
          ).read(),
          throwsA(
            isA<MissingMigrationException>()
                .having((e) => e.migration, 'migration', syncV2Migration)
                .having(
                  (e) => '$e',
                  'text',
                  contains('supabase/migrations/20260918000000_sync_v2.sql'),
                ),
          ),
        );
      });
    }

    test('an older schema is a missing migration too', () async {
      await expectLater(
        SyncStateRemoteDatasource(
          answering({'schema': 1, 'horizon': 5}),
        ).read(),
        throwsA(isA<MissingMigrationException>()),
      );
    });

    test('any other error passes through', () async {
      await expectLater(
        SyncStateRemoteDatasource(
          answering({'code': '500', 'message': 'boom'}, status: 500),
        ).read(),
        throwsA(isA<PostgrestException>()),
      );
    });
  });

  group('PostgrestStockRemote', () {
    test('sends one change and reads the answer', () async {
      final result =
          await PostgrestStockRemote(
            answering({'status': 'applied', 'quantity': 3, 'row_version': 2}),
          ).apply(
            StockOp(
              opId: 'op1',
              medicationId: 'm1',
              delta: -1,
              createdAt: DateTime.utc(2026),
            ),
          );
      expect(sent(0), 'http://supabase.test/rest/v1/rpc/apply_stock_change');
      expect(jsonDecode(seen.single.body), {
        'p_op_id': 'op1',
        'p_medication_id': 'm1',
        'p_delta': -1,
        'p_set_to': null,
      });
      expect(result.status, StockChangeStatus.applied);
      expect(result.quantity, 3);
      expect(result.rowVersion, 2);
    });
  });
}
```

Create `test/data/datasources/stock_outbox_local_datasource_test.dart` (Task 4 adds a second group):

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/data/datasources/stock_outbox_local_datasource.dart';

StockOp _op(String id, {int? delta, int? setTo, int minute = 0}) => StockOp(
  opId: id,
  medicationId: 'm1',
  delta: delta,
  setTo: setTo,
  createdAt: DateTime.utc(2026, 3, 5, 8, minute),
);

void main() {
  group('applyStockOps', () {
    test('applies changes in order and clamps like the server', () {
      expect(applyStockOps(10, const []), 10);
      expect(applyStockOps(10, [_op('a', delta: -1), _op('b', delta: -1)]), 8);
      expect(applyStockOps(1, [_op('a', delta: -3)]), 0);
      expect(
        applyStockOps(10, [
          _op('a', delta: -1),
          _op('b', setTo: 20),
          _op('c', delta: -2),
        ]),
        18,
      );
      expect(applyStockOps(999998, [_op('a', delta: 5)]), maxStock);
    });

    test('a change is a delta or a count, never both', () {
      expect(
        () => _op('x', delta: 1, setTo: 1),
        throwsA(isA<AssertionError>()),
      );
    });

    test('a change round-trips through its row', () {
      final op = _op('a', delta: -2, minute: 7);
      final back = StockOp.fromRow(op.toRow());
      expect(
        [back.opId, back.medicationId, back.delta, back.setTo, back.createdAt],
        ['a', 'm1', -2, null, DateTime.utc(2026, 3, 5, 8, 7)],
      );
    });
  });
}
```

Create `test/helpers/fake_server_test.dart`:

```dart
/// The fake server keeps the rules of `20260918000000_sync_v2.sql`; these
/// mirror `tools/sql/sync_v2_checks.sql`, so a fake that drifts from the
/// migration fails here.
library;

import 'package:flutter_test/flutter_test.dart';

import 'fake_server.dart';

void main() {
  late DateTime now;
  late FakeServerCore core;

  setUp(() {
    now = DateTime.utc(2026, 9, 16, 12);
    core = FakeServerCore(() => now);
  });

  Map<String, dynamic> med() => core.rowsOf('medications')['m1']!;

  test('a 0.3.0 insert gets version 1, no write id, its own edit time and '
      'an arrival stamp', () {
    core.legacyUpsert('medications', {
      'id': 'm1',
      'name': 'Ibuprofen',
      'quantity': 10,
      'updated_at': '2026-09-01T08:00:00.000Z',
    });
    expect(med()['row_version'], 1);
    expect(med()['write_id'], isNull);
    expect(med()['edited_at'], '2026-09-01T08:00:00.000Z');
    expect(med()['updated_at'], '2026-09-16T12:00:00.000Z');
    expect(med()['sync_xid'], greaterThanOrEqualTo(1000));
  });

  test('a 0.3.0 update counts as made on arrival and clears the write id', () {
    core.legacyUpsert('medications', {'id': 'm1', 'name': 'Ibu'});
    core.patch('medications', 'm1', {'write_id': 'w1', 'notes': 'x'});
    now = now.add(const Duration(minutes: 5));
    core.legacyUpsert('medications', {'id': 'm1', 'name': 'Ibuprofen'});
    expect(med()['row_version'], 3);
    expect(med()['write_id'], isNull);
    expect(med()['edited_at'], '2026-09-16T12:05:00.000Z');
    expect(med()['updated_at'], '2026-09-16T12:05:00.000Z');
  });

  test('a conditional update applies once; a replay matches nothing', () {
    core.legacyUpsert('medications', {'id': 'm1', 'name': 'Ibu'});
    final first = core.patch('medications', 'm1', {
      'notes': 'a',
      'write_id': 'w1',
      'edited_at': '2026-09-16T10:00:00.000Z',
    }, ifVersion: 1);
    expect(first!['row_version'], 2);
    expect(first['edited_at'], '2026-09-16T10:00:00.000Z');
    expect(
      core.patch('medications', 'm1', {'notes': 'a'}, ifVersion: 1),
      isNull,
    );
  });

  test(
    'a future edit time is capped at now; a repeated write id is cleared',
    () {
      core.legacyUpsert('medications', {'id': 'm1', 'name': 'Ibu'});
      core.patch('medications', 'm1', {
        'write_id': 'w2',
        'edited_at': '2099-01-01T00:00:00.000Z',
      });
      expect(med()['edited_at'], '2026-09-16T12:00:00.000Z');
      core.patch('medications', 'm1', {'notes': 'x', 'write_id': 'w2'});
      expect(med()['write_id'], isNull);
    },
  );

  test('an automatic change keeps updated_at; a real one moves it', () {
    core.insertIfAbsent('dose_logs', [
      {
        'id': 'd1',
        'status': 'pending',
        'updated_at': '1970-01-01T00:00:00.000Z',
        'write_id': 'gen',
        'edited_at': '1970-01-01T00:00:00.000Z',
      },
    ]);
    Map<String, dynamic> dose() => core.rowsOf('dose_logs')['d1']!;
    expect(dose()['updated_at'], '1970-01-01T00:00:00.000Z');
    core.patch('dose_logs', 'd1', {
      'status': 'missed',
      'write_id': 'auto',
      'edited_at': '1970-01-01T00:00:00.001Z',
    }, ifVersion: 1);
    expect(dose()['updated_at'], '1970-01-01T00:00:00.000Z');
    expect(dose()['edited_at'], '1970-01-01T00:00:00.000Z');
    core.patch('dose_logs', 'd1', {
      'status': 'taken',
      'write_id': 'real',
      'edited_at': '2026-09-16T11:59:00.000Z',
    }, ifVersion: 2);
    expect(dose()['updated_at'], '2026-09-16T12:00:00.000Z');
    expect(
      core.patch(
        'dose_logs',
        'd1',
        {'deleted_at': 'x'},
        ifStatus: 'pending',
        ifLive: true,
      ),
      isNull,
      reason: 'a guarded delete skips a taken dose',
    );
  });

  test('the horizon holds back a transaction still open', () {
    final slow = core.begin();
    slow.insert('medications', {'id': 'slow', 'name': 'Slow'});
    core.legacyUpsert('medications', {'id': 'fast', 'name': 'Fast'});
    expect(core.page('medications', horizon: core.horizon), isEmpty);
    slow.commit();
    expect(
      core.page('medications', horizon: core.horizon).map((r) => r['id']),
      ['slow', 'fast'],
    );
  });

  test('stock: applied, duplicate, clamped, counted, missing, gone', () {
    core.legacyUpsert('medications', {
      'id': 'm1',
      'name': 'Ibu',
      'quantity': 10,
    });
    expect(core.applyStockChange(opId: 'a', medicationId: 'm1', delta: -3), {
      'status': 'applied',
      'quantity': 7,
      'row_version': 2,
    });
    expect(core.applyStockChange(opId: 'a', medicationId: 'm1', delta: -3), {
      'status': 'duplicate',
      'quantity': 7,
    });
    expect(
      core.applyStockChange(
        opId: 'b',
        medicationId: 'm1',
        delta: -100,
      )['quantity'],
      0,
    );
    expect(
      core.applyStockChange(
        opId: 'c',
        medicationId: 'm1',
        setTo: 20,
      )['quantity'],
      20,
    );
    expect(core.applyStockChange(opId: 'd', medicationId: 'nope', delta: -1), {
      'status': 'missing',
    });
    core.patch('medications', 'm1', {'deleted_at': '2026-09-16T12:00:00.000Z'});
    expect(core.applyStockChange(opId: 'e', medicationId: 'm1', delta: -1), {
      'status': 'gone',
    });
    expect(core.ledger.keys, ['a', 'b', 'c']);
    expect(
      () => core.applyStockChange(
        opId: 'f',
        medicationId: 'm1',
        delta: -1,
        setTo: 1,
      ),
      throwsArgumentError,
    );
  });

  test('a tombstone cascades to the children as a 0.3.0 write', () {
    core.legacyUpsert('treatments', {'id': 't1', 'name': 'Flu'});
    core.legacyUpsert('prescriptions', {'id': 'p1', 'treatment_id': 't1'});
    core.patch('treatments', 't1', {
      'deleted_at': '2026-09-16T12:00:00.000Z',
      'write_id': 'w',
    });
    final p = core.rowsOf('prescriptions')['p1']!;
    expect(p['deleted_at'], '2026-09-16T12:00:00.000Z');
    expect(p['write_id'], isNull);
    expect(p['row_version'], 2);
  });
}
```

Run: `fvm flutter test test/data/datasources/sync_table_test.dart test/data/datasources/stock_outbox_local_datasource_test.dart test/helpers/fake_server_test.dart`
Expected: FAIL to load (the libraries do not exist).

- [ ] **Step 6: The client classes**

Create `lib/data/datasources/sync_page.dart`:

```dart
/// Medora - One page of a delta pull (sync v2).
///
/// Every synced row carries `sync_xid`, the id of the transaction that last
/// wrote it (migration 20260918000000). A pull asks the server for its
/// horizon first (`medora_sync_state`): every transaction below it has
/// finished, so every row with `sync_xid < horizon` that will ever be
/// visible is visible now. A pull then reads `[its key, horizon)` in pages,
/// ordered by `sync_xid` and then `id`, and a row committed late is never
/// skipped: its transaction id keeps it above the horizon until it commits.
///
/// A hosted Supabase project answers at most 1000 rows per request and says
/// nothing when it cut an answer short, so a page shorter than
/// [pullPageSize] is the last one.
library;

import 'package:supabase_flutter/supabase_flutter.dart';

/// The most rows one pull request asks for.
const pullPageSize = 1000;

/// Where a pull continues: after the row `(xid, id)`, or, with no [id],
/// from the first row whose `sync_xid` is at least [xid].
class PullKey {
  const PullKey(this.xid, [this.id]);

  /// Parses [toStorage]'s output; null for anything else.
  static PullKey? fromStorage(String? raw) {
    if (raw == null) return null;
    final bar = raw.indexOf('|');
    if (bar < 0) return null;
    final xid = int.tryParse(raw.substring(0, bar));
    if (xid == null) return null;
    final id = raw.substring(bar + 1);
    return PullKey(xid, id.isEmpty ? null : id);
  }

  final int xid;
  final String? id;

  String toStorage() => '$xid|${id ?? ''}';

  @override
  bool operator ==(Object other) =>
      other is PullKey && other.xid == xid && other.id == id;

  @override
  int get hashCode => Object.hash(xid, id);

  @override
  String toString() => 'PullKey($xid, $id)';
}

/// [query] narrowed to one page: rows below [horizon] that come after
/// [after] (from the start when null), in `sync_xid, id` order, at most
/// [limit] of them.
PostgrestTransformBuilder<PostgrestList> pullPage(
  PostgrestFilterBuilder<PostgrestList> query, {
  required PullKey? after,
  required int horizon,
  int limit = pullPageSize,
}) {
  var filtered = query.lt('sync_xid', horizon);
  if (after != null) {
    final id = after.id;
    filtered = id == null
        ? filtered.gte('sync_xid', after.xid)
        : filtered.or(
            'sync_xid.gt.${after.xid},'
            'and(sync_xid.eq.${after.xid},id.gt.${_quoted(id)})',
          );
  }
  return filtered
      .order('sync_xid', ascending: true)
      .order('id', ascending: true)
      .limit(limit);
}

/// [value] as a double-quoted PostgREST filter value, so the dots, colons,
/// commas and parentheses it may hold are not read as syntax.
String _quoted(String value) =>
    '"${value.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';
```

Create `lib/data/datasources/sync_table.dart`:

```dart
/// Medora - The server side of one synced table (sync v2).
///
/// The four synced tables (medications, treatments, prescriptions, dose
/// logs) are read and written the same way, so one class does it for each.
/// The rows go in and out as JSON maps: the model's `toJson` keys plus the
/// server's bookkeeping ([RemoteMeta]).
library;

import 'package:medora/data/datasources/schema_errors.dart';
import 'package:medora/data/datasources/sync_page.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// The server's bookkeeping on a synced row (migration 20260918000000).
class RemoteMeta {
  const RemoteMeta({
    required this.syncXid,
    required this.rowVersion,
    this.writeId,
    this.editedAt,
    this.updatedAt,
    this.deletedAt,
  });

  factory RemoteMeta.fromJson(Map<String, dynamic> json) => RemoteMeta(
    syncXid: (json['sync_xid'] as num?)?.toInt() ?? 0,
    rowVersion: (json['row_version'] as num?)?.toInt() ?? 1,
    writeId: json['write_id'] as String?,
    editedAt: _time(json['edited_at']),
    updatedAt: _time(json['updated_at']),
    deletedAt: _time(json['deleted_at']),
  );

  final int syncXid;
  final int rowVersion;

  /// The write attempt that produced this copy; null for a writer that sends
  /// none (Medora 0.3.0, the tombstone cascade).
  final String? writeId;

  /// When the change was made; 1970 for a change the app made on its own.
  /// Null only for rows untouched since the migration: read [updatedAt].
  final DateTime? editedAt;
  final DateTime? updatedAt;
  final DateTime? deletedAt;

  /// [editedAt], or [updatedAt] for a row from before the migration.
  DateTime? get effectiveEditedAt => editedAt ?? updatedAt;

  static DateTime? _time(Object? raw) =>
      raw is String ? DateTime.tryParse(raw)?.toUtc() : null;
}

/// One synced table on the server.
abstract interface class SyncTable {
  /// One page of rows below [horizon] after [after] (see `pullPage`),
  /// tombstones included.
  Future<List<Map<String, dynamic>>> page({
    required PullKey? after,
    required int horizon,
  });

  /// The row with [id], tombstone included, or null.
  Future<Map<String, dynamic>?> fetch(String id);

  /// The rows with these [ids]; ids the server lacks are absent.
  Future<List<Map<String, dynamic>>> fetchMany(List<String> ids);

  /// Updates the row [id] with [changes] when it is still at [ifVersion]
  /// (any version when null), `status` equals [ifStatus] (when set) and,
  /// with [ifLive], it is not deleted. Returns the row as written, or null
  /// when no row matched.
  Future<Map<String, dynamic>?> patch(
    String id,
    Map<String, Object?> changes, {
    int? ifVersion,
    String? ifStatus,
    bool ifLive = false,
  });

  /// Inserts [rows], leaving every id the server already has untouched
  /// (`ON CONFLICT (id) DO NOTHING`). Every row must have the same keys.
  Future<void> insertIfAbsent(List<Map<String, Object?>> rows);
}

/// [SyncTable] over PostgREST.
class PostgrestSyncTable implements SyncTable {
  /// [select] must start with `*`, so the bookkeeping columns come along.
  /// A write the server refuses for a column it lacks becomes a
  /// [MissingColumnException] naming [migration] ([fallbackColumn] when the
  /// server names none).
  PostgrestSyncTable(
    this._client,
    this.table, {
    String select = '*',
    this.migration,
    this.fallbackColumn,
  }) : assert(select.startsWith('*'), 'select must include every column'),
       _select = select;

  final SupabaseClient _client;
  final String table;
  final String _select;
  final String? migration;
  final String? fallbackColumn;

  Future<T> _write<T>(Future<T> Function() send) {
    final file = migration;
    if (file == null) return send();
    return mapMissingColumn(
      send,
      table: table,
      migration: file,
      fallbackColumn: fallbackColumn ?? 'id',
    );
  }

  @override
  Future<List<Map<String, dynamic>>> page({
    required PullKey? after,
    required int horizon,
  }) async => pullPage(
    _client.from(table).select(_select),
    after: after,
    horizon: horizon,
  );

  @override
  Future<Map<String, dynamic>?> fetch(String id) =>
      _client.from(table).select(_select).eq('id', id).maybeSingle();

  @override
  Future<List<Map<String, dynamic>>> fetchMany(List<String> ids) async {
    if (ids.isEmpty) return const [];
    return _client.from(table).select(_select).inFilter('id', ids);
  }

  @override
  Future<Map<String, dynamic>?> patch(
    String id,
    Map<String, Object?> changes, {
    int? ifVersion,
    String? ifStatus,
    bool ifLive = false,
  }) async {
    return _write(() async {
      var query = _client.from(table).update(changes).eq('id', id);
      if (ifVersion != null) query = query.eq('row_version', ifVersion);
      if (ifStatus != null) query = query.eq('status', ifStatus);
      if (ifLive) query = query.isFilter('deleted_at', null);
      final rows = await query.select(_select);
      return rows.isEmpty ? null : rows.first;
    });
  }

  @override
  Future<void> insertIfAbsent(List<Map<String, Object?>> rows) async {
    if (rows.isEmpty) return;
    await _write(
      () => _client
          .from(table)
          .upsert(rows, onConflict: 'id', ignoreDuplicates: true),
    );
  }
}
```

Create `lib/data/datasources/stock_outbox_local_datasource.dart`:

```dart
/// Medora - Stock changes waiting to reach the server (sync v2).
///
/// A stock change is sent as a change, never as the new total: a delta (a
/// dose taken, a pack added, an undo) or a counted quantity typed into the
/// form. Each carries an id; the server applies an id once
/// (`apply_stock_change`), so a retry after a lost answer never counts it
/// twice, and changes from two devices both apply.
library;

/// One stock change: exactly one of [delta] and [setTo].
class StockOp {
  const StockOp({
    required this.opId,
    required this.medicationId,
    this.delta,
    this.setTo,
    required this.createdAt,
  }) : assert((delta == null) != (setTo == null), 'one kind per change');

  factory StockOp.fromRow(Map<String, Object?> row) => StockOp(
    opId: row['op_id']! as String,
    medicationId: row['medication_id']! as String,
    delta: row['delta'] as int?,
    setTo: row['set_to'] as int?,
    createdAt: DateTime.parse(row['created_at']! as String),
  );

  final String opId;
  final String medicationId;
  final int? delta;
  final int? setTo;
  final DateTime createdAt;

  Map<String, Object?> toRow() => {
    'op_id': opId,
    'medication_id': medicationId,
    'delta': delta,
    'set_to': setTo,
    'created_at': createdAt.toUtc().toIso8601String(),
  };
}

/// The largest stock the app stores.
const maxStock = 999999;

/// [quantity] after [ops], in order, clamped like the server clamps.
int applyStockOps(int quantity, Iterable<StockOp> ops) {
  var q = quantity;
  for (final op in ops) {
    q = (op.setTo ?? q + op.delta!).clamp(0, maxStock);
  }
  return q;
}
```

Create `lib/data/datasources/stock_remote.dart`:

```dart
/// Medora - Stock changes on the server (`apply_stock_change`, sync v2).
library;

import 'package:medora/data/datasources/stock_outbox_local_datasource.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

enum StockChangeStatus {
  /// Applied now.
  applied,

  /// This op id was applied before (a retry after a lost answer).
  duplicate,

  /// The medication is deleted: drop the change.
  gone,

  /// No such medication on the server yet: keep the change.
  missing,
}

class StockChangeResult {
  const StockChangeResult(this.status, {this.quantity, this.rowVersion});

  factory StockChangeResult.fromJson(Map<String, dynamic> json) =>
      StockChangeResult(
        StockChangeStatus.values.byName(json['status']! as String),
        quantity: (json['quantity'] as num?)?.toInt(),
        rowVersion: (json['row_version'] as num?)?.toInt(),
      );

  final StockChangeStatus status;

  /// The quantity right after the change ([StockChangeStatus.applied],
  /// [StockChangeStatus.duplicate]).
  final int? quantity;

  /// The medication's `row_version` after the change (applied only).
  final int? rowVersion;
}

abstract interface class StockRemote {
  Future<StockChangeResult> apply(StockOp op);
}

class PostgrestStockRemote implements StockRemote {
  PostgrestStockRemote(this._client);

  final SupabaseClient _client;

  @override
  Future<StockChangeResult> apply(StockOp op) async {
    final raw = await _client.rpc<dynamic>(
      'apply_stock_change',
      params: {
        'p_op_id': op.opId,
        'p_medication_id': op.medicationId,
        'p_delta': op.delta,
        'p_set_to': op.setTo,
      },
    );
    return StockChangeResult.fromJson(raw as Map<String, dynamic>);
  }
}
```

Create `lib/data/datasources/sync_state_remote_datasource.dart`:

```dart
/// Medora - What the server says about sync itself (sync v2).
library;

import 'package:medora/data/datasources/schema_errors.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// The migration this build needs (see `docs/architecture.md`, Sync).
const syncV2Migration = 'supabase/migrations/20260918000000_sync_v2.sql';

/// The sync schema this build speaks.
const requiredSyncSchema = 2;

/// One answer of `medora_sync_state()`.
class SyncServerState {
  const SyncServerState({required this.schema, required this.horizon});

  final int schema;

  /// Every transaction below this id has finished (see `pullPage`).
  final int horizon;
}

class SyncStateRemoteDatasource {
  SyncStateRemoteDatasource(this._client);

  final SupabaseClient _client;

  /// The server's sync state. Throws [MissingMigrationException] when the
  /// project lacks [syncV2Migration]; any other error passes through.
  Future<SyncServerState> read() async {
    final Object? raw;
    try {
      raw = await _client.rpc<dynamic>('medora_sync_state');
    } on PostgrestException catch (e) {
      if (isMissingFunction(e)) {
        throw MissingMigrationException(migration: syncV2Migration, cause: e);
      }
      rethrow;
    }
    return parseSyncState(raw);
  }
}

/// PostgREST `PGRST202` (not in the schema cache) or Postgres `42883`
/// (undefined function).
bool isMissingFunction(PostgrestException e) =>
    e.code == 'PGRST202' || e.code == '42883';

/// [raw] read as a sync state; a missing or older schema is a
/// [MissingMigrationException].
SyncServerState parseSyncState(Object? raw) {
  if (raw is! Map) {
    throw const MissingMigrationException(migration: syncV2Migration);
  }
  final schema = (raw['schema'] as num?)?.toInt() ?? 0;
  final horizon = (raw['horizon'] as num?)?.toInt();
  if (schema < requiredSyncSchema || horizon == null) {
    throw MissingMigrationException(migration: syncV2Migration, cause: raw);
  }
  return SyncServerState(schema: schema, horizon: horizon);
}
```

Append to `lib/data/datasources/schema_errors.dart`:

```dart
/// A Supabase project without the sync v2 migration ([migration]): it has
/// no `medora_sync_state` function, or one that reports an older schema.
/// The sync cycle stops before it writes anything.
class MissingMigrationException implements Exception {
  const MissingMigrationException({required this.migration, this.cause});

  /// The migration file to apply, relative to the repository root.
  final String migration;

  /// The server's answer, when there was one.
  final Object? cause;

  @override
  String toString() =>
      'The Supabase project is missing the sync v2 migration. '
      'Apply $migration to the project, then sync again'
      '${cause is PostgrestException ? ' (server: ${(cause! as PostgrestException).message})' : ''}.';
}
```

- [ ] **Step 7: The four remote datasources gain `rows`**

Keep every existing method, because the sync cycle still uses them until Task 6. Change only the constructors and add the fields. Keep each file's imports sorted.

`medication_remote_datasource.dart`: replace `MedicationRemoteDatasource(this._client);` with

```dart
  MedicationRemoteDatasource(SupabaseClient client)
    : _client = client,
      rows = PostgrestSyncTable(
        client,
        AppConstants.medicationsTable,
        migration: medicationEanMigration,
        fallbackColumn: 'ean',
      ),
      stock = PostgrestStockRemote(client);

  /// The `medications` rows (sync v2).
  final SyncTable rows;

  /// `apply_stock_change` (sync v2).
  final StockRemote stock;
```

It also needs `import 'package:medora/data/datasources/stock_remote.dart';` and `import 'package:medora/data/datasources/sync_table.dart';`.

`treatment_remote_datasource.dart`: replace `TreatmentRemoteDatasource(this._client);` with

```dart
  TreatmentRemoteDatasource(SupabaseClient client)
    : _client = client,
      rows = PostgrestSyncTable(
        client,
        AppConstants.treatmentsTable,
        migration: treatmentSickLeaveMigration,
        fallbackColumn: 'sick_leave_from',
      );

  /// The `treatments` rows (sync v2).
  final SyncTable rows;
```

`prescription_remote_datasource.dart`: replace `PrescriptionRemoteDatasource(this._client);` with

```dart
  PrescriptionRemoteDatasource(SupabaseClient client)
    : _client = client,
      rows = PostgrestSyncTable(
        client,
        AppConstants.prescriptionsTable,
        select: '*, medications(name), treatments(name)',
      );

  /// The `prescriptions` rows (sync v2).
  final SyncTable rows;
```

`dose_log_remote_datasource.dart`: replace `DoseLogRemoteDatasource(this._client);` with

```dart
  DoseLogRemoteDatasource(SupabaseClient client)
    : _client = client,
      rows = PostgrestSyncTable(
        client,
        AppConstants.doseLogsTable,
        select: '*, prescriptions(id, medications(name))',
      );

  /// The `dose_logs` rows (sync v2).
  final SyncTable rows;
```

The prescription and dose-log files also need `import 'package:medora/data/datasources/sync_table.dart';`, and so does the treatment file.

`test/helpers/fake_remotes.dart` implements these classes, so its four fakes need the new members now. Add to each (the same `FakeRemoteTable`-backed fakes stay; this is only to compile — Task 6 replaces the file):

```dart
  @override
  SyncTable get rows => throw UnimplementedError('sync v2: Task 6');
```

and to `FakeMedicationRemote` also:

```dart
  @override
  StockRemote get stock => throw UnimplementedError('sync v2: Task 6');
```

Import `sync_table.dart` and `stock_remote.dart` there.

- [ ] **Step 8: The fake server**

Create `test/helpers/fake_server.dart`:

```dart
/// A fake Supabase server that behaves like the migrations up to
/// `20260918000000_sync_v2.sql`: one xid per request, a horizon held back
/// by transactions still open, `row_version`, the write-id rule, edit-time
/// normalisation, the `updated_at` rules, guarded updates, the tombstone
/// cascade, the stock ledger and a 1000-row answer cap.
///
/// The Dart-level fakes (`fake_remotes.dart`) and the HTTP fake
/// (`fake_postgrest.dart`) are both views of one [FakeServerCore], so the
/// server rules live in one place. Keep it in step with
/// `tools/sql/sync_v2_checks.sql`.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:medora/data/datasources/stock_outbox_local_datasource.dart';
import 'package:medora/data/datasources/stock_remote.dart';
import 'package:medora/data/datasources/sync_page.dart';
import 'package:medora/data/datasources/sync_table.dart';

final _weakCeiling = DateTime.utc(1970, 1, 2);
final _epoch = DateTime.utc(1970);

String _iso(DateTime t) => t.toUtc().toIso8601String();
DateTime? _time(Object? raw) =>
    raw is String ? DateTime.tryParse(raw)?.toUtc() : null;

/// The children each parent's tombstone cascades to.
const _cascade = {
  'treatments': ('prescriptions', 'treatment_id'),
  'medications': ('prescriptions', 'medication_id'),
  'prescriptions': ('dose_logs', 'prescription_id'),
};

class FakeServerCore {
  FakeServerCore(this.clock);

  /// The server's `now()`.
  final DateTime Function() clock;

  int _nextXid = 1000;
  final Set<int> _open = {};

  /// Committed rows per table, by id.
  final Map<String, Map<String, Map<String, dynamic>>> tables = {};

  /// The stock ledger: op id → the quantity after it was applied.
  final Map<String, ({String medicationId, int quantityAfter})> ledger = {};

  /// Every request answered, in order (`table:verb`), for request counts.
  final List<String> requests = [];

  /// The most rows one fetch answers (PostgREST `max_rows`).
  int rowCap = 1000;

  Map<String, Map<String, dynamic>> rowsOf(String table) =>
      tables.putIfAbsent(table, () => {});

  /// `medora_sync_state()['horizon']`.
  int get horizon => _open.isEmpty ? _nextXid : _open.reduce(math.min);

  /// Starts a request that commits only when [FakeTransaction.commit] is
  /// called: its rows stay invisible and it holds the horizon back.
  FakeTransaction begin() {
    final xid = _nextXid++;
    _open.add(xid);
    return FakeTransaction._(this, xid);
  }

  T _request<T>(String what, T Function(int xid) body) {
    requests.add(what);
    return body(_nextXid++);
  }

  // ── The trigger ────────────────────────────────────────────

  Map<String, dynamic> _stamp(
    Map<String, dynamic>? old,
    Map<String, dynamic> row,
    int xid,
  ) {
    final now = clock().toUtc();
    row['sync_xid'] = xid;
    var edited = _time(row['edited_at']);
    if (old == null) {
      row['row_version'] = 1;
      edited ??= _time(row['updated_at']) ?? now;
    } else {
      row['row_version'] = (old['row_version'] as int? ?? 1) + 1;
      final writeId = row['write_id'];
      if (writeId == null || writeId == old['write_id']) {
        row['write_id'] = null;
        edited = now;
      } else {
        edited ??= _time(old['updated_at']) ?? now;
      }
    }
    final weak = edited.isBefore(_weakCeiling);
    edited = weak ? _epoch : (edited.isAfter(now) ? now : edited);
    row['edited_at'] = _iso(edited);
    if (old == null) {
      if (!weak) {
        row['updated_at'] = _iso(now);
      } else if (!row.containsKey('updated_at')) {
        row['updated_at'] = _iso(now);
      }
    } else {
      row['updated_at'] = row['write_id'] != null && weak
          ? old['updated_at']
          : _iso(now);
    }
    return row;
  }

  // ── Requests ───────────────────────────────────────────────

  /// `insert … on conflict (id) do nothing`, one transaction.
  int insertIfAbsent(String table, List<Map<String, dynamic>> jsons) =>
      _request('$table:insert', (xid) => _insert(table, jsons, xid));

  int _insert(String table, List<Map<String, dynamic>> jsons, int xid) {
    final rows = rowsOf(table);
    var inserted = 0;
    for (final json in jsons) {
      final id = json['id'] as String;
      if (rows.containsKey(id)) continue;
      rows[id] = _stamp(null, {
        'created_at': _iso(clock()),
        'deleted_at': null,
        'write_id': null,
        ...json,
      }, xid);
      inserted++;
    }
    return inserted;
  }

  /// `update … where id = [id] [and row_version = ifVersion] [and status =
  /// ifStatus] [and deleted_at is null] returning *`.
  Map<String, dynamic>? patch(
    String table,
    String id,
    Map<String, dynamic> changes, {
    int? ifVersion,
    String? ifStatus,
    bool ifLive = false,
  }) => _request('$table:patch', (xid) {
    final old = rowsOf(table)[id];
    if (old == null) return null;
    if (ifVersion != null && old['row_version'] != ifVersion) return null;
    if (ifStatus != null && old['status'] != ifStatus) return null;
    if (ifLive && old['deleted_at'] != null) return null;
    return _update(table, old, changes, xid);
  });

  Map<String, dynamic> _update(
    String table,
    Map<String, dynamic> old,
    Map<String, dynamic> changes,
    int xid,
  ) {
    final id = old['id'] as String;
    final row = _stamp(old, {
      ...old,
      // A client that sends no write id leaves the column as it was; the
      // trigger then clears it.
      'write_id': old['write_id'],
      ...changes,
    }, xid);
    rowsOf(table)[id] = row;
    final child = _cascade[table];
    if (child != null &&
        old['deleted_at'] == null &&
        row['deleted_at'] != null) {
      for (final c in rowsOf(child.$1).values.toList()) {
        if (c[child.$2] == id && c['deleted_at'] == null) {
          _update(child.$1, c, {'deleted_at': row['deleted_at']}, xid);
        }
      }
    }
    return Map.of(row);
  }

  /// What Medora 0.3.0 sends: `upsert(toJson())`, no write id, no edit
  /// time; only the payload's columns are set on conflict.
  Map<String, dynamic> legacyUpsert(String table, Map<String, dynamic> json) =>
      _request('$table:legacy', (xid) {
        final old = rowsOf(table)[json['id']];
        if (old == null) {
          _insert(table, [json], xid);
          return Map.of(rowsOf(table)[json['id']]!);
        }
        return _update(table, old, {...json}..remove('write_id'), xid);
      });

  /// One page of a delta pull (`pullPage`).
  List<Map<String, dynamic>> page(
    String table, {
    required int horizon,
    int? afterXid,
    String? afterId,
    int limit = 1000,
  }) {
    requests.add('$table:page');
    final matching = [
      for (final r in rowsOf(table).values)
        if ((r['sync_xid'] as int) < horizon &&
            (afterXid == null ||
                (afterId == null
                    ? (r['sync_xid'] as int) >= afterXid
                    : _after(r, afterXid, afterId))))
          Map<String, dynamic>.of(r),
    ]..sort(_byKey);
    return matching.take(math.min(limit, rowCap)).toList();
  }

  static bool _after(Map<String, dynamic> r, int xid, String id) {
    final x = r['sync_xid'] as int;
    return x > xid || (x == xid && (r['id'] as String).compareTo(id) > 0);
  }

  static int _byKey(Map<String, dynamic> a, Map<String, dynamic> b) {
    final byXid = (a['sync_xid'] as int).compareTo(b['sync_xid'] as int);
    return byXid != 0
        ? byXid
        : (a['id'] as String).compareTo(b['id'] as String);
  }

  Map<String, dynamic>? fetch(String table, String id) {
    requests.add('$table:fetch');
    final row = rowsOf(table)[id];
    return row == null ? null : Map.of(row);
  }

  /// `apply_stock_change(...)`.
  Map<String, dynamic> applyStockChange({
    required String opId,
    required String medicationId,
    int? delta,
    int? setTo,
  }) => _request('rpc:apply_stock_change', (xid) {
    if ((delta == null) == (setTo == null)) {
      throw ArgumentError('pass exactly one of delta and setTo');
    }
    final done = ledger[opId];
    if (done != null) {
      return {'status': 'duplicate', 'quantity': done.quantityAfter};
    }
    final med = rowsOf('medications')[medicationId];
    if (med == null) return {'status': 'missing'};
    if (med['deleted_at'] != null) return {'status': 'gone'};
    final current = (med['quantity'] as num?)?.toInt() ?? 0;
    final next = (setTo ?? current + delta!).clamp(0, 999999);
    final row = _update('medications', med, {
      'quantity': next,
      'write_id': opId,
    }, xid);
    ledger[opId] = (medicationId: medicationId, quantityAfter: next);
    return {
      'status': 'applied',
      'quantity': next,
      'row_version': row['row_version'],
    };
  });

  /// `medora_sync_state()`.
  Map<String, dynamic> syncState() {
    requests.add('rpc:medora_sync_state');
    return {'schema': 2, 'horizon': horizon};
  }
}

/// A request whose transaction is still open ([FakeServerCore.begin]).
class FakeTransaction {
  FakeTransaction._(this._core, this.xid);

  final FakeServerCore _core;
  final int xid;
  final List<void Function()> _writes = [];

  /// A 0.3.0-style insert that lands when [commit] is called.
  void insert(String table, Map<String, dynamic> json) =>
      _writes.add(() => _core._insert(table, [json], xid));

  void commit() {
    for (final w in _writes) {
      w();
    }
    _core._open.remove(xid);
  }
}

/// [SyncTable] over [FakeServerCore], with the failure knobs the sync tests
/// use.
class FakeSyncTable implements SyncTable {
  FakeSyncTable(this.core, this.table);

  final FakeServerCore core;
  final String table;

  /// Ids whose writes throw, as a server that refuses them.
  final Set<String> failIds = {};

  /// Ids whose single-row fetch throws — a server that cannot be reached
  /// while the user is discarding a stuck row.
  final Set<String> failGetIds = {};

  /// When set, every page request throws it.
  Object? throwOnFetch;

  /// Awaited before every request; a test can hold a cycle open.
  Future<void> Function()? beforeCall;

  /// When set, a write to one of these ids lands but its answer is lost:
  /// the call throws after the server applied it.
  final Set<String> loseAnswerFor = {};

  /// Every page request: the key it asked from and the horizon.
  final List<({PullKey? after, int horizon})> pageCalls = [];

  /// The key of every page request, in order (null: from the start).
  List<PullKey?> get sinceCalls => [for (final c in pageCalls) c.after];

  /// Runs on every page request before it is answered ([call] counts from
  /// 1); a test can throw from it to fail one page.
  void Function(int call, PullKey? after)? onPage;

  /// The size of every insert request, in order.
  final List<int> insertBatches = [];

  Map<String, Map<String, dynamic>> get rows => core.rowsOf(table);

  void _guard(String id) {
    if (failIds.contains(id)) throw StateError('remote failure for $id');
  }

  void _maybeLose(String id) {
    if (loseAnswerFor.remove(id)) {
      throw TimeoutException('answer lost for $table/$id');
    }
  }

  @override
  Future<List<Map<String, dynamic>>> page({
    required PullKey? after,
    required int horizon,
  }) async {
    await beforeCall?.call();
    pageCalls.add((after: after, horizon: horizon));
    onPage?.call(pageCalls.length, after);
    final failure = throwOnFetch;
    if (failure != null) throw failure;
    return core.page(
      table,
      horizon: horizon,
      afterXid: after?.xid,
      afterId: after?.id,
    );
  }

  @override
  Future<Map<String, dynamic>?> fetch(String id) async {
    await beforeCall?.call();
    if (failGetIds.contains(id)) {
      throw StateError('remote get failure for $id');
    }
    return core.fetch(table, id);
  }

  @override
  Future<List<Map<String, dynamic>>> fetchMany(List<String> ids) async {
    await beforeCall?.call();
    return [for (final id in ids) ?core.fetch(table, id)];
  }

  @override
  Future<Map<String, dynamic>?> patch(
    String id,
    Map<String, Object?> changes, {
    int? ifVersion,
    String? ifStatus,
    bool ifLive = false,
  }) async {
    await beforeCall?.call();
    _guard(id);
    final written = core.patch(
      table,
      id,
      Map<String, dynamic>.of(changes),
      ifVersion: ifVersion,
      ifStatus: ifStatus,
      ifLive: ifLive,
    );
    _maybeLose(id);
    return written;
  }

  @override
  Future<void> insertIfAbsent(List<Map<String, Object?>> rows) async {
    await beforeCall?.call();
    for (final r in rows) {
      _guard(r['id']! as String);
    }
    insertBatches.add(rows.length);
    core.insertIfAbsent(table, [for (final r in rows) Map.of(r)]);
    for (final r in rows) {
      _maybeLose(r['id']! as String);
    }
  }

  // ── Test helpers ───────────────────────────────────────────

  /// Seeds a row as if a 0.3.0 device had written it before this test (no
  /// write id). [updatedAt] sets its `updated_at` and `edited_at`.
  Map<String, dynamic> seed(Map<String, dynamic> json, {DateTime? updatedAt}) {
    final row = core.legacyUpsert(table, json);
    if (updatedAt != null) {
      row['updated_at'] = _iso(updatedAt);
      row['edited_at'] = _iso(updatedAt);
      rows[row['id'] as String] = row;
    }
    return row;
  }

  /// Another 0.4.0 device's conditional-free update of [id].
  Map<String, dynamic>? editFromOtherDevice(
    String id,
    Map<String, dynamic> changes, {
    required DateTime editedAt,
  }) => core.patch(table, id, {
    ...changes,
    'write_id': 'other-${core.requests.length}',
    'edited_at': _iso(editedAt),
  });

  Map<String, dynamic>? get(String id) => rows[id];
}

/// [StockRemote] over [FakeServerCore].
class FakeStockRemote implements StockRemote {
  FakeStockRemote(this.core);

  final FakeServerCore core;

  /// How many of the next changes land with their answer lost.
  int loseNextAnswers = 0;

  @override
  Future<StockChangeResult> apply(StockOp op) async {
    final json = core.applyStockChange(
      opId: op.opId,
      medicationId: op.medicationId,
      delta: op.delta,
      setTo: op.setTo,
    );
    if (loseNextAnswers > 0) {
      loseNextAnswers--;
      throw TimeoutException('answer lost for stock change ${op.opId}');
    }
    return StockChangeResult.fromJson(json);
  }
}

extension FakeSyncTableLegacy on FakeSyncTable {
  /// A 0.3.0 device's whole-row upsert; returns the stored `updated_at`.
  Future<DateTime?> upsert(Map<String, dynamic> json) async {
    final row = core.legacyUpsert(table, json);
    return DateTime.tryParse(row['updated_at'] as String? ?? '')?.toUtc();
  }

  /// A 0.3.0 device's delete.
  void tombstone(String id) {
    if (rows[id] == null) return;
    core.patch(table, id, {'deleted_at': _iso(core.clock())});
  }

  /// A row removed by a server purge.
  void hardDelete(String id) => rows.remove(id);

  List<Map<String, dynamic>> all() => rows.values.map(Map.of).toList();

  List<Map<String, dynamic>> live() =>
      all().where((r) => r['deleted_at'] == null).toList();

  DateTime? updatedAt(String id) =>
      DateTime.tryParse(rows[id]?['updated_at'] as String? ?? '')?.toUtc();
}
```

- [ ] **Step 9: Run the tests**

Run: `fvm flutter test test/data/datasources/sync_table_test.dart test/data/datasources/stock_outbox_local_datasource_test.dart test/helpers/fake_server_test.dart`
Expected: `sync_table_test` +18, the stock tests +3 and `fake_server_test` +8, all passed.

Mutations (scratch worktree):
- `pullPage` without `.lt('sync_xid', horizon)` → `a first page…` fails.
- `FakeServerCore._stamp` without the `writeId == old['write_id']` clause → `a 0.3.0 update counts…` fails.
- `isMissingFunction` without `'42883'` → `a missing function (42883)…` fails.

- [ ] **Step 10: README and gates**

In `README.md` §"Optional: cloud sync with Supabase":
- "applies all four migrations" becomes "applies all five migrations";
- add `20260918000000_sync_v2.sql` to the paste-in-order list;
- add this bullet under "Apply every migration before an updated app syncs":

```markdown
   - `20260918000000_sync_v2.sql` adds the sync bookkeeping (`sync_xid`, `row_version`, `write_id`, `edited_at`), the `medora_sync_state` and `apply_stock_change` functions and the `stock_changes` ledger. Medora 0.4.0 does not sync at all without it (Settings names the file); Medora 0.3.0 keeps working with it. `tools/check_supabase_sql.sh` checks the migrations against a throwaway Postgres 15 (Docker), never against your project.
```

Run the gates. Commit in two commits:
- `feat(supabase): sync v2 migration with a server change cursor, row versions and a stock ledger`: the SQL, the tools, CI, README.
- `feat(sync): client and fake for the sync v2 server contract`: the Dart files.

---

## Task 4: Local schema v16, edit times on every local write, backups

**Why before the sync tasks:** a merge that compares edit times is only right once every local write records its time. The probe showed that without it a take loses to the other device's automatic "missed".

**Files:**
- Modify: `lib/data/local/migrations.dart` (append migration 16; `kSchemaVersion = 16`)
- Modify: `lib/data/local/app_database.dart` (`clearAllData` also empties `stock_outbox`)
- Modify: `lib/data/datasources/stock_outbox_local_datasource.dart` (append `StockOutboxLocalDatasource`)
- Modify: `lib/data/datasources/medication_local_datasource.dart`, `treatment_local_datasource.dart`, `prescription_local_datasource.dart`, `dose_log_local_datasource.dart`:
  - `_toRow` becomes `static rowOf`;
  - `edited_at` is stamped on every local write.
- Modify: `lib/services/backup_service.dart` (`localOnlyColumns`, restore clears the bookkeeping, merge compares instants)
- Modify: `lib/services/local_upload_marker.dart` (`markAllForUpload` clears the bookkeeping and the outbox)
- Modify: `lib/data/repositories/treatment_repository_impl.dart` (`updateTreatment` refuses a deleted row)
- Test: `test/data/local/app_database_test.dart`, `test/data/datasources/edit_time_test.dart` (new), `test/data/datasources/stock_outbox_local_datasource_test.dart`, `test/services/backup_service_test.dart`, `test/services/local_upload_marker_test.dart`, `test/data/repositories/treatment_repository_test.dart`

**Interfaces:**
- Consumes: `StockOp` (Task 3).
- Produces:
  - Local columns `edited_at`, `sync_version`, `sync_base`, `sync_write_id` on the four tables; `dose_logs.delete_guard`; table `stock_outbox`.
  - `static Map<String, dynamic> MedicationLocalDatasource.rowOf(MedicationModel, String syncStatus)`, and the same on `TreatmentLocalDatasource`, `PrescriptionLocalDatasource` and `DoseLogLocalDatasource` with their models.
  - `class StockOutboxLocalDatasource`:
    - `static const table = 'stock_outbox'`
    - `static Future<void> enqueue(DatabaseExecutor, StockOp)`
    - `Future<List<StockOp>> pending({String? medicationId})`
    - `static Future<List<StockOp>> pendingIn(DatabaseExecutor, {String? medicationId})`
    - `Future<bool> remove(String opId)`
    - `Future<void> clearAll()`
  - `static const Set<String> BackupService.localOnlyColumns`

- [ ] **Step 1: Tests first**

In `test/data/local/app_database_test.dart`:
- append `16` to every expected `appliedMigrations()` list (there are five: `[11, 12, 13, 14, 15]` → `[11, 12, 13, 14, 15, 16]`);
- in `clearAllData empties every table`, insert one `stock_outbox` row before the call and add `'stock_outbox'` to the checked tables;
- add these two tests before `clearAllData empties every table`:

```dart
  test('migration 16 adds the sync bookkeeping and the stock outbox', () async {
    final db = await AppDatabase.instance.database;
    for (final table in [
      'medications',
      'treatments',
      'prescriptions',
      'dose_logs',
    ]) {
      expect(
        await columnsOf(db, table),
        containsAll([
          'edited_at',
          'sync_version',
          'sync_base',
          'sync_write_id',
        ]),
        reason: table,
      );
    }
    expect(await columnsOf(db, 'dose_logs'), contains('delete_guard'));
    expect(
      await columnsOf(db, 'stock_outbox'),
      containsAll(['op_id', 'medication_id', 'delta', 'set_to', 'created_at']),
    );
    await db.insert('medications', {'id': 'm1', 'name': 'M', 'quantity': 1});
    await expectLater(
      db.insert('stock_outbox', {
        'op_id': 'both',
        'medication_id': 'm1',
        'delta': -1,
        'set_to': 3,
        'created_at': '2026-03-05T08:00:00.000Z',
      }),
      throwsA(isA<DatabaseException>()),
      reason: 'a change is a delta or a count, never both',
    );
  });

  test('upgrading a v15 database keeps the time of an edit still waiting '
      'to be pushed', () async {
    final dir = await Directory.systemTemp.createTemp('medora_mig16_');
    final path = p.join(dir.path, 'medora.db');
    final legacy = await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 15,
        onCreate: (db, _) async {
          await AppDatabase.createBaseSchema(db);
          for (final m in kMigrations.where((m) => m.version <= 15)) {
            await m.run(db);
          }
        },
      ),
    );
    await legacy.insert('medications', {
      'id': 'pending',
      'name': 'Edited',
      'quantity': 1,
      'updated_at': '2026-09-15T10:00:00.000',
      'sync_status': 'pending_update',
    });
    await legacy.insert('medications', {
      'id': 'synced',
      'name': 'Pulled',
      'quantity': 1,
      'updated_at': '2026-09-14T10:00:00.000',
      'sync_status': 'synced',
    });
    await legacy.close();

    AppDatabase.debugPathOverride = path;
    await AppDatabase.instance.reset();
    final upgraded = await AppDatabase.instance.database;
    final rows = {
      for (final r in await upgraded.query('medications')) r['id']: r,
    };
    expect(rows['pending']!['edited_at'], '2026-09-15T10:00:00.000');
    expect(rows['synced']!['edited_at'], isNull);
    expect(rows['pending']!['sync_version'], isNull);
    expect(await AppDatabase.instance.appliedMigrations(), [
      11,
      12,
      13,
      14,
      15,
      16,
    ]);
    await AppDatabase.instance.reset();
    await dir.delete(recursive: true);
  });
```

Create `test/data/datasources/edit_time_test.dart`:

```dart
/// Every local write stamps when it was made (`edited_at`), so a merge can
/// tell a person's change from an older one, and from the app's own
/// (1970). A row stored from the server is left to the sync cycle.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:medora/core/clock.dart';
import 'package:medora/data/datasources/dose_log_local_datasource.dart';
import 'package:medora/data/datasources/medication_local_datasource.dart';
import 'package:medora/data/datasources/prescription_local_datasource.dart';
import 'package:medora/data/datasources/treatment_local_datasource.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/models/dose_log_model.dart';
import 'package:medora/data/models/medication_model.dart';
import 'package:medora/data/models/treatment_model.dart';

import '../../helpers/seed.dart';
import '../../helpers/test_database.dart';

void main() {
  setUp(setUpTestDatabase);
  tearDown(tearDownTestDatabase);

  Future<Map<String, Object?>> row(String table, String id) async =>
      (await (await AppDatabase.instance.database).query(
        table,
        where: 'id = ?',
        whereArgs: [id],
      )).single;

  test('a pending upsert takes the model stamp; a synced one leaves the '
      'column alone', () async {
    final local = MedicationLocalDatasource();
    final at = DateTime(2026, 3, 5, 10);
    await local.upsert(
      MedicationModel(id: 'm1', name: 'Ibu', quantity: 1, updatedAt: at),
      syncStatus: SyncStatus.pendingUpdate,
    );
    expect((await row('medications', 'm1'))['edited_at'], at.toIso8601String());
    await local.upsert(
      MedicationModel(
        id: 'm1',
        name: 'Ibu',
        quantity: 1,
        updatedAt: DateTime(2026, 3, 5, 11),
      ),
      syncStatus: SyncStatus.synced,
    );
    expect((await row('medications', 'm1'))['edited_at'], at.toIso8601String());
  });

  test('archiving, a treatment edit and deletes stamp now', () async {
    final meds = MedicationLocalDatasource();
    await meds.upsert(
      const MedicationModel(id: 'm1', name: 'Ibu', quantity: 1),
      syncStatus: SyncStatus.synced,
    );
    final before = DateTime.now().subtract(const Duration(seconds: 1));
    await meds.archiveMedication('m1');
    final archived = (await row('medications', 'm1'))['edited_at']! as String;
    expect(DateTime.parse(archived).isAfter(before), isTrue);
    expect(archived, (await row('medications', 'm1'))['updated_at']);

    final treatments = TreatmentLocalDatasource();
    await treatments.upsert(
      TreatmentModel(
        id: 't1',
        name: 'Flu',
        startDate: DateTime(2026, 3),
        updatedAt: DateTime(2026, 3, 5, 9),
      ),
      syncStatus: SyncStatus.pendingUpdate,
    );
    expect(
      (await row('treatments', 't1'))['edited_at'],
      DateTime(2026, 3, 5, 9).toIso8601String(),
    );
    await treatments.markDeleted('t1');
    final deleted = (await row('treatments', 't1'))['edited_at']! as String;
    expect(DateTime.parse(deleted).isAfter(before), isTrue);
  });

  test('a dose status change and a prescription pause stamp the same instant '
      'as updated_at', () async {
    final db = await AppDatabase.instance.database;
    final seeded = await seedPrescription(db);
    final doseId = await seedDoseLog(
      db,
      seeded.prescriptionId,
      DateTime(2026, 3, 1, 8),
    );
    await DoseLogLocalDatasource().updateStatus(
      doseId,
      'taken',
      takenTime: DateTime(2026, 3, 1, 8, 5),
      syncStatus: SyncStatus.pendingUpdate,
    );
    final dose = await row('dose_logs', doseId);
    expect(dose['edited_at'], dose['updated_at']);

    await PrescriptionLocalDatasource().deactivate(seeded.prescriptionId);
    final p = await row('prescriptions', seeded.prescriptionId);
    expect(p['edited_at'], p['updated_at']);
  });

  test('a generated dose carries the automatic 1970 edit time', () async {
    final db = await AppDatabase.instance.database;
    final seeded = await seedPrescription(db);
    await DoseLogLocalDatasource().insertBatchIfAbsent([
      DoseLogModel(
        id: 'g1',
        prescriptionId: seeded.prescriptionId,
        scheduledTime: DateTime(2026, 3, 1, 8),
        updatedAt: generatedUpdatedAt,
      ),
    ], syncStatus: SyncStatus.pendingCreate);
    expect(
      (await row('dose_logs', 'g1'))['edited_at'],
      generatedUpdatedAt.toIso8601String(),
    );
  });
}
```

Append this group to `test/data/datasources/stock_outbox_local_datasource_test.dart`, inside `main()`, and add the imports `package:medora/data/local/app_database.dart` and `../../helpers/test_database.dart`:

```dart
  group('StockOutboxLocalDatasource', () {
    setUp(() async {
      await setUpTestDatabase();
      final db = await AppDatabase.instance.database;
      await db.insert('medications', {'id': 'm1', 'name': 'M', 'quantity': 5});
      await db.insert('medications', {'id': 'm2', 'name': 'N', 'quantity': 5});
    });
    tearDown(tearDownTestDatabase);

    test('keeps changes oldest first, per medication, until removed', () async {
      final db = await AppDatabase.instance.database;
      await db.transaction((txn) async {
        await StockOutboxLocalDatasource.enqueue(
          txn,
          _op('late', delta: -1, minute: 9),
        );
        await StockOutboxLocalDatasource.enqueue(
          txn,
          _op('early', delta: -1, minute: 1),
        );
        await StockOutboxLocalDatasource.enqueue(
          txn,
          StockOp(
            opId: 'other',
            medicationId: 'm2',
            setTo: 3,
            createdAt: DateTime.utc(2026, 3, 5, 8, 5),
          ),
        );
      });
      final outbox = StockOutboxLocalDatasource();
      expect((await outbox.pending()).map((o) => o.opId), [
        'early',
        'other',
        'late',
      ]);
      expect((await outbox.pending(medicationId: 'm1')).map((o) => o.opId), [
        'early',
        'late',
      ]);
      expect(await outbox.remove('early'), isTrue);
      expect(await outbox.remove('early'), isFalse);
      expect((await outbox.pending()).map((o) => o.opId), ['other', 'late']);
      await outbox.clearAll();
      expect(await outbox.pending(), isEmpty);
    });

    test('a medication deleted here takes its changes with it', () async {
      final db = await AppDatabase.instance.database;
      await StockOutboxLocalDatasource.enqueue(db, _op('a', delta: -1));
      await db.delete('medications', where: 'id = ?', whereArgs: ['m1']);
      expect(await StockOutboxLocalDatasource().pending(), isEmpty);
    });
  });
```

Add to `test/services/backup_service_test.dart`, before `photos round-trip through the backup file`:

```dart
  test(
    'a backup leaves out the sync bookkeeping and keeps the edit time',
    () async {
      final db = await AppDatabase.instance.database;
      await seedEverything(db);
      await db.update('medications', {
        'edited_at': '2026-03-01T09:00:00.000',
        'sync_version': 4,
        'sync_base': '{}',
        'sync_write_id': 'w1',
      });
      await db.update('dose_logs', {'delete_guard': 'if_pending'});
      final file = await makeService().exportToFile(outDir);
      final tables =
          (jsonDecode(await file.readAsString())
                  as Map<String, dynamic>)['tables']
              as Map<String, dynamic>;
      final med =
          (tables['medications'] as List).single as Map<String, dynamic>;
      final dose = (tables['dose_logs'] as List).single as Map<String, dynamic>;
      for (final key in BackupService.localOnlyColumns) {
        expect(med.containsKey(key), isFalse, reason: key);
        expect(dose.containsKey(key), isFalse, reason: key);
      }
      expect(med['edited_at'], '2026-03-01T09:00:00.000');
    },
  );

  test('a restored row knows nothing about a server copy', () async {
    final db = await AppDatabase.instance.database;
    await seedEverything(db);
    final id = (await db.query('medications')).single['id']! as String;
    await db.update('medications', {'updated_at': '2099-01-01T09:00:00.000'});
    final file = await makeService().exportToFile(outDir);
    await db.update('medications', {
      'updated_at': '2098-01-01T09:00:00.000',
      'sync_version': 7,
      'sync_base': '{"id":"x"}',
      'sync_write_id': 'w7',
    });

    await makeService().restore(
      file,
      mode: RestoreMode.merge,
      markPending: true,
    );

    final row = (await db.query(
      'medications',
      where: 'id = ?',
      whereArgs: [id],
    )).single;
    expect(
      [row['sync_version'], row['sync_base'], row['sync_write_id']],
      [null, null, null],
    );
    expect(row['sync_status'], SyncStatus.pendingUpdate);
  });

  // Bites under TZ=Europe/Rome (the gates run it): there the local naive
  // stamp sorts after the backup's UTC one as text, though it is older.
  test('a merge compares stamps as instants, whatever their format', () async {
    final db = await AppDatabase.instance.database;
    await seedEverything(db);
    final id = (await db.query('medications')).single['id']! as String;
    await db.update('medications', {
      'name': 'From the backup',
      'updated_at': DateTime.utc(2026, 3, 5, 10, 30).toIso8601String(),
    });
    final file = await makeService().exportToFile(outDir);
    await db.update('medications', {
      'name': 'Older on the device',
      'updated_at': DateTime.utc(2026, 3, 5, 10).toLocal().toIso8601String(),
    });

    await makeService().restore(file, mode: RestoreMode.merge);

    expect(
      (await db.query(
        'medications',
        where: 'id = ?',
        whereArgs: [id],
      )).single['name'],
      'From the backup',
    );
  });
```

Add to `test/services/local_upload_marker_test.dart`, before `pending_delete rows are left alone`:

```dart
  test(
    'what this device knew about another account\'s server is dropped',
    () async {
      final db = await AppDatabase.instance.database;
      final seeded = await seedPrescription(db);
      await db.update('medications', {
        'sync_version': 3,
        'sync_base': '{"id":"x"}',
        'sync_write_id': 'w1',
      });
      await db.insert('stock_outbox', {
        'op_id': 'op1',
        'medication_id': seeded.medicationId,
        'delta': -1,
        'created_at': '2026-03-05T08:00:00.000Z',
      });

      await makeMarker().markAllForUpload('user-b');

      final med = (await db.query('medications')).single;
      expect(
        [med['sync_version'], med['sync_base'], med['sync_write_id']],
        [null, null, null],
      );
      expect(await db.query('stock_outbox'), isEmpty);
    },
  );
```

Add to `test/data/repositories/treatment_repository_test.dart`, before `endTreatment on a missing id fails instead of writing`:

```dart
    test('updateTreatment on a row deleted on this device fails and keeps '
        'the delete', () async {
      await local.upsert(episode, syncStatus: SyncStatus.synced);
      await local.markDeleted('t1');
      final repo = TreatmentRepositoryImpl(localDatasource: local);

      final result = await repo.updateTreatment(
        episode.toDomain().copyWith(name: 'Brought back?'),
      );

      expect(result.isFailure, isTrue);
      expect(await syncStatus('t1'), SyncStatus.pendingDelete);
      expect((await local.getTreatmentById('t1'))!.name, episode.name);
    });
```

Run: `fvm flutter test test/data/local/app_database_test.dart test/data/datasources/edit_time_test.dart test/data/datasources/stock_outbox_local_datasource_test.dart test/services/backup_service_test.dart test/services/local_upload_marker_test.dart test/data/repositories/treatment_repository_test.dart`
Expected: FAIL. The failures are the migration-list mismatches, the missing columns and table, `StockOutboxLocalDatasource` undefined, `BackupService.localOnlyColumns` undefined, and `updateTreatment` succeeding.

- [ ] **Step 2: Migration 16**

In `lib/data/local/migrations.dart`, set `const int kSchemaVersion = 16;` and append to `kMigrations`:

```dart
  // v16: sync v2 (supabase/migrations/20260918000000_sync_v2.sql). Each
  // synced row keeps when its last change was made here (`edited_at`, 1970
  // for a change the app made on its own), the server copy it was last in
  // step with (`sync_version`, `sync_base`, the base of every merge) and
  // the write attempt whose answer never came (`sync_write_id`). A dose the
  // app drops from a changed schedule is deleted on the server only while
  // it is still pending (`delete_guard`). Stock changes wait in their own
  // outbox, as changes, never as totals.
  Migration(16, (db) async {
    for (final table in [
      'medications',
      'treatments',
      'prescriptions',
      'dose_logs',
    ]) {
      await db.execute('ALTER TABLE $table ADD COLUMN edited_at TEXT');
      await db.execute('ALTER TABLE $table ADD COLUMN sync_version INTEGER');
      await db.execute('ALTER TABLE $table ADD COLUMN sync_base TEXT');
      await db.execute('ALTER TABLE $table ADD COLUMN sync_write_id TEXT');
      // A change still waiting to be pushed was made when it was stamped.
      await db.execute(
        "UPDATE $table SET edited_at = updated_at WHERE sync_status != 'synced'",
      );
    }
    await db.execute('ALTER TABLE dose_logs ADD COLUMN delete_guard TEXT');
    await db.execute('''
      CREATE TABLE stock_outbox (
        op_id TEXT PRIMARY KEY,
        medication_id TEXT NOT NULL
          REFERENCES medications(id) ON DELETE CASCADE,
        delta INTEGER,
        set_to INTEGER,
        created_at TEXT NOT NULL,
        CHECK ((delta IS NULL) <> (set_to IS NULL))
      )
    ''');
    await db.execute(
      'CREATE INDEX idx_local_stock_outbox_med '
      'ON stock_outbox(medication_id, created_at)',
    );
  }),
```

In `lib/data/local/app_database.dart` (`clearAllData`), add `await db.delete('stock_outbox');` as the first delete: it references `medications`.

- [ ] **Step 3: The outbox table class**

Append to `lib/data/datasources/stock_outbox_local_datasource.dart`, and add `import 'package:medora/data/local/app_database.dart';` and `import 'package:sqflite/sqflite.dart';`:

```dart
class StockOutboxLocalDatasource {
  StockOutboxLocalDatasource();

  static const table = 'stock_outbox';

  Future<Database> get _db => AppDatabase.instance.database;

  /// Adds [op] inside [txn], the transaction that changes the quantity.
  static Future<void> enqueue(DatabaseExecutor txn, StockOp op) =>
      txn.insert(table, op.toRow());

  /// The changes still waiting, oldest first; only [medicationId]'s when
  /// given.
  Future<List<StockOp>> pending({String? medicationId}) async =>
      pendingIn(await _db, medicationId: medicationId);

  /// [pending] inside an open transaction.
  static Future<List<StockOp>> pendingIn(
    DatabaseExecutor db, {
    String? medicationId,
  }) async {
    final rows = await db.query(
      table,
      where: medicationId == null ? null : 'medication_id = ?',
      whereArgs: medicationId == null ? null : [medicationId],
      orderBy: 'created_at, op_id',
    );
    return rows.map(StockOp.fromRow).toList();
  }

  /// Drops the change [opId]; true when it was there.
  Future<bool> remove(String opId) async =>
      await (await _db).delete(table, where: 'op_id = ?', whereArgs: [opId]) >
      0;

  Future<void> clearAll() async => (await _db).delete(table);
}
```

- [ ] **Step 4: `rowOf` and edit times in the four local datasources**

In each of the four files:
- rename `Map<String, dynamic> _toRow(` to `static Map<String, dynamic> rowOf(`;
- rename every `_toRow(` call to `rowOf(`.

The body of `_toRow` does not use `this` in any of the four.

At the end of the map `rowOf` returns in **medication**, **treatment** and **dose log** (after `'sync_status': syncStatus,`), add:

```dart
      // A change made here was made when it was stamped; a pulled row gets
      // the server's edit time from the sync cycle instead.
      if (syncStatus != SyncStatus.synced)
        'edited_at':
            m.updatedAt?.toIso8601String() ?? DateTime.now().toIso8601String(),
```

In **prescription**, `rowOf` builds from `toLocalMap()`. Before `return row;`, add:

```dart
    if (syncStatus != SyncStatus.synced) {
      row['edited_at'] =
          m.updatedAt?.toIso8601String() ?? DateTime.now().toIso8601String();
    }
```

In every `markDeleted` of the four files, add `'edited_at': DateTime.now().toIso8601String(),` to the update map. In the dose log file, also add `'delete_guard': null,`: a person's delete is never guarded.

**Medication `_editRow`.** Replace the stamping part with:

```dart
      final raw = row['updated_at'] as String?;
      final previous = raw == null ? null : DateTime.tryParse(raw);
      final stamp = nextUpdatedAt(previous, DateTime.now()).toIso8601String();
      await txn.update(
        'medications',
        {
          ...changes(row),
          'sync_status': editedSyncStatus(status),
          'updated_at': stamp,
          'edited_at': stamp,
        },
```

**Prescription `_setActive`.** Likewise, compute `final stamp = nextUpdatedAt(previous, DateTime.now()).toIso8601String();` and write `'updated_at': stamp, 'edited_at': stamp,`.

**Dose log `updateStatus`.** Replace the `updates` map with:

```dart
    final stamp = nextUpdatedAt(previous, DateTime.now()).toIso8601String();
    final updates = <String, dynamic>{
      'status': status,
      'sync_status': syncStatus,
      'updated_at': stamp,
      'edited_at': stamp,
    };
```

A generated dose goes through `insertBatchIfAbsent` → `rowOf(model, pending_create)`, whose `updatedAt` is `generatedUpdatedAt`. So its `edited_at` is 1970, the automatic edit time, with no extra code.

- [ ] **Step 5: Backups**

In `lib/services/backup_service.dart`:

1. Library doc: replace "minus `sync_status`, which is local bookkeeping and is re-stamped on restore." with "minus the local sync bookkeeping ([localOnlyColumns]), which is re-stamped on restore. `edited_at` stays: a restored row keeps the time its last change was made."
2. Add to the class:

```dart
  /// Columns that describe this device's sync state, never carried by a
  /// backup: another device, or this one later, is in another state.
  static const localOnlyColumns = {
    'sync_status',
    'sync_version',
    'sync_base',
    'sync_write_id',
    'delete_guard',
  };
```

3. In `exportToFile`, change `if (entry.key != 'sync_status') entry.key: entry.value,` to

```dart
                if (!localOnlyColumns.contains(entry.key))
                  entry.key: entry.value,
```

4. In `_read`, change `parsed.add({...row}..remove('sync_status'));` to

```dart
        parsed.add(
          {...row}..removeWhere((k, _) => localOnlyColumns.contains(k)),
        );
```

5. Replace `_applyRow` (and its doc comment) with this version. It clears the bookkeeping and compares instants (m-13). The doc comment of `restore` gains one sentence: "Nothing about the server copy is known any more, so the next push merges by edit time."

```dart
  /// Writes one backed-up row; returns whether it was written.
  ///
  /// In [RestoreMode.replace] the tables were emptied first, so every row is
  /// a plain insert. In [RestoreMode.merge] a row whose id is not on the
  /// device is inserted; for an id that already exists only the tables in
  /// [_versioned] are compared, and the backup wins only when its
  /// `updated_at` is strictly newer - a tie, a missing timestamp, or a row of
  /// `families`/`family_members` (which carry no `updated_at`) keeps whatever
  /// the device already holds. Stamps are compared as instants: the device
  /// holds both naive-local and UTC stamps.
  Future<bool> _applyRow(
    Transaction txn,
    String table,
    Map<String, Object?> row,
    RestoreMode mode,
    String status,
  ) async {
    final values = {
      ...row,
      'sync_status': status,
      if (_versioned.contains(table)) ...{
        'sync_version': null,
        'sync_base': null,
        'sync_write_id': null,
      },
      if (table == 'dose_logs') 'delete_guard': null,
    };
    final id = row['id'];
    if (mode == RestoreMode.replace || id == null) {
      await txn.insert(table, values);
      return true;
    }

    final existing = await txn.query(
      table,
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (existing.isEmpty) {
      await txn.insert(table, values);
      return true;
    }
    if (!_versioned.contains(table)) return false;

    final mine = _instant(existing.single['updated_at']);
    final theirs = _instant(row['updated_at']);
    if (mine != null && (theirs == null || !theirs.isAfter(mine))) {
      return false;
    }
    await txn.update(table, values, where: 'id = ?', whereArgs: [id]);
    return true;
  }

  static DateTime? _instant(Object? raw) =>
      raw is String ? DateTime.tryParse(raw)?.toUtc() : null;
```

- [ ] **Step 6: Upload marker and the treatment guard**

In `lib/services/local_upload_marker.dart`, `markAllForUpload`, add before the per-table loop:

```dart
    // What this device knew about a server copy belongs to the account it
    // came from: the merge bases go, and so do stock changes still waiting
    // for that account (the upload carries each quantity).
    await db.transaction((txn) async {
      for (final table in const [
        'medications',
        'treatments',
        'prescriptions',
        'dose_logs',
      ]) {
        await txn.update(table, const {
          'sync_version': null,
          'sync_base': null,
          'sync_write_id': null,
        });
      }
      await txn.delete('stock_outbox');
    });
```

In `lib/data/repositories/treatment_repository_impl.dart`, `updateTreatment`, directly after `final previous = await localDatasource.getTreatmentById(treatment.id);`, add:

```dart
      // An edit of a treatment deleted on this device would bring it back.
      if (previous?.deletedAt != null) {
        return const Result.failure('Treatment was deleted');
      }
```

- [ ] **Step 7: Run the tests, both zones**

Run: `fvm flutter test test/data test/services/backup_service_test.dart test/services/local_upload_marker_test.dart`
Run: `TZ=Europe/Rome fvm flutter test test/services/backup_service_test.dart`
Expected: all pass. The instant-comparison test only fails the old code under `TZ=Europe/Rome`; the gates run that zone.

Mutations (scratch worktree):
- Drop `'edited_at': stamp` from `updateStatus` → `a dose status change…` fails.
- Compare the `updated_at` strings again in `_applyRow` → `a merge compares stamps as instants…` fails under Rome.
- Drop the upload-marker transaction → `what this device knew…` fails.

- [ ] **Step 8: Gates and commit**

Run the gates. Commit message `feat(data): local schema v16 with sync bookkeeping and edit times on every write`. The body names:
- migration 16;
- the outbox table;
- `rowOf`;
- the backup rules: bookkeeping never exported, cleared on restore, stamps compared as instants (sick-branch m-13);
- the upload-marker reset;
- the `updateTreatment` delete guard (sync follow-up m-6).

---

## Task 5: The merge engine, beside the old cycle

**What this task delivers:** the per-row sync engine of design §7.2–§7.4, as new files with their own tests. `SyncService` does not use it yet, so the app behaves exactly as before and the whole suite stays green.

**Files:**
- Create: `lib/data/sync/row_merge.dart` (pure: policies, `changedColumns`, `mergeRows`)
- Create: `lib/data/sync/sync_meta.dart` (wire copies, local row mapping, bookkeeping values)
- Create: `lib/data/sync/row_settle.dart` (the v2 settle; Task 6 deletes the old `push_settle.dart`)
- Create: `lib/data/sync/table_sync.dart` (pull one row, push one row)
- Create: `test/data/sync/row_merge_test.dart`, `test/data/sync/row_settle_test.dart`, `test/data/sync/table_sync_test.dart`

**Interfaces:**
- Consumes:
  - `SyncTable`, `RemoteMeta` (Task 3);
  - `StockOutboxLocalDatasource.pendingIn`, `applyStockOps` (Tasks 3–4);
  - the four `LocalDatasource.rowOf` (Task 4);
  - the local columns of migration 16.
- Produces:
  - `row_merge.dart`:
    - `final DateTime weakEditCeiling` (1970-01-02 UTC), `final DateTime automaticEditedAt` (1970-01-01 UTC)
    - `class MergePolicy { const MergePolicy({required List<Set<String>> groups, Set<String> serverOwned = const {}}); static const bookkeeping = {'id', 'user_id', 'updated_at', 'deleted_at'}; }`
    - `class MergeConflict { Set<String> columns; bool keptLocal; }`, `class MergeResult { Map<String, Object?> row; List<MergeConflict> conflicts; }`
    - `Set<String> changedColumns(Map<String, Object?>? base, Map<String, Object?> local, MergePolicy policy)`
    - `MergeResult mergeRows({required Map<String, Object?>? base, required Map<String, Object?> local, required Map<String, Object?> remote, required DateTime? localEditedAt, required DateTime? remoteEditedAt, required MergePolicy policy})`
    - `bool sameContent(Map<String, Object?> a, Map<String, Object?> b, MergePolicy policy)`
    - `const medicationMerge`, `treatmentMerge`, `prescriptionMerge`, `doseLogMerge`; `MergePolicy mergePolicyOf(String table)`; `bool isAutomaticEdit(DateTime? editedAt)`
  - `sync_meta.dart`:
    - `const syncedTables`, `const syncMetaColumnNames`
    - `Map<String, Object?> canonicalWire(String table, Map<String, dynamic> json)`
    - `Map<String, Object?> localWire(String table, Map<String, Object?> row, {String? userId})`
    - `Map<String, Object?> localRowOf(String table, Map<String, dynamic> json, String syncStatus)`
    - `class LocalSyncMeta { factory LocalSyncMeta.fromRow(Map<String, Object?> row); int? version; Map<String, Object?>? base; String? writeId; DateTime? editedAt; }`
    - `Map<String, Object?> syncMetaValues({required int? version, required Map<String, Object?>? base, String? writeId, DateTime? editedAt})`
    - `const Map<String, Object?> clearedSyncMeta`
  - `row_settle.dart`: `Future<bool> settlePushedRow(Database db, String table, {required Map<String, Object?> pushed, required Map<String, dynamic> server, required String Function() newOpId})` — true when the row still has changes to push.
  - `table_sync.dart`:
    - `enum PullOutcome { inserted, replaced, merged, deleted, kept }`, `class PullApplied { PullOutcome outcome; List<MergeConflict> conflicts; }`
    - `enum PushOutcome { settled, pending }`, `class PushResult { PushOutcome outcome; List<MergeConflict> conflicts; }`
    - `class TableSync { TableSync({required String table, required SyncTable remote, required String Function() newWriteId, required DateTime Function() now}); static const maxAttempts = 2; Future<PullApplied> applyPulled(Map<String, dynamic> json); Future<PushResult> pushRow(Map<String, Object?> row, {required String? userId, bool force = false}); }`

- [ ] **Step 1: Write the merge tests**

Create `test/data/sync/row_merge_test.dart`. The scenarios, with their exact expected values:
- **S1, two groups:** A ended the illness on the server (`end_date` `2026-03-05`, `is_active` false, `sick_leave_to` `2026-03-05`), B added `CERT-B`. Expected: all four values kept, no conflict.
- **One group changed on both sides:** the later edit (10:00 against 09:00) wins the whole `{sick_leave_from, sick_leave_to}` group, in either direction. The conflict is reported with `keptLocal`.
- **A tie** keeps the server's value.
- **An automatic "missed"** (edit time 1970) loses to a take edited in 2020, and to one with no known edit time.
- **No base:** equal values are no conflict. `name` and `doctor` go to the later edit, and the conflicts come in the local row's key order.
- **A server-owned column** always comes from the server.

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/data/sync/row_merge.dart';

void main() {
  // The illness as both devices last saw it on the server.
  const base = <String, Object?>{
    'id': 't1',
    'name': 'Sinusitis',
    'end_date': null,
    'is_active': true,
    'sick_leave_from': '2026-03-02',
    'sick_leave_to': null,
    'sick_leave_ref': null,
    'updated_at': '2026-03-02T09:00:00.000Z',
  };
  // A table whose `quantity` only the server writes.
  const stockOwned = MergePolicy(groups: [], serverOwned: {'quantity'});
  final nine = DateTime.utc(2026, 3, 5, 9);
  final ten = DateTime.utc(2026, 3, 5, 10);

  group('changedColumns', () {
    test('lists what differs from the base, bookkeeping left out', () {
      final local = {
        ...base,
        'sick_leave_ref': 'CERT-B',
        'updated_at': '2026-03-05T10:00:00.000Z',
      };
      expect(changedColumns(base, local, treatmentMerge), {'sick_leave_ref'});
    });

    test('with no base every column counts, bookkeeping still left out', () {
      expect(changedColumns(null, base, treatmentMerge), {
        'name',
        'end_date',
        'is_active',
        'sick_leave_from',
        'sick_leave_to',
        'sick_leave_ref',
      });
    });

    test('never lists a server-owned column', () {
      const med = {'id': 'm1', 'name': 'Ibu', 'quantity': 10};
      expect(changedColumns(med, {...med, 'quantity': 8}, stockOwned), isEmpty);
    });
  });

  group('mergeRows', () {
    test('S1: different groups changed on each side are both kept', () {
      // A ended the illness (on the server); B added the certificate.
      final remote = {
        ...base,
        'end_date': '2026-03-05',
        'is_active': false,
        'sick_leave_to': '2026-03-05',
      };
      final local = {...base, 'sick_leave_ref': 'CERT-B'};
      final result = mergeRows(
        base: base,
        local: local,
        remote: remote,
        localEditedAt: nine,
        remoteEditedAt: ten,
        policy: treatmentMerge,
      );
      expect(
        [
          result.row['end_date'],
          result.row['is_active'],
          result.row['sick_leave_to'],
          result.row['sick_leave_ref'],
        ],
        ['2026-03-05', false, '2026-03-05', 'CERT-B'],
      );
      expect(result.conflicts, isEmpty);
    });

    test('the same group changed on both sides: the later edit wins, '
        'as a whole group', () {
      final remote = {
        ...base,
        'sick_leave_from': '2026-03-03',
        'sick_leave_to': '2026-03-06',
      };
      final local = {...base, 'sick_leave_to': '2026-03-09'};
      final localLater = mergeRows(
        base: base,
        local: local,
        remote: remote,
        localEditedAt: ten,
        remoteEditedAt: nine,
        policy: treatmentMerge,
      );
      expect(
        [localLater.row['sick_leave_from'], localLater.row['sick_leave_to']],
        ['2026-03-02', '2026-03-09'],
      );
      expect(localLater.conflicts.single.keptLocal, isTrue);
      expect(localLater.conflicts.single.columns, {
        'sick_leave_from',
        'sick_leave_to',
      });

      final remoteLater = mergeRows(
        base: base,
        local: local,
        remote: remote,
        localEditedAt: nine,
        remoteEditedAt: ten,
        policy: treatmentMerge,
      );
      expect(
        [remoteLater.row['sick_leave_from'], remoteLater.row['sick_leave_to']],
        ['2026-03-03', '2026-03-06'],
      );
      expect(remoteLater.conflicts.single.keptLocal, isFalse);
    });

    test('a tie keeps the server copy', () {
      final result = mergeRows(
        base: base,
        local: {...base, 'name': 'Local'},
        remote: {...base, 'name': 'Remote'},
        localEditedAt: nine,
        remoteEditedAt: nine,
        policy: treatmentMerge,
      );
      expect(result.row['name'], 'Remote');
    });

    test('an automatic change never beats a real one, even a much older '
        'one or one with no known edit time', () {
      const dose = {'id': 'd1', 'status': 'pending', 'taken_time': null};
      for (final remoteEditedAt in [DateTime.utc(2020), null]) {
        final result = mergeRows(
          base: dose,
          local: {...dose, 'status': 'missed'},
          remote: {
            ...dose,
            'status': 'taken',
            'taken_time': '2026-03-01T07:05:00.000Z',
          },
          localEditedAt: automaticEditedAt,
          remoteEditedAt: remoteEditedAt,
          policy: doseLogMerge,
        );
        expect(
          [result.row['status'], result.row['taken_time']],
          ['taken', '2026-03-01T07:05:00.000Z'],
          reason: '$remoteEditedAt',
        );
      }
    });

    test('with no base, equal values are no conflict and different ones '
        'go to the later edit', () {
      final result = mergeRows(
        base: null,
        local: {...base, 'name': 'Cold', 'doctor': 'Dr. Bianchi'},
        remote: {...base, 'doctor': 'Dr. Rossi'},
        localEditedAt: ten,
        remoteEditedAt: nine,
        policy: treatmentMerge,
      );
      expect(
        [result.row['name'], result.row['doctor'], result.row['is_active']],
        ['Cold', 'Dr. Bianchi', true],
      );
      expect(result.conflicts.map((c) => c.columns), [
        {'name'},
        {'doctor'},
      ]);
    });

    test('a server-owned column always comes from the server', () {
      const med = {'id': 'm1', 'name': 'Ibu', 'quantity': 10};
      final result = mergeRows(
        base: med,
        local: {...med, 'name': 'Ibuprofen', 'quantity': 3},
        remote: {...med, 'quantity': 8},
        localEditedAt: ten,
        remoteEditedAt: nine,
        policy: stockOwned,
      );
      expect([result.row['name'], result.row['quantity']], ['Ibuprofen', 8]);
    });
  });

  test('mergePolicyOf knows the four synced tables only', () {
    expect(mergePolicyOf('dose_logs'), same(doseLogMerge));
    expect(() => mergePolicyOf('families'), throwsArgumentError);
  });

  test('sameContent ignores bookkeeping', () {
    expect(
      sameContent(base, {...base, 'updated_at': 'later'}, treatmentMerge),
      isTrue,
    );
    expect(sameContent(base, {...base, 'name': 'x'}, treatmentMerge), isFalse);
  });
}
```

Run: `fvm flutter test test/data/sync/row_merge_test.dart`
Expected: FAIL to load (`row_merge.dart` does not exist).

- [ ] **Step 2: The merge**

Create `lib/data/sync/row_merge.dart`:

```dart
/// Medora - Three-way merge of a synced row (sync v2).
///
/// A pending local copy and the server's copy are merged against the base:
/// the server copy this device was last in step with. Columns that only
/// make sense together form a group; a group only one side changed takes
/// that side, a group both changed takes the later edit. Pure, no I/O.
library;

/// Stamps before this are the app's own changes, never a person's.
final DateTime weakEditCeiling = DateTime.utc(1970, 1, 2);

/// The edit time of a change the app made on its own.
final DateTime automaticEditedAt = DateTime.utc(1970);

/// How one synced table merges.
class MergePolicy {
  const MergePolicy({required this.groups, this.serverOwned = const {}});

  /// Columns that only change together. A column in no group is a group of
  /// its own.
  final List<Set<String>> groups;

  /// Columns the client never writes through a row update; the server's
  /// value is always kept.
  final Set<String> serverOwned;

  /// Keys that are bookkeeping on every table, never merged or diffed.
  static const bookkeeping = {'id', 'user_id', 'updated_at', 'deleted_at'};

  Set<String> _groupOf(String column) =>
      groups.firstWhere((g) => g.contains(column), orElse: () => {column});
}

/// One group the two sides changed differently, and which side was kept.
class MergeConflict {
  const MergeConflict(this.columns, {required this.keptLocal});
  final Set<String> columns;
  final bool keptLocal;

  @override
  String toString() => 'MergeConflict($columns, keptLocal: $keptLocal)';
}

class MergeResult {
  const MergeResult(this.row, this.conflicts);
  final Map<String, Object?> row;
  final List<MergeConflict> conflicts;
}

/// The columns of [local] that differ from [base], bookkeeping and
/// [MergePolicy.serverOwned] left out. A null [base] means "unknown": every
/// column counts as changed.
Set<String> changedColumns(
  Map<String, Object?>? base,
  Map<String, Object?> local,
  MergePolicy policy,
) => {
  for (final key in local.keys)
    if (!MergePolicy.bookkeeping.contains(key) &&
        !policy.serverOwned.contains(key) &&
        (base == null || !base.containsKey(key) || base[key] != local[key]))
      key,
};

/// Merges a local pending copy with the server's.
///
/// Per group: a group only one side changed since [base] takes that side;
/// a group both sides changed to different values takes the side edited
/// later ([localEditedAt] against [remoteEditedAt]; a tie keeps the
/// server's). With no [base] every group counts as changed on both sides.
/// Server-owned and bookkeeping columns always come from [remote].
MergeResult mergeRows({
  required Map<String, Object?>? base,
  required Map<String, Object?> local,
  required Map<String, Object?> remote,
  required DateTime? localEditedAt,
  required DateTime? remoteEditedAt,
  required MergePolicy policy,
}) {
  final merged = Map<String, Object?>.of(remote);
  final conflicts = <MergeConflict>[];
  final localChanged = changedColumns(base, local, policy);
  final remoteChanged = changedColumns(base, remote, policy);
  final done = <String>{};
  for (final column in localChanged) {
    if (done.contains(column)) continue;
    final group = policy._groupOf(column);
    done.addAll(group);
    final sameValues = group.every((c) => local[c] == remote[c]);
    if (sameValues) continue;
    final remoteTouched = group.any(remoteChanged.contains);
    final takeLocal = !remoteTouched || _isLater(localEditedAt, remoteEditedAt);
    if (remoteTouched) {
      conflicts.add(MergeConflict(group, keptLocal: takeLocal));
    }
    if (takeLocal) {
      for (final c in group) {
        if (local.containsKey(c)) merged[c] = local[c];
      }
    }
  }
  return MergeResult(merged, conflicts);
}

/// True when an edit at [a] beats one at [b]. A change the app made on its
/// own ([a] before [weakEditCeiling]) never beats anything; an unknown [b]
/// loses to any real edit.
bool _isLater(DateTime? a, DateTime? b) {
  if (a == null || a.toUtc().isBefore(weakEditCeiling)) return false;
  if (b == null) return true;
  return a.toUtc().isAfter(b.toUtc());
}

/// True when [a] and [b] hold the same client-written values.
bool sameContent(
  Map<String, Object?> a,
  Map<String, Object?> b,
  MergePolicy policy,
) =>
    changedColumns(a, b, policy).isEmpty &&
    changedColumns(b, a, policy).isEmpty;

/// How each synced table merges (see the design, section 4.5).
const medicationMerge = MergePolicy(
  groups: [
    {'barcode', 'ean'},
  ],
);

const treatmentMerge = MergePolicy(
  groups: [
    {'end_date', 'is_active'},
    {'sick_leave_from', 'sick_leave_to'},
  ],
);

const prescriptionMerge = MergePolicy(
  groups: [
    {
      'schedule_type',
      'interval_hours',
      'duration_days',
      'start_time',
      'schedule_times',
    },
    {'dosage', 'dosage_amount', 'dosage_unit'},
  ],
);

const doseLogMerge = MergePolicy(
  groups: [
    {'status', 'taken_time'},
  ],
);

/// The policy of [table].
MergePolicy mergePolicyOf(String table) => switch (table) {
  'medications' => medicationMerge,
  'treatments' => treatmentMerge,
  'prescriptions' => prescriptionMerge,
  'dose_logs' => doseLogMerge,
  _ => throw ArgumentError.value(table, 'table', 'not a merged table'),
};

/// True when [editedAt] marks a change the app made on its own.
bool isAutomaticEdit(DateTime? editedAt) =>
    editedAt != null && editedAt.toUtc().isBefore(weakEditCeiling);
```

Run: `fvm flutter test test/data/sync/row_merge_test.dart`
Expected: `+11: All tests passed!`

- [ ] **Step 3: Write the settle and engine tests**

Create `test/data/sync/row_settle_test.dart`. It covers four cases:
- an unchanged row becomes `synced` with version 4, a cleared write id and base name `Pushed`;
- a row edited in flight stays `pending_update` with version 4;
- a pending delete stays;
- a vanished row reports nothing to push.

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/sync/row_settle.dart';
import 'package:medora/data/sync/sync_meta.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../helpers/test_database.dart';

void main() {
  setUp(setUpTestDatabase);
  tearDown(tearDownTestDatabase);

  const pushedAt = '2026-03-05T10:00:00.000';

  Map<String, dynamic> server({String name = 'Pushed', int quantity = 5}) => {
    'id': 'm1',
    'user_id': 'u',
    'name': name,
    'quantity': quantity,
    'row_version': 4,
    'sync_xid': 1200,
    'write_id': 'w1',
    'edited_at': '2026-03-05T10:00:00+00:00',
    'updated_at': '2026-03-05T10:00:01+00:00',
  };

  Future<Map<String, Object?>> seed(
    Database db, {
    String status = 'pending_update',
  }) async {
    await db.insert('medications', {
      'id': 'm1',
      'name': 'Pushed',
      'quantity': 5,
      'updated_at': pushedAt,
      'sync_status': status,
      'sync_write_id': 'w1',
    });
    return (await db.query('medications')).single;
  }

  Future<Map<String, Object?>> row(Database db) async =>
      (await db.query('medications')).single;

  test(
    'an unchanged row is synced and takes the server copy as its base',
    () async {
      final db = await AppDatabase.instance.database;
      final pushed = await seed(db);

      final pending = await settlePushedRow(
        db,
        'medications',
        pushed: pushed,
        server: server(),
        newOpId: () => 'op',
      );

      expect(pending, isFalse);
      final r = await row(db);
      expect(r['sync_status'], 'synced');
      expect(r['sync_version'], 4);
      expect(r['sync_write_id'], isNull);
      expect(LocalSyncMeta.fromRow(r).base!['name'], 'Pushed');
      expect(r['updated_at'], isNot(pushedAt));
    },
  );

  test('a row edited meanwhile stays pending with the new base', () async {
    final db = await AppDatabase.instance.database;
    final pushed = await seed(db);
    await db.update('medications', {
      'name': 'Edited meanwhile',
      'updated_at': '2026-03-05T10:00:00.500',
    });

    final pending = await settlePushedRow(
      db,
      'medications',
      pushed: pushed,
      server: server(),
      newOpId: () => 'op',
    );

    expect(pending, isTrue);
    final r = await row(db);
    expect(r['sync_status'], 'pending_update');
    expect(r['name'], 'Edited meanwhile');
    expect(r['sync_version'], 4);
    expect(r['sync_write_id'], isNull);
  });

  test('a delete made meanwhile stays a pending delete', () async {
    final db = await AppDatabase.instance.database;
    final pushed = await seed(db);
    await db.update('medications', {'sync_status': 'pending_delete'});

    expect(
      await settlePushedRow(
        db,
        'medications',
        pushed: pushed,
        server: server(),
        newOpId: () => 'op',
      ),
      isTrue,
    );
    expect((await row(db))['sync_status'], 'pending_delete');
  });

  test('a row that is gone is nothing to push', () async {
    final db = await AppDatabase.instance.database;
    final pushed = await seed(db);
    await db.delete('medications');

    expect(
      await settlePushedRow(
        db,
        'medications',
        pushed: pushed,
        server: server(),
        newOpId: () => 'op',
      ),
      isFalse,
    );
  });
}
```

Create `test/data/sync/table_sync_test.dart`. Every scenario starts from a realistic state. `warmUp()` means a treatment a 0.3.0 device made three days ago (09:00, 2 March), pulled here; the dose group means a generated dose another device inserted with the automatic edit time, pulled here. The scenarios and their expected values:
- **S1b:** another device ended the illness at 09:00. This device, offline, adds `CERT-B` at 10:00, then pushes. Expected:
  - on the server: `[is_active, end_date, sick_leave_to, sick_leave_ref]` = `[false, '2026-03-05', '2026-03-05', 'CERT-B']`, `row_version` 3;
  - locally: `synced`, version 3, no write id;
  - the requests: a conditional PATCH that matched nothing, a fetch, a PATCH.
- **A lost answer:** the write lands, the answer is lost, and the next push recognises its own write id. Expected: the only request is one fetch; the row is `synced` at version 2 with no write id.
- **A lost answer, then a newer edit:** the server ends with `notes` `after food`, `doctor` `Dr. Bianchi` and version 3; the last request is a PATCH.
- **Pull:** a pending local edit (`CERT-B`, 10:00) merges with a newer server copy that ended the illness. Expected: `pending_update`, `is_active` 0, `CERT-B`, version 2; the next push lands version 3.
- **Same field:** the server holds `A` (10:05) and this device `B` (10:07). Expected: `B` is kept and reported with `keptLocal`.
- **Delete of a never-confirmed create:** the server gets a tombstone; the create that lands late changes nothing; nothing remains locally.
- **Doses:**
  - an automatic "missed" loses to a take made elsewhere (`taken` everywhere);
  - an automatic "missed" lands as `missed` and keeps `updated_at` and `edited_at` at `1970-01-01T00:00:00.000Z`;
  - a time correction and a take elsewhere are both kept;
  - a guarded delete of a dose taken elsewhere leaves the server row live, and the local row becomes `taken`/`synced` with no guard;
  - a guarded delete of a still-pending dose deletes it on the server and here.

```dart
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/sync/row_merge.dart';
import 'package:medora/data/sync/sync_meta.dart';
import 'package:medora/data/sync/table_sync.dart';

import '../../helpers/fake_server.dart';
import '../../helpers/test_database.dart';

void main() {
  late DateTime now;
  late FakeServerCore core;
  late FakeSyncTable remote;
  late TableSync sync;
  var ids = 0;

  setUp(() async {
    ids = 0;
    await setUpTestDatabase();
    now = DateTime.utc(2026, 3, 5, 12);
    core = FakeServerCore(() => now);
    remote = FakeSyncTable(core, 'treatments');
    sync = TableSync(
      table: 'treatments',
      remote: remote,
      newWriteId: () => 'w${ids++}',
      now: () => now,
    );
  });
  tearDown(tearDownTestDatabase);

  Future<Map<String, Object?>> local(String id) async =>
      (await (await AppDatabase.instance.database).query(
        'treatments',
        where: 'id = ?',
        whereArgs: [id],
      )).single;

  Future<void> edit(String id, Map<String, Object?> values, DateTime at) async {
    final db = await AppDatabase.instance.database;
    await db.update(
      'treatments',
      {
        ...values,
        'sync_status': 'pending_update',
        'updated_at': at.toIso8601String(),
        'edited_at': at.toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// A treatment made three days ago on a 0.3.0 device, pulled here.
  Future<void> warmUp() async {
    now = DateTime.utc(2026, 3, 2, 9);
    remote.seed({
      'id': 't1',
      'user_id': 'u',
      'name': 'Sinusitis',
      'start_date': '2026-03-02',
      'is_active': true,
      'sick_leave_from': '2026-03-02',
      'doctor': 'Dr. Rossi',
      'updated_at': '2026-03-02T09:00:00.000Z',
    });
    now = DateTime.utc(2026, 3, 5, 12);
    for (final row in core.page('treatments', horizon: core.horizon)) {
      await sync.applyPulled(row);
    }
  }

  test(
    'S1b: A ended it; B adds the certificate number offline, then syncs',
    () async {
      await warmUp();
      // A (another 0.4.0 device) ends the illness and closes the leave.
      remote.editFromOtherDevice('t1', {
        'end_date': '2026-03-05',
        'is_active': false,
        'sick_leave_to': '2026-03-05',
      }, editedAt: DateTime.utc(2026, 3, 5, 9));
      // B, offline, types the certificate number later.
      await edit('t1', {
        'sick_leave_ref': 'CERT-B',
      }, DateTime.utc(2026, 3, 5, 10));
      final result = await sync.pushRow(await local('t1'), userId: 'u');
      expect(result.outcome, PushOutcome.settled);
      expect(result.conflicts, isEmpty);
      final server = remote.get('t1')!;
      expect(
        [
          server['is_active'],
          server['end_date'],
          server['sick_leave_to'],
          server['sick_leave_ref'],
        ],
        [false, '2026-03-05', '2026-03-05', 'CERT-B'],
      );
      expect(server['row_version'], 3);
      final row = await local('t1');
      expect(row['sync_status'], 'synced');
      expect(
        [row['is_active'], row['end_date'], row['sick_leave_ref']],
        [0, '2026-03-05', 'CERT-B'],
      );
      expect(row['sync_version'], 3);
      expect(row['sync_write_id'], isNull);
      // 1 failed patch, 1 fetch, 1 patch.
      expect(core.requests.where((r) => r.startsWith('treatments:')).toList(), [
        'treatments:legacy',
        'treatments:page',
        'treatments:patch',
        'treatments:patch',
        'treatments:fetch',
        'treatments:patch',
      ]);
    },
  );

  test('a lost answer is recognised as this device\'s own write', () async {
    await warmUp();
    await edit('t1', {'notes': 'after food'}, DateTime.utc(2026, 3, 5, 10));
    remote.loseAnswerFor.add('t1');
    await expectLater(
      sync.pushRow(await local('t1'), userId: 'u'),
      throwsA(isA<TimeoutException>()),
    );
    expect((await local('t1'))['sync_write_id'], 'w0');
    // The next cycle: nothing is sent twice, the row settles.
    final before = core.requests.length;
    final result = await sync.pushRow(await local('t1'), userId: 'u');
    expect(result.outcome, PushOutcome.settled);
    expect(core.requests.sublist(before), ['treatments:fetch']);
    final row = await local('t1');
    expect(
      [row['sync_status'], row['sync_version'], row['sync_write_id']],
      ['synced', 2, null],
    );
  });

  test(
    'a lost answer, then a newer edit: only the newer edit goes out',
    () async {
      await warmUp();
      await edit('t1', {'notes': 'after food'}, DateTime.utc(2026, 3, 5, 10));
      remote.loseAnswerFor.add('t1');
      await expectLater(
        sync.pushRow(await local('t1'), userId: 'u'),
        throwsA(isA<TimeoutException>()),
      );
      await edit('t1', {
        'doctor': 'Dr. Bianchi',
      }, DateTime.utc(2026, 3, 5, 10, 5));
      final result = await sync.pushRow(await local('t1'), userId: 'u');
      expect(result.outcome, PushOutcome.settled);
      final server = remote.get('t1')!;
      expect(
        [server['notes'], server['doctor'], server['row_version']],
        ['after food', 'Dr. Bianchi', 3],
      );
      expect(core.requests.last, 'treatments:patch');
    },
  );

  test('pull: a pending local edit merges with a newer server copy', () async {
    await warmUp();
    await edit('t1', {
      'sick_leave_ref': 'CERT-B',
    }, DateTime.utc(2026, 3, 5, 10));
    final horizon = core.horizon;
    remote.editFromOtherDevice('t1', {
      'end_date': '2026-03-05',
      'is_active': false,
    }, editedAt: DateTime.utc(2026, 3, 5, 9));
    final page = core.page(
      'treatments',
      horizon: core.horizon,
      afterXid: horizon,
    );
    final applied = await sync.applyPulled(page.single);
    expect(applied.outcome, PullOutcome.merged);
    final row = await local('t1');
    expect(
      [
        row['sync_status'],
        row['is_active'],
        row['sick_leave_ref'],
        row['sync_version'],
      ],
      ['pending_update', 0, 'CERT-B', 2],
    );
    // The push then sends only the certificate number.
    await sync.pushRow(await local('t1'), userId: 'u');
    expect(remote.get('t1')!['sick_leave_ref'], 'CERT-B');
    expect(remote.get('t1')!['row_version'], 3);
  });

  test('same field: the later edit wins, the other is reported', () async {
    await warmUp();
    remote.editFromOtherDevice('t1', {
      'sick_leave_ref': 'A',
    }, editedAt: DateTime.utc(2026, 3, 5, 10, 5));
    await edit('t1', {'sick_leave_ref': 'B'}, DateTime.utc(2026, 3, 5, 10, 7));
    final result = await sync.pushRow(await local('t1'), userId: 'u');
    expect(result.conflicts.single.keptLocal, isTrue);
    expect(remote.get('t1')!['sick_leave_ref'], 'B');
  });

  test('delete of a never-confirmed create leaves a tombstone', () async {
    final db = await AppDatabase.instance.database;
    await db.insert('treatments', {
      'id': 't9',
      'name': 'Cold',
      'start_date': '2026-03-05',
      'is_active': 1,
      'updated_at': '2026-03-05T11:00:00.000Z',
      'sync_status': 'pending_delete',
      'sync_write_id': 'lost',
      'deleted_at': '2026-03-05T11:30:00.000Z',
    });
    await sync.pushRow(
      await db.query('treatments', where: "id = 't9'").then((r) => r.single),
      userId: 'u',
    );
    expect(remote.get('t9')!['deleted_at'], isNotNull);
    // The late insert lands and changes nothing.
    core.insertIfAbsent('treatments', [
      {
        'id': 't9',
        'user_id': 'u',
        'name': 'Cold',
        'start_date': '2026-03-05',
        'write_id': 'lost',
      },
    ]);
    expect(remote.get('t9')!['deleted_at'], isNotNull);
    expect(await db.query('treatments', where: "id = 't9'"), isEmpty);
  });

  group('doses', () {
    late FakeSyncTable doses;
    late TableSync doseSync;
    setUp(() async {
      doses = FakeSyncTable(core, 'dose_logs');
      doseSync = TableSync(
        table: 'dose_logs',
        remote: doses,
        newWriteId: () => 'd${ids++}',
        now: () => now,
      );
      final db = await AppDatabase.instance.database;
      await db.insert('medications', {
        'id': 'm1',
        'name': 'Ibu',
        'quantity': 10,
        'sync_status': 'synced',
      });
      await db.insert('treatments', {
        'id': 't1',
        'name': 'Flu',
        'start_date': '2026-03-01',
        'is_active': 1,
        'sync_status': 'synced',
      });
      await db.insert('prescriptions', {
        'id': 'p1',
        'treatment_id': 't1',
        'medication_id': 'm1',
        'dosage': '1',
        'start_time': '2026-03-01T08:00:00.000',
        'sync_status': 'synced',
      });
      // A generated dose, inserted by another device, pulled here.
      core.insertIfAbsent('dose_logs', [
        {
          'id': 'd1',
          'prescription_id': 'p1',
          'scheduled_time': '2026-03-01T07:00:00.000Z',
          'status': 'pending',
          'updated_at': '1970-01-01T00:00:00.000Z',
          'write_id': 'gen',
          'edited_at': '1970-01-01T00:00:00.000Z',
        },
      ]);
      for (final row in core.page('dose_logs', horizon: core.horizon)) {
        await doseSync.applyPulled(row);
      }
    });

    Future<Map<String, Object?>> dose() async =>
        (await (await AppDatabase.instance.database).query(
          'dose_logs',
          where: "id = 'd1'",
        )).single;

    Future<void> localChange(Map<String, Object?> values) async {
      final db = await AppDatabase.instance.database;
      await db.update('dose_logs', {
        ...values,
        'sync_status': 'pending_update',
      }, where: "id = 'd1'");
    }

    test('automatic missed loses to a take made elsewhere', () async {
      doses.editFromOtherDevice('d1', {
        'status': 'taken',
        'taken_time': '2026-03-01T07:05:00.000Z',
      }, editedAt: DateTime.utc(2026, 3, 1, 7, 5));
      await localChange({
        'status': 'missed',
        'edited_at': automaticEditedAt.toIso8601String(),
      });
      final result = await doseSync.pushRow(await dose(), userId: 'u');
      expect(result.outcome, PushOutcome.settled);
      expect(doses.get('d1')!['status'], 'taken');
      expect((await dose())['status'], 'taken');
      expect((await dose())['sync_status'], 'synced');
    });

    test('automatic missed lands as missed and keeps updated_at', () async {
      await localChange({
        'status': 'missed',
        'edited_at': automaticEditedAt.toIso8601String(),
      });
      await doseSync.pushRow(await dose(), userId: 'u');
      expect(
        [
          doses.get('d1')!['status'],
          doses.get('d1')!['updated_at'],
          doses.get('d1')!['edited_at'],
        ],
        ['missed', '1970-01-01T00:00:00.000Z', '1970-01-01T00:00:00.000Z'],
      );
    });

    test(
      'a shifted time correction and a take elsewhere are both kept',
      () async {
        doses.editFromOtherDevice('d1', {
          'status': 'taken',
          'taken_time': '2026-03-01T07:05:00.000Z',
        }, editedAt: DateTime.utc(2026, 3, 1, 7, 5));
        await localChange({
          'scheduled_time': '2026-03-01T06:00:00.000',
          'edited_at': automaticEditedAt.toIso8601String(),
        });
        await doseSync.pushRow(await dose(), userId: 'u');
        final server = doses.get('d1')!;
        expect(
          [
            server['status'],
            DateTime.parse(server['scheduled_time'] as String).toUtc(),
          ],
          ['taken', DateTime.parse('2026-03-01T06:00:00.000').toUtc()],
        );
      },
    );

    test('a dropped slot is deleted only while pending', () async {
      doses.editFromOtherDevice('d1', {
        'status': 'taken',
        'taken_time': '2026-03-01T07:05:00.000Z',
      }, editedAt: DateTime.utc(2026, 3, 1, 7, 5));
      final db = await AppDatabase.instance.database;
      await db.update('dose_logs', {
        'sync_status': 'pending_delete',
        'delete_guard': 'if_pending',
      }, where: "id = 'd1'");
      await doseSync.pushRow(await dose(), userId: 'u');
      expect(doses.get('d1')!['deleted_at'], isNull);
      final row = await dose();
      expect(
        [row['status'], row['sync_status'], row['delete_guard']],
        ['taken', 'synced', null],
      );
    });

    test(
      'a dropped slot still pending is deleted on the server and here',
      () async {
        final db = await AppDatabase.instance.database;
        await db.update('dose_logs', {
          'sync_status': 'pending_delete',
          'delete_guard': 'if_pending',
        }, where: "id = 'd1'");
        await doseSync.pushRow(await dose(), userId: 'u');
        expect(doses.get('d1')!['deleted_at'], isNotNull);
        expect(await db.query('dose_logs', where: "id = 'd1'"), isEmpty);
      },
    );
  });

  test('isAutomaticEdit', () {
    expect(isAutomaticEdit(automaticEditedAt), isTrue);
    expect(isAutomaticEdit(DateTime.utc(2026)), isFalse);
    expect(syncedTables, hasLength(4));
  });
}
```

Run: `fvm flutter test test/data/sync/row_settle_test.dart test/data/sync/table_sync_test.dart`
Expected: FAIL to load.

- [ ] **Step 4: The engine**

Create `lib/data/sync/sync_meta.dart`:

```dart
/// Medora - A synced row's local bookkeeping (sync v2).
///
/// Next to its data, every local row of the four synced tables keeps:
/// - `edited_at`: when its last change was made here (1970 for a change the
///   app made on its own);
/// - `sync_version` and `sync_base`: the server's `row_version` and the
///   canonical copy of the server row this device was last in step with,
///   the base of every merge;
/// - `sync_write_id`: the write attempt whose answer never arrived.
library;

import 'dart:convert';

import 'package:medora/data/datasources/dose_log_local_datasource.dart';
import 'package:medora/data/datasources/medication_local_datasource.dart';
import 'package:medora/data/datasources/prescription_local_datasource.dart';
import 'package:medora/data/datasources/treatment_local_datasource.dart';
import 'package:medora/data/models/dose_log_model.dart';
import 'package:medora/data/models/medication_model.dart';
import 'package:medora/data/models/prescription_model.dart';
import 'package:medora/data/models/treatment_model.dart';

/// The tables sync v2 merges, in foreign-key order.
const syncedTables = [
  'medications',
  'treatments',
  'prescriptions',
  'dose_logs',
];

/// The bookkeeping columns of a synced local row.
const syncMetaColumnNames = [
  'edited_at',
  'sync_version',
  'sync_base',
  'sync_write_id',
];

/// The canonical wire copy of [json], a server row: its model's `toJson`, so
/// two copies with equal content compare equal whatever format each side
/// wrote its timestamps in.
Map<String, Object?> canonicalWire(String table, Map<String, dynamic> json) =>
    switch (table) {
      'medications' => MedicationModel.fromJson(json).toJson(),
      'treatments' => TreatmentModel.fromJson(json).toJson(),
      'prescriptions' => PrescriptionModel.fromJson(json).toJson(),
      'dose_logs' => DoseLogModel.fromJson(json).toJson(),
      _ => throw ArgumentError.value(table, 'table', 'not a synced table'),
    };

/// The wire copy of the local row [row]. [userId] fills `user_id` on the
/// tables that carry it.
Map<String, Object?> localWire(
  String table,
  Map<String, Object?> row, {
  String? userId,
}) => switch (table) {
  'medications' => MedicationModel.fromLocalMap({
    ...row,
    'user_id': userId ?? row['user_id'],
  }).toJson(),
  'treatments' => TreatmentModel.fromLocalMap({
    ...row,
    'user_id': userId ?? row['user_id'],
  }).toJson(),
  'prescriptions' => PrescriptionModel.fromLocalMap(row).toJson(),
  'dose_logs' => DoseLogModel.fromLocalMap(row).toJson(),
  _ => throw ArgumentError.value(table, 'table', 'not a synced table'),
};

/// The local row (data columns and `sync_status`) for the server row
/// [json].
Map<String, Object?> localRowOf(
  String table,
  Map<String, dynamic> json,
  String syncStatus,
) => switch (table) {
  'medications' => MedicationLocalDatasource.rowOf(
    MedicationModel.fromJson(json),
    syncStatus,
  ),
  'treatments' => TreatmentLocalDatasource.rowOf(
    TreatmentModel.fromJson(json),
    syncStatus,
  ),
  'prescriptions' => PrescriptionLocalDatasource.rowOf(
    PrescriptionModel.fromJson(json),
    syncStatus,
  ),
  'dose_logs' => DoseLogLocalDatasource.rowOf(
    DoseLogModel.fromJson(json),
    syncStatus,
  ),
  _ => throw ArgumentError.value(table, 'table', 'not a synced table'),
};

/// The bookkeeping of one local row.
class LocalSyncMeta {
  const LocalSyncMeta({this.version, this.base, this.writeId, this.editedAt});

  factory LocalSyncMeta.fromRow(Map<String, Object?> row) {
    final rawBase = row['sync_base'] as String?;
    final rawEdited = row['edited_at'] as String?;
    return LocalSyncMeta(
      version: row['sync_version'] as int?,
      base: rawBase == null
          ? null
          : (jsonDecode(rawBase) as Map<String, dynamic>),
      writeId: row['sync_write_id'] as String?,
      editedAt: rawEdited == null ? null : DateTime.tryParse(rawEdited),
    );
  }

  final int? version;
  final Map<String, Object?>? base;
  final String? writeId;
  final DateTime? editedAt;
}

/// The bookkeeping columns for a row now in step with the server row
/// [version] / [base]. [editedAt] is written only when given.
Map<String, Object?> syncMetaValues({
  required int? version,
  required Map<String, Object?>? base,
  String? writeId,
  DateTime? editedAt,
}) => {
  'sync_version': version,
  'sync_base': base == null ? null : jsonEncode(base),
  'sync_write_id': writeId,
  if (editedAt != null) 'edited_at': editedAt.toUtc().toIso8601String(),
};

/// The bookkeeping columns cleared: nothing is known about the server copy.
const Map<String, Object?> clearedSyncMeta = {
  'sync_version': null,
  'sync_base': null,
  'sync_write_id': null,
};
```

Create `lib/data/sync/row_settle.dart`:

```dart
/// Medora - What a sync cycle does with a row it has just pushed (sync v2).
library;

import 'package:medora/data/datasources/stock_outbox_local_datasource.dart';
import 'package:medora/data/datasources/sync_table.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/sync/sync_meta.dart';
import 'package:sqflite/sqflite.dart';

/// Settles the row [pushed] of [table] after the server answered [server]
/// for it (the row as written, or as fetched when it carries this device's
/// write id). Returns true when the row still has changes to push.
///
/// - **Unchanged since the push read it** (same local `updated_at`): the
///   server copy is stored as `synced` and becomes the base.
/// - **Edited while the push was in flight:** the server copy becomes the
///   base and the row stays `pending_update`, so the next push sends only
///   the newer difference.
/// - **Deleted meanwhile** (`pending_delete`) or gone: left alone; a pending
///   delete returns true.
Future<bool> settlePushedRow(
  Database db,
  String table, {
  required Map<String, Object?> pushed,
  required Map<String, dynamic> server,
  required String Function() newOpId,
}) {
  final id = pushed['id']! as String;
  final meta = RemoteMeta.fromJson(server);
  final base = canonicalWire(table, server);
  return db.transaction((txn) async {
    final rows = await txn.query(table, where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) return false;
    final current = rows.first;
    final status = current['sync_status'] as String?;
    if (status == SyncStatus.pendingDelete) return true;
    if (current['updated_at'] == pushed['updated_at']) {
      final row = localRowOf(table, server, SyncStatus.synced);
      if (table == 'medications') {
        row['quantity'] = applyStockOps(
          (server['quantity'] as num?)?.toInt() ?? 0,
          await StockOutboxLocalDatasource.pendingIn(txn, medicationId: id),
        );
      }
      row.addAll(
        syncMetaValues(
          version: meta.rowVersion,
          base: base,
          editedAt: meta.effectiveEditedAt,
        ),
      );
      if (table == 'dose_logs') row['delete_guard'] = null;
      await txn.update(table, row, where: 'id = ?', whereArgs: [id]);
      return false;
    }
    await txn.update(
      table,
      {
        ...syncMetaValues(version: meta.rowVersion, base: base),
        'sync_status': SyncStatus.pendingUpdate,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
    return true;
  });
}
```

Create `lib/data/sync/table_sync.dart`:

```dart
/// Medora - Pull and push of one synced table (sync v2).
///
/// The sync cycle (`SyncService`) decides when and in which order; this
/// class does the per-row work for medications, treatments, prescriptions
/// and dose logs: it applies a pulled row (storing it, merging it with a
/// pending local change, or deleting), and pushes one pending row
/// (conditional on the server version it was based on, recognising its own
/// write when an answer was lost). It records nothing about failures: an
/// error propagates to the cycle, which backs the row off.
library;

import 'package:medora/data/datasources/stock_outbox_local_datasource.dart';
import 'package:medora/data/datasources/sync_table.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/sync/row_merge.dart';
import 'package:medora/data/sync/row_settle.dart';
import 'package:medora/data/sync/sync_meta.dart';
import 'package:sqflite/sqflite.dart';

/// What applying one pulled row did.
enum PullOutcome {
  /// A row new to this device was stored.
  inserted,

  /// The local copy was replaced by the server's.
  replaced,

  /// A pending local change was merged with the server's copy.
  merged,

  /// The local row was deleted (a tombstone).
  deleted,

  /// Nothing changed: a local delete waits to be pushed, or the server copy
  /// is one this device already merged.
  kept,
}

class PullApplied {
  const PullApplied(this.outcome, [this.conflicts = const []]);
  final PullOutcome outcome;

  /// Groups both sides changed; see [MergeConflict].
  final List<MergeConflict> conflicts;
}

/// What pushing one row did.
enum PushOutcome {
  /// The row is in step with the server (or gone).
  settled,

  /// The row still has changes for a later cycle: it was edited while the
  /// push ran, or the server moved on twice while this cycle merged.
  pending,
}

class PushResult {
  const PushResult(this.outcome, [this.conflicts = const []]);
  final PushOutcome outcome;
  final List<MergeConflict> conflicts;
}

class TableSync {
  TableSync({
    required this.table,
    required this.remote,
    required this.newWriteId,
    required this.now,
  }) : policy = mergePolicyOf(table);

  final String table;
  final SyncTable remote;

  /// A fresh id for a write attempt or a stock change (uuid v4 in the app).
  final String Function() newWriteId;
  final DateTime Function() now;
  final MergePolicy policy;

  /// How many times one push tries again after the server moved on.
  static const maxAttempts = 2;

  Future<Database> get _db => AppDatabase.instance.database;

  // ── Pull ───────────────────────────────────────────────────

  /// Applies the pulled server row [json] (see the design, section 7.2).
  Future<PullApplied> applyPulled(Map<String, dynamic> json) async {
    final db = await _db;
    return db.transaction((txn) => _applyPulled(txn, json));
  }

  Future<PullApplied> _applyPulled(
    Transaction txn,
    Map<String, dynamic> json,
  ) async {
    final id = json['id']! as String;
    final meta = RemoteMeta.fromJson(json);
    final rows = await txn.query(table, where: 'id = ?', whereArgs: [id]);
    final local = rows.isEmpty ? null : rows.first;
    final tombstone = meta.deletedAt != null;

    if (local == null) {
      if (tombstone) return const PullApplied(PullOutcome.kept);
      await _storeServer(txn, json, meta, SyncStatus.synced, exists: false);
      return const PullApplied(PullOutcome.inserted);
    }

    final status = local['sync_status'] as String?;
    final localMeta = LocalSyncMeta.fromRow(local);
    final localEditedAt = _editedAtOf(local, localMeta);
    final pending =
        status == SyncStatus.pendingCreate ||
        status == SyncStatus.pendingUpdate;
    // An automatic tombstone (a dose dropped from a changed schedule) loses
    // to a real change still waiting here; every other tombstone wins.
    final resurrect =
        tombstone &&
        isAutomaticEdit(meta.editedAt) &&
        pending &&
        !isAutomaticEdit(localEditedAt);
    if (tombstone && !resurrect) {
      await txn.delete(table, where: 'id = ?', whereArgs: [id]);
      return const PullApplied(PullOutcome.deleted);
    }

    if (status == SyncStatus.pendingDelete) {
      final guarded = local['delete_guard'] == 'if_pending';
      if (guarded && json['status'] != 'pending') {
        await _storeServer(txn, json, meta, SyncStatus.synced, exists: true);
        return const PullApplied(PullOutcome.replaced);
      }
      return const PullApplied(PullOutcome.kept);
    }

    final knownVersion = localMeta.version;
    if (!pending) {
      // A synced row at this version already holds this content.
      if (knownVersion != null && meta.rowVersion <= knownVersion) {
        return const PullApplied(PullOutcome.kept);
      }
      await _storeServer(txn, json, meta, SyncStatus.synced, exists: true);
      return const PullApplied(PullOutcome.replaced);
    }

    final remoteWire = canonicalWire(table, json);
    final localCopy = localWire(table, local);
    if (localMeta.writeId != null && meta.writeId == localMeta.writeId) {
      return _adoptOwnWrite(txn, json, meta, remoteWire, localCopy);
    }
    if (knownVersion != null && meta.rowVersion <= knownVersion) {
      return const PullApplied(PullOutcome.kept);
    }

    final merge = mergeRows(
      base: localMeta.base,
      local: localCopy,
      remote: remoteWire,
      localEditedAt: localEditedAt,
      remoteEditedAt: meta.effectiveEditedAt,
      policy: policy,
    );
    final settled = !resurrect && sameContent(merge.row, remoteWire, policy);
    await _storeServer(
      txn,
      {...json, ...merge.row, if (resurrect) 'deleted_at': null},
      meta,
      settled ? SyncStatus.synced : SyncStatus.pendingUpdate,
      exists: true,
      base: remoteWire,
      editedAt: settled ? meta.effectiveEditedAt : localEditedAt,
    );
    return PullApplied(PullOutcome.merged, merge.conflicts);
  }

  /// The server copy carries this device's unconfirmed write: it becomes the
  /// base; the row is in step if nothing changed here since.
  Future<PullApplied> _adoptOwnWrite(
    Transaction txn,
    Map<String, dynamic> json,
    RemoteMeta meta,
    Map<String, Object?> remoteWire,
    Map<String, Object?> localCopy,
  ) async {
    final id = json['id']! as String;
    if (sameContent(localCopy, remoteWire, policy)) {
      await _storeServer(txn, json, meta, SyncStatus.synced, exists: true);
      return const PullApplied(PullOutcome.replaced);
    }
    await txn.update(
      table,
      {
        ...syncMetaValues(version: meta.rowVersion, base: remoteWire),
        'sync_status': SyncStatus.pendingUpdate,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
    return const PullApplied(PullOutcome.kept);
  }

  /// Stores the server row [json] as the local row, with [status] and the
  /// bookkeeping of [meta]. [base] defaults to the canonical copy of [json].
  Future<void> _storeServer(
    Transaction txn,
    Map<String, dynamic> json,
    RemoteMeta meta,
    String status, {
    required bool exists,
    Map<String, Object?>? base,
    DateTime? editedAt,
  }) async {
    final id = json['id']! as String;
    final row = localRowOf(table, json, status);
    if (table == 'medications') {
      row['quantity'] = applyStockOps(
        (json['quantity'] as num?)?.toInt() ?? 0,
        await StockOutboxLocalDatasource.pendingIn(txn, medicationId: id),
      );
    }
    row.addAll(
      syncMetaValues(
        version: meta.rowVersion,
        base: base ?? canonicalWire(table, json),
        editedAt: editedAt ?? meta.effectiveEditedAt,
      ),
    );
    if (table == 'dose_logs') row['delete_guard'] = null;
    // Update first: an INSERT OR REPLACE would cascade-delete the children.
    final updated = exists
        ? await txn.update(table, row, where: 'id = ?', whereArgs: [id])
        : 0;
    if (updated == 0) {
      await txn.insert(table, row, conflictAlgorithm: ConflictAlgorithm.ignore);
    }
  }

  // ── Push ───────────────────────────────────────────────────

  /// Pushes the pending local row [row] (`pending_create`, `pending_update`
  /// or `pending_delete`). [userId] fills `user_id` where the table has it.
  /// With [force] every column is sent, whatever the server holds.
  Future<PushResult> pushRow(
    Map<String, Object?> row, {
    required String? userId,
    bool force = false,
  }) async {
    final id = row['id']! as String;
    if (row['sync_status'] == SyncStatus.pendingDelete) {
      await _pushDelete(row, userId: userId);
      return const PushResult(PushOutcome.settled);
    }
    if (force) return _forcePush(row, userId: userId);
    final conflicts = <MergeConflict>[];
    var local = await _resolveUnknownWrite(row, conflicts);
    for (var attempt = 0; attempt < maxAttempts && local != null; attempt++) {
      final status = local['sync_status'] as String?;
      if (status == SyncStatus.synced) break;
      final meta = LocalSyncMeta.fromRow(local);
      if (status == SyncStatus.pendingCreate || meta.version == null) {
        local = await _pushCreate(local, userId: userId, conflicts: conflicts);
        continue;
      }
      final changes = patchColumns(policy, meta.base, localWire(table, local));
      if (changes.isEmpty) {
        await _markSynced(id, local['updated_at']);
        return PushResult(PushOutcome.settled, conflicts);
      }
      final writeId = await _beginWrite(local);
      final written = await remote.patch(id, {
        ...changes,
        'write_id': writeId,
        'edited_at': _wireTime(_editedAtOf(local, meta) ?? now()),
      }, ifVersion: meta.version);
      if (written != null) {
        return _settle(local, written, conflicts);
      }
      final server = await remote.fetch(id);
      if (server == null) {
        local = await _asCreate(local);
        continue;
      }
      if (RemoteMeta.fromJson(server).writeId == writeId) {
        return _settle(local, server, conflicts);
      }
      local = await _mergeFrom(server, conflicts);
    }
    return PushResult(
      local == null || local['sync_status'] == SyncStatus.synced
          ? PushOutcome.settled
          : PushOutcome.pending,
      conflicts,
    );
  }

  /// "My copy is the truth": every column, whatever version the server
  /// holds; a row the server lacks is inserted.
  Future<PushResult> _forcePush(
    Map<String, Object?> row, {
    required String? userId,
  }) async {
    final id = row['id']! as String;
    final wire = localWire(table, row, userId: userId);
    final writeId = await _beginWrite(row);
    final stamp = {'write_id': writeId, 'edited_at': _wireTime(now())};
    var server = await remote.patch(id, {
      ...writableColumns(policy, wire),
      ...stamp,
    });
    if (server == null) {
      await remote.insertIfAbsent([
        {...wire, ...stamp},
      ]);
      server = await remote.fetch(id);
      if (server == null) {
        throw StateError('$table/$id is not on the server after insert');
      }
    }
    return _settle(row, server, const []);
  }

  /// A row whose last write attempt never got an answer: when the server
  /// holds that write, it becomes the base. Returns the row to go on with,
  /// or null when it is gone.
  Future<Map<String, Object?>?> _resolveUnknownWrite(
    Map<String, Object?> row,
    List<MergeConflict> conflicts,
  ) async {
    final id = row['id']! as String;
    final writeId = row['sync_write_id'] as String?;
    if (writeId == null) return row;
    final server = await remote.fetch(id);
    if (server != null && RemoteMeta.fromJson(server).writeId == writeId) {
      final db = await _db;
      final applied = await db.transaction((txn) => _applyPulled(txn, server));
      conflicts.addAll(applied.conflicts);
    } else {
      await _update(id, {'sync_write_id': null});
    }
    return _read(id);
  }

  /// Inserts the row where the server lacks it and reads it back.
  Future<Map<String, Object?>?> _pushCreate(
    Map<String, Object?> local, {
    required String? userId,
    required List<MergeConflict> conflicts,
  }) async {
    final id = local['id']! as String;
    final meta = LocalSyncMeta.fromRow(local);
    if (meta.version == null &&
        local['sync_status'] != SyncStatus.pendingCreate) {
      // An update with no known server copy: read it first.
      final server = await remote.fetch(id);
      if (server != null) return _mergeFrom(server, conflicts);
    }
    final writeId = await _beginWrite(local);
    await remote.insertIfAbsent([
      {
        ...localWire(table, local, userId: userId),
        'write_id': writeId,
        'edited_at': _wireTime(_editedAtOf(local, meta) ?? now()),
      },
    ]);
    final server = await remote.fetch(id);
    if (server == null) {
      throw StateError('$table/$id is not on the server after insert');
    }
    if (RemoteMeta.fromJson(server).writeId == writeId) {
      await settlePushedRow(
        await _db,
        table,
        pushed: local,
        server: server,
        newOpId: newWriteId,
      );
      return _read(id);
    }
    return _mergeFrom(server, conflicts);
  }

  /// Sends a person's delete, or, for a dose the app dropped from a changed
  /// schedule, a delete that applies only while the dose is still pending.
  Future<void> _pushDelete(
    Map<String, Object?> row, {
    required String? userId,
  }) async {
    final id = row['id']! as String;
    final guarded = table == 'dose_logs' && row['delete_guard'] == 'if_pending';
    final createMayLand = row['sync_write_id'] != null;
    final writeId = await _beginWrite(row);
    final deletedAt = _wireTime(now());
    final editedAt = _wireTime(guarded ? automaticEditedAt : now());
    final written = await remote.patch(
      id,
      {'deleted_at': deletedAt, 'write_id': writeId, 'edited_at': editedAt},
      ifStatus: guarded ? 'pending' : null,
      ifLive: guarded,
    );
    if (written == null) {
      final server = await remote.fetch(id);
      if (server == null) {
        if (createMayLand && !guarded) {
          // Its create may still land; a tombstone in its place wins.
          await remote.insertIfAbsent([
            {
              ...localWire(table, row, userId: userId),
              'deleted_at': deletedAt,
              'write_id': writeId,
              'edited_at': editedAt,
            },
          ]);
        }
      } else if (server['deleted_at'] == null) {
        if (!guarded) {
          throw StateError('$table/$id: the server refused the delete');
        }
        // Taken or skipped elsewhere meanwhile: keep that copy.
        final db = await _db;
        await db.transaction((txn) async {
          await txn.update(
            table,
            {'sync_status': SyncStatus.synced, 'delete_guard': null},
            where: 'id = ?',
            whereArgs: [id],
          );
          await _applyPulled(txn, server);
        });
        return;
      }
    }
    final db = await _db;
    await db.delete(table, where: 'id = ?', whereArgs: [id]);
  }

  // ── Helpers ────────────────────────────────────────────────

  /// Stores a fresh write id on the row before it is sent, so an answer
  /// that never arrives can be recognised later.
  Future<String> _beginWrite(Map<String, Object?> local) async {
    final writeId = newWriteId();
    await _update(local['id']! as String, {'sync_write_id': writeId});
    return writeId;
  }

  Future<PushResult> _settle(
    Map<String, Object?> local,
    Map<String, dynamic> server,
    List<MergeConflict> conflicts,
  ) async {
    final pending = await settlePushedRow(
      await _db,
      table,
      pushed: local,
      server: server,
      newOpId: newWriteId,
    );
    return PushResult(
      pending ? PushOutcome.pending : PushOutcome.settled,
      conflicts,
    );
  }

  /// Merges the server copy [server] into the local row and returns the
  /// row as stored.
  Future<Map<String, Object?>?> _mergeFrom(
    Map<String, dynamic> server,
    List<MergeConflict> conflicts,
  ) async {
    final db = await _db;
    final applied = await db.transaction((txn) => _applyPulled(txn, server));
    conflicts.addAll(applied.conflicts);
    return _read(server['id']! as String);
  }

  /// The server no longer has the row (a purge): send it as new.
  Future<Map<String, Object?>?> _asCreate(Map<String, Object?> local) async {
    final id = local['id']! as String;
    await _update(id, {
      ...clearedSyncMeta,
      'sync_status': SyncStatus.pendingCreate,
    });
    return _read(id);
  }

  Future<void> _markSynced(String id, Object? pushedUpdatedAt) async {
    final db = await _db;
    await db.update(
      table,
      {'sync_status': SyncStatus.synced, 'sync_write_id': null},
      where: 'id = ? AND updated_at IS ?',
      whereArgs: [id, pushedUpdatedAt],
    );
  }

  Future<void> _update(String id, Map<String, Object?> values) async {
    final db = await _db;
    await db.update(table, values, where: 'id = ?', whereArgs: [id]);
  }

  Future<Map<String, Object?>?> _read(String id) async {
    final db = await _db;
    final rows = await db.query(table, where: 'id = ?', whereArgs: [id]);
    return rows.isEmpty ? null : rows.first;
  }

  static DateTime? _editedAtOf(Map<String, Object?> row, LocalSyncMeta meta) =>
      meta.editedAt ??
      (row['updated_at'] is String
          ? DateTime.tryParse(row['updated_at']! as String)
          : null);

  static String _wireTime(DateTime time) => time.toUtc().toIso8601String();
}

/// The columns of [local] a push sends: those that differ from [base], plus
/// `deleted_at: null` when the base is a tombstone this row brings back.
Map<String, Object?> patchColumns(
  MergePolicy policy,
  Map<String, Object?>? base,
  Map<String, Object?> local,
) => {
  for (final column in changedColumns(base, local, policy))
    column: local[column],
  if (base?['deleted_at'] != null && local['deleted_at'] == null)
    'deleted_at': null,
};

/// Every column of [local] a client writes: bookkeeping and server-owned
/// columns left out.
Map<String, Object?> writableColumns(
  MergePolicy policy,
  Map<String, Object?> local,
) => {
  for (final entry in local.entries)
    if (!MergePolicy.bookkeeping.contains(entry.key) &&
        !policy.serverOwned.contains(entry.key))
      entry.key: entry.value,
};
```

Run: `fvm flutter test test/data/sync`
Expected: all pass, including `row_merge_test` +11, `row_settle_test` +4 and `table_sync_test` +12. The old `push_settle_test.dart` still passes, because the old cycle is untouched.

- [ ] **Step 5: Mutation checks (scratch worktree)**

1. In `_isLater`, change `if (a == null || a.toUtc().isBefore(weakEditCeiling)) return false;` to `if (a == null) return false;` → `an automatic change never beats a real one, even a much older one or one with no known edit time` fails.
2. In `mergeRows`, use `final takeLocal = true;` → these fail:
   - `a tie keeps the server copy`;
   - `the same group changed on both sides…`;
   - `an automatic change never beats a real one…`;
   - `automatic missed loses to a take made elsewhere`.
3. In `_pushDelete`, change `ifStatus: guarded ? 'pending' : null,` to `ifStatus: null,` → `a dropped slot is deleted only while pending` fails.

Remove the worktree.

- [ ] **Step 6: Gates and commit**

Run the gates. Expected: everything green; the suite count grows by 27 (11 + 4 + 12).

Commit `feat(sync): the sync v2 merge engine (row merge, settle, per-row pull and push)` with the four library files and the three tests. The body says the cycle does not use the engine yet (Task 6).

---

## Task 6: Switch the cycle to sync v2

**What this task delivers:**
- `SyncService` runs the cycle of design §7.1: migration check, push through `TableSync`, paged pull to the horizon, merge.
- The dose changes the app makes on its own are pushed as automatic changes:
  - overdue "missed";
  - shifted times moved back to their slot;
  - dropped slots deleted only while pending.
- Settings names a missing migration.
- The sync suites move to the v2 fakes.

Stock still goes out as a column in this task (Task 7 moves it to the ledger).

**Files:**
- Modify: `lib/services/sync_service.dart` (rewritten)
- Modify: `lib/services/sync_cursor_store.dart` (rewritten: pull keys, repair version 2)
- Modify: `lib/services/sync_report.dart` (`SyncOverwrite`, `merged`, `overwritten`, `missingMigration`; `skippedStale` removed)
- Modify: `lib/services/local_data_wiper.dart` (wipes the pull keys too)
- Modify: `lib/data/datasources/medication_remote_datasource.dart`, `treatment_remote_datasource.dart`, `prescription_remote_datasource.dart`, `dose_log_remote_datasource.dart` (only `rows`, plus `stock` for medications)
- Delete: `lib/data/datasources/pull_page.dart`, `lib/data/sync/push_settle.dart`
- Modify: `lib/data/datasources/dose_log_local_datasource.dart` (`dropPendingByPrescription`, `markOverduePendingAsMissed({pushable})`, `correctScheduledTimes`; `deletePendingByPrescription` and `isAutomaticallyMissedCopyOf` removed)
- Modify: `lib/domain/repositories/dose_log_repository.dart`, `lib/data/repositories/dose_log_repository_impl.dart` (`correctDoseTimes`, the guarded drop, the sweep flag)
- Modify: `lib/services/dose_schedule_service.dart` (corrects shifted slots before comparing)
- Modify: `lib/presentation/providers/providers.dart` (`syncStateDatasourceProvider`)
- Modify: `lib/presentation/screens/settings/widgets/settings_cloud_section.dart` (the migration line)
- Modify: `lib/l10n/app_en.arb`, `app_de.arb`, `app_it.arb` (`syncNeedsMigration`) and the generated files
- Test, replaced: `test/helpers/fake_remotes.dart`, `test/services/sync_cursor_store_test.dart`
- Test, created: `test/data/datasources/dose_log_sweep_test.dart`
- Test, deleted: `test/data/datasources/pull_page_test.dart`, `test/data/datasources/remote_upsert_response_test.dart`, `test/data/sync/push_settle_test.dart`
- Test, patched: see Step 2

**Interfaces:**
- Consumes: everything from Tasks 3–5.
- Produces:
  - `SyncService({…, required SyncStateRemoteDatasource? syncState, String Function()? newWriteId, …})`. `syncState` is part of `isAvailable`, and `newWriteId` defaults to `const Uuid().v4`.
  - `SyncCursorStore`: `static const pullKeyPrefix = 'sync.pull_key.'`, `static const pullRepairVersion = 2`, `Future<PullKey?> pullKey(String table)`, `Future<void> setPullKey(String table, PullKey key)`, `Future<void> resetPullKey(String table)`. `lastPullAt`/`setLastPullAt` are removed, and `clear()` also removes the pull keys.
  - `SyncReport`: `int merged`, `final List<SyncOverwrite> overwritten`, `String? missingMigration`; `class SyncOverwrite { SyncOverwrite(String table, String id, Set<String> columns, {required bool keptLocal}); }`.
  - `DoseLogRepository.correctDoseTimes(Map<String, DateTime> slotTimes) → Future<Result<int>>`.
  - `DoseLogLocalDatasource`:
    - `Future<int> dropPendingByPrescription(String prescriptionId, {Set<String> keepIds})`
    - `Future<({int changed, int unpushed})> markOverduePendingAsMissed(DateTime cutoff, {bool pushable = true})`
    - `Future<int> correctScheduledTimes(Map<String, DateTime> slotTimes)`
  - `final syncStateDatasourceProvider = Provider<SyncStateRemoteDatasource?>`
  - ARB `syncNeedsMigration(String file)`:
    - en: "The cloud project needs an update: apply {file}"
    - de: "Das Cloud-Projekt braucht ein Update: {file} anwenden"
    - it: "Il progetto cloud va aggiornato: applica {file}"
  - `Key('syncNeedsMigration')` on the Settings line.

- [ ] **Step 1: The fakes become views of the fake server**

Replace `test/helpers/fake_remotes.dart` with the version below.
- `FakeServer` bundles one `FakeServerCore` with a datasource per table.
- `table` stays as an alias of `rows`, so the existing tests keep their `h.meds.table.rows[...]`, `seed`, `failIds` and `beforeCall`.
- The families keep a small JSON table, since sync v2 leaves them as they were.

```dart
/// The fake remote datasources: thin views of one [FakeServerCore]
/// (`fake_server.dart`), which models the server rules.
library;

import 'package:medora/data/datasources/dose_log_remote_datasource.dart';
import 'package:medora/data/datasources/family_remote_datasource.dart';
import 'package:medora/data/datasources/medication_remote_datasource.dart';
import 'package:medora/data/datasources/prescription_remote_datasource.dart';
import 'package:medora/data/datasources/schema_errors.dart';
import 'package:medora/data/datasources/sync_state_remote_datasource.dart';
import 'package:medora/data/datasources/treatment_remote_datasource.dart';
import 'package:medora/data/models/family_member_model.dart';
import 'package:medora/data/models/family_model.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;

import 'fake_server.dart';

export 'fake_server.dart';

/// One fake Supabase project: the shared core and a datasource per table.
class FakeServer {
  /// [medicationRows], [treatmentRows] and [doseRows] build a misbehaving
  /// table in place of the plain one.
  FakeServer(
    DateTime Function() clock, {
    String currentUserId = 'user-a',
    FakeSyncTable Function(FakeServerCore core)? medicationRows,
    FakeSyncTable Function(FakeServerCore core)? treatmentRows,
    FakeSyncTable Function(FakeServerCore core)? doseRows,
  }) : core = FakeServerCore(clock) {
    meds = FakeMedicationRemote(core, rows: medicationRows?.call(core));
    treatments = FakeTreatmentRemote(core, rows: treatmentRows?.call(core));
    prescriptions = FakePrescriptionRemote(core);
    doses = FakeDoseLogRemote(core, rows: doseRows?.call(core));
    families = FakeFamilyRemote(clock, currentUserId: currentUserId);
    state = FakeSyncState(core);
  }

  final FakeServerCore core;
  late final FakeMedicationRemote meds;
  late final FakeTreatmentRemote treatments;
  late final FakePrescriptionRemote prescriptions;
  late final FakeDoseLogRemote doses;
  late final FakeFamilyRemote families;
  late final FakeSyncState state;
}

class FakeMedicationRemote implements MedicationRemoteDatasource {
  /// [rows] replaces the plain table, for a test that needs a server that
  /// misbehaves.
  FakeMedicationRemote(FakeServerCore core, {FakeSyncTable? rows})
    : rows = rows ?? FakeSyncTable(core, 'medications'),
      stock = FakeStockRemote(core);

  @override
  final FakeSyncTable rows;
  @override
  final FakeStockRemote stock;

  /// [rows], under the name older tests use.
  FakeSyncTable get table => rows;
}

class FakeTreatmentRemote implements TreatmentRemoteDatasource {
  FakeTreatmentRemote(FakeServerCore core, {FakeSyncTable? rows})
    : rows = rows ?? FakeSyncTable(core, 'treatments');

  @override
  final FakeSyncTable rows;
  FakeSyncTable get table => rows;
}

class FakePrescriptionRemote implements PrescriptionRemoteDatasource {
  FakePrescriptionRemote(FakeServerCore core)
    : rows = FakePrescriptionTable(core);

  @override
  final FakePrescriptionTable rows;
  FakeSyncTable get table => rows;

  /// What a `timestamptz` column in a UTC session gives back for [raw]: a
  /// time without an offset is read as UTC, and the answer always carries
  /// one (`2026-03-01T08:00:00+00:00`).
  static String asTimestamptz(String raw) {
    final hasOffset = RegExp(
      r'(Z|[+-]\d{2}(:?\d{2})?)$',
    ).hasMatch(raw.substring(raw.indexOf('T') + 1));
    final utc = hasOffset
        ? DateTime.parse(raw).toUtc()
        : DateTime.parse('${raw}Z');
    final text = utc.toIso8601String();
    return '${text.substring(0, text.length - 1)}+00:00';
  }
}

/// Stores `start_time` the way a `timestamptz` column does.
class FakePrescriptionTable extends FakeSyncTable {
  FakePrescriptionTable(FakeServerCore core) : super(core, 'prescriptions');

  static Map<String, Object?> _asStored(Map<String, Object?> json) => {
    ...json,
    if (json['start_time'] case final String t)
      'start_time': FakePrescriptionRemote.asTimestamptz(t),
  };

  @override
  Future<Map<String, dynamic>?> patch(
    String id,
    Map<String, Object?> changes, {
    int? ifVersion,
    String? ifStatus,
    bool ifLive = false,
  }) => super.patch(
    id,
    _asStored(changes),
    ifVersion: ifVersion,
    ifStatus: ifStatus,
    ifLive: ifLive,
  );

  @override
  Future<void> insertIfAbsent(List<Map<String, Object?>> rows) =>
      super.insertIfAbsent([for (final r in rows) _asStored(r)]);
}

class FakeDoseLogRemote implements DoseLogRemoteDatasource {
  FakeDoseLogRemote(FakeServerCore core, {FakeSyncTable? rows})
    : rows = rows ?? FakeSyncTable(core, 'dose_logs');

  @override
  final FakeSyncTable rows;
  FakeSyncTable get table => rows;
}

class FakeSyncState implements SyncStateRemoteDatasource {
  FakeSyncState(this.core);

  final FakeServerCore core;

  /// False: the project lacks the sync v2 migration.
  bool migrated = true;

  @override
  Future<SyncServerState> read() async {
    if (!migrated) {
      throw const MissingMigrationException(
        migration: syncV2Migration,
        cause: PostgrestException(
          message:
              'Could not find the function public.medora_sync_state without '
              'parameters in the schema cache',
          code: 'PGRST202',
        ),
      );
    }
    return parseSyncState(core.syncState());
  }
}

/// The families' tables, which sync v2 leaves as they were: JSON rows by id.
class FakeRemoteTable {
  FakeRemoteTable(this.clock);

  final DateTime Function() clock;
  final Map<String, Map<String, dynamic>> rows = {};

  /// Ids whose writes throw, as a server that refuses them.
  final Set<String> failIds = {};

  void _guard(String id) {
    if (failIds.contains(id)) throw StateError('remote failure for $id');
  }

  Future<void> upsert(Map<String, dynamic> json) async {
    final id = json['id'] as String;
    _guard(id);
    rows[id] = {...?rows[id], ...json};
  }

  void hardDelete(String id) {
    _guard(id);
    rows.remove(id);
  }

  /// A row already on the server.
  void seed(Map<String, dynamic> json, {DateTime? updatedAt}) {
    rows[json['id'] as String] = {
      ...json,
      'updated_at': (updatedAt ?? clock()).toUtc().toIso8601String(),
    };
  }

  List<Map<String, dynamic>> all() =>
      rows.values.map(Map<String, dynamic>.from).toList();
}

class FakeFamilyRemote implements FamilyRemoteDatasource {
  FakeFamilyRemote(DateTime Function() clock, {this.currentUserId = 'user-a'})
    : families = FakeRemoteTable(clock),
      members = FakeRemoteTable(clock);
  final FakeRemoteTable families;
  final FakeRemoteTable members;
  String currentUserId;

  @override
  Future<FamilyModel> createFamily(FamilyModel family) async {
    await families.upsert(family.toJson());
    return FamilyModel.fromJson(families.rows[family.id]!);
  }

  @override
  Future<void> upsertFamily(FamilyModel family) async =>
      families.upsert(family.toJson());
  @override
  Future<FamilyModel?> getFamilyByInviteCode(String code) async {
    final matches = families.all().where((r) => r['invite_code'] == code);
    return matches.isEmpty ? null : FamilyModel.fromJson(matches.first);
  }

  @override
  Future<FamilyModel?> getFamilyById(String id) async {
    final row = families.rows[id];
    return row == null ? null : FamilyModel.fromJson(row);
  }

  @override
  Future<FamilyMemberModel> addMember(FamilyMemberModel member) async {
    await members.upsert(member.toJson());
    return FamilyMemberModel.fromJson(members.rows[member.id]!);
  }

  @override
  Future<void> upsertMember(FamilyMemberModel member) async =>
      members.upsert(member.toJson());
  @override
  Future<List<FamilyMemberModel>> getMembers(String familyId) async => members
      .all()
      .where((r) => r['family_id'] == familyId)
      .map(FamilyMemberModel.fromJson)
      .toList();
  @override
  Future<void> removeMember(String memberId) async =>
      members.hardDelete(memberId);
  @override
  Future<FamilyMemberModel?> getCurrentMembership() async {
    final matches = members.all().where((r) => r['user_id'] == currentUserId);
    return matches.isEmpty ? null : FamilyMemberModel.fromJson(matches.first);
  }

  @override
  Future<String> regenerateInviteCode(String familyId) async {
    await families.upsert({
      ...families.rows[familyId]!,
      'invite_code': 'NEWCODE',
    });
    return 'NEWCODE';
  }

  @override
  Future<void> deleteFamily(String familyId) async =>
      families.hardDelete(familyId);
  @override
  Future<({FamilyModel family, FamilyMemberModel member})> joinFamily(
    String inviteCode,
    String displayName,
  ) async {
    final family = await getFamilyByInviteCode(inviteCode);
    if (family == null) throw StateError('Invalid invite code');
    final member = FamilyMemberModel(
      id: 'member-$currentUserId',
      familyId: family.id,
      userId: currentUserId,
      displayName: displayName,
      role: 'member',
    );
    await members.upsert(member.toJson());
    return (
      family: family,
      member: FamilyMemberModel.fromJson(members.rows[member.id]!),
    );
  }
}
```

In `test/helpers/failing_dose_repo.dart` and in the fake repository of `test/presentation/screens/dose_schedule_screen_test.dart`, forward the new method. The patch in Step 2 has both.

- [ ] **Step 2: Port the tests**

Delete the tests of removed code:

```bash
git rm test/data/datasources/pull_page_test.dart test/data/datasources/remote_upsert_response_test.dart test/data/sync/push_settle_test.dart
```

`sync_page.dart` is covered by `sync_table_test.dart` (Task 3), and the v2 settle by `row_settle_test.dart` (Task 5).

Replace `test/services/sync_cursor_store_test.dart`. The pull keys are stored as `"xid|id"`; repair version 2 clears the old `sync.last_pull_at.*` keys and the new keys once:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/data/datasources/sync_page.dart';
import 'package:medora/services/sync_cursor_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('in-memory store round-trips, resets one table and clears', () async {
    final store = SyncCursorStore.inMemory();
    expect(await store.pullKey('medications'), isNull);
    await store.setPullKey('medications', const PullKey(812, 'm1'));
    await store.setPullKey('dose_logs', const PullKey(900));
    expect(await store.pullKey('medications'), const PullKey(812, 'm1'));
    await store.resetPullKey('medications');
    expect(await store.pullKey('medications'), isNull);
    expect(await store.pullKey('dose_logs'), const PullKey(900));
    await store.clear();
    expect(await store.pullKey('dose_logs'), isNull);
  });

  test('prefs store keeps keys under sync.pull_key.<table>, and clear() '
      'also drops the old timestamp cursors', () async {
    SharedPreferences.setMockInitialValues({
      'sync.last_pull_at.dose_logs': '2026-03-04T11:00:00.000Z',
    });
    final prefs = await SharedPreferences.getInstance();
    final store = SyncCursorStore(prefs);
    await store.setPullKey('dose_logs', const PullKey(812, 'd|1'));
    expect(prefs.getString('sync.pull_key.dose_logs'), '812|d|1');
    expect(await store.pullKey('dose_logs'), const PullKey(812, 'd|1'));
    await store.clear();
    expect(prefs.getString('sync.pull_key.dose_logs'), isNull);
    expect(prefs.getString('sync.last_pull_at.dose_logs'), isNull);
  });

  group('pull repair (version 2)', () {
    Future<SharedPreferences> prefsWith(Map<String, Object> values) async {
      SharedPreferences.setMockInitialValues(values);
      return SharedPreferences.getInstance();
    }

    test('an upgraded device clears its cursors once and records the repair '
        'only when finished', () async {
      final prefs = await prefsWith({
        'sync.last_pull_at.medications': '2026-03-04T11:00:00.000Z',
        'sync.failed_row.medications/m1': '{}',
      });
      final store = SyncCursorStore(prefs);

      expect(await store.startPullRepair(), isTrue);
      expect(prefs.getString('sync.last_pull_at.medications'), isNull);
      expect(prefs.getString('sync.failed_row.medications/m1'), '{}');
      expect(prefs.getInt('sync.pull_repair.reset'), 2);
      expect(prefs.getInt('sync.pull_repair.done'), isNull);

      // Not finished: still due, but the keys a partial pull stored since
      // are kept.
      await store.setPullKey('medications', const PullKey(812));
      expect(await store.startPullRepair(), isTrue);
      expect(await store.pullKey('medications'), const PullKey(812));

      await store.finishPullRepair();
      expect(prefs.getInt('sync.pull_repair.done'), 2);
      expect(await store.startPullRepair(), isFalse);
      expect(await store.pullKey('medications'), const PullKey(812));
    });

    test('a device that finished the first repair runs this one', () async {
      final prefs = await prefsWith({
        'sync.last_pull_at.dose_logs': '2026-03-04T11:00:00.000Z',
        'sync.pull_repair.reset': 1,
        'sync.pull_repair.done': 1,
      });
      final store = SyncCursorStore(prefs);
      expect(await store.startPullRepair(), isTrue);
      expect(prefs.getString('sync.last_pull_at.dose_logs'), isNull);
    });

    test('without any cursor there is nothing to repair', () async {
      final prefs = await prefsWith({});
      final store = SyncCursorStore(prefs);
      expect(await store.startPullRepair(), isFalse);
      expect(prefs.getInt('sync.pull_repair.done'), 2);
    });

    test('the markers outlive clear()', () async {
      final prefs = await prefsWith({'sync.pull_key.medications': '812|'});
      final store = SyncCursorStore(prefs);
      await store.startPullRepair();
      await store.finishPullRepair();
      await store.clear();
      expect(prefs.getInt('sync.pull_repair.done'), 2);
      expect(await store.startPullRepair(), isFalse);
    });

    test('an in-memory store has nothing an older build stored', () async {
      final store = SyncCursorStore.inMemory();
      await store.setPullKey('medications', const PullKey(1));
      expect(await store.startPullRepair(), isFalse);
      expect(await store.pullKey('medications'), const PullKey(1));
    });
  });
}
```

Create `test/data/datasources/dose_log_sweep_test.dart`. With sync, a synced overdue dose becomes an automatic change to push (`pending_update`, `edited_at` 1970) and an unpushed undo is left alone. Without sync, the undone dose is swept too, and no status changes.

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/data/datasources/dose_log_local_datasource.dart';
import 'package:medora/data/local/app_database.dart';

import '../../helpers/seed.dart';
import '../../helpers/test_database.dart';

void main() {
  setUp(setUpTestDatabase);
  tearDown(tearDownTestDatabase);

  Future<Map<String, Object?>> row(String id) async =>
      (await (await AppDatabase.instance.database).query(
        'dose_logs',
        where: 'id = ?',
        whereArgs: [id],
      )).single;

  test('with sync, a synced overdue dose becomes an automatic change to '
      'push; an unpushed undo is left alone', () async {
    final db = await AppDatabase.instance.database;
    final p = (await seedPrescription(db)).prescriptionId;
    final synced = await seedDoseLog(db, p, DateTime(2026, 3, 1, 8));
    final undone = await seedDoseLog(db, p, DateTime(2026, 3, 1, 16));
    await db.update(
      'dose_logs',
      {'sync_status': SyncStatus.pendingUpdate},
      where: 'id = ?',
      whereArgs: [undone],
    );

    final result = await DoseLogLocalDatasource().markOverduePendingAsMissed(
      DateTime(2026, 3, 2),
    );

    expect(result, (changed: 1, unpushed: 1));
    final s = await row(synced);
    expect(
      [s['status'], s['sync_status'], s['edited_at']],
      ['missed', 'pending_update', '1970-01-01T00:00:00.000Z'],
    );
    final u = await row(undone);
    expect([u['status'], u['sync_status']], ['pending', 'pending_update']);
  });

  test('without sync, an undone overdue dose is marked missed too, and no '
      'status changes', () async {
    final db = await AppDatabase.instance.database;
    final p = (await seedPrescription(db)).prescriptionId;
    final undone = await seedDoseLog(db, p, DateTime(2026, 3, 1, 16));
    await db.update(
      'dose_logs',
      {'sync_status': SyncStatus.pendingUpdate},
      where: 'id = ?',
      whereArgs: [undone],
    );

    final result = await DoseLogLocalDatasource().markOverduePendingAsMissed(
      DateTime(2026, 3, 2),
      pushable: false,
    );

    expect(result, (changed: 1, unpushed: 0));
    final u = await row(undone);
    expect([u['status'], u['sync_status']], ['missed', 'pending_update']);
  });
}
```

Apply this patch to the smaller suites. What changes, and why:
- **Every hand-built `SyncService`** gets `syncState:` (a `FakeSyncState`, or `null` in the local-only wiring test), and the fakes are built on one `FakeServerCore`.
- **`treatment_remote_datasource_test` / `medication_remote_datasource_test`:** the write path is `rows.insertIfAbsent` / `rows.patch`. The removed `upsertTreatment` / `mapMedicationSchemaErrors` tests go.
- **`treatment_sync_test`:** "End does not overwrite a newer server row (last write wins)" becomes "End and a certificate number added on another device are both kept (I-1)". Expected: `is_active` false, `end_date` set, `sick_leave_ref` `A-REF`, no overwrite. `seedInSync` runs one cycle, so the device holds its base. The unmigrated-project rig wraps the real `PostgrestSyncTable`.
- **`settings_sync_failures_test`:**
  - three new widget tests (en/de/it) find `Key('syncNeedsMigration')` with the exact texts above;
  - one more checks that a migrated project shows no such line.
- **`sync_request_test`:** marking overdue doses asks for a sync after each marked dose, including a synced one (`[pending_update, pending_create]`), and stamps `edited_at` `1970-01-01T00:00:00.000Z`.
- **`local_upload_marker_test`:** the cursor it clears is a pull key.
- **`multi_device_dose_sync_test`:**
  - "pulling the dose again does not undo missed" now expects the server to hold `missed` with `edited_at` 1970;
  - an unpushed undo reaches the server first, then the conclusion (`row_version` +2);
  - the explicit-status group is now "of two explicit statuses the later one wins";
  - new **PR5** test: A marks the dose missed offline, B takes it later and syncs first. Expected: `taken` on the server and on both devices, and A's row `synced`.
- **`multi_device_schedule_sync_test`:**
  - B now pulls A's generated doses. New test: "B pulls the doses A generated, with no generation of its own".
  - "a prescription B holds without doses" deletes B's pulled doses first, to reproduce an old build's state.
  - The "other times" test expects 6 slots, because A's regeneration dropped the old six on the server.
  - The warm-up checks a pull key instead of a cursor time.
- **`repository_sync_test`:** the rig is built on `FakeServerCore`, and `writeWhileCyclePushes` takes a `FakeSyncTable`.
- **`repository_sync_wiring_test`, `integration/sync_convergence_test`:** they pass `syncState`.

```diff
--- a/test/data/datasources/medication_remote_datasource_test.dart
+++ b/test/data/datasources/medication_remote_datasource_test.dart
@@ -1,11 +1,11 @@
 /// Review I2: a Supabase project without the `ean` column must fail with a
 /// message that names the migration, not with a raw PostgREST code that the
-/// push then retries forever.
+/// push then retries forever. The write path itself is covered in
+/// `sync_table_test.dart`.
 library;
 
 import 'package:flutter_test/flutter_test.dart';
 import 'package:medora/data/datasources/medication_remote_datasource.dart';
-import 'package:medora/data/datasources/schema_errors.dart';
 import 'package:supabase_flutter/supabase_flutter.dart';
 
 void main() {
@@ -47,37 +47,4 @@
     expect(missingMedicationColumn(error), isNull);
     expect(missingMedicationColumn(StateError('offline')), isNull);
   });
-
-  test(
-    'a push against a project without the column reports the migration',
-    () async {
-      await expectLater(
-        mapMedicationSchemaErrors<void>(
-          () async => throw const PostgrestException(
-            message:
-                "Could not find the 'ean' column of 'medications' in the "
-                'schema cache',
-            code: 'PGRST204',
-          ),
-        ),
-        throwsA(
-          isA<MissingColumnException>().having(
-            (e) => e.toString(),
-            'message',
-            contains('20260916000000_medication_ean.sql'),
-          ),
-        ),
-      );
-    },
-  );
-
-  test('a push that succeeds is untouched', () async {
-    expect(await mapMedicationSchemaErrors(() async => 42), 42);
-    await expectLater(
-      mapMedicationSchemaErrors<void>(
-        () async => throw StateError('network down'),
-      ),
-      throwsA(isA<StateError>()),
-    );
-  });
 }
--- a/test/data/datasources/treatment_remote_datasource_test.dart
+++ b/test/data/datasources/treatment_remote_datasource_test.dart
@@ -66,7 +66,7 @@
     );
 
     await expectLater(
-      remote.upsertTreatment(treatment),
+      remote.rows.insertIfAbsent([treatment.toJson()]),
       throwsA(
         isA<MissingColumnException>()
             .having((e) => e.table, 'table', 'treatments')
@@ -100,25 +100,25 @@
     );
 
     await expectLater(
-      remote.upsertTreatment(treatment),
+      remote.rows.insertIfAbsent([treatment.toJson()]),
       throwsA(isA<PostgrestException>().having((e) => e.code, 'code', '42501')),
     );
   });
 
-  test('a push that succeeds returns the server stamp', () async {
+  test('an update to such a project names the migration too', () async {
     final remote = TreatmentRemoteDatasource(
-      stubClient(
-        () => http.Response(
-          jsonEncode({'updated_at': '2026-03-01T10:00:00+00:00'}),
-          201,
-          headers: {'content-type': 'application/json'},
+      stubClient(() => missingColumnAnswer('sick_leave_ref')),
+    );
+
+    await expectLater(
+      remote.rows.patch('t1', {'sick_leave_ref': 'A'}, ifVersion: 2),
+      throwsA(
+        isA<MissingColumnException>().having(
+          (e) => e.column,
+          'column',
+          'sick_leave_ref',
         ),
       ),
     );
-
-    expect(
-      await remote.upsertTreatment(treatment),
-      DateTime.utc(2026, 3, 1, 10),
-    );
   });
 }
--- a/test/data/repositories/sync_request_test.dart
+++ b/test/data/repositories/sync_request_test.dart
@@ -303,8 +303,8 @@
       expect(requests.statuses, isEmpty);
     });
 
-    test('marking overdue doses asks for a sync only when a changed dose is '
-        'not on the server yet', () async {
+    test('marking overdue doses asks for a sync after each marked dose is '
+        'queued', () async {
       final db = await AppDatabase.instance.database;
       final prescriptionId = (await seedPrescription(db)).prescriptionId;
       final synced = await seedDoseLog(
@@ -319,31 +319,35 @@
         where: 'id = ?',
         whereArgs: [id],
       );
-      final requests = _Requests('dose_logs')..id = id;
-      final repo = DoseLogRepositoryImpl(
-        localDatasource: DoseLogLocalDatasource(),
-        prescriptionLocal: PrescriptionLocalDatasource(),
-        requestSync: requests.call,
-      );
-
-      // Only the synced dose is overdue: marked, but nothing to push.
+      final requests = _Requests('dose_logs')..id = synced;
+      final repo = DoseLogRepositoryImpl(
+        localDatasource: DoseLogLocalDatasource(),
+        prescriptionLocal: PrescriptionLocalDatasource(),
+        requestSync: requests.call,
+      );
+
+      // The synced dose is overdue: marked, and queued as an automatic
+      // change so the server stops showing it as pending.
       final first = await repo.markOverduePendingAsMissed(
         DateTime(2026, 3, 1, 7),
       );
       await pumpEventQueue();
       expect(first.dataOrNull, 1);
-      expect(requests.statuses, isEmpty);
       final syncedRow = (await db.query(
         'dose_logs',
         where: 'id = ?',
         whereArgs: [synced],
       )).single;
       expect(syncedRow['status'], 'missed');
-      expect(syncedRow['sync_status'], 'synced');
-
-      await repo.markOverduePendingAsMissed(DateTime(2026, 3, 1, 9));
-      await pumpEventQueue();
-      expect(requests.statuses, [pendingCreate]);
+      expect(syncedRow['edited_at'], '1970-01-01T00:00:00.000Z');
+
+      requests.id = id;
+      final second = await repo.markOverduePendingAsMissed(
+        DateTime(2026, 3, 1, 9),
+      );
+      await pumpEventQueue();
+      expect(second.dataOrNull, 1);
+      expect(requests.statuses, [pendingUpdate, pendingCreate]);
     });
 
     test('deleting asks for one sync after the tombstone, and a missing '
--- a/test/helpers/failing_dose_repo.dart
+++ b/test/helpers/failing_dose_repo.dart
@@ -72,4 +72,8 @@
   Future<Result<List<DoseLog>>> regenerateDoseLogsForPrescription(
     String prescriptionId,
   ) => inner.regenerateDoseLogsForPrescription(prescriptionId);
+
+  @override
+  Future<Result<int>> correctDoseTimes(Map<String, DateTime> slotTimes) =>
+      inner.correctDoseTimes(slotTimes);
 }
--- a/test/integration/sync_convergence_test.dart
+++ b/test/integration/sync_convergence_test.dart
@@ -13,6 +13,7 @@
 import 'package:medora/data/datasources/medication_remote_datasource.dart';
 import 'package:medora/data/datasources/prescription_local_datasource.dart';
 import 'package:medora/data/datasources/prescription_remote_datasource.dart';
+import 'package:medora/data/datasources/sync_state_remote_datasource.dart';
 import 'package:medora/data/datasources/treatment_local_datasource.dart';
 import 'package:medora/data/datasources/treatment_remote_datasource.dart';
 import 'package:medora/data/local/app_database.dart';
@@ -85,6 +86,7 @@
       doseLogRemote: DoseLogRemoteDatasource(c),
       familyLocal: FamilyLocalDatasource(),
       familyRemote: FamilyRemoteDatasource(c),
+      syncState: SyncStateRemoteDatasource(c),
       cursors: SyncCursorStore.inMemory(),
       isOnline: () => true,
       currentUserId: () => uid,
--- a/test/presentation/providers/repository_sync_wiring_test.dart
+++ b/test/presentation/providers/repository_sync_wiring_test.dart
@@ -34,6 +34,7 @@
         doseLogRemote: null,
         familyLocal: FamilyLocalDatasource(),
         familyRemote: null,
+        syncState: null,
         isOnline: () => true,
         currentUserId: () => 'user-a',
         onlineStream: const Stream<bool>.empty(),
@@ -52,7 +53,7 @@
   setUp(setUpTestDatabase);
   tearDown(tearDownTestDatabase);
 
-  DateTime clock() => DateTime.now().toUtc();
+  final core = FakeServerCore(() => DateTime.now().toUtc());
 
   /// A container whose remote datasources exist only for the tables in
   /// [remotes] (all four: cloud mode; none: local-only mode), with [sync]
@@ -65,18 +66,18 @@
       overrides: [
         syncServiceProvider.overrideWithValue(sync),
         medicationDatasourceProvider.overrideWithValue(
-          remotes.contains('medications') ? FakeMedicationRemote(clock) : null,
+          remotes.contains('medications') ? FakeMedicationRemote(core) : null,
         ),
         treatmentDatasourceProvider.overrideWithValue(
-          remotes.contains('treatments') ? FakeTreatmentRemote(clock) : null,
+          remotes.contains('treatments') ? FakeTreatmentRemote(core) : null,
         ),
         prescriptionDatasourceProvider.overrideWithValue(
           remotes.contains('prescriptions')
-              ? FakePrescriptionRemote(clock)
+              ? FakePrescriptionRemote(core)
               : null,
         ),
         doseLogDatasourceProvider.overrideWithValue(
-          remotes.contains('dose_logs') ? FakeDoseLogRemote(clock) : null,
+          remotes.contains('dose_logs') ? FakeDoseLogRemote(core) : null,
         ),
       ],
     );
--- a/test/presentation/screens/dose_schedule_screen_test.dart
+++ b/test/presentation/screens/dose_schedule_screen_test.dart
@@ -95,6 +95,10 @@
   Future<Result<List<DoseLog>>> regenerateDoseLogsForPrescription(
     String prescriptionId,
   ) => inner.regenerateDoseLogsForPrescription(prescriptionId);
+
+  @override
+  Future<Result<int>> correctDoseTimes(Map<String, DateTime> slotTimes) =>
+      inner.correctDoseTimes(slotTimes);
 }
 
 void main() {
--- a/test/presentation/screens/settings_sync_failures_test.dart
+++ b/test/presentation/screens/settings_sync_failures_test.dart
@@ -36,18 +36,20 @@
   ) async {
     final now = DateTime.utc(2026, 3, 4, 12);
     final failures = SyncFailureStore.inMemory();
-    final meds = FakeMedicationRemote(() => now);
+    final server = FakeServer(() => now);
+    final meds = server.meds;
     final service = SyncService(
       medicationLocal: MedicationLocalDatasource(),
       medicationRemote: meds,
       treatmentLocal: TreatmentLocalDatasource(),
-      treatmentRemote: FakeTreatmentRemote(() => now),
+      treatmentRemote: server.treatments,
       prescriptionLocal: PrescriptionLocalDatasource(),
-      prescriptionRemote: FakePrescriptionRemote(() => now),
+      prescriptionRemote: server.prescriptions,
       doseLogLocal: DoseLogLocalDatasource(),
-      doseLogRemote: FakeDoseLogRemote(() => now),
+      doseLogRemote: server.doses,
       familyLocal: FamilyLocalDatasource(),
-      familyRemote: FakeFamilyRemote(() => now),
+      familyRemote: server.families,
+      syncState: server.state,
       failures: failures,
       isOnline: () => true,
       currentUserId: () => 'user-a',
@@ -126,18 +128,20 @@
     final now = DateTime.utc(2026, 3, 4, 12);
     var clock = now;
     final failures = SyncFailureStore.inMemory();
-    final meds = FakeMedicationRemote(() => clock);
+    final server = FakeServer(() => clock);
+    final meds = server.meds;
     final service = SyncService(
       medicationLocal: MedicationLocalDatasource(),
       medicationRemote: meds,
       treatmentLocal: TreatmentLocalDatasource(),
-      treatmentRemote: FakeTreatmentRemote(() => clock),
+      treatmentRemote: server.treatments,
       prescriptionLocal: PrescriptionLocalDatasource(),
-      prescriptionRemote: FakePrescriptionRemote(() => clock),
+      prescriptionRemote: server.prescriptions,
       doseLogLocal: DoseLogLocalDatasource(),
-      doseLogRemote: FakeDoseLogRemote(() => clock),
+      doseLogRemote: server.doses,
       familyLocal: FamilyLocalDatasource(),
-      familyRemote: FakeFamilyRemote(() => clock),
+      familyRemote: server.families,
+      syncState: server.state,
       failures: failures,
       isOnline: () => true,
       currentUserId: () => 'user-a',
@@ -192,18 +196,20 @@
     final now = DateTime.utc(2026, 3, 4, 12);
     var clock = now;
     final failures = SyncFailureStore.inMemory();
-    final meds = FakeMedicationRemote(() => clock);
+    final server = FakeServer(() => clock);
+    final meds = server.meds;
     final service = SyncService(
       medicationLocal: MedicationLocalDatasource(),
       medicationRemote: meds,
       treatmentLocal: TreatmentLocalDatasource(),
-      treatmentRemote: FakeTreatmentRemote(() => clock),
+      treatmentRemote: server.treatments,
       prescriptionLocal: PrescriptionLocalDatasource(),
-      prescriptionRemote: FakePrescriptionRemote(() => clock),
+      prescriptionRemote: server.prescriptions,
       doseLogLocal: DoseLogLocalDatasource(),
-      doseLogRemote: FakeDoseLogRemote(() => clock),
+      doseLogRemote: server.doses,
       familyLocal: FamilyLocalDatasource(),
-      familyRemote: FakeFamilyRemote(() => clock),
+      familyRemote: server.families,
+      syncState: server.state,
       failures: failures,
       isOnline: () => true,
       currentUserId: () => 'user-a',
@@ -280,4 +286,120 @@
     expect(rows.single['name'], 'Server');
     expect(await failures.get('medications', 'bad'), isNull);
   });
+
+  for (final (locale, text) in const [
+    (
+      'en',
+      'The cloud project needs an update: apply '
+          'supabase/migrations/20260918000000_sync_v2.sql',
+    ),
+    (
+      'de',
+      'Das Cloud-Projekt braucht ein Update: '
+          'supabase/migrations/20260918000000_sync_v2.sql anwenden',
+    ),
+    (
+      'it',
+      'Il progetto cloud va aggiornato: applica '
+          'supabase/migrations/20260918000000_sync_v2.sql',
+    ),
+  ]) {
+    testWidgets('a project without the sync migration is named in Settings '
+        '($locale)', (tester) async {
+      final now = DateTime.utc(2026, 3, 4, 12);
+      final server = FakeServer(() => now);
+      server.state.migrated = false;
+      final service = SyncService(
+        medicationLocal: MedicationLocalDatasource(),
+        medicationRemote: server.meds,
+        treatmentLocal: TreatmentLocalDatasource(),
+        treatmentRemote: server.treatments,
+        prescriptionLocal: PrescriptionLocalDatasource(),
+        prescriptionRemote: server.prescriptions,
+        doseLogLocal: DoseLogLocalDatasource(),
+        doseLogRemote: server.doses,
+        familyLocal: FamilyLocalDatasource(),
+        familyRemote: server.families,
+        syncState: server.state,
+        isOnline: () => true,
+        currentUserId: () => 'user-a',
+        onlineStream: const Stream<bool>.empty(),
+        now: () => now,
+      );
+      addTearDown(service.dispose);
+      final report = (await service.syncAll())!;
+      expect(report.missingMigration, isNotNull);
+      await tester.pump(const Duration(seconds: 3));
+
+      await pumpMedoraApp(
+        tester,
+        const SettingsScreen(),
+        locale: Locale(locale),
+        overrides: [
+          sharedPreferencesProvider.overrideWithValue(
+            await SharedPreferences.getInstance(),
+          ),
+          syncStartupDelayProvider.overrideWithValue(Duration.zero),
+          reminderPortProvider.overrideWithValue(FakePort()),
+          platformCapabilitiesProvider.overrideWithValue(
+            PlatformCapabilities.mobile,
+          ),
+          syncServiceProvider.overrideWithValue(service),
+        ],
+      );
+      await tester.pumpAndSettle();
+      final line = find.byKey(const Key('syncNeedsMigration'));
+      await tester.scrollUntilVisible(
+        line,
+        200,
+        scrollable: find.byType(Scrollable).first,
+      );
+      expect(
+        find.descendant(of: line, matching: find.text(text)),
+        findsOneWidget,
+      );
+    });
+  }
+
+  testWidgets('a migrated project shows no migration line', (tester) async {
+    final now = DateTime.utc(2026, 3, 4, 12);
+    final server = FakeServer(() => now);
+    final service = SyncService(
+      medicationLocal: MedicationLocalDatasource(),
+      medicationRemote: server.meds,
+      treatmentLocal: TreatmentLocalDatasource(),
+      treatmentRemote: server.treatments,
+      prescriptionLocal: PrescriptionLocalDatasource(),
+      prescriptionRemote: server.prescriptions,
+      doseLogLocal: DoseLogLocalDatasource(),
+      doseLogRemote: server.doses,
+      familyLocal: FamilyLocalDatasource(),
+      familyRemote: server.families,
+      syncState: server.state,
+      isOnline: () => true,
+      currentUserId: () => 'user-a',
+      onlineStream: const Stream<bool>.empty(),
+      now: () => now,
+    );
+    addTearDown(service.dispose);
+    expect((await service.syncAll())!.isClean, isTrue);
+    await tester.pump(const Duration(seconds: 3));
+    await pumpMedoraApp(
+      tester,
+      const SettingsScreen(),
+      overrides: [
+        sharedPreferencesProvider.overrideWithValue(
+          await SharedPreferences.getInstance(),
+        ),
+        syncStartupDelayProvider.overrideWithValue(Duration.zero),
+        reminderPortProvider.overrideWithValue(FakePort()),
+        platformCapabilitiesProvider.overrideWithValue(
+          PlatformCapabilities.mobile,
+        ),
+        syncServiceProvider.overrideWithValue(service),
+      ],
+    );
+    await tester.pumpAndSettle();
+    expect(find.byKey(const Key('syncNeedsMigration')), findsNothing);
+  });
 }
--- a/test/services/local_upload_marker_test.dart
+++ b/test/services/local_upload_marker_test.dart
@@ -1,4 +1,5 @@
 import 'package:flutter_test/flutter_test.dart';
+import 'package:medora/data/datasources/sync_page.dart';
 import 'package:medora/data/local/app_database.dart';
 import 'package:medora/services/local_upload_marker.dart';
 import 'package:medora/services/sync_cursor_store.dart';
@@ -28,7 +29,7 @@
     final seeded = await seedPrescription(db);
     await seedDoseLog(db, seeded.prescriptionId, DateTime(2026, 3, 1, 8));
     final cursors = SyncCursorStore.inMemory();
-    await cursors.setLastPullAt('medications', DateTime.utc(2026));
+    await cursors.setPullKey('medications', const PullKey(1234));
 
     final n = await makeMarker(cursors: cursors).markAllForUpload('user-a');
 
@@ -46,7 +47,7 @@
         reason: table,
       );
     }
-    expect(await cursors.lastPullAt('medications'), isNull);
+    expect(await cursors.pullKey('medications'), isNull);
   });
 
   test(
--- a/test/services/multi_device_dose_sync_test.dart
+++ b/test/services/multi_device_dose_sync_test.dart
@@ -30,13 +30,8 @@
 import '../helpers/test_database.dart';
 
 /// The shared server.
-class _Server {
-  DateTime now() => DateTime.now().toUtc();
-  late final meds = FakeMedicationRemote(now);
-  late final treatments = FakeTreatmentRemote(now);
-  late final prescriptions = FakePrescriptionRemote(now);
-  late final doses = FakeDoseLogRemote(now);
-  late final families = FakeFamilyRemote(now);
+class _Server extends FakeServer {
+  _Server() : super(() => DateTime.now().toUtc());
 
   Map<String, dynamic> dose(String id) => doses.table.rows[id]!;
 }
@@ -54,6 +49,7 @@
       doseLogRemote: server.doses,
       familyLocal: FamilyLocalDatasource(),
       familyRemote: server.families,
+      syncState: server.state,
       isOnline: () => online,
       currentUserId: () => 'user-a',
       onlineStream: const Stream<bool>.empty(),
@@ -220,16 +216,17 @@
       await expectTakenEverywhere();
     });
 
-    test('pulling the pending copy again does not undo "missed"', () async {
-      await b.run((_) => b.startup.run());
-      // A full pull returns the server's pending copy the conclusion was
-      // drawn from (a stale skip rewinds the cursor the same way).
+    test('pulling the dose again does not undo "missed"', () async {
+      await b.run((_) => b.startup.run());
+      // The conclusion reached the server, as the app's own change.
+      expect(server.dose(doseId)['status'], 'missed');
+      expect(server.dose(doseId)['edited_at'], '1970-01-01T00:00:00.000Z');
+      // A full pull brings it back unchanged.
       await b.cursors.clear();
       await b.sync();
       final row = await b.dose(doseId);
       expect(row['status'], 'missed');
       expect(row['sync_status'], SyncStatus.synced);
-      expect(server.dose(doseId)['status'], 'pending');
 
       // A real change on the server still wins.
       await a.run((_) => a.doses.markDoseTaken(doseId));
@@ -238,6 +235,7 @@
 
     test('an undo still waiting to be pushed is not marked missed', () async {
       await a.run((_) => a.doses.markDoseTaken(doseId));
+      final takenVersion = server.dose(doseId)['row_version'] as int;
       a.online = false;
       await a.run((_) => a.doses.markDosePending(doseId));
       // Past the grace period, still offline.
@@ -246,16 +244,16 @@
       expect(offline['status'], 'pending');
       expect(offline['sync_status'], SyncStatus.pendingUpdate);
 
-      // The undo reaches the server as what the user did.
-      a.online = true;
-      await a.run((_) => a.startup.run());
-      expect(server.dose(doseId)['status'], 'pending');
-      // Once it is synced, the next start draws the local conclusion.
+      // Online: the undo reaches the server first, as what the user did;
+      // then the start draws its conclusion and sends it as the app's own.
+      a.online = true;
       await a.run((_) => a.startup.run());
       final after = await a.dose(doseId);
       expect(after['status'], 'missed');
       expect(after['sync_status'], SyncStatus.synced);
-      expect(server.dose(doseId)['status'], 'pending');
+      expect(server.dose(doseId)['status'], 'missed');
+      expect(server.dose(doseId)['edited_at'], '1970-01-01T00:00:00.000Z');
+      expect(server.dose(doseId)['row_version'], takenVersion + 2);
     });
 
     test('startup marks doses missed only after its sync', () async {
@@ -375,10 +373,10 @@
     });
   });
 
-  // The server stamps every update with its own clock, so of two explicit
-  // changes the one that reaches the server last wins, whenever it was
-  // made.
-  group('an explicit status wins in the order the devices sync', () {
+  // Of two explicit changes of the same dose, the one made later wins,
+  // whichever device syncs first (the edit time, capped at the moment the
+  // server received it).
+  group('of two explicit statuses the later one wins', () {
     test('B skips the dose after A took it', () async {
       await a.run((_) => a.doses.markDoseTaken(doseId));
       await b.sync();
@@ -403,6 +401,21 @@
       expect((await b.dose(doseId))['status'], 'missed');
     });
 
+    test('PR5: A marks the dose missed offline, B takes it later and syncs '
+        'first', () async {
+      a.online = false;
+      await a.run((_) => a.doses.markDoseMissed(doseId));
+      await b.run((_) => b.doses.markDoseTaken(doseId));
+      expect(server.dose(doseId)['status'], 'taken');
+      a.online = true;
+      await a.sync();
+      expect(server.dose(doseId)['status'], 'taken');
+      final onA = await a.dose(doseId);
+      expect(onA['status'], 'taken');
+      expect(onA['sync_status'], SyncStatus.synced);
+      await expectTakenEverywhere();
+    });
+
     test('A takes the dose after B explicitly marked it missed', () async {
       await b.run((_) => b.doses.markDoseMissed(doseId));
       await a.sync();
--- a/test/services/multi_device_schedule_sync_test.dart
+++ b/test/services/multi_device_schedule_sync_test.dart
@@ -39,13 +39,8 @@
 import '../helpers/seed.dart';
 import '../helpers/test_database.dart';
 
-class _Server {
-  DateTime now() => DateTime.now().toUtc();
-  late final meds = FakeMedicationRemote(now);
-  late final treatments = FakeTreatmentRemote(now);
-  late final prescriptions = FakePrescriptionRemote(now);
-  late final doses = FakeDoseLogRemote(now);
-  late final families = FakeFamilyRemote(now);
+class _Server extends FakeServer {
+  _Server() : super(() => DateTime.now().toUtc());
 
   Iterable<Map<String, dynamic>> dosesOf(String prescriptionId) => doses
       .table
@@ -93,6 +88,7 @@
       doseLogRemote: server.doses,
       familyLocal: FamilyLocalDatasource(),
       familyRemote: server.families,
+      syncState: server.state,
       isOnline: () => online,
       currentUserId: () => 'user-a',
       onlineStream: const Stream<bool>.empty(),
@@ -282,8 +278,8 @@
     await b.sync();
     await a.sync();
     for (final device in [a, b]) {
-      final cursor = await device.cursors.lastPullAt('dose_logs');
-      expect(cursor!.year, greaterThan(2000), reason: device.name);
+      final key = await device.cursors.pullKey('dose_logs');
+      expect(key!.xid, greaterThan(1000), reason: device.name);
     }
   }
 }
@@ -511,14 +507,34 @@
       expect(await h.b.remindersFor(p.prescriptionId), isEmpty);
     });
 
+    test(
+      'B pulls the doses A generated, with no generation of its own',
+      () async {
+        h.b.pullHook = false;
+        final p = await h.createOnA(
+          start: DateTime(today.year, today.month, today.day + 1, 8),
+          durationDays: 3,
+        );
+        await h.b.appSync(ensure: false);
+        await expectBMatchesA(p.prescriptionId);
+      },
+    );
+
     test('a prescription B holds without doses gets them on resume', () async {
-      // B pulled it with a build that generated nothing.
+      // B holds it without its doses, as a build before sync v2 left it.
       h.b.pullHook = false;
       final p = await h.createOnA(
         start: DateTime(today.year, today.month, today.day + 1, 8),
         durationDays: 3,
       );
       await h.b.appSync(ensure: false);
+      await h.b.run(
+        (db) => db.delete(
+          'dose_logs',
+          where: 'prescription_id = ?',
+          whereArgs: [p.prescriptionId],
+        ),
+      );
       expect(await h.b.slots(p.prescriptionId), isEmpty);
       h.b.pullHook = true;
 
@@ -558,6 +574,8 @@
       });
       await h.b.appSync(ensure: false);
       h.b.pullHook = true;
+      // A's regeneration dropped the old six on the server too, so B holds
+      // only the new ones.
       expect(await h.b.slots(p.prescriptionId), hasLength(6));
 
       await h.b.resume();
--- a/test/services/repository_sync_test.dart
+++ b/test/services/repository_sync_test.dart
@@ -28,22 +28,25 @@
 import '../helpers/test_database.dart';
 
 class _Rig {
+  late final FakeServerCore core;
   _Rig() {
     DateTime serverNow() => DateTime.now().toUtc();
-    meds = FakeMedicationRemote(serverNow);
-    prescriptions = FakePrescriptionRemote(serverNow);
-    doses = FakeDoseLogRemote(serverNow);
+    core = FakeServerCore(serverNow);
+    meds = FakeMedicationRemote(core);
+    prescriptions = FakePrescriptionRemote(core);
+    doses = FakeDoseLogRemote(core);
     service = SyncService(
       medicationLocal: medicationLocal,
       medicationRemote: meds,
       treatmentLocal: TreatmentLocalDatasource(),
-      treatmentRemote: FakeTreatmentRemote(serverNow),
+      treatmentRemote: FakeTreatmentRemote(core),
       prescriptionLocal: prescriptionLocal,
       prescriptionRemote: prescriptions,
       doseLogLocal: doseLogLocal,
       doseLogRemote: doses,
       familyLocal: FamilyLocalDatasource(),
       familyRemote: FakeFamilyRemote(serverNow),
+      syncState: FakeSyncState(core),
       isOnline: () => true,
       currentUserId: () => 'user-a',
       onlineStream: const Stream<bool>.empty(),
@@ -96,7 +99,7 @@
   /// Runs a sync cycle whose first call into [table] (its push of the
   /// pending row) is held until [write] has run.
   Future<void> writeWhileCyclePushes(
-    FakeRemoteTable table,
+    FakeSyncTable table,
     Future<void> Function() write,
   ) async {
     final release = Completer<void>();
--- a/test/services/treatment_sync_test.dart
+++ b/test/services/treatment_sync_test.dart
@@ -16,6 +16,7 @@
 import 'package:medora/data/datasources/family_local_datasource.dart';
 import 'package:medora/data/datasources/medication_local_datasource.dart';
 import 'package:medora/data/datasources/prescription_local_datasource.dart';
+import 'package:medora/data/datasources/sync_table.dart';
 import 'package:medora/data/datasources/treatment_local_datasource.dart';
 import 'package:medora/data/datasources/treatment_remote_datasource.dart';
 import 'package:medora/data/local/app_database.dart';
@@ -29,23 +30,26 @@
 import '../helpers/test_database.dart';
 
 class _Rig {
+  late final FakeServerCore core;
   _Rig({
     this.serverSkew = Duration.zero,
-    FakeTreatmentRemote Function(DateTime Function() clock)? treatmentRemote,
+    FakeTreatmentRemote Function(FakeServerCore core)? treatmentRemote,
   }) {
     DateTime serverNow() => DateTime.now().toUtc().add(serverSkew);
-    remote = (treatmentRemote ?? FakeTreatmentRemote.new)(serverNow);
+    core = FakeServerCore(serverNow);
+    remote = (treatmentRemote ?? FakeTreatmentRemote.new)(core);
     service = SyncService(
       medicationLocal: MedicationLocalDatasource(),
-      medicationRemote: FakeMedicationRemote(serverNow),
+      medicationRemote: FakeMedicationRemote(core),
       treatmentLocal: local,
       treatmentRemote: remote,
       prescriptionLocal: PrescriptionLocalDatasource(),
-      prescriptionRemote: FakePrescriptionRemote(serverNow),
+      prescriptionRemote: FakePrescriptionRemote(core),
       doseLogLocal: DoseLogLocalDatasource(),
-      doseLogRemote: FakeDoseLogRemote(serverNow),
+      doseLogRemote: FakeDoseLogRemote(core),
       familyLocal: FamilyLocalDatasource(),
       familyRemote: FakeFamilyRemote(serverNow),
+      syncState: FakeSyncState(core),
       isOnline: () => online,
       currentUserId: () => 'user-a',
       onlineStream: const Stream<bool>.empty(),
@@ -106,12 +110,17 @@
 }
 
 /// A server that has not had `20260917000000_treatment_sick_leave.sql`
-/// applied: every treatment push goes through the real datasource, and
-/// PostgREST answers PGRST204 for the first sick-leave key. Reads still come
-/// from the fake table. No Supabase project is contacted.
+/// applied: every treatment write goes through the real
+/// `PostgrestSyncTable`, and PostgREST answers PGRST204 for the first
+/// sick-leave key. Reads still come from the fake table. No Supabase project
+/// is contacted.
 class _UnmigratedTreatmentRemote extends FakeTreatmentRemote {
-  _UnmigratedTreatmentRemote(super.clock) {
-    _client = SupabaseClient(
+  _UnmigratedTreatmentRemote(super.core) : super(rows: _UnmigratedRows(core));
+}
+
+class _UnmigratedRows extends FakeSyncTable {
+  _UnmigratedRows(FakeServerCore core) : super(core, 'treatments') {
+    final client = SupabaseClient(
       'http://supabase.invalid',
       'anon-key',
       httpClient: MockClient(
@@ -130,14 +139,30 @@
       ),
       authOptions: const AuthClientOptions(autoRefreshToken: false),
     );
-    addTearDown(_client.dispose);
+    addTearDown(client.dispose);
+    _real = TreatmentRemoteDatasource(client).rows;
   }
 
-  late final SupabaseClient _client;
+  late final SyncTable _real;
 
   @override
-  Future<DateTime?> upsertTreatment(TreatmentModel model) =>
-      TreatmentRemoteDatasource(_client).upsertTreatment(model);
+  Future<Map<String, dynamic>?> patch(
+    String id,
+    Map<String, Object?> changes, {
+    int? ifVersion,
+    String? ifStatus,
+    bool ifLive = false,
+  }) => _real.patch(
+    id,
+    changes,
+    ifVersion: ifVersion,
+    ifStatus: ifStatus,
+    ifLive: ifLive,
+  );
+
+  @override
+  Future<void> insertIfAbsent(List<Map<String, Object?>> rows) =>
+      _real.insertIfAbsent(rows);
 }
 
 void main() {
@@ -162,10 +187,13 @@
     updatedAt: longAgo,
   );
 
-  /// The server and this device agree on [episode], last synced long ago.
+  /// The server and this device agree on [episode], last synced long ago;
+  /// the device holds the server copy as its merge base, as every device
+  /// does after its first sync v2 cycle.
   Future<void> seedInSync(_Rig r) async {
     r.remote.table.seed(episode.toJson(), updatedAt: longAgo);
     await r.local.upsert(episode, syncStatus: SyncStatus.synced);
+    await r.service.syncAll();
   }
 
   test('End sends every column, sick leave included', () async {
@@ -295,18 +323,15 @@
     expect((await r.localRow('t1'))['sync_status'], SyncStatus.synced);
   });
 
-  test('End does not overwrite a newer server row from another device '
-      '(last write wins)', () async {
+  test('End and a certificate number added on another device are both '
+      'kept (I-1)', () async {
     final r = _Rig();
-    // This device still holds the pre-edit copy ...
-    await r.local.upsert(episode, syncStatus: SyncStatus.synced);
-    // ... while another device recorded a new certificate number, and the
-    // server stamped that edit later than this device's End will be.
-    r.remote.table.seed({
-      ...episode.toJson(),
+    await seedInSync(r);
+    // Another device records a new certificate number and a note.
+    r.remote.table.editFromOtherDevice('t1', {
       'notes': 'edited on the other phone',
       'sick_leave_ref': 'A-REF',
-    }, updatedAt: DateTime.now().toUtc().add(const Duration(hours: 1)));
+    }, editedAt: DateTime.now().toUtc());
 
     await r.repo.endTreatment('t1');
     await r.idle();
@@ -314,11 +339,12 @@
     final row = r.remote.table.rows['t1']!;
     expect(row['notes'], 'edited on the other phone');
     expect(row['sick_leave_ref'], 'A-REF');
-    expect(row['is_active'], isTrue);
-    expect(r.service.lastReport?.skippedStale, 1);
-    // The cycle's pull brought the winner home.
+    expect(row['is_active'], isFalse);
+    expect(row['end_date'], isNotNull);
+    expect(r.service.lastReport?.overwritten, isEmpty);
     final stored = (await r.local.getTreatmentById('t1'))!;
     expect(stored.sickLeaveRef, 'A-REF');
+    expect(stored.isActive, isFalse);
     expect((await r.localRow('t1'))['sync_status'], SyncStatus.synced);
   });
 
```

Apply this patch to `test/services/sync_service_test.dart`. It keeps the behavioural expectations and replaces the tests of removed v1 mechanics with their v2 equivalents:
- **The stale skip:**
  - "a stale pending update is not pushed…" becomes "a pending update with no base meets a newer server copy and takes it";
  - "a stale skipped push rewinds the cursor" becomes "a server copy the pull already went past is merged by the push, not skipped".
- **The create re-send:** "only a dose a person recorded here is sent again for a server stamp" and "a recorded dose whose second send fails…" are removed, because the server stamps inserts now.
- **The 1970 floor and the `updated_at` cursor:**
  - the paging tests read keys and horizons;
  - "1,500 generated doses… and the next pull brings none of them again";
  - "a first pull of 2,500 dose rows… and the next pull starts at the horizon";
  - "rows written in one transaction across a page boundary are each stored exactly once".
- **New:**
  - "a key above the server horizon (a restored server) starts the table over";
  - "a device that finished the first repair runs this one once more".
- **A pending create against an existing server row** now takes the newer copy (merge with no base), and a tombstone still wins over a newer live row.
- **"a pull error keeps the cursor unchanged"** seeds its broken row through the fake's insert, so the row carries `sync_xid` (finding 7).
- **New in `report`:** "a project without the sync migration stops the cycle before any table request". Expected: `missingMigration` is the file, `fatal` contains "Apply supabase/migrations/20260918000000_sync_v2.sql", no request reached the server, the state is `error`, and the pending create is still `pending_create`.

```diff
--- a/test/services/sync_service_test.dart
+++ b/test/services/sync_service_test.dart
@@ -6,7 +6,7 @@
 import 'package:medora/data/datasources/family_local_datasource.dart';
 import 'package:medora/data/datasources/medication_local_datasource.dart';
 import 'package:medora/data/datasources/prescription_local_datasource.dart';
-import 'package:medora/data/datasources/pull_page.dart';
+import 'package:medora/data/datasources/sync_page.dart';
 import 'package:medora/data/datasources/treatment_local_datasource.dart';
 import 'package:medora/data/local/app_database.dart';
 import 'package:medora/data/models/dose_log_model.dart';
@@ -34,18 +34,27 @@
     DateTime? start,
     StreamController<bool>? online,
     FamilyLocalDatasource? familyLocal,
-    FakeMedicationRemote Function(DateTime Function() clock)? medicationRemote,
-    FakeDoseLogRemote Function(DateTime Function() clock)? doseLogRemote,
+    FakeSyncTable Function(FakeServerCore core)? medicationRows,
+    FakeSyncTable Function(FakeServerCore core)? doseRows,
+    FakeServer? server,
     Duration requestTimeout = const Duration(seconds: 30),
     Duration capRetryDelay = const Duration(seconds: 15),
     int maxPullPages = SyncService.defaultMaxPullPages,
     SyncCursorStore? cursors,
   }) : clock = TestClock(start ?? DateTime.utc(2026, 3, 4, 12)) {
-    meds = (medicationRemote ?? FakeMedicationRemote.new)(clock.now);
-    treatments = FakeTreatmentRemote(clock.now);
-    prescriptions = FakePrescriptionRemote(clock.now);
-    doses = (doseLogRemote ?? FakeDoseLogRemote.new)(clock.now);
-    family = FakeFamilyRemote(clock.now);
+    this.server =
+        server ??
+        FakeServer(
+          clock.now,
+          medicationRows: medicationRows,
+          doseRows: doseRows,
+        );
+    core = this.server.core;
+    meds = this.server.meds;
+    treatments = this.server.treatments;
+    prescriptions = this.server.prescriptions;
+    doses = this.server.doses;
+    family = this.server.families;
     this.cursors = cursors ?? SyncCursorStore.inMemory();
     failures = SyncFailureStore.inMemory();
     service = SyncService(
@@ -59,6 +68,7 @@
       doseLogRemote: doses,
       familyLocal: familyLocal ?? FamilyLocalDatasource(),
       familyRemote: family,
+      syncState: this.server.state,
       cursors: this.cursors,
       failures: failures,
       isOnline: () => this.online,
@@ -74,6 +84,8 @@
   }
 
   final TestClock clock;
+  late final FakeServer server;
+  late final FakeServerCore core;
   bool online = true;
   String? userId = 'user-a';
   late final FakeMedicationRemote meds;
@@ -94,64 +106,90 @@
       throw StateError('cannot drop family $id');
 }
 
-/// A medication server whose every upsert is joined by a local edit of the
+/// A medication table whose every write is joined by a local edit of the
 /// same row, as a writer that touches the row on every cycle would do: the
 /// cycle always finds the row changed after its push. Stops after [limit]
 /// edits so a missing cap fails the test instead of hanging it.
-class EditOnEveryPushRemote extends FakeMedicationRemote {
-  EditOnEveryPushRemote(super.clock, {this.limit = 50});
+class EditOnEveryPushTable extends FakeSyncTable {
+  EditOnEveryPushTable(FakeServerCore core, {this.limit = 50})
+    : super(core, 'medications');
 
   final int limit;
   int upserts = 0;
 
+  Future<void> _editLocally(String id) async {
+    upserts++;
+    if (upserts > limit) return;
+    final db = await AppDatabase.instance.database;
+    final row = (await localRow('medications', id))!;
+    final stamp = DateTime.parse(row['updated_at']! as String);
+    await db.update(
+      'medications',
+      {
+        'name': 'edit $upserts',
+        'updated_at': stamp
+            .add(const Duration(milliseconds: 1))
+            .toIso8601String(),
+      },
+      where: 'id = ?',
+      whereArgs: [id],
+    );
+  }
+
   @override
-  Future<DateTime?> upsertMedication(MedicationModel model) async {
-    upserts++;
-    if (upserts <= limit) {
-      final db = await AppDatabase.instance.database;
-      final row = (await localRow('medications', model.id))!;
-      final stamp = DateTime.parse(row['updated_at'] as String);
-      await db.update(
-        'medications',
-        {
-          'name': 'edit $upserts',
-          'updated_at': stamp
-              .add(const Duration(milliseconds: 1))
-              .toIso8601String(),
-        },
-        where: 'id = ?',
-        whereArgs: [model.id],
-      );
+  Future<Map<String, dynamic>?> patch(
+    String id,
+    Map<String, Object?> changes, {
+    int? ifVersion,
+    String? ifStatus,
+    bool ifLive = false,
+  }) async {
+    await _editLocally(id);
+    return super.patch(
+      id,
+      changes,
+      ifVersion: ifVersion,
+      ifStatus: ifStatus,
+      ifLive: ifLive,
+    );
+  }
+
+  @override
+  Future<void> insertIfAbsent(List<Map<String, Object?>> rows) async {
+    for (final r in rows) {
+      await _editLocally(r['id']! as String);
     }
-    return super.upsertMedication(model);
+    return super.insertIfAbsent(rows);
   }
 }
 
-/// A dose-log server whose batch insert lands and whose answer then never
-/// comes while [hang] is set — a response lost to a timeout.
-class HangingInsertRemote extends FakeDoseLogRemote {
-  HangingInsertRemote(super.clock);
+/// A dose table whose batch insert lands and whose answer then never comes
+/// while [hang] is set — a response lost to a timeout.
+class HangingInsertTable extends FakeSyncTable {
+  HangingInsertTable(FakeServerCore core) : super(core, 'dose_logs');
 
   Completer<void>? hang;
 
   @override
-  Future<void> insertDoseLogsIfAbsent(List<DoseLogModel> models) async {
-    await super.insertDoseLogsIfAbsent(models);
+  Future<void> insertIfAbsent(List<Map<String, Object?>> rows) async {
+    await super.insertIfAbsent(rows);
     final gate = hang;
     if (gate != null) await gate.future;
   }
 }
 
-/// A dose-log server that refuses a whole insert statement, as PostgREST
-/// does, when one of its rows breaks a rule: an id in [rejectIds] (a
-/// constraint), or a prescription the server does not have (the foreign key
-/// and the row-level policy). Its read-back can leave out [hideIds].
-class RejectingDoseRemote extends FakeDoseLogRemote {
-  RejectingDoseRemote(super.clock);
+/// A dose table that refuses a whole insert statement, as PostgREST does,
+/// when one of its rows breaks a rule: an id in [rejectIds] (a constraint),
+/// or a prescription the server does not have (the foreign key and the
+/// row-level policy). Its read-back can leave out [hideIds].
+class RejectingDoseTable extends FakeSyncTable {
+  RejectingDoseTable(FakeServerCore core) : super(core, 'dose_logs');
 
   final Set<String> rejectIds = {};
   final Set<String> hideIds = {};
-  FakeRemoteTable? prescriptions;
+
+  /// When set, a dose whose prescription this table lacks is refused.
+  FakeSyncTable? prescriptions;
 
   /// When set, the read-back never answers.
   Object? readBackError;
@@ -159,48 +197,60 @@
   /// Every insert request, as the ids it carried.
   final List<List<String>> inserts = [];
 
-  /// The ids sent with a plain upsert, in order.
+  /// The ids sent with a row update, in order.
   final List<String> upserted = [];
 
-  /// When set, a plain upsert gets no answer.
+  /// When set, a row update gets no answer.
   Object? upsertError;
 
   @override
-  Future<DateTime?> upsertDoseLog(DoseLogModel model) {
-    upserted.add(model.id);
+  Future<Map<String, dynamic>?> patch(
+    String id,
+    Map<String, Object?> changes, {
+    int? ifVersion,
+    String? ifStatus,
+    bool ifLive = false,
+  }) {
+    upserted.add(id);
     final error = upsertError;
     if (error != null) throw error;
-    return super.upsertDoseLog(model);
+    return super.patch(
+      id,
+      changes,
+      ifVersion: ifVersion,
+      ifStatus: ifStatus,
+      ifLive: ifLive,
+    );
   }
 
   @override
-  Future<void> insertDoseLogsIfAbsent(List<DoseLogModel> models) async {
-    inserts.add([for (final m in models) m.id]);
-    for (final m in models) {
-      if (rejectIds.contains(m.id)) {
+  Future<void> insertIfAbsent(List<Map<String, Object?>> rows) async {
+    inserts.add([for (final r in rows) r['id']! as String]);
+    for (final r in rows) {
+      if (rejectIds.contains(r['id'])) {
         throw const PostgrestException(
           message: 'check violation',
           code: '23514',
         );
       }
       final known = prescriptions;
-      if (known != null && !known.rows.containsKey(m.prescriptionId)) {
+      if (known != null && !known.rows.containsKey(r['prescription_id'])) {
         throw const PostgrestException(
           message: 'insert or update violates foreign key constraint',
           code: '23503',
         );
       }
     }
-    return super.insertDoseLogsIfAbsent(models);
+    return super.insertIfAbsent(rows);
   }
 
   @override
-  Future<List<DoseLogModel>> getDoseLogsByIds(List<String> ids) async {
+  Future<List<Map<String, dynamic>>> fetchMany(List<String> ids) async {
     final error = readBackError;
     if (error != null) throw error;
     return [
-      for (final d in await super.getDoseLogsByIds(ids))
-        if (!hideIds.contains(d.id)) d,
+      for (final d in await super.fetchMany(ids))
+        if (!hideIds.contains(d['id'])) d,
     ];
   }
 }
@@ -240,16 +290,16 @@
 
 int cycles() => 1 + SyncService.maxAutomaticReruns;
 
-/// A dose-log server that ignores where a page should start and answers the
+/// A dose table that ignores where a page should start and answers the
 /// first page every time, so a pull that trusted it would never end.
-class EndlessPagesRemote extends FakeDoseLogRemote {
-  EndlessPagesRemote(super.clock);
+class EndlessPagesTable extends FakeSyncTable {
+  EndlessPagesTable(FakeServerCore core) : super(core, 'dose_logs');
 
   @override
-  Future<List<DoseLogModel>> getDoseLogsSince(
-    DateTime? since, {
-    PullKey? after,
-  }) => super.getDoseLogsSince(since);
+  Future<List<Map<String, dynamic>>> page({
+    required PullKey? after,
+    required int horizon,
+  }) => super.page(after: null, horizon: horizon);
 }
 
 /// Seeds [count] dose rows of one local prescription on the server, the
@@ -297,6 +347,7 @@
   SyncService makeLocalOnly() => SyncService(
     medicationLocal: MedicationLocalDatasource(),
     medicationRemote: null,
+    syncState: null,
     treatmentLocal: TreatmentLocalDatasource(),
     treatmentRemote: null,
     prescriptionLocal: PrescriptionLocalDatasource(),
@@ -588,153 +639,133 @@
       },
     );
 
-    test(
-      'a stale pending update is not pushed and the remote copy wins',
-      () async {
-        final h = Harness();
-        // Local edit at T+10min, remote edit at T+20min. No failIds trick:
-        // the push itself must notice the remote row is newer and stand down.
-        await MedicationLocalDatasource().upsert(
-          MedicationModel(
-            id: 'm9',
-            name: 'Local',
-            quantity: 1,
-            updatedAt: h.clock.now().add(const Duration(minutes: 10)),
-          ),
-          syncStatus: SyncStatus.pendingUpdate,
-        );
-        h.meds.table.seed(
-          const MedicationModel(id: 'm9', name: 'Remote', quantity: 1).toJson(),
-          updatedAt: h.clock.now().add(const Duration(minutes: 20)),
-        );
-
-        final report = (await h.service.syncAll())!;
-
-        expect(report.skippedStale, 1);
-        expect(report.pushed, 0);
-        expect(report.failures, isEmpty);
-        expect(h.service.currentState, SyncState.success);
-        expect(h.meds.table.rows['m9']?['name'], 'Remote');
-        final row = await localRow('medications', 'm9');
-        expect(row?['name'], 'Remote');
-        expect(row?['sync_status'], SyncStatus.synced);
-      },
-    );
-
-    test(
-      'a stale skipped push rewinds the cursor so the pull refetches the row',
-      () async {
-        final h = Harness();
-        final t = h.clock.now();
-        // The server stamped the winning remote row at T+20 …
-        h.meds.table.seed(
-          const MedicationModel(
-            id: 'm9b',
-            name: 'Remote',
-            quantity: 1,
-          ).toJson(),
-          updatedAt: t.add(const Duration(minutes: 20)),
-        );
-        // … but this device's cursor already sits past it: `updated_at` is
-        // server-clock on the remote side and device-clock locally, so a
-        // delta pull asking for `> cursor` would never return the row again.
-        await h.cursors.setLastPullAt(
-          'medications',
-          t.add(const Duration(minutes: 30)),
-        );
-        await MedicationLocalDatasource().upsert(
-          MedicationModel(
-            id: 'm9b',
-            name: 'Local',
-            quantity: 1,
-            updatedAt: t.add(const Duration(minutes: 10)),
-          ),
-          syncStatus: SyncStatus.pendingUpdate,
-        );
-
-        final report = (await h.service.syncAll())!;
-
-        expect(report.skippedStale, 1);
-        expect(report.failures, isEmpty);
-        final row = await localRow('medications', 'm9b');
-        expect(
-          row?['name'],
-          'Remote',
-          reason: 'the skipped row must be replaced by the pull it relies on',
-        );
-        expect(row?['sync_status'], SyncStatus.synced);
-      },
-    );
-
-    test('a pending update newer than the remote row is pushed', () async {
+    test('a pending update with no base meets a newer server copy and takes '
+        'it', () async {
+      final h = Harness();
+      // Local edit at T+10min, remote edit at T+20min, and nothing known
+      // about the server copy (a row from before sync v2): the push reads
+      // the server copy and merges by edit time.
+      await MedicationLocalDatasource().upsert(
+        MedicationModel(
+          id: 'm9',
+          name: 'Local',
+          quantity: 1,
+          updatedAt: h.clock.now().add(const Duration(minutes: 10)),
+        ),
+        syncStatus: SyncStatus.pendingUpdate,
+      );
+      h.meds.table.seed(
+        const MedicationModel(id: 'm9', name: 'Remote', quantity: 1).toJson(),
+        updatedAt: h.clock.now().add(const Duration(minutes: 20)),
+      );
+
+      final report = (await h.service.syncAll())!;
+
+      expect(report.merged, 1);
+      final overwrite = report.overwritten.single;
+      expect(overwrite.id, 'm9');
+      expect(overwrite.columns, {'name'});
+      expect(overwrite.keptLocal, isFalse);
+      expect(report.failures, isEmpty);
+      expect(h.service.currentState, SyncState.success);
+      expect(h.meds.table.rows['m9']?['name'], 'Remote');
+      final row = await localRow('medications', 'm9');
+      expect(row?['name'], 'Remote');
+      expect(row?['sync_status'], SyncStatus.synced);
+    });
+
+    test('a server copy the pull already went past is merged by the push, '
+        'not skipped', () async {
+      final h = Harness();
+      final t = h.clock.now();
+      h.meds.table.seed(
+        const MedicationModel(id: 'm9b', name: 'Remote', quantity: 1).toJson(),
+        updatedAt: t.add(const Duration(minutes: 20)),
+      );
+      // This device's pull key is already past that row.
+      await h.cursors.setPullKey('medications', PullKey(h.core.horizon));
+      await MedicationLocalDatasource().upsert(
+        MedicationModel(
+          id: 'm9b',
+          name: 'Local',
+          quantity: 1,
+          updatedAt: t.add(const Duration(minutes: 10)),
+        ),
+        syncStatus: SyncStatus.pendingUpdate,
+      );
+
+      final report = (await h.service.syncAll())!;
+
+      expect(report.failures, isEmpty);
+      expect(report.merged, 1);
+      final row = await localRow('medications', 'm9b');
+      expect(row?['name'], 'Remote');
+      expect(row?['sync_status'], SyncStatus.synced);
+    });
+
+    test('a pending update edited after the server copy is pushed', () async {
       final h = Harness();
       await MedicationLocalDatasource().upsert(
         MedicationModel(
           id: 'm10',
           name: 'Local',
           quantity: 1,
-          updatedAt: h.clock.now().add(const Duration(minutes: 20)),
+          updatedAt: h.clock.now().subtract(const Duration(minutes: 5)),
         ),
         syncStatus: SyncStatus.pendingUpdate,
       );
       h.meds.table.seed(
         const MedicationModel(id: 'm10', name: 'Remote', quantity: 1).toJson(),
-        updatedAt: h.clock.now().add(const Duration(minutes: 5)),
+        updatedAt: h.clock.now().subtract(const Duration(minutes: 20)),
       );
 
       final report = (await h.service.syncAll())!;
 
-      expect(report.skippedStale, 0);
       expect(report.pushed, 1);
+      expect(report.overwritten.single.keptLocal, isTrue);
       expect(h.meds.table.rows['m10']?['name'], 'Local');
-      expect((await localRow('medications', 'm10'))?['name'], 'Local');
-    });
-
-    test(
-      'a pending create and a tombstone push even against a newer remote row',
-      () async {
-        final h = Harness();
-        final local = MedicationLocalDatasource();
-        // pending_create whose id already exists remotely, newer.
-        await local.upsert(
-          MedicationModel(
-            id: 'm11',
-            name: 'Local',
-            quantity: 1,
-            updatedAt: h.clock.now(),
-          ),
-          syncStatus: SyncStatus.pendingCreate,
-        );
-        h.meds.table.seed(
-          const MedicationModel(
-            id: 'm11',
-            name: 'Remote',
-            quantity: 1,
-          ).toJson(),
-          updatedAt: h.clock.now().add(const Duration(hours: 1)),
-        );
-        // pending_delete against a newer remote row.
-        h.meds.table.seed(
-          const MedicationModel(
-            id: 'm12',
-            name: 'Doomed',
-            quantity: 1,
-          ).toJson(),
-          updatedAt: h.clock.now().add(const Duration(hours: 1)),
-        );
-        await local.upsert(
-          const MedicationModel(id: 'm12', name: 'Doomed', quantity: 1),
-          syncStatus: SyncStatus.synced,
-        );
-        await local.markDeleted('m12');
-
-        final report = (await h.service.syncAll())!;
-
-        expect(report.skippedStale, 0);
-        expect(h.meds.table.rows['m11']?['name'], 'Local');
-        expect(h.meds.table.rows['m12']?['deleted_at'], isNotNull);
-      },
-    );
+      final row = (await localRow('medications', 'm10'))!;
+      expect(row['name'], 'Local');
+      expect(row['sync_status'], SyncStatus.synced);
+      expect(row['sync_version'], h.meds.table.rows['m10']!['row_version']);
+    });
+
+    test('a pending create meets a newer server copy and takes it; a '
+        'tombstone still wins over a newer live row', () async {
+      final h = Harness();
+      final local = MedicationLocalDatasource();
+      // pending_create whose id already exists remotely, edited later.
+      await local.upsert(
+        MedicationModel(
+          id: 'm11',
+          name: 'Local',
+          quantity: 1,
+          updatedAt: h.clock.now().subtract(const Duration(hours: 1)),
+        ),
+        syncStatus: SyncStatus.pendingCreate,
+      );
+      h.meds.table.seed(
+        const MedicationModel(id: 'm11', name: 'Remote', quantity: 1).toJson(),
+        updatedAt: h.clock.now().subtract(const Duration(minutes: 1)),
+      );
+      // pending_delete against a newer remote row.
+      h.meds.table.seed(
+        const MedicationModel(id: 'm12', name: 'Doomed', quantity: 1).toJson(),
+        updatedAt: h.clock.now().subtract(const Duration(minutes: 1)),
+      );
+      await local.upsert(
+        const MedicationModel(id: 'm12', name: 'Doomed', quantity: 1),
+        syncStatus: SyncStatus.synced,
+      );
+      await local.markDeleted('m12');
+
+      await h.service.syncAll();
+
+      expect(h.meds.table.rows['m11']?['name'], 'Remote');
+      expect((await localRow('medications', 'm11'))?['name'], 'Remote');
+      expect(h.meds.table.rows['m12']?['deleted_at'], isNotNull);
+      expect(await localRow('medications', 'm12'), isNull);
+    });
 
     test('force push ignores a newer remote row', () async {
       final h = Harness();
@@ -754,7 +785,6 @@
 
       final report = (await h.service.forcePush())!;
 
-      expect(report.skippedStale, 0);
       expect(report.pushed, 1);
       expect(h.meds.table.rows['m13']?['name'], 'Local');
     });
@@ -787,14 +817,40 @@
       final report = await h.service.syncAll();
       expect(report, isNotNull);
       expect(report!.pushed, 1);
-      expect(
-        report.pulled,
-        greaterThanOrEqualTo(2),
-      ); // 'a' comes back from the fake + 't'
+      // Only 't': 'a' was written after this cycle's horizon, so the next
+      // cycle sees it (and keeps it, being the same version).
+      expect(report.pulled, 1);
       expect(report.failures, isEmpty);
       expect(report.finishedAt, isNotNull);
       expect(h.service.lastReport, same(report));
       expect(h.service.currentState, SyncState.success);
+    });
+
+    test('a project without the sync migration stops the cycle before any '
+        'table request', () async {
+      final h = Harness();
+      h.server.state.migrated = false;
+      await MedicationLocalDatasource().upsert(
+        const MedicationModel(id: 'a', name: 'A', quantity: 1),
+        syncStatus: SyncStatus.pendingCreate,
+      );
+
+      final report = (await h.service.syncAll())!;
+
+      expect(
+        report.missingMigration,
+        'supabase/migrations/20260918000000_sync_v2.sql',
+      );
+      expect(
+        report.fatal,
+        contains('Apply supabase/migrations/20260918000000_sync_v2.sql'),
+      );
+      expect(h.core.requests, isEmpty);
+      expect(h.service.currentState, SyncState.error);
+      expect(
+        (await localRow('medications', 'a'))!['sync_status'],
+        SyncStatus.pendingCreate,
+      );
     });
 
     test('a failing row is recorded and the state is partial', () async {
@@ -1003,19 +1059,16 @@
 
   group('delta pull', () {
     test(
-      'first pull is full, second pull asks since the newest updated_at minus 1s',
+      'first pull is full; the next starts at the first one\'s horizon',
       () async {
         final h = Harness();
         h.meds.table.seed(
           const MedicationModel(id: 'a', name: 'A', quantity: 1).toJson(),
         );
+        final horizon = h.core.horizon;
         await h.service.syncAll();
         expect(h.meds.table.sinceCalls, [null]);
-        final cursor = await h.cursors.lastPullAt('medications');
-        expect(
-          cursor,
-          h.clock.now().toUtc().subtract(const Duration(seconds: 1)),
-        );
+        expect(await h.cursors.pullKey('medications'), PullKey(horizon));
 
         h.clock.advance(const Duration(minutes: 5));
         h.meds.table.seed(
@@ -1023,12 +1076,9 @@
         );
         h.service.debugSetStateForTest(SyncState.idle);
         final report = (await h.service.syncAll())!;
-        expect(h.meds.table.sinceCalls.last, cursor);
-        // 'a's own updated_at sits exactly at cursor + 1s (the deliberate overlap),
-        // so it is legitimately re-fetched and idempotently re-applied alongside
-        // the genuinely new 'b' — the 1 s overlap always re-includes the row it
-        // was computed from, by construction, regardless of elapsed wall time.
-        expect(report.pulled, 2);
+        expect(h.meds.table.sinceCalls.last, PullKey(horizon));
+        // Only the new row: nothing overlaps.
+        expect(report.pulled, 1);
         expect((await localRow('medications', 'b'))?['name'], 'B');
       },
     );
@@ -1049,12 +1099,11 @@
 
       final first = (await h.service.syncAll())!;
       expect(first.pulled, ids.length);
-      expect(await h.cursors.lastPullAt('dose_logs'), DateTime.utc(1970, 1, 2));
 
       h.clock.advance(const Duration(minutes: 5));
       final second = (await h.service.syncAll())!;
       expect(second.pulled, 0);
-      expect(h.doses.table.sinceCalls.last, DateTime.utc(1970, 1, 2));
+      expect(h.doses.table.sinceCalls.last, PullKey(h.core.horizon));
     });
 
     test('force pull clears cursors and pulls everything again', () async {
@@ -1111,23 +1160,16 @@
         const MedicationModel(id: 'a', name: 'A', quantity: 1).toJson(),
       );
       await h.service.syncAll();
-      final before = await h.cursors.lastPullAt('medications');
+      final before = await h.cursors.pullKey('medications');
       h.service.debugSetStateForTest(SyncState.idle);
-      // Make apply fail for a new row: seed a row whose JSON breaks fromJson.
-      h.meds.table.rows['broken'] = {
-        'id': 'broken',
-        'updated_at': h.clock
-            .now()
-            .add(const Duration(minutes: 1))
-            .toUtc()
-            .toIso8601String(),
-      };
+      // Make apply fail for a new row: a row with no name breaks fromJson.
+      h.meds.table.seed({'id': 'broken'});
       final report = (await h.service.syncAll())!;
       expect(
         report.failures.where((f) => f.table == 'medications'),
         isNotEmpty,
       );
-      expect(await h.cursors.lastPullAt('medications'), before);
+      expect(await h.cursors.pullKey('medications'), before);
     });
 
     test('cursor does not advance when a row fails to apply', () async {
@@ -1158,7 +1200,7 @@
       );
       expect(failure.error, startsWith('apply:'));
       expect(report.pulled, 1); // only the valid prescription applied
-      expect(await h.cursors.lastPullAt('prescriptions'), isNull);
+      expect(await h.cursors.pullKey('prescriptions'), isNull);
     });
   });
 
@@ -1561,13 +1603,21 @@
     Future<void> runCase(
       Harness h, {
       required String table,
-      required FakeRemoteTable remote,
+      required FakeSyncTable remote,
       required String column,
       required Future<String> Function(Database db) seed,
       required Map<String, dynamic> Function(Map<String, dynamic> row) toServer,
     }) async {
       final db = await AppDatabase.instance.database;
       final id = await seed(db);
+      remote.seed({
+        ...toServer((await localRow(table, id))!),
+        column: 'server copy',
+      }, updatedAt: h.clock.now().subtract(const Duration(hours: 1)));
+      // This device pulls the server copy: the row has its base.
+      await h.service.syncAll();
+      h.service.debugSetStateForTest(SyncState.idle);
+      remote.pageCalls.clear();
       final pushedAt = h.clock.now().subtract(const Duration(minutes: 2));
       await db.update(
         table,
@@ -1575,14 +1625,11 @@
           column: 'pushed copy',
           'sync_status': SyncStatus.pendingUpdate,
           'updated_at': pushedAt.toIso8601String(),
+          'edited_at': pushedAt.toIso8601String(),
         },
         where: 'id = ?',
         whereArgs: [id],
       );
-      remote.seed({
-        ...toServer((await localRow(table, id))!),
-        column: 'server copy',
-      }, updatedAt: h.clock.now().subtract(const Duration(hours: 1)));
 
       // Hold the push; edit the row meanwhile. The edit is stamped before the
       // server stamps the held push, as it is on a device in step with the
@@ -1768,9 +1815,9 @@
         ).toJson(),
         'deleted_at': deletedAt.toIso8601String(),
       }, updatedAt: deletedAt);
-      // The pull has already seen that tombstone go by, so only the push
+      // The pull has already gone past that tombstone, so only the push
       // can act on it.
-      await h.cursors.setLastPullAt('dose_logs', h.clock.now());
+      await h.cursors.setPullKey('dose_logs', PullKey(h.core.horizon));
 
       await h.service.syncAll();
 
@@ -1840,12 +1887,12 @@
   });
 
   group('new dose logs the server refuses', () {
-    Harness rejecting() => Harness(doseLogRemote: RejectingDoseRemote.new);
+    Harness rejecting() => Harness(doseRows: RejectingDoseTable.new);
 
     test('a row the server rejects fails alone; the rest of its batch '
         'lands', () async {
       final h = rejecting();
-      final remote = h.doses as RejectingDoseRemote;
+      final remote = h.doses.rows as RejectingDoseTable;
       final (_, ids) = await seedSchedule(durationDays: 1);
       remote.rejectIds.add(ids[1]);
 
@@ -1888,7 +1935,7 @@
     test('the doses of a prescription the server refused wait for it, '
         'without a request', () async {
       final h = rejecting();
-      final remote = h.doses as RejectingDoseRemote;
+      final remote = h.doses.rows as RejectingDoseTable;
       remote.prescriptions = h.prescriptions.table;
       final db = await AppDatabase.instance.database;
       final (goodId, good) = await seedSchedule(durationDays: 1);
@@ -1923,7 +1970,7 @@
     test('a row missing from the read-back stays pending with a failure '
         'record', () async {
       final h = rejecting();
-      final remote = h.doses as RejectingDoseRemote;
+      final remote = h.doses.rows as RejectingDoseTable;
       final (_, ids) = await seedSchedule(durationDays: 1);
       remote.hideIds.add(ids.first);
 
@@ -1941,7 +1988,7 @@
     test('a read-back without an answer leaves the rows pending with '
         'backoff', () async {
       final h = rejecting();
-      final remote = h.doses as RejectingDoseRemote;
+      final remote = h.doses.rows as RejectingDoseTable;
       final (_, ids) = await seedSchedule(durationDays: 1);
       remote.readBackError = TimeoutException('no answer');
 
@@ -1954,69 +2001,10 @@
       }
     });
 
-    test('only a dose a person recorded here is sent again for a server '
-        'stamp', () async {
+    test('a recorded dose the server holds in a newer copy is adopted, not '
+        'sent again', () async {
       final h = rejecting();
-      final remote = h.doses as RejectingDoseRemote;
-      final db = await AppDatabase.instance.database;
-      final (prescriptionId, ids) = await seedSchedule(durationDays: 1);
-      final recordedAt = h.clock.now().subtract(const Duration(hours: 1));
-      // A generated dose an older build stamped with the current time.
-      await db.update(
-        'dose_logs',
-        {'updated_at': recordedAt.toIso8601String()},
-        where: 'id = ?',
-        whereArgs: [ids.first],
-      );
-      final intake = await seedDoseLog(
-        db,
-        prescriptionId,
-        recordedAt,
-        id: 'intake',
-        status: 'taken',
-        takenTime: recordedAt,
-      );
-      final weak = await seedDoseLog(
-        db,
-        prescriptionId,
-        recordedAt,
-        id: 'weak',
-      );
-      await db.update(
-        'dose_logs',
-        {'updated_at': recordedAt.toIso8601String()},
-        where: 'id = ?',
-        whereArgs: [intake],
-      );
-      await db.update(
-        'dose_logs',
-        {'updated_at': DateTime.utc(1970).toIso8601String()},
-        where: 'id = ?',
-        whereArgs: [weak],
-      );
-      await db.update('dose_logs', {'sync_status': SyncStatus.pendingCreate});
-
-      final report = (await h.service.syncAll())!;
-
-      expect(report.failures, isEmpty);
-      expect(remote.upserted, [intake]);
-      expect(
-        h.doses.table.updatedAt(intake),
-        h.clock.now(),
-        reason: 'the server stamped it',
-      );
-      final stored = (await localRow('dose_logs', intake))!['updated_at'];
-      expect(
-        DateTime.parse(stored! as String).isAtSameMomentAs(h.clock.now()),
-        isTrue,
-      );
-      expect(h.doses.table.updatedAt(ids.first), recordedAt.toUtc());
-    });
-
-    test('a recorded dose whose second send fails stays pending and is sent '
-        'again', () async {
-      final h = rejecting();
-      final remote = h.doses as RejectingDoseRemote;
+      final remote = h.doses.rows as RejectingDoseTable;
       final db = await AppDatabase.instance.database;
       final seeded = await seedPrescription(db);
       final recordedAt = h.clock.now().subtract(const Duration(hours: 1));
@@ -2032,43 +2020,6 @@
         'updated_at': recordedAt.toIso8601String(),
         'sync_status': SyncStatus.pendingCreate,
       });
-      remote.upsertError = TimeoutException('no answer');
-
-      final report = (await h.service.syncAll())!;
-
-      expect(report.failures.map((f) => f.id), [intake]);
-      final row = (await localRow('dose_logs', intake))!;
-      expect(row['sync_status'], SyncStatus.pendingCreate);
-
-      remote.upsertError = null;
-      h.clock.advance(const Duration(hours: 1));
-      await h.service.syncAll();
-      expect(
-        (await localRow('dose_logs', intake))!['sync_status'],
-        SyncStatus.synced,
-      );
-      expect(h.doses.table.updatedAt(intake), h.clock.now());
-    });
-
-    test('a recorded dose the server holds in a newer copy is adopted, not '
-        'sent again', () async {
-      final h = rejecting();
-      final remote = h.doses as RejectingDoseRemote;
-      final db = await AppDatabase.instance.database;
-      final seeded = await seedPrescription(db);
-      final recordedAt = h.clock.now().subtract(const Duration(hours: 1));
-      final intake = await seedDoseLog(
-        db,
-        seeded.prescriptionId,
-        recordedAt,
-        id: 'intake',
-        status: 'taken',
-        takenTime: recordedAt,
-      );
-      await db.update('dose_logs', {
-        'updated_at': recordedAt.toIso8601String(),
-        'sync_status': SyncStatus.pendingCreate,
-      });
       // An earlier push landed without an answer, and another device has
       // since added a note.
       final local = DoseLogModel.fromLocalMap(
@@ -2106,7 +2057,7 @@
 
     test('a network error while rows go out one by one stops there', () async {
       final h = rejecting();
-      final remote = h.doses as RejectingDoseRemote;
+      final remote = h.doses.rows as RejectingDoseTable;
       final (_, ids) = await seedSchedule(durationDays: 1);
       remote.rejectIds.add(ids[0]);
       // The second row's own request never gets an answer.
@@ -2127,10 +2078,10 @@
   group('request timeout', () {
     test('a batch that lands but whose answer times out converges on the '
         'next attempt', () async {
-      late HangingInsertRemote remote;
+      late HangingInsertTable remote;
       final h = Harness(
         requestTimeout: const Duration(milliseconds: 50),
-        doseLogRemote: (clock) => remote = HangingInsertRemote(clock),
+        doseRows: (core) => remote = HangingInsertTable(core),
       );
       final (_, ids) = await seedSchedule(durationDays: 1);
       remote.hang = Completer<void>();
@@ -2143,9 +2094,9 @@
       expect(report.failures.first.error, contains('TimeoutException'));
       expect(await syncStatuses(ids), everyElement(SyncStatus.pendingCreate));
       // The insert did land; another device then took the first dose.
-      expect(remote.table.rows, hasLength(ids.length));
-      remote.table.rows[ids.first] = {
-        ...remote.table.rows[ids.first]!,
+      expect(remote.rows, hasLength(ids.length));
+      remote.rows[ids.first] = {
+        ...remote.rows[ids.first]!,
         'status': 'taken',
         'updated_at': h.clock.now().toIso8601String(),
       };
@@ -2158,7 +2109,7 @@
       expect(retry.failures, isEmpty);
       expect(await syncStatuses(ids), everyElement(SyncStatus.synced));
       expect((await localRow('dose_logs', ids.first))!['status'], 'taken');
-      expect(remote.table.rows[ids.first]!['status'], 'taken');
+      expect(remote.rows[ids.first]!['status'], 'taken');
     });
 
     test('an upsert that times out keeps the row pending', () async {
@@ -2190,8 +2141,8 @@
 
     test('a pull that times out keeps its cursor', () async {
       final h = Harness(requestTimeout: const Duration(milliseconds: 50));
-      final cursor = DateTime.utc(2026, 3, 2);
-      await h.cursors.setLastPullAt('dose_logs', cursor);
+      final cursor = PullKey(h.core.horizon);
+      await h.cursors.setPullKey('dose_logs', cursor);
       final never = Completer<void>();
       h.doses.table.beforeCall = () => never.future;
 
@@ -2203,7 +2154,7 @@
         report.failures.where((f) => f.table == 'dose_logs' && f.id == '*'),
         hasLength(1),
       );
-      expect(await h.cursors.lastPullAt('dose_logs'), cursor);
+      expect(await h.cursors.pullKey('dose_logs'), cursor);
     });
   });
 
@@ -2278,9 +2229,9 @@
       'automatic re-runs stop after '
       '${SyncService.maxAutomaticReruns}; the row waits for the next sync',
       () async {
-        late EditOnEveryPushRemote remote;
+        late EditOnEveryPushTable remote;
         final h = Harness(
-          medicationRemote: (clock) => remote = EditOnEveryPushRemote(clock),
+          medicationRows: (core) => remote = EditOnEveryPushTable(core),
         );
         await MedicationLocalDatasource().upsert(
           MedicationModel(
@@ -2311,9 +2262,9 @@
     );
 
     test('a sync stopped at the cap retries once after a delay', () async {
-      late EditOnEveryPushRemote remote;
+      late EditOnEveryPushTable remote;
       final h = Harness(
-        medicationRemote: (clock) => remote = EditOnEveryPushRemote(clock),
+        medicationRows: (core) => remote = EditOnEveryPushTable(core),
         capRetryDelay: const Duration(milliseconds: 40),
       );
       await MedicationLocalDatasource().upsert(
@@ -2344,10 +2295,10 @@
     });
 
     test('a sync that finishes cancels a pending cap retry', () async {
-      late EditOnEveryPushRemote remote;
+      late EditOnEveryPushTable remote;
       final h = Harness(
-        medicationRemote: (clock) =>
-            remote = EditOnEveryPushRemote(clock, limit: cycles()),
+        medicationRows: (core) =>
+            remote = EditOnEveryPushTable(core, limit: cycles()),
         capRetryDelay: const Duration(milliseconds: 40),
       );
       await MedicationLocalDatasource().upsert(
@@ -2378,9 +2329,9 @@
     });
 
     test('dispose cancels a pending cap retry', () async {
-      late EditOnEveryPushRemote remote;
+      late EditOnEveryPushTable remote;
       final h = Harness(
-        medicationRemote: (clock) => remote = EditOnEveryPushRemote(clock),
+        medicationRows: (core) => remote = EditOnEveryPushTable(core),
         capRetryDelay: const Duration(milliseconds: 40),
       );
       await MedicationLocalDatasource().upsert(
@@ -2403,9 +2354,9 @@
 
     test('a cycle still running when the service is disposed stops there '
         'and arms no retry', () async {
-      late EditOnEveryPushRemote remote;
+      late EditOnEveryPushTable remote;
       final h = Harness(
-        medicationRemote: (clock) => remote = EditOnEveryPushRemote(clock),
+        medicationRows: (core) => remote = EditOnEveryPushTable(core),
         capRetryDelay: const Duration(milliseconds: 40),
       );
       await MedicationLocalDatasource().upsert(
@@ -2641,37 +2592,37 @@
   });
 
   group('paged pull (the server answers at most 1000 rows)', () {
-    test(
-      'a first pull of 2,500 dose rows stores all of them in one cycle',
-      () async {
-        final h = Harness();
-        final base = h.clock.now().subtract(const Duration(days: 1));
-        DateTime stamp(int i) => base.add(Duration(milliseconds: i));
-        await seedRemoteDoses(h, 2500, stamp);
-
-        final report = (await h.service.syncAll())!;
-
-        expect(report.failures, isEmpty);
-        expect(report.pulled, 2500);
-        expect(await localDoseCount(), 2500);
-        expect(h.doses.table.pageCalls, hasLength(3));
-        expect(
-          await h.cursors.lastPullAt('dose_logs'),
-          stamp(2499).toUtc().subtract(const Duration(seconds: 1)),
-        );
-      },
-    );
-
-    test('rows sharing one updated_at across a page boundary are each stored '
-        'exactly once', () async {
-      final h = Harness();
-      final shared = h.clock.now().subtract(const Duration(hours: 2));
-      final later = h.clock.now().subtract(const Duration(hours: 1));
-      final ids = await seedRemoteDoses(
-        h,
-        1800,
-        (i) => i < 1500 ? shared : later.add(Duration(milliseconds: i)),
-      );
+    test('a first pull of 2,500 dose rows stores all of them in one cycle, '
+        'and the next pull starts at the horizon', () async {
+      final h = Harness();
+      await seedRemoteDoses(h, 2500, (_) => h.clock.now());
+      final horizon = h.core.horizon;
+
+      final report = (await h.service.syncAll())!;
+
+      expect(report.failures, isEmpty);
+      expect(report.pulled, 2500);
+      expect(await localDoseCount(), 2500);
+      expect(h.doses.table.pageCalls, hasLength(3));
+      expect(h.doses.table.pageCalls.map((c) => c.horizon).toSet(), {horizon});
+      expect(await h.cursors.pullKey('dose_logs'), PullKey(horizon));
+    });
+
+    test('rows written in one transaction across a page boundary are each '
+        'stored exactly once', () async {
+      final h = Harness();
+      final db = await AppDatabase.instance.database;
+      final presc = await seedPrescription(db);
+      // One insert of 1,500 rows is one transaction: they share a sync_xid.
+      h.core.insertIfAbsent('dose_logs', [
+        for (var i = 0; i < 1500; i++)
+          DoseLogModel(
+            id: 'shared-${i.toString().padLeft(4, '0')}',
+            prescriptionId: presc.prescriptionId,
+            scheduledTime: DateTime.utc(2026, 3).add(Duration(minutes: i)),
+          ).toJson(),
+      ]);
+      await seedRemoteDoses(h, 300, (_) => h.clock.now());
 
       final report = (await h.service.syncAll())!;
 
@@ -2680,40 +2631,32 @@
       // would count twice, a skipped one not at all.
       expect(report.pulled, 1800);
       expect(await localDoseCount(), 1800);
-      for (final id in ids) {
-        expect(await localRow('dose_logs', id), isNotNull, reason: id);
-      }
       expect(h.doses.table.pageCalls, hasLength(2));
-      expect(h.doses.table.pageCalls[1].after?.updatedAt, shared.toUtc());
-      expect(
-        await h.cursors.lastPullAt('dose_logs'),
-        later
-            .add(const Duration(milliseconds: 1799))
-            .toUtc()
-            .subtract(const Duration(seconds: 1)),
-      );
-    });
-
-    test('1,500 generated doses all arrive on a first pull, and the cursor '
-        'then passes them', () async {
+      final shared = h.doses.table.rows['shared-0999']!['sync_xid'] as int;
+      expect(h.doses.table.pageCalls[1].after, PullKey(shared, 'shared-0999'));
+    });
+
+    test('1,500 generated doses all arrive on a first pull, and the next '
+        'pull brings none of them again', () async {
       final h = Harness();
       await seedRemoteDoses(h, 1500, (_) => DateTime.utc(1970));
 
       final report = (await h.service.syncAll())!;
-
       expect(report.pulled, 1500);
       expect(await localDoseCount(), 1500);
-      expect(await h.cursors.lastPullAt('dose_logs'), DateTime.utc(1970, 1, 2));
-    });
-
-    test('a failure on page 2 keeps page 1 and its cursor; the next cycle '
+
+      h.doses.table.pageCalls.clear();
+      final second = (await h.service.syncAll())!;
+      expect(second.pulled, 0);
+      expect(h.doses.table.pageCalls, hasLength(1));
+    });
+
+    test('a failure on page 2 keeps page 1 and its key; the next cycle '
         'completes', () async {
       final h = Harness();
-      final base = h.clock.now().subtract(const Duration(days: 1));
-      DateTime stamp(int i) => base.add(Duration(seconds: i));
-      final ids = await seedRemoteDoses(h, 2500, stamp);
+      final ids = await seedRemoteDoses(h, 2500, (_) => h.clock.now());
       var failed = false;
-      h.doses.table.onPage = (call, since, after) {
+      h.doses.table.onPage = (call, after) {
         if (after != null && !failed) {
           failed = true;
           throw StateError('connection reset');
@@ -2728,13 +2671,14 @@
         ['*'],
       );
       expect(await localDoseCount(), 1000);
-      // Page 1 is the 1000 oldest rows.
+      // Page 1 is the 1000 rows written first.
       expect(await localRow('dose_logs', ids[999]), isNotNull);
       expect(await localRow('dose_logs', ids[1000]), isNull);
-      final pageOneEnd = stamp(
-        999,
-      ).toUtc().subtract(const Duration(seconds: 1));
-      expect(await h.cursors.lastPullAt('dose_logs'), pageOneEnd);
+      final pageOneEnd = PullKey(
+        h.doses.table.rows[ids[999]]!['sync_xid'] as int,
+        ids[999],
+      );
+      expect(await h.cursors.pullKey('dose_logs'), pageOneEnd);
 
       h.clock.advance(const Duration(minutes: 5));
       h.doses.table.pageCalls.clear();
@@ -2742,47 +2686,14 @@
 
       expect(second.failures, isEmpty);
       expect(await localDoseCount(), 2500);
-      expect(h.doses.table.pageCalls.first.since, pageOneEnd);
-      expect(
-        await h.cursors.lastPullAt('dose_logs'),
-        stamp(2499).toUtc().subtract(const Duration(seconds: 1)),
-      );
-    });
-
-    test('a failure on page 2 among generated doses keeps the cursor before '
-        'them, so the next cycle still gets the rest', () async {
-      final h = Harness();
-      await seedRemoteDoses(h, 1500, (_) => DateTime.utc(1970));
-      var failed = false;
-      h.doses.table.onPage = (call, since, after) {
-        if (after != null && !failed) {
-          failed = true;
-          throw StateError('connection reset');
-        }
-      };
-
-      await h.service.syncAll();
-
-      expect(await localDoseCount(), 1000);
-      expect(
-        await h.cursors.lastPullAt('dose_logs'),
-        DateTime.utc(1969, 12, 31, 23, 59, 59),
-      );
-
-      h.clock.advance(const Duration(minutes: 5));
-      final second = (await h.service.syncAll())!;
-
-      expect(second.failures, isEmpty);
-      expect(await localDoseCount(), 1500);
-      expect(await h.cursors.lastPullAt('dose_logs'), DateTime.utc(1970, 1, 2));
-    });
-
-    test('a row on page 2 that fails to apply holds the cursor at page 1 while '
+      expect(h.doses.table.pageCalls.first.after, pageOneEnd);
+      expect(await h.cursors.pullKey('dose_logs'), PullKey(h.core.horizon));
+    });
+
+    test('a row on page 2 that fails to apply holds the key at page 1 while '
         'later pages are still stored', () async {
       final h = Harness();
-      final base = h.clock.now().subtract(const Duration(days: 1));
-      DateTime stamp(int i) => base.add(Duration(seconds: i));
-      final ids = await seedRemoteDoses(h, 2500, stamp);
+      final ids = await seedRemoteDoses(h, 2500, (_) => h.clock.now());
       // Its prescription is nowhere, so the local insert breaks the foreign
       // key and throws.
       h.doses.table.rows[ids[1500]]!['prescription_id'] = 'no-such';
@@ -2796,14 +2707,27 @@
       expect(await localDoseCount(), 2499);
       expect(await localRow('dose_logs', ids[2499]), isNotNull);
       expect(
-        await h.cursors.lastPullAt('dose_logs'),
-        stamp(999).toUtc().subtract(const Duration(seconds: 1)),
-      );
+        await h.cursors.pullKey('dose_logs'),
+        PullKey(h.doses.table.rows[ids[999]]!['sync_xid'] as int, ids[999]),
+      );
+    });
+
+    test('a key above the server horizon (a restored server) starts the '
+        'table over', () async {
+      final h = Harness();
+      await seedRemoteDoses(h, 3, (_) => h.clock.now());
+      await h.cursors.setPullKey('dose_logs', PullKey(h.core.horizon + 500));
+
+      final report = (await h.service.syncAll())!;
+
+      expect(report.pulled, 3);
+      expect(h.doses.table.pageCalls.first.after, isNull);
+      expect(await h.cursors.pullKey('dose_logs'), PullKey(h.core.horizon));
     });
 
     test('a server that never ends a page stops the pull after the page '
         'limit', () async {
-      final h = Harness(doseLogRemote: EndlessPagesRemote.new, maxPullPages: 3);
+      final h = Harness(doseRows: EndlessPagesTable.new, maxPullPages: 3);
       await seedRemoteDoses(
         h,
         1200,
@@ -2819,6 +2743,7 @@
       expect(await localDoseCount(), 1000);
     });
   });
+
   group('pull repair after an upgrade', () {
     // What an older build left in the preferences: every table's cursor
     // where its newest-first, capped pull put it, and no repair marker.
@@ -2925,7 +2850,7 @@
       }
     }
 
-    List<FakeRemoteTable> remoteTables(Harness h) => [
+    List<FakeSyncTable> remoteTables(Harness h) => [
       h.meds.table,
       h.treatments.table,
       h.prescriptions.table,
@@ -2963,14 +2888,15 @@
         'taken',
       );
       for (final table in remoteTables(h)) {
-        expect(table.pageCalls.first.since, isNull);
+        expect(table.pageCalls.first.after, isNull);
       }
       expect(h.doses.table.pageCalls, hasLength(2));
-      expect(prefs.getInt(doneKey), 1);
-      // The cursors are the full pull's own again.
+      expect(prefs.getInt(doneKey), SyncCursorStore.pullRepairVersion);
+      // The keys are the full pull's own: the old timestamps are gone.
+      expect(await h.cursors.pullKey('medications'), PullKey(h.core.horizon));
       expect(
-        await h.cursors.lastPullAt('medications'),
-        clock.subtract(const Duration(days: 2, seconds: 1)),
+        prefs.getKeys().where((k) => k.startsWith('sync.last_pull_at.')),
+        isEmpty,
       );
     });
 
@@ -2983,24 +2909,28 @@
       final h = Harness(start: clock, cursors: SyncCursorStore(prefs));
       await seedServerOnly(h, clock.subtract(const Duration(days: 2)));
       await h.service.syncAll();
-      final cursor = await h.cursors.lastPullAt('medications');
+      final cursor = await h.cursors.pullKey('medications');
       expect(cursor, isNotNull);
 
       h.clock.advance(const Duration(minutes: 5));
       await h.service.syncAll();
-      expect(h.meds.table.pageCalls.last.since, cursor);
-
-      // A restart: a new service over the same preferences.
+      expect(h.meds.table.pageCalls.last.after, cursor);
+
+      // A restart: a new service over the same preferences and server.
+      for (final table in remoteTables(h)) {
+        table.pageCalls.clear();
+      }
       final restarted = Harness(
         start: h.clock.now(),
         cursors: SyncCursorStore(prefs),
+        server: h.server,
       );
       await restarted.service.syncAll();
       for (final table in remoteTables(restarted)) {
-        expect(table.pageCalls.first.since, isNotNull);
+        expect(table.pageCalls.first.after, isNotNull);
       }
-      expect(restarted.meds.table.pageCalls.single.since, cursor);
-      expect(prefs.getInt(doneKey), 1);
+      expect(restarted.meds.table.pageCalls.single.after, cursor);
+      expect(prefs.getInt(doneKey), SyncCursorStore.pullRepairVersion);
     });
 
     test('a sync that cannot run (offline, signed out) leaves the repair for '
@@ -3028,7 +2958,7 @@
       final report = (await h.service.syncAll())!;
       expect(report.failures, isEmpty);
       await expectAllLocal(missing);
-      expect(prefs.getInt(doneKey), 1);
+      expect(prefs.getInt(doneKey), SyncCursorStore.pullRepairVersion);
     });
 
     test('a repair sync whose pull fails is not recorded; a later sync '
@@ -3055,16 +2985,16 @@
         expect(await localRow('dose_logs', id), isNull);
       }
       expect(prefs.getInt(doneKey), isNull);
-      final medCursor = await h.cursors.lastPullAt('medications');
+      final medCursor = await h.cursors.pullKey('medications');
 
       h.doses.table.throwOnFetch = null;
       h.clock.advance(const Duration(minutes: 5));
       final second = (await h.service.syncAll())!;
       expect(second.failures, isEmpty);
       await expectAllLocal(missing);
-      expect(h.doses.table.pageCalls.last.since, isNull);
-      expect(h.meds.table.pageCalls.last.since, medCursor);
-      expect(prefs.getInt(doneKey), 1);
+      expect(h.doses.table.pageCalls.last.after, isNull);
+      expect(h.meds.table.pageCalls.last.after, medCursor);
+      expect(prefs.getInt(doneKey), SyncCursorStore.pullRepairVersion);
     });
 
     test('a failed family fetch leaves the repair unfinished too', () async {
@@ -3084,7 +3014,7 @@
       h.clock.advance(const Duration(minutes: 5));
       final second = (await h.service.syncAll())!;
       expect(second.failures, isEmpty);
-      expect(prefs.getInt(doneKey), 1);
+      expect(prefs.getInt(doneKey), SyncCursorStore.pullRepairVersion);
     });
 
     test('local-only mode leaves the cursors and the marker alone', () async {
@@ -3093,6 +3023,7 @@
       final service = SyncService(
         medicationLocal: MedicationLocalDatasource(),
         medicationRemote: null,
+        syncState: null,
         treatmentLocal: TreatmentLocalDatasource(),
         treatmentRemote: null,
         prescriptionLocal: PrescriptionLocalDatasource(),
@@ -3113,6 +3044,32 @@
       expect(snapshot(prefs), before);
     });
 
+    test(
+      'a device that finished the first repair runs this one once more',
+      () async {
+        final clock = DateTime.utc(2026, 3, 4, 12);
+        final prefs = await prefsWith({
+          for (final t in tables)
+            'sync.last_pull_at.$t': clock
+                .subtract(const Duration(hours: 1))
+                .toIso8601String(),
+          'sync.pull_repair.reset': 1,
+          'sync.pull_repair.done': 1,
+        });
+        final h = Harness(start: clock, cursors: SyncCursorStore(prefs));
+        final missing = await seedServerOnly(
+          h,
+          clock.subtract(const Duration(days: 2)),
+        );
+
+        await h.service.syncAll();
+
+        await expectAllLocal(missing);
+        expect(h.meds.table.pageCalls.first.after, isNull);
+        expect(prefs.getInt(doneKey), 2);
+      },
+    );
+
     test('a fresh install records the repair with its first pull', () async {
       final prefs = await prefsWith({});
       final h = Harness(cursors: SyncCursorStore(prefs));
@@ -3121,12 +3078,12 @@
       );
 
       await h.service.syncAll();
-      expect(prefs.getInt(doneKey), 1);
-      final cursor = await h.cursors.lastPullAt('medications');
+      expect(prefs.getInt(doneKey), SyncCursorStore.pullRepairVersion);
+      final cursor = await h.cursors.pullKey('medications');
 
       h.clock.advance(const Duration(minutes: 5));
       await h.service.syncAll();
-      expect(h.meds.table.pageCalls.map((c) => c.since), [null, cursor]);
+      expect(h.meds.table.pageCalls.map((c) => c.after), [null, cursor]);
     });
 
     test('the repair pull keeps local changes still waiting to be pushed, '
@@ -3182,8 +3139,8 @@
       final report = (await h.service.syncAll())!;
 
       expect(report.skippedBackoff, 2);
-      expect(prefs.getInt(doneKey), 1);
-      expect(h.meds.table.pageCalls.first.since, isNull);
+      expect(prefs.getInt(doneKey), SyncCursorStore.pullRepairVersion);
+      expect(h.meds.table.pageCalls.first.after, isNull);
       final edited = (await localRow('medications', 'm-edit'))!;
       expect(edited['name'], 'Local');
       expect(edited['sync_status'], SyncStatus.pendingUpdate);
```

- [ ] **Step 3: Run the ported suites to see them fail**

Run: `fvm flutter test test/services test/data test/presentation/screens/settings_sync_failures_test.dart`
Expected: compile errors, among them:
- `syncState` is not a parameter of `SyncService`;
- `pullKey` is not defined;
- `correctDoseTimes` is not defined;
- `syncNeedsMigration` is not defined;
- `FakeSyncState`'s `read` has nothing to override.

- [ ] **Step 4: The string**

Apply to the three ARB files (English carries the placeholder block), then run `fvm flutter gen-l10n && cat untranslated.txt` (prints `{}`):

```diff
--- a/lib/l10n/app_en.arb
+++ b/lib/l10n/app_en.arb
@@ -466,6 +466,8 @@
   "syncNever": "Not synced yet",
   "lastSyncSummary": "Last sync {time}: {pushed} sent, {pulled} received, {deleted} deleted, {failed} failed",
   "@lastSyncSummary": { "placeholders": { "time": { "type": "String" }, "pushed": { "type": "int" }, "pulled": { "type": "int" }, "deleted": { "type": "int" }, "failed": { "type": "int" } } },
+  "syncNeedsMigration": "The cloud project needs an update: apply {file}",
+  "@syncNeedsMigration": { "placeholders": { "file": { "type": "String" } } },
   "syncFailedItems": "Failed items",
   "syncSkippedBackoff": "{n} waiting to retry",
   "@syncSkippedBackoff": { "placeholders": { "n": { "type": "int" } } },
--- a/lib/l10n/app_de.arb
+++ b/lib/l10n/app_de.arb
@@ -285,6 +285,7 @@
   "syncPartial": "Mit Fehlern abgeschlossen",
   "syncNever": "Noch nicht synchronisiert",
   "lastSyncSummary": "Letzte Synchronisierung {time}: {pushed} gesendet, {pulled} empfangen, {deleted} gelöscht, {failed} fehlgeschlagen",
+  "syncNeedsMigration": "Das Cloud-Projekt braucht ein Update: {file} anwenden",
   "syncFailedItems": "Fehlgeschlagene Einträge",
   "syncSkippedBackoff": "{n} warten auf einen neuen Versuch",
   "discardLocalChange": "Lokale Änderung verwerfen",
--- a/lib/l10n/app_it.arb
+++ b/lib/l10n/app_it.arb
@@ -285,6 +285,7 @@
   "syncPartial": "Completata con alcuni errori",
   "syncNever": "Non ancora sincronizzato",
   "lastSyncSummary": "Ultima sincronizzazione {time}: {pushed} inviati, {pulled} ricevuti, {deleted} eliminati, {failed} falliti",
+  "syncNeedsMigration": "Il progetto cloud va aggiornato: applica {file}",
   "syncFailedItems": "Elementi non riusciti",
   "syncSkippedBackoff": "{n} in attesa di riprovare",
   "discardLocalChange": "Scarta la modifica locale",
```

- [ ] **Step 5: The remote datasources lose their v1 methods**

Replace the four files. They keep only `rows` (and `stock`); the schema-error helpers of the medication file stay.

```dart
/// Medora - Medication Remote Datasource (sync v2).
library;

import 'package:medora/core/constants.dart';
import 'package:medora/data/datasources/schema_errors.dart';
import 'package:medora/data/datasources/stock_remote.dart';
import 'package:medora/data/datasources/sync_table.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// The migration that adds the `ean` column this datasource sends.
const medicationEanMigration =
    'supabase/migrations/20260916000000_medication_ean.sql';

/// [error] read as a missing `medications` column (see [missingColumn]),
/// else null.
MissingColumnException? missingMedicationColumn(Object error) => missingColumn(
  error,
  table: AppConstants.medicationsTable,
  migration: medicationEanMigration,
  fallbackColumn: 'ean',
);

class MedicationRemoteDatasource {
  MedicationRemoteDatasource(SupabaseClient client)
    : rows = PostgrestSyncTable(
        client,
        AppConstants.medicationsTable,
        migration: medicationEanMigration,
        fallbackColumn: 'ean',
      ),
      stock = PostgrestStockRemote(client);

  /// The `medications` rows.
  final SyncTable rows;

  /// `apply_stock_change`.
  final StockRemote stock;
}
```

```dart
/// Medora - Treatment Remote Datasource (sync v2).
library;

import 'package:medora/core/constants.dart';
import 'package:medora/data/datasources/sync_table.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// The migration that adds the sick-leave columns this datasource sends.
const treatmentSickLeaveMigration =
    'supabase/migrations/20260917000000_treatment_sick_leave.sql';

class TreatmentRemoteDatasource {
  TreatmentRemoteDatasource(SupabaseClient client)
    : rows = PostgrestSyncTable(
        client,
        AppConstants.treatmentsTable,
        migration: treatmentSickLeaveMigration,
        fallbackColumn: 'sick_leave_from',
      );

  /// The `treatments` rows. A write to a project without
  /// [treatmentSickLeaveMigration] fails with a `MissingColumnException`
  /// naming the file.
  final SyncTable rows;
}
```

```dart
/// Medora - Prescription Remote Datasource (sync v2).
library;

import 'package:medora/core/constants.dart';
import 'package:medora/data/datasources/sync_table.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class PrescriptionRemoteDatasource {
  PrescriptionRemoteDatasource(SupabaseClient client)
    : rows = PostgrestSyncTable(
        client,
        AppConstants.prescriptionsTable,
        select: '*, medications(name), treatments(name)',
      );

  /// The `prescriptions` rows.
  final SyncTable rows;
}
```

```dart
/// Medora - Dose Log Remote Datasource (sync v2).
library;

import 'package:medora/core/constants.dart';
import 'package:medora/data/datasources/sync_table.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class DoseLogRemoteDatasource {
  DoseLogRemoteDatasource(SupabaseClient client)
    : rows = PostgrestSyncTable(
        client,
        AppConstants.doseLogsTable,
        select: '*, prescriptions(id, medications(name))',
      );

  /// The `dose_logs` rows. New doses go out with
  /// [SyncTable.insertIfAbsent] in batches (see `SyncService`).
  final SyncTable rows;
}
```

Then delete the old page and settle files:

```bash
git rm lib/data/datasources/pull_page.dart lib/data/sync/push_settle.dart
```

- [ ] **Step 6: The app's own dose changes**

Apply this patch. It covers:
- **the guarded drop:** a dose no server has seen (no `sync_version` and no `sync_write_id`) is still deleted at once — local-only mode, or a generated dose not sent yet;
- **the pushed sweep,** with `pushable` false in local-only mode;
- **the time correction** of untouched synced pending doses;
- **the repository and domain methods,** and the call in `DoseScheduleService.ensureScheduled`, before the off-schedule comparison.

```diff
--- a/lib/data/datasources/dose_log_local_datasource.dart
+++ b/lib/data/datasources/dose_log_local_datasource.dart
@@ -5,6 +5,7 @@
 import 'package:medora/data/local/app_database.dart';
 import 'package:medora/data/models/dose_log_model.dart';
 import 'package:medora/data/models/medication_model.dart';
+import 'package:medora/data/sync/row_merge.dart';
 import 'package:medora/domain/entities/dose_log.dart';
 import 'package:sqflite/sqflite.dart';
 
@@ -299,46 +300,81 @@
     await db.delete('dose_logs');
   }
 
-  /// Delete only pending dose logs for a specific prescription, except the
-  /// ones in [keepIds]. Preserves taken/skipped/missed logs.
-  Future<int> deletePendingByPrescription(
+  /// Drops the pending doses of [prescriptionId], except the ones in
+  /// [keepIds]; taken, skipped and missed doses are never touched. Returns
+  /// how many were dropped.
+  ///
+  /// A dose no server has seen (no known server version and no write
+  /// attempt: local-only mode, or a generated dose not sent yet) is deleted
+  /// here and now. Every other one becomes a guarded delete
+  /// (`delete_guard = 'if_pending'`, automatic edit time): the server
+  /// deletes it only while it is still pending there, so a dose taken on
+  /// another device meanwhile survives and comes back here.
+  Future<int> dropPendingByPrescription(
     String prescriptionId, {
     Set<String> keepIds = const {},
   }) async {
     final db = await _db;
-    final keep = keepIds.toList();
-    return db.delete(
-      'dose_logs',
-      where:
-          'prescription_id = ? AND status = ?'
-          '${keep.isEmpty ? '' : ' AND id NOT IN (${List.filled(keep.length, '?').join(', ')})'}',
-      whereArgs: [prescriptionId, 'pending', ...keep],
-    );
+    return db.transaction((txn) async {
+      final rows = await txn.query(
+        'dose_logs',
+        columns: ['id', 'sync_version', 'sync_write_id'],
+        where:
+            "prescription_id = ? AND status = 'pending' AND sync_status != ?",
+        whereArgs: [prescriptionId, SyncStatus.pendingDelete],
+      );
+      var dropped = 0;
+      for (final row in rows) {
+        final id = row['id']! as String;
+        if (keepIds.contains(id)) continue;
+        dropped++;
+        if (row['sync_version'] == null && row['sync_write_id'] == null) {
+          await txn.delete('dose_logs', where: 'id = ?', whereArgs: [id]);
+          continue;
+        }
+        await txn.update(
+          'dose_logs',
+          {
+            'sync_status': SyncStatus.pendingDelete,
+            'delete_guard': 'if_pending',
+            'deleted_at': DateTime.now().toIso8601String(),
+            'edited_at': automaticEditedAt.toIso8601String(),
+          },
+          where: 'id = ?',
+          whereArgs: [id],
+        );
+      }
+      return dropped;
+    });
   }
 
   /// Mark pending doses scheduled before [cutoff] as missed. Returns how
-  /// many changed, and how many of those still have to be pushed. Scoped to doses whose prescription is active and scheduled,
-  /// whose treatment is active (or absent), and whose medication is not
-  /// archived (or absent) — the same predicates [getPendingBetween] uses.
+  /// many changed, and how many of those have to be pushed (all of them).
+  /// Scoped to doses whose prescription is active and scheduled, whose
+  /// treatment is active (or absent), and whose medication is not archived
+  /// (or absent) — the same predicates [getPendingBetween] uses.
   ///
-  /// "Missed" is the app's own conclusion, not something the user did, so
-  /// it must never beat a dose taken on another device that this device has
-  /// not pulled yet:
-  /// - each row is stamped just past its own stamp ([automaticUpdatedAt]),
-  ///   not with the current time;
-  /// - `sync_status` is left alone. A row the server already has stays
-  ///   `synced`, so the change is not pushed: the server would stamp the
-  ///   update with its own clock and turn it into the newest write. Every
-  ///   device draws the same conclusion from its own copy, and a later pull
-  ///   of a real change replaces it. A row the server does not have yet
-  ///   (`pending_create`) is inserted only if still absent there.
+  /// "Missed" is the app's own conclusion, not something the user did, so it
+  /// carries the automatic edit time ([automaticEditedAt]): pushed, it loses
+  /// to any real change of the same dose made on another device, and the
+  /// server keeps `updated_at` so older builds never count it as newer.
+  /// - a `synced` row becomes `pending_update`; its push is conditional on
+  ///   the version this device holds;
+  /// - a `pending_create` row keeps its status and goes out with the insert;
   /// - a row with a change still waiting to be pushed (`pending_update`, for
   ///   example an undo made offline) is left alone: the push would send the
-  ///   sweep's "missed" as the user's change, and the server would stamp it
-  ///   as the newest write. It is swept once it is synced.
+  ///   sweep's "missed" with the user's edit time. It is swept once synced.
+  ///
+  /// `updated_at` moves just past its own stamp ([automaticUpdatedAt]), so a
+  /// push in flight notices the row changed.
+  ///
+  /// Without sync ([pushable] false, local-only mode) nothing is ever
+  /// pushed, so a dose taken and then undone (left `pending_update`) is
+  /// swept too, and no status changes.
   Future<({int changed, int unpushed})> markOverduePendingAsMissed(
-    DateTime cutoff,
-  ) async {
+    DateTime cutoff, {
+    bool pushable = true,
+  }) async {
     final db = await _db;
     return db.transaction((txn) async {
       final rows = await txn.query(
@@ -360,7 +396,7 @@
         whereArgs: [
           cutoff.toIso8601String(),
           SyncStatus.pendingDelete,
-          SyncStatus.pendingUpdate,
+          pushable ? SyncStatus.pendingUpdate : SyncStatus.pendingDelete,
         ],
       );
       for (final row in rows) {
@@ -371,17 +407,54 @@
           {
             'status': 'missed',
             'updated_at': automaticUpdatedAt(previous).toIso8601String(),
+            'edited_at': automaticEditedAt.toIso8601String(),
+            if (pushable && row['sync_status'] == SyncStatus.synced)
+              'sync_status': SyncStatus.pendingUpdate,
           },
           where: 'id = ?',
           whereArgs: [row['id']],
         );
       }
-      return (
-        changed: rows.length,
-        unpushed: rows
-            .where((r) => r['sync_status'] != SyncStatus.synced)
-            .length,
-      );
+      return (changed: rows.length, unpushed: pushable ? rows.length : 0);
+    });
+  }
+
+  /// Moves each dose in [slotTimes] (dose id → its slot's time) to that
+  /// time, when it is still a pending dose nobody touched: `synced`, and
+  /// with no edit time or the automatic one. Older builds stored some slots
+  /// hours off under the slot's own id. The change carries the automatic
+  /// edit time, so it never beats a real change made elsewhere; returns how
+  /// many moved.
+  Future<int> correctScheduledTimes(Map<String, DateTime> slotTimes) async {
+    if (slotTimes.isEmpty) return 0;
+    final db = await _db;
+    return db.transaction((txn) async {
+      var moved = 0;
+      for (final entry in slotTimes.entries) {
+        final rows = await txn.query(
+          'dose_logs',
+          columns: ['updated_at'],
+          where:
+              "id = ? AND status = 'pending' AND sync_status = ? "
+              "AND (edited_at IS NULL OR edited_at < '1970-01-02')",
+          whereArgs: [entry.key, SyncStatus.synced],
+        );
+        if (rows.isEmpty) continue;
+        final raw = rows.first['updated_at'] as String?;
+        final previous = raw == null ? null : DateTime.tryParse(raw);
+        moved += await txn.update(
+          'dose_logs',
+          {
+            'scheduled_time': entry.value.toIso8601String(),
+            'updated_at': automaticUpdatedAt(previous).toIso8601String(),
+            'edited_at': automaticEditedAt.toIso8601String(),
+            'sync_status': SyncStatus.pendingUpdate,
+          },
+          where: 'id = ?',
+          whereArgs: [entry.key],
+        );
+      }
+      return moved;
     });
   }
 
@@ -417,28 +490,6 @@
       whereArgs: [id, pushedUpdatedAt, SyncStatus.pendingCreate],
     );
     return deleted > 0;
-  }
-
-  /// True when the local copy of [remote] is an overdue dose this device
-  /// marked missed on its own ([markOverduePendingAsMissed]) and [remote] is
-  /// the still-pending copy that conclusion was drawn from, or an older one.
-  /// A pull must not turn such a dose back into a pending one.
-  Future<bool> isAutomaticallyMissedCopyOf(DoseLogModel remote) async {
-    if (remote.status != DoseStatus.pending) return false;
-    final db = await _db;
-    final rows = await db.query(
-      'dose_logs',
-      columns: ['updated_at'],
-      where: 'id = ? AND status = ? AND sync_status = ?',
-      whereArgs: [remote.id, 'missed', SyncStatus.synced],
-      limit: 1,
-    );
-    if (rows.isEmpty) return false;
-    final raw = rows.first['updated_at'] as String?;
-    final local = raw == null ? null : DateTime.tryParse(raw);
-    final remoteAt = remote.updatedAt;
-    if (local == null || remoteAt == null) return false;
-    return !remoteAt.toUtc().isAfter(local.toUtc());
   }
 
   DoseLogModel _fromRow(Map<String, dynamic> row) {
--- a/lib/domain/repositories/dose_log_repository.dart
+++ b/lib/domain/repositories/dose_log_repository.dart
@@ -63,4 +63,9 @@
   Future<Result<List<DoseLog>>> regenerateDoseLogsForPrescription(
     String prescriptionId,
   );
+
+  /// Moves doses stored under a slot's id at another time to that slot's
+  /// time ([slotTimes]: dose id → slot time), when nobody touched them.
+  /// Returns how many moved.
+  Future<Result<int>> correctDoseTimes(Map<String, DateTime> slotTimes);
 }
--- a/lib/data/repositories/dose_log_repository_impl.dart
+++ b/lib/data/repositories/dose_log_repository_impl.dart
@@ -95,9 +95,7 @@
   Future<Result<int>> markOverduePendingAsMissed(DateTime cutoff) async {
     try {
       final (:changed, :unpushed) = await localDatasource
-          .markOverduePendingAsMissed(cutoff);
-      // A dose the server already has stays `synced`: the change is local
-      // only (see the datasource), so there is nothing to push.
+          .markOverduePendingAsMissed(cutoff, pushable: _requestSync != null);
       if (unpushed > 0) _syncSoon();
       return Result.success(changed);
     } catch (e, st) {
@@ -317,17 +315,30 @@
                   unmatchedIds.contains(dose.id)))
             dose.id,
       };
-      // Delete only pending (not yet taken/skipped/missed) dose logs
-      await localDatasource.deletePendingByPrescription(
+      // Drop only pending (not yet taken/skipped/missed) dose logs; the
+      // server copies go with a guarded delete.
+      final dropped = await localDatasource.dropPendingByPrescription(
         prescriptionId,
         keepIds: keepIds,
       );
 
+      if (dropped > 0) _syncSoon();
       // Generate fresh dose logs
       return await generateDoseLogsForPrescription(prescriptionId);
     } catch (e, st) {
       debugPrint('❌ regenerateDoseLogs FAILED: $e\n$st');
       return Result.failure('Failed to regenerate dose logs: $e', st);
+    }
+  }
+
+  @override
+  Future<Result<int>> correctDoseTimes(Map<String, DateTime> slotTimes) async {
+    try {
+      final moved = await localDatasource.correctScheduledTimes(slotTimes);
+      if (moved > 0) _syncSoon();
+      return Result.success(moved);
+    } catch (e, st) {
+      return Result.failure('Failed to correct dose times: $e', st);
     }
   }
 
--- a/lib/services/dose_schedule_service.dart
+++ b/lib/services/dose_schedule_service.dart
@@ -105,6 +105,8 @@
           p.id,
         )).dataOrNull;
         if (stored == null) continue;
+        final shifted = _shiftedSlots(p.id, times, stored);
+        if (shifted.isNotEmpty) await _doses.correctDoseTimes(shifted);
         final off = _offSchedule(p.id, times, stored);
         final attempted = _attempted.putIfAbsent(p.id, () => <String>{});
         if (attempted.containsAll(off)) continue;
@@ -120,6 +122,25 @@
       debugPrint('⚠ Doses: checking the schedules failed: $e');
     }
     return regenerated;
+  }
+
+  /// The pending doses stored under a slot's own id at another time, with
+  /// the time that slot has: dose id → slot time.
+  static Map<String, DateTime> _shiftedSlots(
+    String prescriptionId,
+    List<DateTime> times,
+    List<DoseLog> stored,
+  ) {
+    final byId = {for (final d in stored) d.id: d};
+    final shifted = <String, DateTime>{};
+    for (final t in times) {
+      final dose = byId[scheduledDoseId(prescriptionId, t)];
+      if (dose == null || dose.status != DoseStatus.pending) continue;
+      if (doseSlotKey(dose.scheduledTime) != doseSlotKey(t)) {
+        shifted[dose.id] = t;
+      }
+    }
+    return shifted;
   }
 
   /// The ids of the scheduled doses [stored] lacks, and of the pending
```

- [ ] **Step 7: Cursor store, report, wiper**

Replace `lib/services/sync_cursor_store.dart`:

```dart
/// Medora - Per-table pull keys for delta sync (sync v2).
///
/// Stores, per table, where the next pull starts (`PullKey`: a transaction
/// id and a row id), so a pull asks only for rows written since.
///
/// It also keeps the markers of the one-time pull repair
/// ([startPullRepair]): builds before the paged pull read each table newest
/// first, and the server answers at most 1000 rows, so their cursors moved
/// past older rows that never arrived.
library;

import 'package:medora/data/datasources/sync_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SyncCursorStore {
  SyncCursorStore(SharedPreferences prefs) : _prefs = prefs;

  /// Non-persistent store for tests and for builds without cloud sync.
  SyncCursorStore.inMemory() : _prefs = null;

  /// The `updated_at` cursors of builds before sync v2. Still cleared by
  /// [clear], never written.
  static const keyPrefix = 'sync.last_pull_at.';

  /// The sync v2 pull keys (`PullKey.toStorage`).
  static const pullKeyPrefix = 'sync.pull_key.';

  /// The pull repair this build runs once per device. A later build that
  /// needs every table pulled in full once more raises it. Version 2 is the
  /// switch to sync v2: every table is pulled once from the start, so every
  /// row gets its merge base.
  static const pullRepairVersion = 2;

  /// The repair version whose cursor reset was applied. Outside [keyPrefix],
  /// so [clear] and a local data wipe keep it.
  static const pullRepairResetKey = 'sync.pull_repair.reset';

  /// The repair version whose full pull finished.
  static const pullRepairDoneKey = 'sync.pull_repair.done';

  final SharedPreferences? _prefs;
  final Map<String, PullKey> _memoryKeys = {};

  /// An in-memory store holds nothing an older build wrote, so it has
  /// nothing to repair.
  final Map<String, int> _memoryMarkers = {
    pullRepairResetKey: pullRepairVersion,
    pullRepairDoneKey: pullRepairVersion,
  };

  /// Where the next pull of [table] starts; null = from the beginning.
  Future<PullKey?> pullKey(String table) async {
    final prefs = _prefs;
    if (prefs == null) return _memoryKeys[table];
    return PullKey.fromStorage(prefs.getString('$pullKeyPrefix$table'));
  }

  Future<void> setPullKey(String table, PullKey key) async {
    final prefs = _prefs;
    if (prefs == null) {
      _memoryKeys[table] = key;
      return;
    }
    await prefs.setString('$pullKeyPrefix$table', key.toStorage());
  }

  /// Forgets [table]'s pull key: its next pull starts from the beginning.
  Future<void> resetPullKey(String table) async {
    _memoryKeys.remove(table);
    await _prefs?.remove('$pullKeyPrefix$table');
  }

  /// Forgets every cursor, old and new.
  Future<void> clear() async {
    _memoryKeys.clear();
    final prefs = _prefs;
    if (prefs == null) return;
    for (final key
        in prefs
            .getKeys()
            .where(
              (k) => k.startsWith(keyPrefix) || k.startsWith(pullKeyPrefix),
            )
            .toList()) {
      await prefs.remove(key);
    }
  }

  /// Called at the start of a sync cycle. True while the pull repair is not
  /// finished: the cycle's pull then counts as the repair pull, and the
  /// caller calls [finishPullRepair] once every table was fetched.
  ///
  /// The first time for this [pullRepairVersion] it clears every table's
  /// cursor, so the pull starts from the beginning and brings the rows an
  /// older build's cursor had moved past. It does so once only: a pull that
  /// fails part-way stores a cursor only for pages it stored in full, oldest
  /// first, so a retry goes on from there instead of from the start.
  ///
  /// A store with no cursor at all (a fresh install, or one whose data was
  /// wiped) has nothing to repair and is marked finished at once.
  Future<bool> startPullRepair() async {
    if (_marker(pullRepairDoneKey) >= pullRepairVersion) return false;
    if (_marker(pullRepairResetKey) < pullRepairVersion) {
      if (!_hasCursor()) {
        await finishPullRepair();
        return false;
      }
      await clear();
      await _setMarker(pullRepairResetKey, pullRepairVersion);
    }
    return true;
  }

  /// Records that the repair pull of this [pullRepairVersion] finished.
  Future<void> finishPullRepair() async {
    await _setMarker(pullRepairResetKey, pullRepairVersion);
    await _setMarker(pullRepairDoneKey, pullRepairVersion);
  }

  bool _hasCursor() {
    final prefs = _prefs;
    if (prefs == null) return _memoryKeys.isNotEmpty;
    return prefs.getKeys().any(
      (k) => k.startsWith(keyPrefix) || k.startsWith(pullKeyPrefix),
    );
  }

  int _marker(String key) {
    final prefs = _prefs;
    if (prefs == null) return _memoryMarkers[key] ?? 0;
    return prefs.getInt(key) ?? 0;
  }

  Future<void> _setMarker(String key, int version) async {
    final prefs = _prefs;
    if (prefs == null) {
      _memoryMarkers[key] = version;
      return;
    }
    await prefs.setInt(key, version);
  }
}
```

Apply:

```diff
--- a/lib/services/sync_report.dart
+++ b/lib/services/sync_report.dart
@@ -11,6 +11,25 @@
   String toString() => '$table/$id: $error';
 }
 
+/// A group of columns two devices changed differently: the cycle kept one
+/// side ([keptLocal] says which) and dropped the other.
+class SyncOverwrite {
+  const SyncOverwrite(
+    this.table,
+    this.id,
+    this.columns, {
+    required this.keptLocal,
+  });
+  final String table;
+  final String id;
+  final Set<String> columns;
+  final bool keptLocal;
+
+  @override
+  String toString() =>
+      '$table/$id ${columns.join(',')}: kept ${keptLocal ? 'this device' : 'the server'}';
+}
+
 /// Counters are filled in while the cycle runs; read it through
 /// `SyncService.lastReport` only after the cycle has finished.
 class SyncReport {
@@ -22,10 +41,12 @@
   int pulled = 0;
   int deleted = 0;
 
-  /// Pending updates whose push was skipped because the remote row was
-  /// strictly newer — the pull phase overwrites the local copy instead.
-  /// Not a failure.
-  int skippedStale = 0;
+  /// Rows whose pending local change was merged with a newer server copy,
+  /// on push or on pull.
+  int merged = 0;
+
+  /// Same-field changes one side lost (see the design, section 4.5).
+  final List<SyncOverwrite> overwritten = [];
 
   /// Rows whose push was skipped because they are inside their failure
   /// backoff window (see `SyncFailureStore`). Not a failure either — they are
@@ -37,6 +58,10 @@
   /// Set when the whole cycle aborted (not a per-row error).
   String? fatal;
 
+  /// The migration file the Supabase project lacks, when that is why the
+  /// cycle aborted.
+  String? missingMigration;
+
   bool get hasFailures => failures.isNotEmpty;
   bool get isClean => fatal == null && failures.isEmpty;
 }
--- a/lib/services/local_data_wiper.dart
+++ b/lib/services/local_data_wiper.dart
@@ -50,6 +50,7 @@
             .where(
               (k) =>
                   k.startsWith(SyncCursorStore.keyPrefix) ||
+                  k.startsWith(SyncCursorStore.pullKeyPrefix) ||
                   k.startsWith(SyncFailureStore.keyPrefix),
             )
             .toList()) {
```

- [ ] **Step 8: The cycle**

Replace `lib/services/sync_service.dart`:
- It keeps the queueing, timers, backoff, families and the prescription hook.
- It delegates each row to `TableSync`.
- It checks the migration first; a `MissingMigrationException` sets `report.fatal` and `report.missingMigration`, and the state becomes `error`.
- It pages every table from its key to the horizon (§7.2).
- It batches new doses (§7.3).
- It implements force push, force pull and `discardFailedRow` as in §7.6.

```dart
/// Medora - Sync Service
///
/// Bidirectional sync between local SQLite and Supabase (sync v2, see
/// `docs/superpowers/specs/2026-09-16-sync-v2-design.md`).
///
/// Offline-first. A cycle first asks the server for its sync state
/// (`medora_sync_state`): a project without the sync v2 migration stops the
/// cycle before anything is written ([MissingMigrationException]). Then it
/// pushes, then it pulls.
///
/// - **Push.** A pending row is sent as the columns that differ from its
///   base (the server copy it was last in step with), and only if the server
///   row is still that version. When the server moved on, the two copies are
///   merged column group by column group (`row_merge.dart`) and the rest is
///   sent again. Each attempt carries a write id stored before it is sent, so
///   an answer that never arrived is recognised later. New dose logs go out
///   in batches, inserted only where the server lacks them.
/// - **Pull.** Each table is read from its stored key up to the server's
///   horizon, in pages; a pending local row is merged, not overwritten.
///
/// For medications, treatments, prescriptions and dose logs this is the only
/// push path: the repositories write locally and ask for a [syncAll], which
/// queues behind a running cycle. One [syncAll] re-runs itself at most
/// [SyncService.maxAutomaticReruns] times, then retries once after
/// [SyncService.capRetryDelay]. Every request to the server has a timeout
/// ([SyncService.requestTimeout]) and fails like a network error.
///
/// After an upgrade, the first cycle that runs pulls every table from the
/// beginning once ([SyncCursorStore.startPullRepair]), so every row gets its
/// merge base. Nothing local is wiped.
///
/// Every cycle produces a [SyncReport]; per-row failures never abort the
/// cycle. A row that fails to push repeatedly is backed off exponentially
/// (`SyncFailureStore`) so it stops poisoning every cycle, and the user can
/// give up on it with [discardFailedRow].
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:medora/core/supabase_config.dart';
import 'package:medora/data/datasources/dose_log_local_datasource.dart';
import 'package:medora/data/datasources/dose_log_remote_datasource.dart';
import 'package:medora/data/datasources/family_local_datasource.dart';
import 'package:medora/data/datasources/family_remote_datasource.dart';
import 'package:medora/data/datasources/medication_local_datasource.dart';
import 'package:medora/data/datasources/medication_remote_datasource.dart';
import 'package:medora/data/datasources/prescription_local_datasource.dart';
import 'package:medora/data/datasources/prescription_remote_datasource.dart';
import 'package:medora/data/datasources/schema_errors.dart';
import 'package:medora/data/datasources/sync_page.dart';
import 'package:medora/data/datasources/sync_state_remote_datasource.dart';
import 'package:medora/data/datasources/sync_table.dart';
import 'package:medora/data/datasources/treatment_local_datasource.dart';
import 'package:medora/data/datasources/treatment_remote_datasource.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/models/family_member_model.dart';
import 'package:medora/data/models/family_model.dart';
import 'package:medora/data/models/prescription_model.dart';
import 'package:medora/data/sync/row_merge.dart';
import 'package:medora/data/sync/row_settle.dart';
import 'package:medora/data/sync/sync_meta.dart';
import 'package:medora/data/sync/table_sync.dart';
import 'package:medora/services/connectivity_service.dart';
import 'package:medora/services/dose_schedule_service.dart';
import 'package:medora/services/sync_cursor_store.dart';
import 'package:medora/services/sync_failure_store.dart';
import 'package:medora/services/sync_report.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;
import 'package:uuid/uuid.dart';

export 'package:medora/services/sync_report.dart';

/// Current state of the sync process.
enum SyncState { idle, syncing, success, partial, error }

class SyncService {
  SyncService({
    required this.medicationLocal,
    required this.medicationRemote,
    required this.treatmentLocal,
    required this.treatmentRemote,
    required this.prescriptionLocal,
    required this.prescriptionRemote,
    required this.doseLogLocal,
    required this.doseLogRemote,
    required this.familyLocal,
    required this.familyRemote,
    required this.syncState,
    String Function()? newWriteId,
    SyncCursorStore? cursors,
    SyncFailureStore? failures,
    bool Function()? isOnline,
    String? Function()? currentUserId,
    Stream<bool>? onlineStream,
    DateTime Function()? now,
    this.onFirstSuccessfulSync,
    this.onPrescriptionsPulled,
    this.requestTimeout = const Duration(seconds: 30),
    this.capRetryDelay = const Duration(seconds: 15),
    this.maxPullPages = defaultMaxPullPages,
  }) : _cursors = cursors ?? SyncCursorStore.inMemory(),
       _failures = failures ?? SyncFailureStore.inMemory(),
       _isOnline = isOnline ?? (() => ConnectivityService.instance.isOnline),
       _currentUserId = currentUserId ?? (() => SupabaseConfig.currentUserId),
       _onlineStream =
           onlineStream ?? ConnectivityService.instance.onlineStream,
       _now = now ?? DateTime.now,
       _newWriteId = newWriteId ?? const Uuid().v4;

  final MedicationLocalDatasource medicationLocal;
  final MedicationRemoteDatasource? medicationRemote;
  final TreatmentLocalDatasource treatmentLocal;
  final TreatmentRemoteDatasource? treatmentRemote;
  final PrescriptionLocalDatasource prescriptionLocal;
  final PrescriptionRemoteDatasource? prescriptionRemote;
  final DoseLogLocalDatasource doseLogLocal;
  final DoseLogRemoteDatasource? doseLogRemote;
  final FamilyLocalDatasource familyLocal;
  final FamilyRemoteDatasource? familyRemote;

  /// `medora_sync_state`; null in local-only mode.
  final SyncStateRemoteDatasource? syncState;
  final String Function() _newWriteId;

  /// Called with the signed-in user id after a clean cycle. Belt and braces
  /// for the data-owner bookkeeping the auth screen normally does: if a sign
  /// in ever completed without the screen recording the owner, the first
  /// clean sync records it. The callback itself decides whether an owner is
  /// already stored.
  final Future<void> Function(String userId)? onFirstSuccessfulSync;

  /// Called once per pull that stored a prescription new to this device or
  /// one whose schedule changed, after the dose logs were pulled. The doses
  /// the other device generated for it carry the 1970 stamp and never come
  /// with a delta pull, so this device generates its own copies (see
  /// `DoseScheduleService.applyPulled`); the sync they ask for runs as this
  /// cycle's re-run and adopts the server's copies. A failure only logs.
  final Future<void> Function(PulledPrescriptions pulled)?
  onPrescriptionsPulled;

  /// How long one request to the server may take before the cycle gives up
  /// on it. A timed-out request counts as a network failure: the row stays
  /// pending (with backoff) and a table whose fetch timed out keeps its
  /// cursor. The request itself may still land; see [_remote].
  final Duration requestTimeout;

  /// How long after a [syncAll] stopped at [maxAutomaticReruns] the one
  /// delayed retry runs.
  final Duration capRetryDelay;

  /// The most pages one table pulls in one cycle ([pullPageSize] rows each).
  /// A server that keeps answering full pages cannot hold the cycle for
  /// ever; the next cycle continues from the stored cursor.
  final int maxPullPages;

  final SyncCursorStore _cursors;
  final SyncFailureStore _failures;
  final bool Function() _isOnline;
  final String? Function() _currentUserId;
  final Stream<bool> _onlineStream;
  final DateTime Function() _now;

  /// True when every remote datasource exists (cloud mode, configured build).
  bool get isAvailable =>
      medicationRemote != null &&
      treatmentRemote != null &&
      prescriptionRemote != null &&
      doseLogRemote != null &&
      familyRemote != null &&
      syncState != null;

  final _stateController = StreamController<SyncState>.broadcast();
  Stream<SyncState> get stateStream => _stateController.stream;
  SyncState _currentState = SyncState.idle;
  SyncState get currentState => _currentState;

  SyncReport? _lastReport;
  SyncReport? get lastReport => _lastReport;
  DateTime? get lastSyncTime => _lastReport?.finishedAt;

  // ── Auto-sync on reconnect (Task 6 wires the provider) ─────

  StreamSubscription<bool>? _onlineSub;
  Timer? _reconnectTimer;
  Timer? _idleTimer;
  bool _wasOnline = true;

  /// Sync once, [debounce] after connectivity comes back. Idempotent.
  void startAutoSync({Duration debounce = const Duration(seconds: 2)}) {
    if (_onlineSub != null) return;
    _wasOnline = _isOnline();
    _onlineSub = _onlineStream.listen((online) {
      final cameOnline = online && !_wasOnline;
      _wasOnline = online;
      if (!cameOnline) return;
      _reconnectTimer?.cancel();
      _reconnectTimer = Timer(debounce, () => unawaited(syncAll()));
    });
  }

  void stopAutoSync() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _onlineSub?.cancel();
    _onlineSub = null;
  }

  // ── Entry points ───────────────────────────────────────────

  /// Push pending local changes, then pull remote changes. Returns the report,
  /// or null when the cycle was skipped (local-only, offline, signed out, or
  /// already syncing).
  Future<SyncReport?> syncAll() => _syncAll(retryAfterCap: true);

  Future<SyncReport?> _syncAll({required bool retryAfterCap}) => _run(
    'sync',
    (report) async {
      final state = await _remote(syncState!.read());
      // Only here, past every guard in [_run] and the migration check:
      // local-only mode, an offline device, a signed-out user and an
      // unmigrated project leave the repair for a later sync.
      final repairing = await _cursors.startPullRepair();
      await _pushPendingChanges(report);
      final fetchedAll = await _pullAll(
        report,
        force: false,
        horizon: state.horizon,
      );
      // A table whose fetch failed keeps the key of its last stored page
      // (none, if it failed at once), so the next cycle still gets the rest;
      // the repair is recorded once a cycle has fetched every table.
      if (repairing && fetchedAll) await _cursors.finishPullRepair();
    },
    queueable: true,
    retryAfterCap: retryAfterCap,
  );

  /// Push ALL local rows regardless of sync_status: "my copy is the truth".
  Future<SyncReport?> forcePush() => _run('force push', (report) async {
    await _remote(syncState!.read());
    await _pushPendingChanges(report, forceAll: true);
  });

  /// Wipe local rows and pull everything again.
  Future<SyncReport?> forcePull() => _run('force pull', (report) async {
    final state = await _remote(syncState!.read());
    await _cursors.clear();
    // Every local row is about to be replaced by the server's, so no row is
    // still waiting to be pushed and no backoff record means anything.
    await _failures.clearAll();
    await AppDatabase.instance.clearAllData();
    await _pullAll(report, force: true, horizon: state.horizon);
    // Everything was pulled from the start: that is the repair.
    await _cursors.finishPullRepair();
  });

  /// How many times one [syncAll] runs another cycle on its own, for rows
  /// still pending after their push or for requests made meanwhile. Past
  /// that, whatever is still pending waits for the next request, so a row
  /// that changes on every cycle cannot keep the service syncing for ever.
  static const maxAutomaticReruns = 3;

  /// Set when a plain [syncAll] was asked for while a cycle was running; the
  /// running cycle then runs one more before it returns.
  bool _rerunRequested = false;

  /// The one delayed [syncAll] armed when a sync stopped at the re-run cap
  /// with work left, so that work is not stranded until the next trigger.
  /// The retry itself never arms another, so this cannot become a loop.
  Timer? _capRetryTimer;

  @visibleForTesting
  bool get hasCapRetryScheduled => _capRetryTimer != null;

  /// Runs one cycle. [queueable] marks a request that must not simply be
  /// dropped when a cycle is already running: it is remembered and re-run once
  /// the current cycle finishes, so a change made mid-cycle is not left
  /// unsynced until the next trigger. Force operations are explicit user
  /// actions and are never queued.
  ///
  /// A sync asked for during a force operation runs as a plain [syncAll]
  /// right after it, before the force operation's future completes.
  ///
  /// Returns the report of *this* call's own first cycle; a queued re-run is
  /// what [lastReport] ends up holding.
  Future<SyncReport?> _run(
    String label,
    Future<void> Function(SyncReport) body, {
    bool queueable = false,
    bool retryAfterCap = false,
  }) async {
    if (_disposed) return null;
    if (!isAvailable) {
      debugPrint('Sync: $label skipped (local-only mode)');
      return null;
    }
    if (_currentState == SyncState.syncing) {
      if (queueable) {
        debugPrint('Sync: $label queued behind the running cycle');
        _rerunRequested = true;
      }
      return null;
    }
    if (!_isOnline()) {
      debugPrint('Sync: $label skipped (offline)');
      return null;
    }
    if (_currentUserId() == null) {
      debugPrint('Sync: $label skipped (unauthenticated)');
      return null;
    }

    _rerunRequested = false;
    // This cycle covers whatever a pending retry was going to send.
    if (retryAfterCap) _cancelCapRetry();
    SyncReport? first;
    var reruns = 0;
    do {
      _rerunRequested = false;
      _setState(SyncState.syncing);
      final report = SyncReport(startedAt: _now());
      first ??= report;
      await _cycle(label, report, body);
      // A disposed service has been replaced: its cycle ends here, and it
      // arms nothing that would run later next to its successor.
      if (_disposed) break;
      if (!queueable || !_rerunRequested) break;
      // A queued re-run answers to the same guards as a fresh request: if
      // the device went offline or the user signed out while the cycle ran,
      // it is dropped rather than run against nothing.
      if (!_isOnline() || _currentUserId() == null) {
        debugPrint('Sync: queued $label dropped (offline or signed out)');
        _rerunRequested = false;
      } else if (reruns == maxAutomaticReruns) {
        debugPrint(
          'Sync: $label stopped after $reruns re-runs; '
          '${retryAfterCap ? 'retrying in $capRetryDelay' : 'rows still pending wait for the next sync'}',
        );
        _rerunRequested = false;
        if (retryAfterCap) {
          _capRetryTimer ??= Timer(capRetryDelay, () {
            _capRetryTimer = null;
            unawaited(_syncAll(retryAfterCap: false));
          });
        }
      } else {
        reruns++;
      }
    } while (_rerunRequested);
    final requestedDuringForce = !queueable && _rerunRequested && !_disposed;
    _rerunRequested = false;
    // A force operation does not re-run itself, but a sync asked for while
    // it ran (a write, or a row edited while the force push sent it) still
    // has to happen: without this it would wait for the next trigger.
    if (requestedDuringForce) await syncAll();
    return first;
  }

  Future<void> _cycle(
    String label,
    SyncReport report,
    Future<void> Function(SyncReport) body,
  ) async {
    try {
      await body(report);
    } on MissingMigrationException catch (e) {
      debugPrint('Sync: $label stopped — $e');
      report.fatal = '$e';
      report.missingMigration = e.migration;
    } on _FetchFailedFatally catch (e) {
      // Force pull already wiped the local database, so a whole-table fetch
      // failure leaves the device with a hole in its data. That is a failed
      // cycle, not a partial one.
      debugPrint('Sync: $label aborted — ${e.table} fetch failed: ${e.cause}');
      report.fatal = '$label: ${e.table} fetch failed';
    } catch (e, st) {
      debugPrint('Sync: fatal error during $label: $e\n$st');
      report.fatal = '$e';
    }
    report.finishedAt = _now();
    final userId = _currentUserId();
    if (report.isClean && userId != null && onFirstSuccessfulSync != null) {
      try {
        await onFirstSuccessfulSync!(userId);
      } catch (e) {
        debugPrint('Sync: recording the data owner failed: $e');
      }
    }
    _lastReport = report;
    debugPrint(
      'Sync: $label done — pushed ${report.pushed}, pulled ${report.pulled}, '
      'deleted ${report.deleted}, merged ${report.merged}, '
      'overwritten ${report.overwritten}, '
      'skipped-backoff ${report.skippedBackoff}, '
      'failed ${report.failures.length}',
    );
    _setState(
      report.fatal != null
          ? SyncState.error
          : report.hasFailures
          ? SyncState.partial
          : SyncState.success,
    );
    _returnToIdleLater();
  }

  /// Drops a finished cycle's state back to [SyncState.idle] after a moment,
  /// so the UI has time to show the outcome. Cancellable: a new cycle (or
  /// [dispose]) kills the pending timer, otherwise the previous cycle's timer
  /// would fire mid-flight and lie about the current one.
  void _returnToIdleLater() {
    _idleTimer?.cancel();
    if (_disposed) return;
    _idleTimer = Timer(const Duration(seconds: 2), () {
      _idleTimer = null;
      if (_currentState == SyncState.success ||
          _currentState == SyncState.partial) {
        _setState(SyncState.idle);
      }
    });
  }

  // ── Push ───────────────────────────────────────────────────

  /// The per-row sync of one of the four merged tables.
  late final Map<String, TableSync> _tables = {
    if (medicationRemote != null)
      'medications': _tableSync('medications', medicationRemote!.rows),
    if (treatmentRemote != null)
      'treatments': _tableSync('treatments', treatmentRemote!.rows),
    if (prescriptionRemote != null)
      'prescriptions': _tableSync('prescriptions', prescriptionRemote!.rows),
    if (doseLogRemote != null)
      'dose_logs': _tableSync('dose_logs', doseLogRemote!.rows),
  };

  TableSync _tableSync(String table, SyncTable rows) => TableSync(
    table: table,
    remote: _TimedSyncTable(rows, requestTimeout),
    newWriteId: _newWriteId,
    now: _now,
  );

  Future<void> _pushPendingChanges(
    SyncReport report, {
    bool forceAll = false,
  }) async {
    final db = await AppDatabase.instance.database;
    final userId = _currentUserId();
    if (userId == null) return;

    final where = forceAll ? null : 'sync_status != ?';
    final whereArgs = forceAll ? null : [SyncStatus.synced];

    // Families are pushed by two batches: this one sends live rows, and the
    // one after the members finishes the tombstones a "leave family" leaves
    // behind. Tombstones are excluded here by the query rather than skipped
    // inside the callback, so a row the second batch is backing off is not
    // visited twice per cycle — the earlier visit used to clear the very
    // failure record the second batch had just written, and the backoff
    // could never escalate.
    final familyWhere = forceAll
        ? 'sync_status != ?'
        : 'sync_status != ? AND sync_status != ?';
    final familyWhereArgs = forceAll
        ? [SyncStatus.pendingDelete]
        : [SyncStatus.synced, SyncStatus.pendingDelete];

    // FK order: Families -> Medications -> Treatments -> Prescriptions ->
    // DoseLogs
    await _pushBatch('families', report, familyWhere, familyWhereArgs, (
      row,
    ) async {
      final model = FamilyModel.fromJson(row);
      await _remote(familyRemote!.upsertFamily(model));
      await db.update(
        'families',
        {'sync_status': SyncStatus.synced},
        where: 'id = ?',
        whereArgs: [model.id],
      );
      return true;
    });

    await _pushBatch('family_members', report, where, whereArgs, (row) async {
      final model = FamilyMemberModel.fromJson(row);
      if (row['sync_status'] == SyncStatus.pendingDelete) {
        await _remote(familyRemote!.removeMember(model.id));
        await familyLocal.hardDeleteMember(model.id);
      } else {
        await _remote(familyRemote!.upsertMember(model));
        await db.update(
          'family_members',
          {'sync_status': SyncStatus.synced},
          where: 'id = ?',
          whereArgs: [model.id],
        );
      }
      return true;
    });

    // Families the user left: drop locally once their member rows are gone.
    await _pushBatch(
      'families',
      report,
      'sync_status = ?',
      [SyncStatus.pendingDelete],
      (row) async {
        final id = row['id'] as String;
        final remaining = await db.query(
          'family_members',
          columns: ['id'],
          where: 'family_id = ? AND sync_status = ?',
          whereArgs: [id, SyncStatus.pendingDelete],
        );
        if (remaining.isNotEmpty) return false; // member removal still pending
        await familyLocal.deleteFamily(id);
        return true;
      },
    );

    await _pushTable('medications', report, userId, forceAll: forceAll);
    await _pushTable('treatments', report, userId, forceAll: forceAll);
    await _pushTable('prescriptions', report, userId, forceAll: forceAll);
    // A dose this device created is only ever inserted where the server does
    // not have it yet, in batches (see [_pushNewDoseLogs]); a forced push is
    // the exception, since it means "my copy is the truth".
    if (!forceAll) await _pushNewDoseLogs(report);
    await _pushTable(
      'dose_logs',
      report,
      userId,
      forceAll: forceAll,
      skipCreates: !forceAll,
    );
  }

  /// Pushes the pending rows of one merged [table] through its [TableSync].
  /// A dose whose prescription the server refused this cycle waits for it.
  Future<void> _pushTable(
    String table,
    SyncReport report,
    String userId, {
    required bool forceAll,
    bool skipCreates = false,
  }) async {
    final sync = _tables[table]!;
    final refused = table == 'dose_logs'
        ? await _refusedPrescriptions()
        : const <String>{};
    await _pushBatch(
      table,
      report,
      forceAll
          ? null
          : skipCreates
          ? 'sync_status != ? AND sync_status != ?'
          : 'sync_status != ?',
      forceAll
          ? null
          : skipCreates
          ? [SyncStatus.synced, SyncStatus.pendingCreate]
          : [SyncStatus.synced],
      (row) async {
        if (refused.contains(row['prescription_id'])) {
          report.skippedBackoff++;
          return false;
        }
        final result = await sync.pushRow(row, userId: userId, force: forceAll);
        _recordConflicts(report, table, row['id']! as String, result.conflicts);
        if (result.outcome == PushOutcome.pending) _rerunRequested = true;
        return true;
      },
    );
  }

  void _recordConflicts(
    SyncReport report,
    String table,
    String id,
    List<MergeConflict> conflicts,
  ) {
    if (conflicts.isEmpty) return;
    report.merged++;
    for (final c in conflicts) {
      report.overwritten.add(
        SyncOverwrite(table, id, c.columns, keptLocal: c.keptLocal),
      );
    }
  }

  /// Prescriptions that are not on the server yet and failed to go there:
  /// their doses would be refused too (sick-branch review m-3 counts a
  /// `pending_update` that never reached the server as well).
  Future<Set<String>> _refusedPrescriptions() async {
    final db = await AppDatabase.instance.database;
    final refused = <String>{};
    for (final p in await db.query(
      'prescriptions',
      columns: ['id'],
      where: 'sync_status != ? AND sync_version IS NULL',
      whereArgs: [SyncStatus.synced],
    )) {
      final id = p['id']! as String;
      if (await _failures.get('prescriptions', id) != null) refused.add(id);
    }
    return refused;
  }

  /// How many new dose logs one request inserts. The read-back lists their
  /// ids in the URL, which keeps it well under common URL limits.
  static const doseLogInsertBatchSize = 100;

  /// Pushes the `pending_create` dose logs: a generated schedule can be
  /// hundreds of rows, and the same dose (deterministic id) can already be on
  /// the server, taken on another device.
  ///
  /// Per batch: each row gets a write id, stored before the request; one
  /// insert that leaves existing rows alone; then one read of the same ids.
  /// A row the server holds with this device's write id is settled
  /// ([settlePushedRow]); a row someone else wrote is merged (a generated
  /// copy always loses to it). A row missing from the read-back stays
  /// pending with backoff.
  ///
  /// - **The server refuses the batch** ([PostgrestException]): each row is
  ///   sent alone and only the rows the server refuses on their own stay
  ///   pending with backoff.
  /// - **No answer** (a network error or a timeout): every row of the batch
  ///   stays pending with backoff; its write id recognises the insert if it
  ///   landed.
  /// - **A dose whose prescription the server refused** waits, counted as
  ///   backing off, without a failure of its own.
  ///
  /// A failed batch never stops the batches after it.
  Future<void> _pushNewDoseLogs(SyncReport report) async {
    final db = await AppDatabase.instance.database;
    final rows = await db.query(
      'dose_logs',
      where: 'sync_status = ?',
      whereArgs: [SyncStatus.pendingCreate],
      orderBy: 'scheduled_time',
    );
    final refused = await _refusedPrescriptions();
    final ready = <Map<String, dynamic>>[];
    final backedOff = <String>{};
    for (final row in rows) {
      final id = row['id'] as String;
      if (refused.contains(row['prescription_id'])) {
        report.skippedBackoff++;
        continue;
      }
      final failure = await _failures.get('dose_logs', id);
      if (failure != null) {
        if (failure.isBackingOffAt(_now())) {
          report.skippedBackoff++;
          continue;
        }
        backedOff.add(id);
      }
      ready.add(row);
    }
    final sync = _tables['dose_logs']!;
    for (var start = 0; start < ready.length; start += doseLogInsertBatchSize) {
      final batch = await _withWriteIds(
        ready.sublist(
          start,
          (start + doseLogInsertBatchSize).clamp(0, ready.length),
        ),
      );
      final landed = await _insertNewDoseLogs(batch, report);
      if (landed.isEmpty) continue;
      final List<Map<String, dynamic>> server;
      try {
        server = await _remote(
          doseLogRemote!.rows.fetchMany([
            for (final row in landed) row['id'] as String,
          ]),
        );
      } catch (e) {
        await _failNewDoseLogs(landed, report, e);
        continue;
      }
      final byId = {for (final d in server) d['id'] as String: d};
      for (final row in landed) {
        final id = row['id'] as String;
        final remote = byId[id];
        if (remote == null) {
          await _failures.recordFailure('dose_logs', id, _now());
          report.failures.add(
            SyncFailure(
              'dose_logs',
              id,
              'push: not on the server after insert',
            ),
          );
          continue;
        }
        final bool pending;
        if (RemoteMeta.fromJson(remote).writeId == row['sync_write_id']) {
          pending = await settlePushedRow(
            db,
            'dose_logs',
            pushed: row,
            server: remote,
            newOpId: _newWriteId,
          );
        } else {
          final applied = await sync.applyPulled(remote);
          _recordConflicts(report, 'dose_logs', id, applied.conflicts);
          pending = await _isLocallyPending('dose_logs', id);
        }
        report.pushed++;
        if (backedOff.contains(id)) await _failures.clear('dose_logs', id);
        if (pending) _rerunRequested = true;
      }
      await Future<void>.delayed(Duration.zero);
    }
  }

  /// [rows] with a fresh write id each, stored on the local rows first.
  Future<List<Map<String, dynamic>>> _withWriteIds(
    List<Map<String, dynamic>> rows,
  ) async {
    final db = await AppDatabase.instance.database;
    final stamped = <Map<String, dynamic>>[];
    await db.transaction((txn) async {
      for (final row in rows) {
        final writeId = _newWriteId();
        await txn.update(
          'dose_logs',
          {'sync_write_id': writeId},
          where: 'id = ?',
          whereArgs: [row['id']],
        );
        stamped.add({...row, 'sync_write_id': writeId});
      }
    });
    return stamped;
  }

  /// The insert payload of the local dose row [row].
  static Map<String, Object?> _newDosePayload(Map<String, dynamic> row) {
    final edited = row['edited_at'] ?? row['updated_at'];
    return {
      ...localWire('dose_logs', row),
      'write_id': row['sync_write_id'],
      'edited_at': edited is String
          ? DateTime.parse(edited).toUtc().toIso8601String()
          : automaticEditedAt.toIso8601String(),
    };
  }

  /// Inserts [batch] where the server lacks its rows and returns the rows
  /// the server now has (see [_pushNewDoseLogs]); the others are recorded
  /// as failures.
  Future<List<Map<String, dynamic>>> _insertNewDoseLogs(
    List<Map<String, dynamic>> batch,
    SyncReport report,
  ) async {
    try {
      await _remote(
        doseLogRemote!.rows.insertIfAbsent([
          for (final row in batch) _newDosePayload(row),
        ]),
      );
      return batch;
    } on PostgrestException catch (e) {
      if (batch.length == 1) {
        await _failNewDoseLogs(batch, report, e);
        return const [];
      }
      debugPrint(
        'Sync: the server refused a batch of ${batch.length} dose logs '
        '(${e.code}); sending them one by one',
      );
    } catch (e) {
      await _failNewDoseLogs(batch, report, e);
      return const [];
    }
    final landed = <Map<String, dynamic>>[];
    for (var i = 0; i < batch.length; i++) {
      final row = batch[i];
      try {
        await _remote(
          doseLogRemote!.rows.insertIfAbsent([_newDosePayload(row)]),
        );
        landed.add(row);
      } on PostgrestException catch (e) {
        await _failNewDoseLogs([row], report, e);
      } catch (e) {
        // No answer: the rest would most likely time out one by one too.
        await _failNewDoseLogs(batch.sublist(i), report, e);
        break;
      }
    }
    return landed;
  }

  Future<void> _failNewDoseLogs(
    List<Map<String, dynamic>> rows,
    SyncReport report,
    Object error,
  ) async {
    for (final row in rows) {
      final id = row['id'] as String;
      await _failures.recordFailure('dose_logs', id, _now());
      report.failures.add(SyncFailure('dose_logs', id, 'push: $error'));
    }
  }

  /// [call] with the cycle's [requestTimeout]. A request that times out
  /// throws [TimeoutException] and is handled like any network error; its
  /// result, if it ever arrives, is ignored, so it never settles a row.
  Future<T> _remote<T>(Future<T> call) => call.timeout(requestTimeout);

  /// Runs [processRow] per row; a thrown error becomes a [SyncFailure] and the
  /// batch continues. [processRow] returns false when the row was skipped
  /// (not counted).
  Future<void> _pushBatch(
    String table,
    SyncReport report,
    String? where,
    List<dynamic>? whereArgs,
    Future<bool> Function(Map<String, dynamic>) processRow,
  ) async {
    final db = await AppDatabase.instance.database;
    final rows = await db.query(table, where: where, whereArgs: whereArgs);
    for (var i = 0; i < rows.length; i++) {
      final row = rows[i];
      final id = '${row['id']}';
      final failure = await _failures.get(table, id);
      if (failure != null && failure.isBackingOffAt(_now())) {
        report.skippedBackoff++;
        continue;
      }
      try {
        // Only a row that actually went through is forgiven: a row that was
        // skipped (stale, or waiting for another batch) has proved nothing
        // and must keep whatever backoff it had.
        if (await processRow(row)) {
          report.pushed++;
          if (failure != null) await _failures.clear(table, id);
        }
      } catch (e) {
        await _failures.recordFailure(table, id, _now());
        report.failures.add(SyncFailure(table, id, 'push: $e'));
      }
      // Yield to the UI every few rows.
      if (i % 5 == 2) await Future<void>.delayed(Duration.zero);
    }
  }

  /// Give up on a row that keeps failing to push: replace the local copy with
  /// the server's and forget its backoff. Exposed for the settings failures
  /// dialog.
  ///
  /// The server row is fetched directly and stored with its merge base; a
  /// row the server does not have (or has tombstoned) is deleted locally.
  /// That is also what discarding a local `pending_delete` means: keep the
  /// server's copy.
  ///
  /// Throws when the fetch fails, leaving the row pending so the caller can
  /// surface the error and the user can try again.
  Future<void> discardFailedRow(String table, String id) async {
    switch (table) {
      case 'medications' || 'treatments' || 'prescriptions' || 'dose_logs':
        final remote = await _remote(_tables[table]!.remote.fetch(id));
        final db = await AppDatabase.instance.database;
        await db.delete(table, where: 'id = ?', whereArgs: [id]);
        if (remote != null && remote['deleted_at'] == null) {
          await _tables[table]!.applyPulled(remote);
        }
      case 'families':
        final remote = await familyRemote!.getFamilyById(id);
        await _replaceLocal(
          remote,
          deletedAt: null,
          delete: () => familyLocal.deleteFamily(id),
          upsert: (f) =>
              familyLocal.upsertFamily(f, syncStatus: SyncStatus.synced),
        );
      case 'family_members':
        await _discardFailedMember(id);
      default:
        throw ArgumentError.value(table, 'table', 'not a synced table');
    }
    await _failures.clear(table, id);
    debugPrint('Sync: discarded the local change to $table/$id');
  }

  /// Applies the server's copy of a row the user gave up on: a missing or
  /// tombstoned row is deleted locally, anything else is stored as `synced`.
  Future<void> _replaceLocal<T>(
    T? remote, {
    required DateTime? deletedAt,
    required Future<void> Function() delete,
    required Future<void> Function(T row) upsert,
  }) async {
    if (remote == null || deletedAt != null) {
      await delete();
      return;
    }
    await upsert(remote);
  }

  /// Family members have no get-by-id endpoint; the member list of the
  /// family the local row belongs to is the equivalent lookup.
  Future<void> _discardFailedMember(String id) async {
    final db = await AppDatabase.instance.database;
    final rows = await db.query(
      'family_members',
      columns: ['family_id'],
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    final familyId = rows.isEmpty ? null : rows.first['family_id'] as String?;
    if (familyId == null) {
      await familyLocal.hardDeleteMember(id);
      return;
    }
    final members = await familyRemote!.getMembers(familyId);
    FamilyMemberModel? remote;
    for (final m in members) {
      if (m.id == id) remote = m;
    }
    if (remote == null) {
      await familyLocal.hardDeleteMember(id);
      return;
    }
    await familyLocal.upsertMember(remote, syncStatus: SyncStatus.synced);
  }

  // ── Pull ───────────────────────────────────────────────────

  /// Returns false when a fetch failed, so some table was not read to its
  /// end (or to [maxPullPages]).
  Future<bool> _pullAll(
    SyncReport report, {
    required bool force,
    required int horizon,
  }) async {
    final pulled = PulledPrescriptions();
    final families = await _pullFamilies(report, failFast: force);
    final both = await Future.wait([
      _pullTable('medications', report, force: force, horizon: horizon),
      _pullTable('treatments', report, force: force, horizon: horizon),
    ]);
    final prescriptions = await _pullTable(
      'prescriptions',
      report,
      force: force,
      horizon: horizon,
      pulled: pulled,
    );
    final doses = await _pullTable(
      'dose_logs',
      report,
      force: force,
      horizon: horizon,
    );
    final hook = onPrescriptionsPulled;
    if (hook != null && !pulled.isEmpty) {
      try {
        await hook(pulled);
      } catch (e) {
        debugPrint('Sync: generating doses for pulled prescriptions: $e');
      }
    }
    return families && !both.contains(false) && prescriptions && doses;
  }

  /// The default for [maxPullPages]: 50,000 rows per table per cycle.
  static const defaultMaxPullPages = 50;

  /// Delta pull for one table: the rows from its stored key up to
  /// [horizon], in pages of [pullPageSize] (see `pullPage`), each applied
  /// through [TableSync.applyPulled].
  ///
  /// The key is stored after every page, so a failure part-way leaves it at
  /// the end of the last page that was fully stored. Once a row fails to
  /// apply, the key stays where it was for the rest of the cycle, so that
  /// row is fetched again. A page shorter than [pullPageSize] ends the pull
  /// and stores the horizon as the next start. A stored key above the
  /// horizon (a restored server) starts the table over.
  ///
  /// A failure to fetch a page is normally recorded and ends this table's
  /// pull. When [force] is set the caller has already cleared the local
  /// database, so the same failure aborts the whole cycle instead.
  ///
  /// [pulled] collects prescriptions that are new here or whose schedule
  /// changed.
  Future<bool> _pullTable(
    String table,
    SyncReport report, {
    required bool force,
    required int horizon,
    PulledPrescriptions? pulled,
  }) async {
    final sync = _tables[table]!;
    var after = force ? null : await _cursors.pullKey(table);
    if (after != null && after.xid > horizon) {
      debugPrint(
        'Sync: $table key ${after.xid} is past the horizon $horizon; '
        'pulling it from the start',
      );
      await _cursors.resetPullKey(table);
      after = null;
    }
    var keyHeld = false;
    for (var page = 0; page < maxPullPages; page++) {
      final List<Map<String, dynamic>> rows;
      try {
        rows = await _remote(sync.remote.page(after: after, horizon: horizon));
      } catch (e) {
        report.failures.add(SyncFailure(table, '*', 'pull: $e'));
        if (force) throw _FetchFailedFatally(table, e);
        return false;
      }
      for (final row in rows) {
        final id = row['id'] as String;
        try {
          final before = pulled == null
              ? null
              : await prescriptionLocal.getPrescriptionById(id);
          final applied = await sync.applyPulled(row);
          _recordConflicts(report, table, id, applied.conflicts);
          switch (applied.outcome) {
            case PullOutcome.deleted:
              report.deleted++;
            case PullOutcome.kept:
              break;
            case PullOutcome.inserted ||
                PullOutcome.replaced ||
                PullOutcome.merged:
              report.pulled++;
              if (pulled != null) {
                await _notePulledPrescription(pulled, id, before);
              }
          }
        } catch (e) {
          keyHeld = true;
          report.failures.add(SyncFailure(table, id, 'apply: $e'));
        }
      }
      final complete = rows.length < pullPageSize;
      if (rows.isNotEmpty) {
        after = PullKey(
          RemoteMeta.fromJson(rows.last).syncXid,
          rows.last['id'] as String,
        );
      }
      if (!keyHeld) {
        if (complete) {
          await _cursors.setPullKey(table, PullKey(horizon));
        } else if (after != null) {
          await _cursors.setPullKey(table, after);
        }
      }
      if (complete) return true;
    }
    debugPrint(
      'Sync: $table pull stopped after $maxPullPages pages; '
      'the next cycle continues',
    );
    return true;
  }

  /// Records in [pulled] whether prescription [id] is new here or its
  /// schedule changed from [before].
  Future<void> _notePulledPrescription(
    PulledPrescriptions pulled,
    String id,
    PrescriptionModel? before,
  ) async {
    final after = await prescriptionLocal.getPrescriptionById(id);
    if (after == null) return;
    if (before == null) {
      pulled.added.add(id);
    } else if (_scheduleChanged(before, after)) {
      pulled.changed.add(id);
    }
  }

  /// Returns false when a fetch failed.
  Future<bool> _pullFamilies(SyncReport report, {bool failFast = false}) async {
    try {
      final membership = await _remote(familyRemote!.getCurrentMembership());
      if (membership == null) return true;
      final family = await _remote(
        familyRemote!.getFamilyById(membership.familyId),
      );
      if (family == null) return true;
      // A row with unpushed local changes (in particular a pending_delete
      // from "leave family" / "remove member") must not be stamped back to
      // `synced` from the remote copy — that would silently drop the user's
      // change before the next push ever gets to send it.
      if (!await _isLocallyPending('families', family.id)) {
        await familyLocal.upsertFamily(family, syncStatus: SyncStatus.synced);
        report.pulled++;
      }
      final members = await _remote(familyRemote!.getMembers(family.id));
      for (final m in members) {
        if (await _isLocallyPending('family_members', m.id)) continue;
        await familyLocal.upsertMember(m, syncStatus: SyncStatus.synced);
        report.pulled++;
      }
      // Members that vanished remotely are dropped locally (pending local
      // rows are left alone — the next push decides their fate).
      await familyLocal.deleteMembersNotIn(
        family.id,
        members.map((m) => m.id).toSet(),
      );
      return true;
    } catch (e) {
      report.failures.add(SyncFailure('families', '*', 'pull: $e'));
      if (failFast) throw _FetchFailedFatally('families', e);
      return false;
    }
  }

  /// True when the local row exists and still has unpushed changes.
  Future<bool> _isLocallyPending(String table, String id) async {
    final db = await AppDatabase.instance.database;
    final rows = await db.query(
      table,
      columns: ['id'],
      where: 'id = ? AND sync_status != ?',
      whereArgs: [id, SyncStatus.synced],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  // ── Helpers ────────────────────────────────────────────────

  /// True when [after] generates other doses than [before] would.
  static bool _scheduleChanged(
    PrescriptionModel before,
    PrescriptionModel after,
  ) =>
      before.scheduleType != after.scheduleType ||
      before.intervalHours != after.intervalHours ||
      before.durationDays != after.durationDays ||
      before.startTime != after.startTime ||
      before.isActive != after.isActive ||
      !listEquals(before.scheduleTimes, after.scheduleTimes);

  void _setState(SyncState state) {
    // A starting cycle outlives the previous one's return-to-idle timer.
    if (state == SyncState.syncing) {
      _idleTimer?.cancel();
      _idleTimer = null;
    }
    _currentState = state;
    if (_stateController.isClosed) return;
    _stateController.add(state);
  }

  void _cancelCapRetry() {
    _capRetryTimer?.cancel();
    _capRetryTimer = null;
  }

  /// Set by [dispose]; a disposed service starts no cycle.
  bool _disposed = false;

  void dispose() {
    _disposed = true;
    stopAutoSync();
    _cancelCapRetry();
    _idleTimer?.cancel();
    _idleTimer = null;
    if (!_stateController.isClosed) _stateController.close();
  }

  @visibleForTesting
  void debugSetStateForTest(SyncState state) => _setState(state);
}

/// Internal: a whole-table fetch failed during a cycle that must not continue
/// (force pull, where the local database has already been cleared).
class _FetchFailedFatally implements Exception {
  _FetchFailedFatally(this.table, this.cause);

  final String table;
  final Object cause;

  @override
  String toString() => '_FetchFailedFatally($table): $cause';
}

/// [SyncTable] with every request under [timeout].
class _TimedSyncTable implements SyncTable {
  _TimedSyncTable(this._inner, this._timeout);

  final SyncTable _inner;
  final Duration _timeout;

  @override
  Future<List<Map<String, dynamic>>> page({
    required PullKey? after,
    required int horizon,
  }) => _inner.page(after: after, horizon: horizon).timeout(_timeout);

  @override
  Future<Map<String, dynamic>?> fetch(String id) =>
      _inner.fetch(id).timeout(_timeout);

  @override
  Future<List<Map<String, dynamic>>> fetchMany(List<String> ids) =>
      _inner.fetchMany(ids).timeout(_timeout);

  @override
  Future<Map<String, dynamic>?> patch(
    String id,
    Map<String, Object?> changes, {
    int? ifVersion,
    String? ifStatus,
    bool ifLive = false,
  }) => _inner
      .patch(
        id,
        changes,
        ifVersion: ifVersion,
        ifStatus: ifStatus,
        ifLive: ifLive,
      )
      .timeout(_timeout);

  @override
  Future<void> insertIfAbsent(List<Map<String, Object?>> rows) =>
      _inner.insertIfAbsent(rows).timeout(_timeout);
}
```

- [ ] **Step 9: Wiring and Settings**

Apply:

```diff
--- a/lib/presentation/providers/providers.dart
+++ b/lib/presentation/providers/providers.dart
@@ -19,6 +19,7 @@
 import 'package:medora/data/datasources/medication_remote_datasource.dart';
 import 'package:medora/data/datasources/prescription_local_datasource.dart';
 import 'package:medora/data/datasources/prescription_remote_datasource.dart';
+import 'package:medora/data/datasources/sync_state_remote_datasource.dart';
 import 'package:medora/data/datasources/treatment_local_datasource.dart';
 import 'package:medora/data/datasources/treatment_remote_datasource.dart';
 import 'package:medora/data/local/app_database.dart';
@@ -132,6 +133,11 @@
   return client == null ? null : FamilyRemoteDatasource(client);
 });
 
+final syncStateDatasourceProvider = Provider<SyncStateRemoteDatasource?>((ref) {
+  final client = ref.watch(supabaseClientProvider);
+  return client == null ? null : SyncStateRemoteDatasource(client);
+});
+
 // ============================================================
 // Repository Providers (offline-first; remote may be null)
 // ============================================================
@@ -315,6 +321,7 @@
     doseLogRemote: ref.watch(doseLogDatasourceProvider),
     familyLocal: ref.watch(familyLocalDatasourceProvider),
     familyRemote: ref.watch(familyDatasourceProvider),
+    syncState: ref.watch(syncStateDatasourceProvider),
     cursors: ref.watch(syncCursorStoreProvider),
     failures: ref.watch(syncFailureStoreProvider),
     // Belt and braces: the auth screen records the data owner right after a
--- a/lib/presentation/screens/settings/widgets/settings_cloud_section.dart
+++ b/lib/presentation/screens/settings/widgets/settings_cloud_section.dart
@@ -150,6 +150,18 @@
                 ? () => showSyncFailures(ref, context, l10n, lastReport!)
                 : null,
           ),
+          // A project without the sync migration syncs nothing until the
+          // file is applied; say which file, where the owner looks.
+          if (lastReport?.missingMigration case final file?)
+            ListTile(
+              key: const Key('syncNeedsMigration'),
+              dense: true,
+              leading: Icon(Icons.error_outline, color: context.colors.error),
+              title: Text(
+                l10n.syncNeedsMigration(file),
+                style: TextStyle(color: context.colors.error),
+              ),
+            ),
           ExpansionTile(
             title: Text(l10n.advanced),
             childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
```

- [ ] **Step 10: Run everything, both zones**

Run: `fvm flutter analyze --fatal-infos`
Expected: `No issues found!`

Run: `fvm flutter test test/services/sync_service_test.dart test/services/treatment_sync_test.dart test/services/multi_device_dose_sync_test.dart test/services/multi_device_schedule_sync_test.dart test/services/sync_cursor_store_test.dart test/presentation/screens/settings_sync_failures_test.dart test/data/datasources/dose_log_sweep_test.dart`
Expected: +98, +10, +16, +16, +7, +7 and +2, all passed.

Run: `fvm flutter test` and `TZ=Europe/Rome fvm flutter test`
Expected: `All tests passed!` in both.

- [ ] **Step 11: Mutation checks (scratch worktree)**

1. In `SyncService._syncAll`, put `await _pushPendingChanges(report);` before `final state = await _remote(syncState!.read());` → `a project without the sync migration stops the cycle before any table request` fails, along with the request-count tests.
2. In `DoseLogLocalDatasource.dropPendingByPrescription`, change `if (row['sync_version'] == null && row['sync_write_id'] == null) {` to `if (true) {` → `a schedule B holds at other times, with as many doses a day, is regenerated on resume` fails: the server keeps the old slots.
3. In `markOverduePendingAsMissed`, change `if (pushable && row['sync_status'] == SyncStatus.synced)` to `if (false)` → these fail:
   - `pulling the dose again does not undo "missed"`;
   - `an undo still waiting to be pushed is not marked missed`;
   - the first `dose_log_sweep_test`.
4. In `mergeRows` (Task 5), change `takeLocal` to `!remoteTouched || localEditedAt != null` (the pushing device always wins, as today) → PR5 fails, and so do four more tests in `multi_device_dose_sync_test`.

Remove the worktree.

- [ ] **Step 12: Gates and commit**

Run the gates.

Commit `feat(sync): run the sync cycle on the v2 server contract`. The body lists:
- field-level merge (I-1, S1a/S1b, PR5);
- conditional changed-column writes with write ids (S-3);
- the transaction-horizon pull, so generated and late-committed rows arrive (S-5, I-C);
- automatic missed and time corrections pushed as automatic changes (S-1, S-7);
- guarded dose deletes (S-6);
- the migration check and its Settings line;
- repair version 2;
- the local-only hard-delete rule and the local-only sweep fix;
- the removed v1 mechanics.

---

## Task 7: Stock goes out as changes (the ledger)

**What this task delivers:** design §4.8 and §7.5.
- Every stock change in cloud mode waits in `stock_outbox` as a delta or a counted quantity.
- `apply_stock_change` applies each change once.
- `quantity` is server-owned in the merge.
- Two devices each taking a tablet end at the same count, and a lost answer never counts twice.

**Files:**
- Create: `lib/data/sync/stock_sync.dart`, `test/data/sync/stock_sync_test.dart`
- Modify: `lib/data/sync/row_merge.dart` (`quantity` server-owned)
- Modify: `lib/data/sync/row_settle.dart` (a create whose quantity changed in flight queues the difference)
- Modify: `lib/services/sync_service.dart` (`stockOutbox`, `_pushStock`, `_queueForcedStock`, discard of a stuck change)
- Modify: `lib/data/datasources/medication_local_datasource.dart` (`adjustQuantity(…, {String? opId})`, `upsert(…, {StockOp? stockOp})`)
- Modify: `lib/data/repositories/medication_repository_impl.dart` (`newOpId`; a stock change and a counted form quantity go to the outbox in cloud mode)
- Modify: `lib/services/backup_service.dart` (`newOpId`; a restore for upload queues each quantity as a count)
- Modify: `lib/presentation/providers/providers.dart` (`stockOutboxDatasourceProvider`)
- Test: `test/data/sync/row_settle_test.dart`, `test/services/sync_service_test.dart`, `test/services/repository_sync_test.dart`, `test/services/backup_service_test.dart`, `test/data/repositories/sync_request_test.dart`, `test/data/repositories/medication_repository_local_only_test.dart`, `test/presentation/providers/dose_providers_test.dart`

**Interfaces:**
- Consumes: `StockRemote`, `StockChangeResult` (Task 3); `StockOutboxLocalDatasource`, `applyStockOps` (Tasks 3–4); `TableSync`, `LocalSyncMeta`, `syncMetaValues` (Task 5).
- Produces:
  - `Future<StockChangeStatus> sendStockOp(StockRemote remote, StockOp op)`
  - `SyncService({…, StockOutboxLocalDatasource? stockOutbox, …})`; `final StockOutboxLocalDatasource stockOutbox`; `discardFailedRow('stock_outbox', opId)` drops the change.
  - `MedicationLocalDatasource.adjustQuantity(String id, int delta, {String? opId})` and `upsert(MedicationModel model, {required String syncStatus, StockOp? stockOp})`
  - `MedicationRepositoryImpl({required MedicationLocalDatasource localDatasource, RequestSync? requestSync, String Function()? newOpId})`
  - `BackupService({…, String Function()? newOpId})`
  - `final stockOutboxDatasourceProvider = Provider<StockOutboxLocalDatasource>`

- [ ] **Step 1: Tests first**

Create `test/data/sync/stock_sync_test.dart`. Each scenario starts from a medication with 10 in stock that a 0.3.0 device made and this device pulled. The four scenarios, with their exact expected values:
- **Two devices each take one tablet.** Another device's −1 lands first, then this device's. Expected: 8 on the server and here, and the outbox is empty.
- **A lost answer.** The first send throws. The retry answers `duplicate`. Expected: 9 on the server, and the outbox is empty.
- **A pull while a change waits.** The server drops to 7 through another device's −3. Expected: 6 here, because the waiting −1 is kept on top.
- **This device's own stock change moves the base.** Expected: `sync_version` 2, and the next name edit is a single PATCH with no conflict, with 9 on the server.

```dart
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:medora/data/datasources/stock_outbox_local_datasource.dart';
import 'package:medora/data/datasources/stock_remote.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/sync/stock_sync.dart';
import 'package:medora/data/sync/table_sync.dart';

import '../../helpers/fake_server.dart';
import '../../helpers/test_database.dart';

void main() {
  late FakeServerCore core;
  late FakeStockRemote stock;
  late TableSync meds;

  setUp(() async {
    await setUpTestDatabase();
    core = FakeServerCore(() => DateTime.utc(2026, 3, 5, 12));
    stock = FakeStockRemote(core);
    meds = TableSync(
      table: 'medications',
      remote: FakeSyncTable(core, 'medications'),
      newWriteId: () => 'w',
      now: () => DateTime.utc(2026, 3, 5, 12),
    );
    core.legacyUpsert('medications', {
      'id': 'm1',
      'user_id': 'u',
      'name': 'Ibu',
      'quantity': 10,
    });
    for (final row in core.page('medications', horizon: core.horizon)) {
      await meds.applyPulled(row);
    }
  });
  tearDown(tearDownTestDatabase);

  Future<int> localQuantity() async =>
      (await (await AppDatabase.instance.database).query(
            'medications',
            where: "id = 'm1'",
          )).single['quantity']!
          as int;

  Future<void> take(String opId) async {
    final db = await AppDatabase.instance.database;
    await db.transaction((txn) async {
      await txn.rawUpdate(
        "UPDATE medications SET quantity = quantity - 1 WHERE id = 'm1'",
      );
      await StockOutboxLocalDatasource.enqueue(
        txn,
        StockOp(
          opId: opId,
          medicationId: 'm1',
          delta: -1,
          createdAt: DateTime.utc(2026, 3, 5, 11),
        ),
      );
    });
  }

  test('two devices each take one: 10 -> 8 on both', () async {
    await take('b1');
    expect(await localQuantity(), 9);
    // The other device's change lands first.
    core.applyStockChange(opId: 'a1', medicationId: 'm1', delta: -1);
    final outbox = StockOutboxLocalDatasource();
    for (final op in await outbox.pending()) {
      expect(await sendStockOp(stock, op), StockChangeStatus.applied);
    }
    expect(core.rowsOf('medications')['m1']!['quantity'], 8);
    expect(await localQuantity(), 8);
    expect(await outbox.pending(), isEmpty);
  });

  test('a lost answer is not counted twice', () async {
    await take('b1');
    stock.loseNextAnswers = 1;
    final outbox = StockOutboxLocalDatasource();
    final op = (await outbox.pending()).single;
    await expectLater(sendStockOp(stock, op), throwsA(isA<TimeoutException>()));
    expect(await outbox.pending(), hasLength(1));
    expect(await sendStockOp(stock, op), StockChangeStatus.duplicate);
    expect(core.rowsOf('medications')['m1']!['quantity'], 9);
    expect(await outbox.pending(), isEmpty);
  });

  test('a pull while a change waits keeps it on top', () async {
    await take('b1');
    core.applyStockChange(opId: 'a1', medicationId: 'm1', delta: -3);
    for (final row in core.page('medications', horizon: core.horizon)) {
      await meds.applyPulled(row);
    }
    expect(await localQuantity(), 6);
  });

  test(
    'own stock change moves the base: the next edit is no conflict',
    () async {
      await take('b1');
      await sendStockOp(
        stock,
        (await StockOutboxLocalDatasource().pending()).single,
      );
      final db = await AppDatabase.instance.database;
      final row = (await db.query('medications', where: "id = 'm1'")).single;
      expect(row['sync_version'], 2);
      await db.update('medications', {
        'name': 'Ibuprofen',
        'sync_status': 'pending_update',
        'edited_at': '2026-03-05T11:59:00.000Z',
      }, where: "id = 'm1'");
      final before = core.requests.length;
      await meds.pushRow(
        (await db.query('medications', where: "id = 'm1'")).single,
        userId: 'u',
      );
      expect(core.requests.sublist(before), ['medications:patch']);
      expect(core.rowsOf('medications')['m1']!['quantity'], 9);
    },
  );
}
```

Apply this patch to the existing tests. What changes, and why:
- **`row_settle_test`:** "a create whose quantity changed meanwhile queues the difference". The row was pushed with 5 and is at 3 now. Expected: one outbox op, `-2`, and the row stays `pending_update`.
- **`sync_service_test`:** force push counts 2 (the row and its quantity as a count). A new group, `stock changes`, covers five cases:
  - **Waits for its create.** A change for a medication the server lacks is held back (`skippedBackoff` 1, empty ledger). An hour later it goes out after the create (ledger `['count']`, quantity 7).
  - **A lost answer holds the later changes back.** The first cycle fails `('stock_outbox', 'op0')` with ledger `['op0']` and quantity 9. An hour later the ledger is `['op0', 'op1']`, the quantity is 8 on both sides, and the outbox is empty.
  - **The medication is gone from the server.** The change fails, and `discardFailedRow` drops it.
  - **A rename never sends the quantity.** −1 here, a rename, and −3 from another phone. Expected: `['Ibuprofen 400', 6]` on the server, and 6 here.
  - **A counted quantity (20) and another phone's dose** apply in arrival order. Expected: 19 on both sides, and the ledger `[('op0', 20), ('other', 19)]` (open question Q3, option a).
- **`backup_service_test`:** a restore for upload queues each medication's quantity as one count, `(id, null, quantity)`.
- **`repository_sync_test`:** the offline doses wait as one outbox change (−2). Expected: 7 on both sides, `synced`, and the outbox empty.
- **`sync_request_test`:** a stock change leaves a synced row `synced` when it asks for its sync (the change waits in the outbox).
- **`medication_repository_local_only_test`, `dose_providers_test`:** without sync, a stock change of a synced row changes the quantity only, and nothing is queued.

```diff
--- a/test/data/sync/row_settle_test.dart
+++ b/test/data/sync/row_settle_test.dart
@@ -1,4 +1,5 @@
 import 'package:flutter_test/flutter_test.dart';
+import 'package:medora/data/datasources/stock_outbox_local_datasource.dart';
 import 'package:medora/data/local/app_database.dart';
 import 'package:medora/data/sync/row_settle.dart';
 import 'package:medora/data/sync/sync_meta.dart';
@@ -90,6 +91,30 @@
     expect(r['sync_write_id'], isNull);
   });
 
+  test(
+    'a create whose quantity changed meanwhile queues the difference',
+    () async {
+      final db = await AppDatabase.instance.database;
+      final pushed = await seed(db, status: 'pending_create');
+      await db.update('medications', {
+        'quantity': 3,
+        'updated_at': '2026-03-05T10:00:00.500',
+      });
+
+      await settlePushedRow(
+        db,
+        'medications',
+        pushed: pushed,
+        server: server(),
+        newOpId: () => 'op-diff',
+      );
+
+      final ops = await StockOutboxLocalDatasource().pending();
+      expect(ops.map((o) => (o.opId, o.delta)), [('op-diff', -2)]);
+      expect((await row(db))['sync_status'], 'pending_update');
+    },
+  );
+
   test('a delete made meanwhile stays a pending delete', () async {
     final db = await AppDatabase.instance.database;
     final pushed = await seed(db);
--- a/test/services/sync_service_test.dart
+++ b/test/services/sync_service_test.dart
@@ -6,6 +6,7 @@
 import 'package:medora/data/datasources/family_local_datasource.dart';
 import 'package:medora/data/datasources/medication_local_datasource.dart';
 import 'package:medora/data/datasources/prescription_local_datasource.dart';
+import 'package:medora/data/datasources/stock_outbox_local_datasource.dart';
 import 'package:medora/data/datasources/sync_page.dart';
 import 'package:medora/data/datasources/treatment_local_datasource.dart';
 import 'package:medora/data/local/app_database.dart';
@@ -16,6 +17,7 @@
 import 'package:medora/data/models/prescription_model.dart';
 import 'package:medora/data/models/treatment_model.dart';
 import 'package:medora/data/repositories/dose_log_repository_impl.dart';
+import 'package:medora/data/repositories/medication_repository_impl.dart';
 import 'package:medora/domain/entities/dose_log.dart';
 import 'package:medora/services/sync_cursor_store.dart';
 import 'package:medora/services/sync_failure_store.dart';
@@ -785,7 +787,8 @@
 
       final report = (await h.service.forcePush())!;
 
-      expect(report.pushed, 1);
+      // The row, and its quantity sent as a count.
+      expect(report.pushed, 2);
       expect(h.meds.table.rows['m13']?['name'], 'Local');
     });
 
@@ -3152,4 +3155,132 @@
       expect(h.meds.table.get('m-edit')!['name'], 'Server');
     });
   });
+
+  group('stock changes', () {
+    /// A medication the server and this device agree on: 10 in stock.
+    Future<Harness> inSync() async {
+      final h = Harness();
+      h.meds.table.seed(
+        const MedicationModel(id: 'm1', name: 'Ibu', quantity: 10).toJson(),
+      );
+      await h.service.syncAll();
+      return h;
+    }
+
+    MedicationRepositoryImpl repo() {
+      var n = 0;
+      return MedicationRepositoryImpl(
+        localDatasource: MedicationLocalDatasource(),
+        requestSync: () async {},
+        newOpId: () => 'op${n++}',
+      );
+    }
+
+    test('a change for a medication the server does not have yet waits for '
+        'its create, then goes out', () async {
+      final h = Harness();
+      // Restored from a backup for upload: no merge base, and the counted
+      // quantity waits as a stock change.
+      await MedicationLocalDatasource().upsert(
+        const MedicationModel(id: 'm1', name: 'Ibu', quantity: 7),
+        syncStatus: SyncStatus.pendingUpdate,
+        stockOp: StockOp(
+          opId: 'count',
+          medicationId: 'm1',
+          setTo: 7,
+          createdAt: DateTime.utc(2026, 3, 4, 11),
+        ),
+      );
+      h.meds.table.failIds.add('m1');
+
+      final first = (await h.service.syncAll())!;
+      expect(first.skippedBackoff, 1);
+      expect(h.core.ledger, isEmpty);
+      expect(await StockOutboxLocalDatasource().pending(), hasLength(1));
+
+      h.meds.table.failIds.clear();
+      h.clock.advance(const Duration(hours: 1));
+      final second = (await h.service.syncAll())!;
+      expect(second.failures, isEmpty);
+      expect(h.core.ledger.keys, ['count']);
+      expect(h.meds.table.get('m1')!['quantity'], 7);
+      expect(await StockOutboxLocalDatasource().pending(), isEmpty);
+    });
+
+    test('a change whose answer is lost holds the later ones back, and each '
+        'counts once', () async {
+      final h = await inSync();
+      final medications = repo();
+      await medications.updateQuantity('m1', -1);
+      await medications.updateQuantity('m1', -1);
+      h.meds.stock.loseNextAnswers = 1;
+
+      final first = (await h.service.syncAll())!;
+      expect(first.failures.map((f) => (f.table, f.id)), [
+        ('stock_outbox', 'op0'),
+      ]);
+      expect(h.core.ledger.keys, ['op0']);
+      expect(h.meds.table.get('m1')!['quantity'], 9);
+
+      h.clock.advance(const Duration(hours: 1));
+      final second = (await h.service.syncAll())!;
+      expect(second.failures, isEmpty);
+      expect(h.core.ledger.keys, ['op0', 'op1']);
+      expect(h.meds.table.get('m1')!['quantity'], 8);
+      expect((await localRow('medications', 'm1'))!['quantity'], 8);
+      expect(await StockOutboxLocalDatasource().pending(), isEmpty);
+    });
+
+    test('a change for a medication gone from the server fails until the '
+        'user discards it', () async {
+      final h = await inSync();
+      await repo().updateQuantity('m1', -1);
+      h.meds.table.hardDelete('m1');
+
+      final report = (await h.service.syncAll())!;
+      final failure = report.failures.single;
+      expect((failure.table, failure.id), ('stock_outbox', 'op0'));
+
+      await h.service.discardFailedRow(failure.table, failure.id);
+      expect(await StockOutboxLocalDatasource().pending(), isEmpty);
+    });
+
+    test('renaming a medication never sends its quantity: a dose from '
+        'another device still counts', () async {
+      final h = await inSync();
+      final medications = repo();
+      await medications.updateQuantity('m1', -1);
+      final m = (await medications.getMedicationById('m1')).dataOrNull!;
+      await medications.updateMedication(m.copyWith(name: 'Ibuprofen 400'));
+      // Meanwhile another phone takes three.
+      h.core.applyStockChange(opId: 'other', medicationId: 'm1', delta: -3);
+
+      await h.service.syncAll();
+
+      final server = h.meds.table.get('m1')!;
+      expect([server['name'], server['quantity']], ['Ibuprofen 400', 6]);
+      expect((await localRow('medications', 'm1'))!['quantity'], 6);
+    });
+
+    test('a counted quantity and a dose from another device apply in the '
+        'order the server receives them', () async {
+      final h = await inSync();
+      final medications = repo();
+      final m = (await medications.getMedicationById('m1')).dataOrNull!;
+      await medications.updateMedication(m.copyWith(quantity: 20));
+      await h.service.syncAll();
+      expect(h.meds.table.get('m1')!['quantity'], 20);
+
+      // The other phone's dose reaches the server after the count.
+      h.core.applyStockChange(opId: 'other', medicationId: 'm1', delta: -1);
+      await h.service.syncAll();
+
+      expect(h.meds.table.get('m1')!['quantity'], 19);
+      expect((await localRow('medications', 'm1'))!['quantity'], 19);
+      expect(
+        [for (final e in h.core.ledger.entries) (e.key, e.value.quantityAfter)],
+        [('op0', 20), ('other', 19)],
+      );
+    });
+  });
 }
--- a/test/services/repository_sync_test.dart
+++ b/test/services/repository_sync_test.dart
@@ -13,6 +13,7 @@
 import 'package:medora/data/datasources/family_local_datasource.dart';
 import 'package:medora/data/datasources/medication_local_datasource.dart';
 import 'package:medora/data/datasources/prescription_local_datasource.dart';
+import 'package:medora/data/datasources/stock_outbox_local_datasource.dart';
 import 'package:medora/data/datasources/treatment_local_datasource.dart';
 import 'package:medora/data/local/app_database.dart';
 import 'package:medora/data/models/dose_log_model.dart';
@@ -209,31 +210,47 @@
       expect(local['sync_status'], SyncStatus.synced);
     });
 
-    test(
-      'medications: a dose taken after an offline one is counted once',
-      () async {
-        final r = _Rig();
-        final db = await AppDatabase.instance.database;
-        final id = (await seedPrescription(db)).medicationId; // quantity 10
-        r.meds.table.seed(
-          MedicationModel.fromLocalMap(
-            await _localRow('medications', id),
-          ).toJson(),
-          updatedAt: longAgo,
-        );
-        await _pendingOffline('medications', id, {'quantity': 8}, offline);
-
-        await r.writeWhileCyclePushes(
-          r.meds.table,
-          () => r.medicationRepo.updateQuantity(id, -1),
-        );
-
-        expect(r.meds.table.rows[id]!['quantity'], 7);
-        final local = await _localRow('medications', id);
-        expect(local['quantity'], 7);
-        expect(local['sync_status'], SyncStatus.synced);
-      },
-    );
+    test('medications: a dose taken while the cycle sends an offline one is '
+        'counted once', () async {
+      final r = _Rig();
+      final db = await AppDatabase.instance.database;
+      final id = (await seedPrescription(db)).medicationId; // quantity 10
+      r.meds.table.seed(
+        MedicationModel.fromLocalMap(
+          await _localRow('medications', id),
+        ).toJson(),
+        updatedAt: longAgo,
+      );
+      // Two tablets taken offline: waiting as one stock change.
+      await db.transaction((txn) async {
+        await txn.update(
+          'medications',
+          {'quantity': 8},
+          where: 'id = ?',
+          whereArgs: [id],
+        );
+        await StockOutboxLocalDatasource.enqueue(
+          txn,
+          StockOp(
+            opId: 'offline-op',
+            medicationId: id,
+            delta: -2,
+            createdAt: offline,
+          ),
+        );
+      });
+
+      await r.writeWhileCyclePushes(
+        r.meds.table,
+        () => r.medicationRepo.updateQuantity(id, -1),
+      );
+
+      expect(r.meds.table.rows[id]!['quantity'], 7);
+      final local = await _localRow('medications', id);
+      expect(local['quantity'], 7);
+      expect(local['sync_status'], SyncStatus.synced);
+      expect(await StockOutboxLocalDatasource().pending(), isEmpty);
+    });
 
     test('dose logs: taken after an offline skip', () async {
       final r = _Rig();
--- a/test/services/backup_service_test.dart
+++ b/test/services/backup_service_test.dart
@@ -2,6 +2,7 @@
 import 'dart:io';
 
 import 'package:flutter_test/flutter_test.dart';
+import 'package:medora/data/datasources/stock_outbox_local_datasource.dart';
 import 'package:medora/data/local/app_database.dart';
 import 'package:medora/data/local/migrations.dart';
 import 'package:medora/services/backup_service.dart';
@@ -462,6 +463,25 @@
     );
   });
 
+  test('a restore for upload queues each medication\'s quantity as a '
+      'count', () async {
+    final db = await AppDatabase.instance.database;
+    await seedEverything(db);
+    final med = (await db.query('medications')).single;
+    final file = await makeService().exportToFile(outDir);
+
+    await makeService().restore(
+      file,
+      mode: RestoreMode.replace,
+      markPending: true,
+    );
+
+    final ops = await StockOutboxLocalDatasource().pending();
+    expect(ops.map((o) => (o.medicationId, o.delta, o.setTo)), [
+      (med['id'], null, med['quantity']),
+    ]);
+  });
+
   test('photos round-trip through the backup file', () async {
     final db = await AppDatabase.instance.database;
     await seedEverything(db);
--- a/test/data/repositories/sync_request_test.dart
+++ b/test/data/repositories/sync_request_test.dart
@@ -88,10 +88,11 @@
       await repo.deleteMedication('m1');
       await pumpEventQueue();
 
+      // A stock change leaves the row as it is and waits in the outbox.
       expect(requests.statuses, [
         pendingCreate,
         pendingUpdate,
-        pendingUpdate,
+        SyncStatus.synced,
         pendingUpdate,
         pendingUpdate,
         pendingDelete,
--- a/test/data/repositories/medication_repository_local_only_test.dart
+++ b/test/data/repositories/medication_repository_local_only_test.dart
@@ -146,11 +146,13 @@
       await repo.unarchiveMedication('m1');
       expect(await status(), SyncStatus.pendingCreate);
 
-      // A synced row becomes an update.
+      // Without sync, a stock change of a synced row changes the quantity
+      // only: nothing is queued, and a later sign-in uploads the row.
       await db.update('medications', {'sync_status': SyncStatus.synced});
       await repo.updateQuantity('m1', -1);
-      expect(await status(), SyncStatus.pendingUpdate);
+      expect(await status(), SyncStatus.synced);
       expect((await repo.getMedicationById('m1')).dataOrNull!.quantity, 8);
+      expect(await db.query('stock_outbox'), isEmpty);
     });
   });
 }
--- a/test/presentation/providers/dose_providers_test.dart
+++ b/test/presentation/providers/dose_providers_test.dart
@@ -574,8 +574,10 @@
         where: 'id = ?',
         whereArgs: [s.medicationId],
       );
-      // The absolute quantity, marked for the sync cycle to push.
-      expect(med.single['sync_status'], SyncStatus.pendingUpdate);
+      // A stock change is not a row edit: with no sync configured the row
+      // stays as it was and nothing is queued.
+      expect(med.single['sync_status'], SyncStatus.synced);
+      expect(await db.query('stock_outbox'), isEmpty);
     });
 
     test(
```

Run: `fvm flutter test test/data/sync test/services/sync_service_test.dart test/services/repository_sync_test.dart test/services/backup_service_test.dart test/data/repositories test/presentation/providers/dose_providers_test.dart`
Expected: compile errors: `stock_sync.dart` is missing, and `stockOp`, `newOpId` and `opId` are undefined.

- [ ] **Step 2: Send one change**

Create `lib/data/sync/stock_sync.dart`:

```dart
/// Medora - Sending one stock change and settling it locally (sync v2).
library;

import 'package:medora/data/datasources/stock_outbox_local_datasource.dart';
import 'package:medora/data/datasources/stock_remote.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/sync/sync_meta.dart';

/// Sends [op] and settles the answer:
/// - applied: the op leaves the outbox and the local quantity becomes the
///   server's plus the changes still waiting. When the server's version is
///   exactly one past the base, the base moves with it, so this device's
///   own stock change does not turn its next edit into a conflict;
/// - duplicate or gone: the op leaves the outbox (the pull brings the
///   quantity, or the deletion);
/// - missing: the op stays for a later cycle.
Future<StockChangeStatus> sendStockOp(StockRemote remote, StockOp op) async {
  final result = await remote.apply(op);
  final db = await AppDatabase.instance.database;
  await db.transaction((txn) async {
    if (result.status == StockChangeStatus.missing) return;
    await txn.delete(
      StockOutboxLocalDatasource.table,
      where: 'op_id = ?',
      whereArgs: [op.opId],
    );
    final quantity = result.quantity;
    if (result.status != StockChangeStatus.applied || quantity == null) {
      return;
    }
    final rows = await txn.query(
      'medications',
      where: 'id = ?',
      whereArgs: [op.medicationId],
    );
    if (rows.isEmpty) return;
    final row = rows.first;
    final values = <String, Object?>{
      'quantity': applyStockOps(
        quantity,
        await StockOutboxLocalDatasource.pendingIn(
          txn,
          medicationId: op.medicationId,
        ),
      ),
    };
    final meta = LocalSyncMeta.fromRow(row);
    final version = meta.version;
    final base = meta.base;
    if (version != null && base != null && result.rowVersion == version + 1) {
      values.addAll(
        syncMetaValues(
          version: result.rowVersion,
          base: {...base, 'quantity': quantity},
          writeId: meta.writeId,
        ),
      );
    }
    await txn.update(
      'medications',
      values,
      where: 'id = ?',
      whereArgs: [op.medicationId],
    );
  });
  return result.status;
}
```

- [ ] **Step 3: The rest**

Apply this patch. It covers:
- the server-owned `quantity`;
- the create delta in the settle;
- the queueing in the local datasource and the repository;
- the restore count;
- the provider;
- the cycle's stock push, which runs after the medication rows and before the treatments, keeps the per-medication order, backs off per change and handles force push.

```diff
--- a/lib/data/sync/row_merge.dart
+++ b/lib/data/sync/row_merge.dart
@@ -125,6 +125,7 @@
   groups: [
     {'barcode', 'ean'},
   ],
+  serverOwned: {'quantity'},
 );
 
 const treatmentMerge = MergePolicy(
--- a/lib/data/sync/row_settle.dart
+++ b/lib/data/sync/row_settle.dart
@@ -15,7 +15,9 @@
 ///   server copy is stored as `synced` and becomes the base.
 /// - **Edited while the push was in flight:** the server copy becomes the
 ///   base and the row stays `pending_update`, so the next push sends only
-///   the newer difference.
+///   the newer difference. A medication created by this push whose
+///   quantity changed meanwhile queues that difference as a stock change
+///   ([newOpId] names it): the server holds the pushed quantity.
 /// - **Deleted meanwhile** (`pending_delete`) or gone: left alone; a pending
 ///   delete returns true.
 Future<bool> settlePushedRow(
@@ -53,6 +55,22 @@
       await txn.update(table, row, where: 'id = ?', whereArgs: [id]);
       return false;
     }
+    if (table == 'medications' &&
+        pushed['sync_status'] == SyncStatus.pendingCreate) {
+      final sent = (pushed['quantity'] as int?) ?? 0;
+      final now = (current['quantity'] as int?) ?? 0;
+      if (now != sent) {
+        await StockOutboxLocalDatasource.enqueue(
+          txn,
+          StockOp(
+            opId: newOpId(),
+            medicationId: id,
+            delta: now - sent,
+            createdAt: DateTime.now(),
+          ),
+        );
+      }
+    }
     await txn.update(
       table,
       {
--- a/lib/data/datasources/medication_local_datasource.dart
+++ b/lib/data/datasources/medication_local_datasource.dart
@@ -4,6 +4,7 @@
 import 'dart:convert';
 
 import 'package:medora/core/clock.dart';
+import 'package:medora/data/datasources/stock_outbox_local_datasource.dart';
 import 'package:medora/data/local/app_database.dart';
 import 'package:medora/data/models/medication_model.dart';
 import 'package:sqflite/sqflite.dart';
@@ -51,12 +52,52 @@
 
   /// Adds [delta] to the stock, never going below zero. Returns the stored
   /// row, or null (and changes nothing) when the medication is missing or
-  /// deleted. Only the quantity and the bookkeeping columns are written, so
-  /// no other column can be lost on the way.
-  Future<MedicationModel?> adjustQuantity(String id, int delta) async {
-    final changed = await _editRow(id, (row) {
-      final current = row['quantity'] as int? ?? 0;
-      return {'quantity': (current + delta).clamp(0, 999999)};
+  /// deleted. Only the quantity is written.
+  ///
+  /// With [opId] (cloud mode) the change also waits in the stock outbox,
+  /// in the same transaction, as a change the server applies once. A
+  /// medication the server does not have yet (`pending_create`) queues
+  /// nothing: its insert carries the quantity, so the row is stamped as
+  /// changed instead, and settling the insert queues the difference.
+  Future<MedicationModel?> adjustQuantity(
+    String id,
+    int delta, {
+    String? opId,
+  }) async {
+    final db = await _db;
+    final changed = await db.transaction((txn) async {
+      final rows = await txn.query(
+        'medications',
+        columns: ['quantity', 'sync_status', 'updated_at'],
+        where: 'id = ?',
+        whereArgs: [id],
+      );
+      if (rows.isEmpty) return false;
+      final row = rows.first;
+      final status = row['sync_status'] as String?;
+      if (status == SyncStatus.pendingDelete) return false;
+      final values = <String, Object?>{
+        'quantity': ((row['quantity'] as int? ?? 0) + delta).clamp(0, maxStock),
+      };
+      if (status == SyncStatus.pendingCreate || opId == null) {
+        final raw = row['updated_at'] as String?;
+        final previous = raw == null ? null : DateTime.tryParse(raw);
+        final stamp = nextUpdatedAt(previous, DateTime.now()).toIso8601String();
+        values['updated_at'] = stamp;
+        values['edited_at'] = stamp;
+      } else {
+        await StockOutboxLocalDatasource.enqueue(
+          txn,
+          StockOp(
+            opId: opId,
+            medicationId: id,
+            delta: delta,
+            createdAt: DateTime.now(),
+          ),
+        );
+      }
+      await txn.update('medications', values, where: 'id = ?', whereArgs: [id]);
+      return true;
     });
     return changed ? getMedicationById(id) : null;
   }
@@ -203,27 +244,36 @@
     return _fromRow(rows.first);
   }
 
+  /// Stores [model]. [stockOp] (a quantity typed into the form, cloud mode)
+  /// waits in the stock outbox, written in the same transaction.
   Future<void> upsert(
     MedicationModel model, {
     required String syncStatus,
+    StockOp? stockOp,
   }) async {
     final db = await _db;
     final row = rowOf(model, syncStatus);
-    // Use UPDATE-first to avoid DELETE+INSERT from ConflictAlgorithm.replace,
-    // which would CASCADE-DELETE prescriptions and dose_logs.
-    final updated = await db.update(
-      'medications',
-      row,
-      where: 'id = ?',
-      whereArgs: [model.id],
-    );
-    if (updated == 0) {
-      await db.insert(
+    await db.transaction((txn) async {
+      // Use UPDATE-first to avoid DELETE+INSERT from
+      // ConflictAlgorithm.replace, which would CASCADE-DELETE prescriptions
+      // and dose_logs.
+      final updated = await txn.update(
         'medications',
         row,
-        conflictAlgorithm: ConflictAlgorithm.ignore,
+        where: 'id = ?',
+        whereArgs: [model.id],
       );
-    }
+      if (updated == 0) {
+        await txn.insert(
+          'medications',
+          row,
+          conflictAlgorithm: ConflictAlgorithm.ignore,
+        );
+      }
+      if (stockOp != null) {
+        await StockOutboxLocalDatasource.enqueue(txn, stockOp);
+      }
+    });
   }
 
   /// Marks the row for deletion: pending push plus a local tombstone stamp
--- a/lib/data/repositories/medication_repository_impl.dart
+++ b/lib/data/repositories/medication_repository_impl.dart
@@ -4,23 +4,34 @@
 import 'package:medora/core/clock.dart';
 import 'package:medora/core/result.dart';
 import 'package:medora/data/datasources/medication_local_datasource.dart';
+import 'package:medora/data/datasources/stock_outbox_local_datasource.dart';
 import 'package:medora/data/local/app_database.dart';
 import 'package:medora/data/models/medication_model.dart';
 import 'package:medora/data/sync/request_sync.dart';
 import 'package:medora/domain/entities/medication.dart';
 import 'package:medora/domain/repositories/medication_repository.dart';
+import 'package:uuid/uuid.dart';
 
 /// Writes go to the local database only: each one stores the row as pending
 /// and asks for a sync cycle, which is the one place that pushes (see
-/// `TreatmentRepositoryImpl`). A stock change is pushed as the new quantity,
-/// under last-write-wins, like every other column.
+/// `TreatmentRepositoryImpl`). A stock change goes out as a change, never as
+/// the new total: in cloud mode it waits in the stock outbox, with an id the
+/// server applies once.
 class MedicationRepositoryImpl implements MedicationRepository {
   /// [requestSync] starts (or queues) a sync cycle; it is not awaited and a
-  /// failure only logs. Null in local-only mode, where nothing is pushed.
-  MedicationRepositoryImpl({required this.localDatasource, this._requestSync});
+  /// failure only logs. Null in local-only mode, where nothing is pushed and
+  /// no stock change is queued. [newOpId] names a stock change.
+  MedicationRepositoryImpl({
+    required this.localDatasource,
+    this._requestSync,
+    String Function()? newOpId,
+  }) : _newOpId = newOpId ?? const Uuid().v4;
 
   final MedicationLocalDatasource localDatasource;
   final RequestSync? _requestSync;
+  final String Function() _newOpId;
+
+  bool get _cloud => _requestSync != null;
 
   @override
   Future<Result<List<Medication>>> getMedications() async {
@@ -114,11 +125,27 @@
           updatedAt: nextUpdatedAt(previous?.updatedAt, DateTime.now()),
         ),
       );
+      // A quantity typed into the form is a count: it goes out as one, so a
+      // dose logged elsewhere meanwhile still applies on top of it.
+      final counted =
+          _cloud &&
+          previous != null &&
+          status != null &&
+          status != SyncStatus.pendingCreate &&
+          previous.quantity != medication.quantity;
       await localDatasource.upsert(
         model,
         syncStatus: status == null
             ? SyncStatus.pendingCreate
             : MedicationLocalDatasource.editedSyncStatus(status),
+        stockOp: counted
+            ? StockOp(
+                opId: _newOpId(),
+                medicationId: medication.id,
+                setTo: medication.quantity,
+                createdAt: DateTime.now(),
+              )
+            : null,
       );
       _syncSoon();
       return Result.success(medication);
@@ -143,7 +170,11 @@
     try {
       // Only the quantity is written: a stock change neither drops another
       // column nor brings a deleted medication back.
-      final updated = await localDatasource.adjustQuantity(id, delta);
+      final updated = await localDatasource.adjustQuantity(
+        id,
+        delta,
+        opId: _cloud ? _newOpId() : null,
+      );
       if (updated == null) {
         return const Result.failure('Medication not found');
       }
--- a/lib/services/backup_service.dart
+++ b/lib/services/backup_service.dart
@@ -15,11 +15,13 @@
 import 'dart:convert';
 import 'dart:io';
 
+import 'package:medora/data/datasources/stock_outbox_local_datasource.dart';
 import 'package:medora/data/local/app_database.dart';
 import 'package:medora/data/local/migrations.dart';
 import 'package:medora/services/photo_storage.dart';
 import 'package:path/path.dart' as p;
 import 'package:sqflite/sqflite.dart';
+import 'package:uuid/uuid.dart';
 
 /// Why a backup file could not be read or applied.
 enum BackupErrorKind {
@@ -86,12 +88,14 @@
     required this._photos,
     required this._now,
     required this._appVersion,
-  });
+    String Function()? newOpId,
+  }) : _newOpId = newOpId ?? const Uuid().v4;
 
   final AppDatabase _database;
   final PhotoStorage _photos;
   final DateTime Function() _now;
   final String _appVersion;
+  final String Function() _newOpId;
 
   /// Columns that describe this device's sync state, never carried by a
   /// backup: another device, or this one later, is in another state.
@@ -245,7 +249,8 @@
   /// cloud-mode device uploads the restored data on the next sync cycle -
   /// except `family_members` (see [_neverPending]), which stays `synced`.
   /// Nothing about the server copy is known any more, so the next push
-  /// merges by edit time.
+  /// merges by edit time, and a restored medication's quantity goes out as
+  /// a counted quantity (a stock change), since a push never sends it.
   Future<BackupManifest> restore(
     File file, {
     required RestoreMode mode,
@@ -268,7 +273,21 @@
               ? SyncStatus.synced
               : status;
           for (final row in rows) {
-            await _applyRow(txn, table, row, mode, tableStatus);
+            final written = await _applyRow(txn, table, row, mode, tableStatus);
+            if (written &&
+                markPending &&
+                table == 'medications' &&
+                row['deleted_at'] == null) {
+              await StockOutboxLocalDatasource.enqueue(
+                txn,
+                StockOp(
+                  opId: _newOpId(),
+                  medicationId: row['id']! as String,
+                  setTo: (row['quantity'] as int?) ?? 0,
+                  createdAt: _now(),
+                ),
+              );
+            }
           }
         }
       });
--- a/lib/presentation/providers/providers.dart
+++ b/lib/presentation/providers/providers.dart
@@ -19,6 +19,7 @@
 import 'package:medora/data/datasources/medication_remote_datasource.dart';
 import 'package:medora/data/datasources/prescription_local_datasource.dart';
 import 'package:medora/data/datasources/prescription_remote_datasource.dart';
+import 'package:medora/data/datasources/stock_outbox_local_datasource.dart';
 import 'package:medora/data/datasources/sync_state_remote_datasource.dart';
 import 'package:medora/data/datasources/treatment_local_datasource.dart';
 import 'package:medora/data/datasources/treatment_remote_datasource.dart';
@@ -138,6 +139,10 @@
   return client == null ? null : SyncStateRemoteDatasource(client);
 });
 
+final stockOutboxDatasourceProvider = Provider<StockOutboxLocalDatasource>(
+  (ref) => StockOutboxLocalDatasource(),
+);
+
 // ============================================================
 // Repository Providers (offline-first; remote may be null)
 // ============================================================
@@ -322,6 +327,7 @@
     familyLocal: ref.watch(familyLocalDatasourceProvider),
     familyRemote: ref.watch(familyDatasourceProvider),
     syncState: ref.watch(syncStateDatasourceProvider),
+    stockOutbox: ref.watch(stockOutboxDatasourceProvider),
     cursors: ref.watch(syncCursorStoreProvider),
     failures: ref.watch(syncFailureStoreProvider),
     // Belt and braces: the auth screen records the data owner right after a
--- a/lib/services/sync_service.dart
+++ b/lib/services/sync_service.dart
@@ -14,7 +14,8 @@
 ///   merged column group by column group (`row_merge.dart`) and the rest is
 ///   sent again. Each attempt carries a write id stored before it is sent, so
 ///   an answer that never arrived is recognised later. New dose logs go out
-///   in batches, inserted only where the server lacks them.
+///   in batches, inserted only where the server lacks them. Stock changes go
+///   out as changes (`stock_sync.dart`), never as totals.
 /// - **Pull.** Each table is read from its stored key up to the server's
 ///   horizon, in pages; a pending local row is merged, not overwritten.
 ///
@@ -48,6 +49,8 @@
 import 'package:medora/data/datasources/prescription_local_datasource.dart';
 import 'package:medora/data/datasources/prescription_remote_datasource.dart';
 import 'package:medora/data/datasources/schema_errors.dart';
+import 'package:medora/data/datasources/stock_outbox_local_datasource.dart';
+import 'package:medora/data/datasources/stock_remote.dart';
 import 'package:medora/data/datasources/sync_page.dart';
 import 'package:medora/data/datasources/sync_state_remote_datasource.dart';
 import 'package:medora/data/datasources/sync_table.dart';
@@ -59,6 +62,7 @@
 import 'package:medora/data/models/prescription_model.dart';
 import 'package:medora/data/sync/row_merge.dart';
 import 'package:medora/data/sync/row_settle.dart';
+import 'package:medora/data/sync/stock_sync.dart';
 import 'package:medora/data/sync/sync_meta.dart';
 import 'package:medora/data/sync/table_sync.dart';
 import 'package:medora/services/connectivity_service.dart';
@@ -87,6 +91,7 @@
     required this.familyLocal,
     required this.familyRemote,
     required this.syncState,
+    StockOutboxLocalDatasource? stockOutbox,
     String Function()? newWriteId,
     SyncCursorStore? cursors,
     SyncFailureStore? failures,
@@ -106,6 +111,7 @@
        _onlineStream =
            onlineStream ?? ConnectivityService.instance.onlineStream,
        _now = now ?? DateTime.now,
+       stockOutbox = stockOutbox ?? StockOutboxLocalDatasource(),
        _newWriteId = newWriteId ?? const Uuid().v4;
 
   final MedicationLocalDatasource medicationLocal;
@@ -121,6 +127,7 @@
 
   /// `medora_sync_state`; null in local-only mode.
   final SyncStateRemoteDatasource? syncState;
+  final StockOutboxLocalDatasource stockOutbox;
   final String Function() _newWriteId;
 
   /// Called with the signed-in user id after a clean cycle. Belt and braces
@@ -467,8 +474,8 @@
         ? [SyncStatus.pendingDelete]
         : [SyncStatus.synced, SyncStatus.pendingDelete];
 
-    // FK order: Families -> Medications -> Treatments -> Prescriptions ->
-    // DoseLogs
+    // FK order: Families -> Medications (+ stock) -> Treatments ->
+    // Prescriptions -> DoseLogs
     await _pushBatch('families', report, familyWhere, familyWhereArgs, (
       row,
     ) async {
@@ -521,6 +528,8 @@
     );
 
     await _pushTable('medications', report, userId, forceAll: forceAll);
+    if (forceAll) await _queueForcedStock();
+    await _pushStock(report);
     await _pushTable('treatments', report, userId, forceAll: forceAll);
     await _pushTable('prescriptions', report, userId, forceAll: forceAll);
     // A dose this device created is only ever inserted where the server does
@@ -608,6 +617,82 @@
     return refused;
   }
 
+  /// Sends the waiting stock changes, oldest first. A medication the server
+  /// does not have yet, or whose change failed this cycle, keeps its later
+  /// changes for the next cycle, so their order holds.
+  Future<void> _pushStock(SyncReport report) async {
+    final db = await AppDatabase.instance.database;
+    final blocked = <String>{};
+    for (final op in await stockOutbox.pending()) {
+      final medicationId = op.medicationId;
+      if (blocked.contains(medicationId)) continue;
+      final med = await db.query(
+        'medications',
+        columns: ['sync_version'],
+        where: 'id = ?',
+        whereArgs: [medicationId],
+      );
+      if (med.isEmpty || med.first['sync_version'] == null) {
+        blocked.add(medicationId);
+        report.skippedBackoff++;
+        continue;
+      }
+      final failure = await _failures.get(
+        StockOutboxLocalDatasource.table,
+        op.opId,
+      );
+      if (failure != null && failure.isBackingOffAt(_now())) {
+        blocked.add(medicationId);
+        report.skippedBackoff++;
+        continue;
+      }
+      try {
+        final status = await _remote(sendStockOp(medicationRemote!.stock, op));
+        if (status == StockChangeStatus.missing) {
+          throw StateError('medication $medicationId is not on the server');
+        }
+        report.pushed++;
+        if (failure != null) {
+          await _failures.clear(StockOutboxLocalDatasource.table, op.opId);
+        }
+      } catch (e) {
+        blocked.add(medicationId);
+        await _failures.recordFailure(
+          StockOutboxLocalDatasource.table,
+          op.opId,
+          _now(),
+        );
+        report.failures.add(
+          SyncFailure(StockOutboxLocalDatasource.table, op.opId, 'push: $e'),
+        );
+      }
+    }
+  }
+
+  /// A forced push sends every local quantity as a counted quantity.
+  Future<void> _queueForcedStock() async {
+    final db = await AppDatabase.instance.database;
+    final meds = await db.query(
+      'medications',
+      columns: ['id', 'quantity'],
+      where: 'sync_status != ?',
+      whereArgs: [SyncStatus.pendingDelete],
+    );
+    await db.transaction((txn) async {
+      for (final m in meds) {
+        await StockOutboxLocalDatasource.enqueue(
+          txn,
+          StockOp(
+            opId: _newWriteId(),
+            medicationId: m['id']! as String,
+            setTo: (m['quantity'] as int?) ?? 0,
+            createdAt: _now(),
+          ),
+        );
+      }
+    });
+  }
+
   /// How many new dose logs one request inserts. The read-back lists their
   /// ids in the URL, which keeps it well under common URL limits.
   static const doseLogInsertBatchSize = 100;
@@ -858,7 +943,8 @@
   /// The server row is fetched directly and stored with its merge base; a
   /// row the server does not have (or has tombstoned) is deleted locally.
   /// That is also what discarding a local `pending_delete` means: keep the
-  /// server's copy.
+  /// server's copy. A stuck stock change ([StockOutboxLocalDatasource.table])
+  /// is dropped.
   ///
   /// Throws when the fetch fails, leaving the row pending so the caller can
   /// surface the error and the user can try again.
@@ -871,6 +957,8 @@
         if (remote != null && remote['deleted_at'] == null) {
           await _tables[table]!.applyPulled(remote);
         }
+      case StockOutboxLocalDatasource.table:
+        await stockOutbox.remove(id);
       case 'families':
         final remote = await familyRemote!.getFamilyById(id);
         await _replaceLocal(
```

- [ ] **Step 4: Run the tests, both zones**

Run: `fvm flutter test test/data/sync/stock_sync_test.dart test/data/sync/row_settle_test.dart test/services/sync_service_test.dart`
Expected: +4, +5 and +103.

Run: `fvm flutter test` and `TZ=Europe/Rome fvm flutter test`
Expected: `All tests passed!` in both.

- [ ] **Step 5: Mutation checks (scratch worktree)**

1. Remove `serverOwned: {'quantity'},` from `medicationMerge` → `renaming a medication never sends its quantity…` fails (the rename sends 9 over the other phone's change).
2. In `_pushStock`, remove `blocked.add(medicationId);` from the `catch` → `a change whose answer is lost holds the later ones back…` fails.
3. In `sendStockOp`, change `if (result.status == StockChangeStatus.missing) return;` to `if (result.status != StockChangeStatus.applied) return;` → `a lost answer is not counted twice` and the lost-answer service test fail (the duplicate stays in the outbox).
4. In `adjustQuantity`, change `if (status == SyncStatus.pendingCreate || opId == null) {` to `if (status == SyncStatus.pendingCreate || opId == null || opId.isNotEmpty) {` (never queue) → these fail:
   - three `stock changes` tests;
   - `a dose taken while the cycle sends an offline one is counted once`;
   - `a medication added, restocked and deleted`.
5. In `restore`, change `if (written &&` to `if (false &&` → `a restore for upload queues each medication's quantity as a count` fails.

Remove the worktree.

- [ ] **Step 6: Gates and commit**

Run the gates. Commit `feat(sync): stock changes go out once each through the server ledger`. The body names:
- S-2;
- open question Q3 (arrival order);
- the known 0.3.0 limitation (an absolute quantity from an old device still replaces a change until every device is updated).

---

## Task 8: The whole suite over a fake PostgREST, and two devices end to end

**What this task delivers:**
- **A fake PostgREST.** `test/helpers/fake_postgrest.dart` serves `FakeServerCore` over HTTP the way PostgREST answers the requests Medora's real datasources send (`MockClient`, no network).
- **A switch for the whole suite.** With `--dart-define=MEDORA_FAKE_TRANSPORT=http`, every fake table, stock remote and sync-state fake in the suite goes through the app's real `PostgrestSyncTable`, `PostgrestStockRemote` and `SyncStateRemoteDatasource`, and the fake's failure knobs keep working. The whole suite then runs a second time against the server rules through the real request code, and CI does the same.
- **Two-device scenarios** that run on both transports.
- **Real-Supabase scenarios** in the manual integration job.

**Files:**
- Create: `test/helpers/fake_postgrest.dart`
- Modify: `test/helpers/fake_server.dart` (`FakeTransport`, `defaultFakeTransport`, the `wire` of `FakeSyncTable` and `FakeStockRemote`)
- Modify: `test/helpers/fake_remotes.dart` (`FakeServer(transport:)`; `FakeSyncState` over HTTP)
- Create: `test/helpers/two_devices.dart`
- Create: `test/services/multi_device_merge_test.dart`, `test/services/mixed_fleet_sync_test.dart`
- Modify: `test/integration/sync_convergence_test.dart` (S1 and stock against a local Supabase)
- Modify: `.github/workflows/ci.yml` (a third test run in the `test` job)

**Interfaces:**
- Consumes: the real remote datasources (Task 6/7), `FakeServerCore` (Task 3).
- Produces:
  - `enum FakeTransport { dart, http }`; `const FakeTransport defaultFakeTransport` (from `String.fromEnvironment('MEDORA_FAKE_TRANSPORT')`)
  - `FakeSyncTable(FakeServerCore core, String table, {FakeTransport? transport})`, `final SyncTable? wire`
  - `FakeStockRemote(FakeServerCore core, {FakeTransport? transport})`, `final StockRemote? wire`
  - `class FakePostgrest { FakePostgrest(FakeServerCore core); factory FakePostgrest.of(FakeServerCore core); bool migrated; List<String> log; SupabaseClient client(); SyncTable table(String name); StockRemote stock(); SyncStateRemoteDatasource state; }`
  - `FakeServer(DateTime Function() clock, {…, FakeTransport transport = defaultFakeTransport})`, and `FakeMedicationRemote`, `FakeTreatmentRemote`, `FakePrescriptionRemote`, `FakeDoseLogRemote`, `FakeSyncState` each take `{FakeTransport? transport}`
  - `class TwoDevices { TwoDevices({FakeTransport transport = FakeTransport.dart}); Device a, b; DateTime clock; FakeServer server; FakeServerCore core; void advance(Duration); void loseNextStockAnswer(); Future<void> dispose(); }`
  - `class Device { Future<T> run<T>(Future<T> Function(Database db) body); Future<SyncReport?> sync(); Future<Map<String, Object?>> row(String table, String id); bool online; SyncService service; MedicationRepositoryImpl medications; TreatmentRepositoryImpl treatments; DoseLogRepositoryImpl doses; }`

- [ ] **Step 1: The fake PostgREST**

Create `test/helpers/fake_postgrest.dart`. It understands:
- `select` with the two embeds the app uses;
- `eq`, `gt`, `gte`, `lt`, `is.null`, `in.(…)`, and `or=(…)` with nested `and(…)`;
- `order` and `limit`;
- `Prefer: return=representation`, `resolution=ignore-duplicates` and `merge-duplicates`;
- the object `Accept` header;
- the two RPCs.

Anything else answers 400, so a request shape the app starts sending is noticed. An update by `id` runs through `FakeServerCore.patch` with the same conditions, so request counts match the Dart path.

```dart
/// [FakeServerCore] served over HTTP the way PostgREST answers the requests
/// Medora's real datasources send, so a test can run the real
/// `PostgrestSyncTable`, `PostgrestStockRemote` and
/// `SyncStateRemoteDatasource` end to end with no network.
///
/// Understood: `select` (with the two embeds the app uses), the filters
/// `eq`, `gt`, `gte`, `lt`, `is.null`, `in.(…)`, `or=(…)` with nested
/// `and(…)`, `order`, `limit`, `Prefer: return=representation`,
/// `resolution=ignore-duplicates` / `merge-duplicates`, the object `Accept`
/// header, and `/rpc/medora_sync_state` and `/rpc/apply_stock_change`.
/// Anything else answers 400, so a request the app starts sending is
/// noticed.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:medora/data/datasources/dose_log_remote_datasource.dart';
import 'package:medora/data/datasources/medication_remote_datasource.dart';
import 'package:medora/data/datasources/prescription_remote_datasource.dart';
import 'package:medora/data/datasources/stock_remote.dart';
import 'package:medora/data/datasources/sync_state_remote_datasource.dart';
import 'package:medora/data/datasources/sync_table.dart';
import 'package:medora/data/datasources/treatment_remote_datasource.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'fake_server.dart';

class FakePostgrest {
  FakePostgrest(this.core);

  /// The one fake PostgREST in front of [core].
  factory FakePostgrest.of(FakeServerCore core) =>
      _byCore[core] ??= FakePostgrest(core);

  static final _byCore = Expando<FakePostgrest>('FakePostgrest');

  final FakeServerCore core;

  /// Every request, as `METHOD path?query`, in order.
  final List<String> log = [];

  /// When false, `/rpc/medora_sync_state` answers PGRST202 as a project
  /// without the migration does.
  bool migrated = true;

  late final http.Client httpClient = MockClient(_handle);

  /// A Supabase client whose REST calls this fake answers.
  SupabaseClient client() => SupabaseClient(
    'http://postgrest.test',
    'anon-key',
    httpClient: httpClient,
    authOptions: const AuthClientOptions(autoRefreshToken: false),
  );

  late final SupabaseClient _client = client();
  late final _medications = MedicationRemoteDatasource(_client);
  late final Map<String, SyncTable> _tables = {
    'medications': _medications.rows,
    'treatments': TreatmentRemoteDatasource(_client).rows,
    'prescriptions': PrescriptionRemoteDatasource(_client).rows,
    'dose_logs': DoseLogRemoteDatasource(_client).rows,
  };

  /// The app's own `PostgrestSyncTable` for [name], talking to this fake.
  SyncTable table(String name) =>
      _tables[name] ?? PostgrestSyncTable(_client, name);

  /// The app's own `PostgrestStockRemote`, talking to this fake.
  StockRemote stock() => _medications.stock;

  /// The app's own `SyncStateRemoteDatasource`, talking to this fake.
  late final SyncStateRemoteDatasource state = SyncStateRemoteDatasource(
    _client,
  );

  static const _reserved = {
    'select',
    'order',
    'limit',
    'on_conflict',
    'columns',
  };

  Future<http.Response> _handle(http.Request request) async {
    log.add('${request.method} ${request.url.path}?${request.url.query}');
    final segments = request.url.pathSegments;
    if (segments.length < 3 || segments[0] != 'rest' || segments[1] != 'v1') {
      return _error(request, 404, 'PGRST000', 'no such route');
    }
    if (segments[2] == 'rpc') {
      return _rpc(request, segments[3]);
    }
    final table = segments[2];
    final query = request.url.queryParametersAll;
    final select = query['select']?.single ?? '*';
    final filters = <String, List<String>>{
      for (final e in query.entries)
        if (!_reserved.contains(e.key)) e.key: e.value,
    };
    final prefer = request.headers['Prefer'] ?? '';
    switch (request.method) {
      case 'GET':
        _count(table, filters);
        var rows = [
          for (final r in core.rowsOf(table).values)
            if (_matchesAll(r, filters)) Map<String, dynamic>.of(r),
        ];
        rows = _ordered(rows, query['order']?.single);
        final limit = int.tryParse(query['limit']?.single ?? '');
        final cap = limit == null
            ? core.rowCap
            : (limit < core.rowCap ? limit : core.rowCap);
        rows = rows.take(cap).toList();
        return _rows(request, table, select, rows);
      case 'PATCH':
        final changes = jsonDecode(request.body) as Map<String, dynamic>;
        final byId = _patchById(table, filters, changes);
        if (byId != null) {
          final written = [?byId.row];
          return prefer.contains('return=representation')
              ? _rows(request, table, select, written)
              : http.Response('', 204, request: request);
        }
        final written = <Map<String, dynamic>>[];
        for (final r in core.rowsOf(table).values.toList()) {
          if (!_matchesAll(r, filters)) continue;
          final row = core.patch(table, r['id'] as String, changes);
          if (row != null) written.add(row);
        }
        return prefer.contains('return=representation')
            ? _rows(request, table, select, written)
            : http.Response('', 204, request: request);
      case 'POST':
        final body = jsonDecode(request.body);
        final rows = [
          for (final r in body is List ? body : [body])
            Map<String, dynamic>.from(r as Map),
        ];
        if (rows.map((r) => r.keys.toSet().length).toSet().length > 1) {
          return _error(request, 400, 'PGRST102', 'All object keys must match');
        }
        if (prefer.contains('resolution=ignore-duplicates')) {
          core.insertIfAbsent(table, rows);
        } else {
          for (final r in rows) {
            core.legacyUpsert(table, r);
          }
        }
        final stored = [
          for (final r in rows)
            Map<String, dynamic>.of(core.rowsOf(table)[r['id']]!),
        ];
        return prefer.contains('return=representation')
            ? _rows(request, table, select, stored, status: 201)
            : http.Response('', 201, request: request);
    }
    return _error(request, 400, 'PGRST000', 'unsupported ${request.method}');
  }

  http.Response _rpc(http.Request request, String fn) {
    final params = request.body.isEmpty
        ? const <String, dynamic>{}
        : jsonDecode(request.body) as Map<String, dynamic>? ?? const {};
    switch (fn) {
      case 'medora_sync_state':
        if (!migrated) {
          return _error(
            request,
            404,
            'PGRST202',
            'Could not find the function public.medora_sync_state without '
                'parameters in the schema cache',
          );
        }
        return _json(request, core.syncState());
      case 'apply_stock_change':
        return _json(
          request,
          core.applyStockChange(
            opId: params['p_op_id'] as String,
            medicationId: params['p_medication_id'] as String,
            delta: params['p_delta'] as int?,
            setTo: params['p_set_to'] as int?,
          ),
        );
    }
    return _error(request, 404, 'PGRST202', 'Could not find the function $fn');
  }

  /// Records a read in [FakeServerCore.requests] the way the core's own
  /// `page` and `fetch` do.
  void _count(String table, Map<String, List<String>> filters) {
    if (filters.containsKey('sync_xid')) {
      core.requests.add('$table:page');
      return;
    }
    for (final f in filters['id'] ?? const <String>[]) {
      final ids = f.startsWith('in.') ? _split(_inner(f.substring(3))) : [f];
      for (final _ in ids) {
        core.requests.add('$table:fetch');
      }
    }
  }

  /// The one update shape the app sends, `id=eq.…` plus the conditions of
  /// `SyncTable.patch`, run as [FakeServerCore.patch]; null for any other
  /// filter set.
  ({Map<String, dynamic>? row})? _patchById(
    String table,
    Map<String, List<String>> filters,
    Map<String, dynamic> changes,
  ) {
    const known = {'id', 'row_version', 'status', 'deleted_at'};
    if (!filters.containsKey('id') || !known.containsAll(filters.keys)) {
      return null;
    }
    String? eq(String column) {
      final values = filters[column];
      if (values == null) return null;
      final v = values.single;
      if (!v.startsWith('eq.')) throw FormatException('$column=$v');
      return _unquote(v.substring(3));
    }

    final live = filters['deleted_at'];
    if (live != null && live.single != 'is.null') {
      throw FormatException('deleted_at=${live.single}');
    }
    final version = eq('row_version');
    return (
      row: core.patch(
        table,
        eq('id')!,
        changes,
        ifVersion: version == null ? null : int.parse(version),
        ifStatus: eq('status'),
        ifLive: live != null,
      ),
    );
  }

  // ── Filters ────────────────────────────────────────────────

  bool _matchesAll(
    Map<String, dynamic> row,
    Map<String, List<String>> filters,
  ) {
    for (final e in filters.entries) {
      for (final value in e.value) {
        final ok = e.key == 'or'
            ? _or(row, _inner(value))
            : e.key == 'and'
            ? _and(row, _inner(value))
            : _test(row, e.key, value);
        if (!ok) return false;
      }
    }
    return true;
  }

  static String _inner(String grouped) {
    if (!grouped.startsWith('(') || !grouped.endsWith(')')) {
      throw FormatException('not a group: $grouped');
    }
    return grouped.substring(1, grouped.length - 1);
  }

  bool _or(Map<String, dynamic> row, String list) =>
      _split(list).any((c) => _condition(row, c));

  bool _and(Map<String, dynamic> row, String list) =>
      _split(list).every((c) => _condition(row, c));

  bool _condition(Map<String, dynamic> row, String c) {
    if (c.startsWith('and(')) return _and(row, _inner(c.substring(3)));
    if (c.startsWith('or(')) return _or(row, _inner(c.substring(2)));
    final dot = c.indexOf('.');
    return _test(row, c.substring(0, dot), c.substring(dot + 1));
  }

  /// Splits a PostgREST list at the commas outside quotes and parentheses.
  static List<String> _split(String list) {
    final parts = <String>[];
    final current = StringBuffer();
    var depth = 0;
    var quoted = false;
    for (var i = 0; i < list.length; i++) {
      final ch = list[i];
      if (quoted) {
        current.write(ch);
        if (ch == r'\' && i + 1 < list.length) {
          current.write(list[++i]);
        } else if (ch == '"') {
          quoted = false;
        }
        continue;
      }
      if (ch == '"') quoted = true;
      if (ch == '(') depth++;
      if (ch == ')') depth--;
      if (ch == ',' && depth == 0) {
        parts.add(current.toString());
        current.clear();
      } else {
        current.write(ch);
      }
    }
    if (current.isNotEmpty) parts.add(current.toString());
    return parts;
  }

  static String _unquote(String v) {
    if (v.length >= 2 && v.startsWith('"') && v.endsWith('"')) {
      return v
          .substring(1, v.length - 1)
          .replaceAll(r'\"', '"')
          .replaceAll(r'\\', r'\');
    }
    return v;
  }

  static bool _test(Map<String, dynamic> row, String column, String expr) {
    final dot = expr.indexOf('.');
    final op = expr.substring(0, dot);
    final raw = expr.substring(dot + 1);
    final actual = row[column];
    switch (op) {
      case 'is':
        return raw == 'null' ? actual == null : '$actual' == raw;
      case 'in':
        return _split(_inner(raw)).map(_unquote).contains('$actual');
      case 'eq':
      case 'gt':
      case 'gte':
      case 'lt':
        if (actual == null) return false;
        final expected = _unquote(raw);
        final int cmp;
        if (actual is num) {
          cmp = actual.compareTo(num.parse(expected));
        } else if (actual is bool) {
          cmp = '$actual' == expected ? 0 : 1;
        } else {
          cmp = '$actual'.compareTo(expected);
        }
        return switch (op) {
          'eq' => cmp == 0,
          'gt' => cmp > 0,
          'gte' => cmp >= 0,
          _ => cmp < 0,
        };
    }
    throw FormatException('unsupported filter $column=$expr');
  }

  static List<Map<String, dynamic>> _ordered(
    List<Map<String, dynamic>> rows,
    String? order,
  ) {
    if (order == null) return rows;
    final keys = [
      for (final part in order.split(','))
        (part.split('.').first, !part.contains('.desc')),
    ];
    return rows..sort((a, b) {
      for (final (column, ascending) in keys) {
        final x = a[column];
        final y = b[column];
        final cmp = x is num && y is num
            ? x.compareTo(y)
            : '$x'.compareTo('$y');
        if (cmp != 0) return ascending ? cmp : -cmp;
      }
      return 0;
    });
  }

  // ── Answers ────────────────────────────────────────────────

  http.Response _rows(
    http.Request request,
    String table,
    String select,
    List<Map<String, dynamic>> rows, {
    int status = 200,
  }) {
    final shaped = [for (final r in rows) _embed(table, select, r)];
    final accept = request.headers['Accept'] ?? '';
    if (accept.contains('vnd.pgrst.object+json')) {
      if (shaped.length != 1) {
        return _error(
          request,
          406,
          'PGRST116',
          'JSON object requested, multiple (or no) rows returned',
        );
      }
      return _json(request, shaped.single, status: status);
    }
    return _json(request, shaped, status: status);
  }

  Map<String, dynamic> _embed(
    String table,
    String select,
    Map<String, dynamic> row,
  ) {
    final out = Map<String, dynamic>.of(row);
    if (table == 'dose_logs' && select.contains('prescriptions(')) {
      final p = core.rowsOf('prescriptions')[row['prescription_id']];
      final m = p == null
          ? null
          : core.rowsOf('medications')[p['medication_id']];
      out['prescriptions'] = p == null
          ? null
          : {
              'id': p['id'],
              'medications': m == null ? null : {'name': m['name']},
            };
    }
    if (table == 'prescriptions' && select.contains('medications(')) {
      final m = core.rowsOf('medications')[row['medication_id']];
      final t = core.rowsOf('treatments')[row['treatment_id']];
      out['medications'] = m == null ? null : {'name': m['name']};
      out['treatments'] = t == null ? null : {'name': t['name']};
    }
    return out;
  }

  static http.Response _json(
    http.Request request,
    Object? body, {
    int status = 200,
  }) => http.Response(
    jsonEncode(body),
    status,
    request: request,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );

  static http.Response _error(
    http.Request request,
    int status,
    String code,
    String message,
  ) => http.Response(
    jsonEncode({
      'code': code,
      'message': message,
      'details': null,
      'hint': null,
    }),
    status,
    request: request,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );
}
```

- [ ] **Step 2: The transport switch**

Apply:

```diff
--- a/test/helpers/fake_server.dart
+++ b/test/helpers/fake_server.dart
@@ -8,6 +8,12 @@
 /// (`fake_postgrest.dart`) are both views of one [FakeServerCore], so the
 /// server rules live in one place. Keep it in step with
 /// `tools/sql/sync_v2_checks.sql`.
+///
+/// Every fake table and stock remote reaches the core one of two ways
+/// ([FakeTransport]): straight, or through the app's real PostgREST
+/// datasources and [FakePostgrest]. The failure knobs work the same either
+/// way. `--dart-define=MEDORA_FAKE_TRANSPORT=http` switches the default, so
+/// the whole suite can run over HTTP.
 library;
 
 import 'dart:async';
@@ -17,6 +23,23 @@
 import 'package:medora/data/datasources/stock_remote.dart';
 import 'package:medora/data/datasources/sync_page.dart';
 import 'package:medora/data/datasources/sync_table.dart';
+
+import 'fake_postgrest.dart';
+
+/// How a fake table reaches [FakeServerCore].
+enum FakeTransport {
+  /// Method calls on the core.
+  dart,
+
+  /// The app's PostgREST datasources, answered by [FakePostgrest].
+  http,
+}
+
+/// The transport a fake uses unless a test names one.
+const FakeTransport defaultFakeTransport =
+    String.fromEnvironment('MEDORA_FAKE_TRANSPORT') == 'http'
+    ? FakeTransport.http
+    : FakeTransport.dart;
 
 final _weakCeiling = DateTime.utc(1970, 1, 2);
 final _epoch = DateTime.utc(1970);
@@ -293,10 +316,17 @@
 /// [SyncTable] over [FakeServerCore], with the failure knobs the sync tests
 /// use.
 class FakeSyncTable implements SyncTable {
-  FakeSyncTable(this.core, this.table);
+  FakeSyncTable(this.core, this.table, {FakeTransport? transport})
+    : wire = (transport ?? defaultFakeTransport) == FakeTransport.http
+          ? FakePostgrest.of(core).table(table)
+          : null;
 
   final FakeServerCore core;
   final String table;
+
+  /// The real PostgREST table the requests go through, in
+  /// [FakeTransport.http]; null when they go straight to [core].
+  final SyncTable? wire;
 
   /// Ids whose writes throw, as a server that refuses them.
   final Set<String> failIds = {};
@@ -350,12 +380,13 @@
     onPage?.call(pageCalls.length, after);
     final failure = throwOnFetch;
     if (failure != null) throw failure;
-    return core.page(
-      table,
-      horizon: horizon,
-      afterXid: after?.xid,
-      afterId: after?.id,
-    );
+    return await wire?.page(after: after, horizon: horizon) ??
+        core.page(
+          table,
+          horizon: horizon,
+          afterXid: after?.xid,
+          afterId: after?.id,
+        );
   }
 
   @override
@@ -364,13 +395,15 @@
     if (failGetIds.contains(id)) {
       throw StateError('remote get failure for $id');
     }
-    return core.fetch(table, id);
+    final http = wire;
+    return http != null ? http.fetch(id) : core.fetch(table, id);
   }
 
   @override
   Future<List<Map<String, dynamic>>> fetchMany(List<String> ids) async {
     await beforeCall?.call();
-    return [for (final id in ids) ?core.fetch(table, id)];
+    return await wire?.fetchMany(ids) ??
+        [for (final id in ids) ?core.fetch(table, id)];
   }
 
   @override
@@ -383,14 +416,23 @@
   }) async {
     await beforeCall?.call();
     _guard(id);
-    final written = core.patch(
-      table,
-      id,
-      Map<String, dynamic>.of(changes),
-      ifVersion: ifVersion,
-      ifStatus: ifStatus,
-      ifLive: ifLive,
-    );
+    final http = wire;
+    final written = http != null
+        ? await http.patch(
+            id,
+            changes,
+            ifVersion: ifVersion,
+            ifStatus: ifStatus,
+            ifLive: ifLive,
+          )
+        : core.patch(
+            table,
+            id,
+            Map<String, dynamic>.of(changes),
+            ifVersion: ifVersion,
+            ifStatus: ifStatus,
+            ifLive: ifLive,
+          );
     _maybeLose(id);
     return written;
   }
@@ -402,7 +444,12 @@
       _guard(r['id']! as String);
     }
     insertBatches.add(rows.length);
-    core.insertIfAbsent(table, [for (final r in rows) Map.of(r)]);
+    final http = wire;
+    if (http != null) {
+      await http.insertIfAbsent(rows);
+    } else {
+      core.insertIfAbsent(table, [for (final r in rows) Map.of(r)]);
+    }
     for (final r in rows) {
       _maybeLose(r['id']! as String);
     }
@@ -438,26 +485,37 @@
 
 /// [StockRemote] over [FakeServerCore].
 class FakeStockRemote implements StockRemote {
-  FakeStockRemote(this.core);
+  FakeStockRemote(this.core, {FakeTransport? transport})
+    : wire = (transport ?? defaultFakeTransport) == FakeTransport.http
+          ? FakePostgrest.of(core).stock()
+          : null;
 
   final FakeServerCore core;
+
+  /// `PostgrestStockRemote` over [FakePostgrest], in [FakeTransport.http].
+  final StockRemote? wire;
 
   /// How many of the next changes land with their answer lost.
   int loseNextAnswers = 0;
 
   @override
   Future<StockChangeResult> apply(StockOp op) async {
-    final json = core.applyStockChange(
-      opId: op.opId,
-      medicationId: op.medicationId,
-      delta: op.delta,
-      setTo: op.setTo,
-    );
+    final http = wire;
+    final result = http != null
+        ? await http.apply(op)
+        : StockChangeResult.fromJson(
+            core.applyStockChange(
+              opId: op.opId,
+              medicationId: op.medicationId,
+              delta: op.delta,
+              setTo: op.setTo,
+            ),
+          );
     if (loseNextAnswers > 0) {
       loseNextAnswers--;
       throw TimeoutException('answer lost for stock change ${op.opId}');
     }
-    return StockChangeResult.fromJson(json);
+    return result;
   }
 }
 
--- a/test/helpers/fake_remotes.dart
+++ b/test/helpers/fake_remotes.dart
@@ -1,5 +1,7 @@
 /// The fake remote datasources: thin views of one [FakeServerCore]
-/// (`fake_server.dart`), which models the server rules.
+/// (`fake_server.dart`), which models the server rules. With
+/// [FakeTransport.http] their requests go through the app's PostgREST
+/// datasources and [FakePostgrest].
 library;
 
 import 'package:medora/data/datasources/dose_log_remote_datasource.dart';
@@ -13,6 +15,7 @@
 import 'package:medora/data/models/family_model.dart';
 import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;
 
+import 'fake_postgrest.dart';
 import 'fake_server.dart';
 
 export 'fake_server.dart';
@@ -20,23 +23,37 @@
 /// One fake Supabase project: the shared core and a datasource per table.
 class FakeServer {
   /// [medicationRows], [treatmentRows] and [doseRows] build a misbehaving
-  /// table in place of the plain one.
+  /// table in place of the plain one; such a table picks its own transport.
   FakeServer(
     DateTime Function() clock, {
     String currentUserId = 'user-a',
     FakeSyncTable Function(FakeServerCore core)? medicationRows,
     FakeSyncTable Function(FakeServerCore core)? treatmentRows,
     FakeSyncTable Function(FakeServerCore core)? doseRows,
+    this.transport = defaultFakeTransport,
   }) : core = FakeServerCore(clock) {
-    meds = FakeMedicationRemote(core, rows: medicationRows?.call(core));
-    treatments = FakeTreatmentRemote(core, rows: treatmentRows?.call(core));
-    prescriptions = FakePrescriptionRemote(core);
-    doses = FakeDoseLogRemote(core, rows: doseRows?.call(core));
+    meds = FakeMedicationRemote(
+      core,
+      rows: medicationRows?.call(core),
+      transport: transport,
+    );
+    treatments = FakeTreatmentRemote(
+      core,
+      rows: treatmentRows?.call(core),
+      transport: transport,
+    );
+    prescriptions = FakePrescriptionRemote(core, transport: transport);
+    doses = FakeDoseLogRemote(
+      core,
+      rows: doseRows?.call(core),
+      transport: transport,
+    );
     families = FakeFamilyRemote(clock, currentUserId: currentUserId);
-    state = FakeSyncState(core);
+    state = FakeSyncState(core, transport: transport);
   }
 
   final FakeServerCore core;
+  final FakeTransport transport;
   late final FakeMedicationRemote meds;
   late final FakeTreatmentRemote treatments;
   late final FakePrescriptionRemote prescriptions;
@@ -48,9 +65,12 @@
 class FakeMedicationRemote implements MedicationRemoteDatasource {
   /// [rows] replaces the plain table, for a test that needs a server that
   /// misbehaves.
-  FakeMedicationRemote(FakeServerCore core, {FakeSyncTable? rows})
-    : rows = rows ?? FakeSyncTable(core, 'medications'),
-      stock = FakeStockRemote(core);
+  FakeMedicationRemote(
+    FakeServerCore core, {
+    FakeSyncTable? rows,
+    FakeTransport? transport,
+  }) : rows = rows ?? FakeSyncTable(core, 'medications', transport: transport),
+       stock = FakeStockRemote(core, transport: transport);
 
   @override
   final FakeSyncTable rows;
@@ -62,8 +82,11 @@
 }
 
 class FakeTreatmentRemote implements TreatmentRemoteDatasource {
-  FakeTreatmentRemote(FakeServerCore core, {FakeSyncTable? rows})
-    : rows = rows ?? FakeSyncTable(core, 'treatments');
+  FakeTreatmentRemote(
+    FakeServerCore core, {
+    FakeSyncTable? rows,
+    FakeTransport? transport,
+  }) : rows = rows ?? FakeSyncTable(core, 'treatments', transport: transport);
 
   @override
   final FakeSyncTable rows;
@@ -71,8 +94,8 @@
 }
 
 class FakePrescriptionRemote implements PrescriptionRemoteDatasource {
-  FakePrescriptionRemote(FakeServerCore core)
-    : rows = FakePrescriptionTable(core);
+  FakePrescriptionRemote(FakeServerCore core, {FakeTransport? transport})
+    : rows = FakePrescriptionTable(core, transport: transport);
 
   @override
   final FakePrescriptionTable rows;
@@ -95,7 +118,8 @@
 
 /// Stores `start_time` the way a `timestamptz` column does.
 class FakePrescriptionTable extends FakeSyncTable {
-  FakePrescriptionTable(FakeServerCore core) : super(core, 'prescriptions');
+  FakePrescriptionTable(FakeServerCore core, {super.transport})
+    : super(core, 'prescriptions');
 
   static Map<String, Object?> _asStored(Map<String, Object?> json) => {
     ...json,
@@ -124,8 +148,11 @@
 }
 
 class FakeDoseLogRemote implements DoseLogRemoteDatasource {
-  FakeDoseLogRemote(FakeServerCore core, {FakeSyncTable? rows})
-    : rows = rows ?? FakeSyncTable(core, 'dose_logs');
+  FakeDoseLogRemote(
+    FakeServerCore core, {
+    FakeSyncTable? rows,
+    FakeTransport? transport,
+  }) : rows = rows ?? FakeSyncTable(core, 'dose_logs', transport: transport);
 
   @override
   final FakeSyncTable rows;
@@ -133,15 +160,24 @@
 }
 
 class FakeSyncState implements SyncStateRemoteDatasource {
-  FakeSyncState(this.core);
+  FakeSyncState(this.core, {FakeTransport? transport})
+    : _http = (transport ?? defaultFakeTransport) == FakeTransport.http
+          ? FakePostgrest.of(core)
+          : null;
 
   final FakeServerCore core;
+  final FakePostgrest? _http;
 
   /// False: the project lacks the sync v2 migration.
   bool migrated = true;
 
   @override
   Future<SyncServerState> read() async {
+    final http = _http;
+    if (http != null) {
+      http.migrated = migrated;
+      return http.state.read();
+    }
     if (!migrated) {
       throw const MissingMigrationException(
         migration: syncV2Migration,
```

- [ ] **Step 3: Two devices, both transports**

Create `test/helpers/two_devices.dart`. Each device has its own SQLite file, cycle, cursors and repositories; both share one fake server and one clock.

```dart
/// Two devices on one account and one fake server (sync v2).
///
/// Each device has its own SQLite file, sync service, cursors, failure
/// store and repositories; they share the server. Only one device's
/// database is open at a time ([Device.run]). Every sync a repository asks
/// for runs before [Device.run] returns, as the app's queued cycles do.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:medora/data/datasources/dose_log_local_datasource.dart';
import 'package:medora/data/datasources/family_local_datasource.dart';
import 'package:medora/data/datasources/medication_local_datasource.dart';
import 'package:medora/data/datasources/prescription_local_datasource.dart';
import 'package:medora/data/datasources/treatment_local_datasource.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/repositories/dose_log_repository_impl.dart';
import 'package:medora/data/repositories/medication_repository_impl.dart';
import 'package:medora/data/repositories/treatment_repository_impl.dart';
import 'package:medora/services/sync_cursor_store.dart';
import 'package:medora/services/sync_failure_store.dart';
import 'package:medora/services/sync_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'fake_remotes.dart';

export 'fake_remotes.dart';

class Device {
  Device(this.name, this.path, this.server, {required DateTime Function() now})
    : _now = now {
    service = SyncService(
      medicationLocal: MedicationLocalDatasource(),
      medicationRemote: server.meds,
      treatmentLocal: TreatmentLocalDatasource(),
      treatmentRemote: server.treatments,
      prescriptionLocal: PrescriptionLocalDatasource(),
      prescriptionRemote: server.prescriptions,
      doseLogLocal: DoseLogLocalDatasource(),
      doseLogRemote: server.doses,
      familyLocal: FamilyLocalDatasource(),
      familyRemote: server.families,
      syncState: server.state,
      newWriteId: () => '$name-w${_ids++}',
      isOnline: () => online,
      currentUserId: () => 'user-a',
      onlineStream: const Stream<bool>.empty(),
      cursors: cursors,
      failures: failures,
      now: now,
    );
    medications = MedicationRepositoryImpl(
      localDatasource: MedicationLocalDatasource(),
      requestSync: _requestSync,
      newOpId: () => '$name-op${_ids++}',
    );
    treatments = TreatmentRepositoryImpl(
      localDatasource: TreatmentLocalDatasource(),
      requestSync: _requestSync,
      now: now,
    );
    doses = DoseLogRepositoryImpl(
      localDatasource: DoseLogLocalDatasource(),
      prescriptionLocal: PrescriptionLocalDatasource(),
      requestSync: _requestSync,
    );
  }

  final String name;
  final String path;
  final FakeServer server;
  final DateTime Function() _now;
  bool online = true;
  var _ids = 0;
  final cursors = SyncCursorStore.inMemory();
  final failures = SyncFailureStore.inMemory();
  late final SyncService service;
  late final MedicationRepositoryImpl medications;
  late final TreatmentRepositoryImpl treatments;
  late final DoseLogRepositoryImpl doses;
  final List<Future<void>> _requests = [];

  Future<void> _requestSync() {
    final cycle = service.syncAll();
    _requests.add(cycle);
    return cycle;
  }

  /// Opens this device's database, runs [body], and waits for every sync
  /// the body asked for.
  Future<T> run<T>(Future<T> Function(Database db) body) async {
    await AppDatabase.instance.reset();
    AppDatabase.debugPathOverride = path;
    final result = await body(await AppDatabase.instance.database);
    await pumpEventQueue();
    while (_requests.isNotEmpty) {
      final pending = List.of(_requests);
      _requests.clear();
      await Future.wait(pending);
      await pumpEventQueue();
    }
    return result;
  }

  Future<SyncReport?> sync() => run((_) => service.syncAll());

  Future<Map<String, Object?>> row(String table, String id) => run(
    (db) async =>
        (await db.query(table, where: 'id = ?', whereArgs: [id])).single,
  );

  DateTime now() => _now();
}

class TwoDevices {
  /// [transport]: how both devices reach the server; the app's real
  /// PostgREST datasources in [FakeTransport.http].
  TwoDevices({this.transport = FakeTransport.dart}) {
    dir = Directory.systemTemp.createTempSync('medora_two_');
    server = FakeServer(() => clock, transport: transport);
    a = Device('A', '${dir.path}/a.db', server, now: () => clock);
    b = Device('B', '${dir.path}/b.db', server, now: () => clock);
  }

  final FakeTransport transport;

  /// The server's tables.
  FakeServerCore get core => server.core;

  /// The next stock change lands and its answer is lost.
  void loseNextStockAnswer() => server.meds.stock.loseNextAnswers++;

  /// The one clock both devices and the server read; tests move it.
  DateTime clock = DateTime.utc(2026, 3, 5, 8);
  late final Directory dir;
  late final FakeServer server;
  late final Device a;
  late final Device b;

  void advance(Duration d) => clock = clock.add(d);

  Future<void> dispose() async {
    a.service.dispose();
    b.service.dispose();
    await AppDatabase.instance.reset();
    AppDatabase.debugPathOverride = null;
    dir.deleteSync(recursive: true);
  }
}
```

Create `test/services/multi_device_merge_test.dart`. It runs every scenario over both transports. Every scenario starts from the same warm state:
- three days ago A recorded the illness (`Sinusitis`, sick leave from 2 March, `Dr. Rossi`) and the ibuprofen pack (12);
- B synced and took two;
- A synced;
- both hold 10.

The scenarios and their expected values:
- **S1a:** B adds `CERT-B` offline at 08:30, A ends the illness at 09:00, and B syncs last. Expected on both devices: `[is_active, end_date, sick_leave_to, sick_leave_ref, sync_status]` = `[0, '2026-03-05', '2026-03-05', 'CERT-B', 'synced']`. On the server: `[false, 'CERT-B']`.
- **S1b:** A ends it and syncs; B, offline, adds the certificate at 09:30 and syncs later. Expected: the same four values on both devices.
- **Both offline, each takes a tablet.** Expected: 8 on the server, A and B.
- **A lost stock answer.** The first cycle fails with table `stock_outbox` and the server at 9. An hour later: still 9 on the server and here.
- **A project without the migration.**
  - `missingMigration` is `supabase/migrations/20260918000000_sync_v2.sql`, and `fatal` names it;
  - no request reached the server tables;
  - the server still holds 10;
  - the state is `error`.
- **A row committed late** (its transaction held open while a later write commits) is not pulled early, and not skipped. After the commit, B holds both rows (3 and 1).

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/domain/entities/medication.dart';
import 'package:medora/domain/entities/treatment.dart';

import '../helpers/test_database.dart';
import '../helpers/two_devices.dart';

void main() {
  for (final transport in FakeTransport.values) {
    group('over ${transport.name}', () => _scenarios(transport));
  }
}

void _scenarios(FakeTransport transport) {
  late TwoDevices h;

  setUp(() async {
    await setUpTestDatabase();
    h = TwoDevices(transport: transport);
    // Three days ago A recorded the illness and the ibuprofen pack; both
    // devices have synced since, and B has changed the stock once.
    h.clock = DateTime.utc(2026, 3, 2, 9);
    await h.a.run((_) async {
      await h.a.treatments.addTreatment(
        Treatment(
          id: 't1',
          name: 'Sinusitis',
          startDate: DateTime(2026, 3, 2),
          sickLeaveFrom: DateTime(2026, 3, 2),
          doctor: 'Dr. Rossi',
        ),
      );
      await h.a.medications.addMedication(
        const Medication(id: 'm1', name: 'Ibuprofen 400', quantity: 12),
      );
    });
    h.advance(const Duration(minutes: 5));
    await h.b.sync();
    await h.b.run((_) => h.b.medications.updateQuantity('m1', -2));
    h.advance(const Duration(minutes: 5));
    await h.a.sync();
    h.clock = DateTime.utc(2026, 3, 5, 8);
    expect((await h.a.row('medications', 'm1'))['quantity'], 10);
    expect((await h.b.row('medications', 'm1'))['quantity'], 10);
  });
  tearDown(() => h.dispose());

  test(
    'S1a: B adds the certificate offline, A ends the illness, B syncs last',
    () async {
      h.b.online = false;
      h.clock = DateTime.utc(2026, 3, 5, 8, 30);
      await h.b.run((_) async {
        final t = (await h.b.treatments.getTreatmentById('t1')).dataOrNull!;
        await h.b.treatments.updateTreatment(
          t.copyWith(sickLeaveRef: 'CERT-B'),
        );
      });
      h.clock = DateTime.utc(2026, 3, 5, 9);
      await h.a.run(
        (_) => h.a.treatments.endTreatment('t1', endSickLeave: true),
      );
      h.b.online = true;
      h.clock = DateTime.utc(2026, 3, 5, 10);
      await h.b.sync();
      await h.a.sync();
      for (final d in [h.a, h.b]) {
        final row = await d.row('treatments', 't1');
        expect(
          [
            row['is_active'],
            row['end_date'],
            row['sick_leave_to'],
            row['sick_leave_ref'],
            row['sync_status'],
          ],
          [0, '2026-03-05', '2026-03-05', 'CERT-B', 'synced'],
          reason: d.name,
        );
      }
      final server = h.core.rowsOf('treatments')['t1']!;
      expect(
        [server['is_active'], server['sick_leave_ref']],
        [false, 'CERT-B'],
      );
    },
  );

  test(
    'S1b: A ends it and syncs; B, offline, adds the certificate later',
    () async {
      h.clock = DateTime.utc(2026, 3, 5, 9);
      await h.a.run(
        (_) => h.a.treatments.endTreatment('t1', endSickLeave: true),
      );
      h.b.online = false;
      h.clock = DateTime.utc(2026, 3, 5, 9, 30);
      await h.b.run((_) async {
        final t = (await h.b.treatments.getTreatmentById('t1')).dataOrNull!;
        await h.b.treatments.updateTreatment(
          t.copyWith(sickLeaveRef: 'CERT-B'),
        );
      });
      h.b.online = true;
      await h.b.sync();
      await h.a.sync();
      for (final d in [h.a, h.b]) {
        final row = await d.row('treatments', 't1');
        expect(
          [
            row['is_active'],
            row['end_date'],
            row['sick_leave_to'],
            row['sick_leave_ref'],
          ],
          [0, '2026-03-05', '2026-03-05', 'CERT-B'],
          reason: d.name,
        );
      }
    },
  );

  test('both offline, each takes one tablet: 10 -> 8 everywhere', () async {
    h.a.online = false;
    h.b.online = false;
    await h.a.run((_) => h.a.medications.updateQuantity('m1', -1));
    await h.b.run((_) => h.b.medications.updateQuantity('m1', -1));
    h.a.online = true;
    h.b.online = true;
    await h.a.sync();
    await h.b.sync();
    await h.a.sync();
    expect(h.core.rowsOf('medications')['m1']!['quantity'], 8);
    expect((await h.a.row('medications', 'm1'))['quantity'], 8);
    expect((await h.b.row('medications', 'm1'))['quantity'], 8);
  });

  test('a lost stock answer is sent again and counted once', () async {
    await h.a.run((_) async {
      h.a.online = false;
      await h.a.medications.updateQuantity('m1', -1);
    });
    h.a.online = true;
    h.loseNextStockAnswer();
    final first = await h.a.sync();
    expect(first!.failures.single.table, 'stock_outbox');
    expect(h.core.rowsOf('medications')['m1']!['quantity'], 9);
    h.advance(const Duration(hours: 1));
    await h.a.sync();
    expect(h.core.rowsOf('medications')['m1']!['quantity'], 9);
    expect((await h.a.row('medications', 'm1'))['quantity'], 9);
  });

  test(
    'a project without the migration stops the cycle before any write',
    () async {
      h.server.state.migrated = false;
      await h.a.run((_) => h.a.medications.updateQuantity('m1', -1));
      final before = h.core.requests.length;
      final report = await h.a.sync();
      expect(
        report!.missingMigration,
        'supabase/migrations/20260918000000_sync_v2.sql',
      );
      expect(report.fatal, contains('20260918000000_sync_v2.sql'));
      expect(h.core.requests.sublist(before), isEmpty);
      expect(h.core.rowsOf('medications')['m1']!['quantity'], 10);
      expect(h.a.service.currentState.name, 'error');
    },
  );

  test('a row committed late is pulled on the next cycle', () async {
    final slow = h.core.begin();
    slow.insert('medications', {
      'id': 'm-late',
      'user_id': 'user-a',
      'name': 'Late',
      'quantity': 3,
    });
    // A later write commits first.
    h.core.legacyUpsert('medications', {
      'id': 'm-fast',
      'user_id': 'user-a',
      'name': 'Fast',
      'quantity': 1,
    });
    await h.b.sync();
    await expectLater(h.b.row('medications', 'm-late'), throwsStateError);
    await expectLater(h.b.row('medications', 'm-fast'), throwsStateError);
    slow.commit();
    await h.b.sync();
    expect((await h.b.row('medications', 'm-late'))['quantity'], 3);
    expect((await h.b.row('medications', 'm-fast'))['quantity'], 1);
  });
}
```

Create `test/services/mixed_fleet_sync_test.dart`. The 0.3.0 phone is played by the server core itself: whole-row upserts with no write id, and a pull by `updated_at`. The scenarios:
- **A 0.3.0 edit of another field survives.** A renames the medication to `Ibuprofen 400` offline; the 0.3.0 phone sets `notes` `after food` at 08:30; A syncs at 09:00. Expected on the server and on A: both values, and A `synced`.
- **An automatic "missed" is invisible to a 0.3.0 cursor** (`legacyPull` is empty). The 0.3.0 phone's later take (09:55, whose stale check sees no newer server copy) wins on A.
- **A row created offline on 0.4.0** at 08:00 and pushed at 10:00 reaches a 0.3.0 cursor that stood at 09:00 (the server stamps inserts on arrival).
- **The known limitation:** a 0.3.0 absolute quantity (10) replaces a −1 that landed before it. A ends with 10.

```dart
/// A Medora 0.3.0 phone still syncing next to 0.4.0 devices, against the
/// migrated server. The 0.3.0 phone is played by the server core itself:
/// whole-row upserts with no write id, and a pull that asks for
/// `updated_at` newer than its cursor.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:medora/data/models/dose_log_model.dart';
import 'package:medora/data/models/medication_model.dart';
import 'package:medora/domain/entities/dose_log.dart';
import 'package:medora/domain/entities/medication.dart';
import 'package:medora/domain/entities/treatment.dart';

import '../helpers/test_database.dart';
import '../helpers/two_devices.dart';

void main() {
  for (final transport in FakeTransport.values) {
    group('over ${transport.name}', () => _scenarios(transport));
  }
}

void _scenarios(FakeTransport transport) {
  late TwoDevices h;

  /// What a 0.3.0 phone whose cursor is [cursor] would pull.
  List<String> legacyPull(String table, DateTime cursor) => [
    for (final r in h.core.rowsOf(table).values)
      if (DateTime.parse(r['updated_at'] as String).isAfter(cursor))
        r['id'] as String,
  ];

  setUp(() async {
    await setUpTestDatabase();
    h = TwoDevices(transport: transport);
    h.clock = DateTime.utc(2026, 3, 2, 9);
    await h.a.run(
      (_) => h.a.medications.addMedication(
        const Medication(id: 'm1', name: 'Ibuprofen', quantity: 10),
      ),
    );
    h.clock = DateTime.utc(2026, 3, 5, 8);
  });
  tearDown(() => h.dispose());

  test('a 0.3.0 edit of another field is kept next to a 0.4.0 edit', () async {
    h.a.online = false;
    await h.a.run((_) async {
      final m = (await h.a.medications.getMedicationById('m1')).dataOrNull!;
      await h.a.medications.updateMedication(m.copyWith(name: 'Ibuprofen 400'));
    });
    h.clock = DateTime.utc(2026, 3, 5, 8, 30);
    final legacy = MedicationModel.fromJson(
      h.core.rowsOf('medications')['m1']!,
    ).toJson()..['notes'] = 'after food';
    h.core.legacyUpsert('medications', legacy);
    h.a.online = true;
    h.clock = DateTime.utc(2026, 3, 5, 9);
    await h.a.sync();
    final server = h.core.rowsOf('medications')['m1']!;
    expect([server['name'], server['notes']], ['Ibuprofen 400', 'after food']);
    final row = await h.a.row('medications', 'm1');
    expect(
      [row['name'], row['notes'], row['sync_status']],
      ['Ibuprofen 400', 'after food', 'synced'],
    );
  });

  test('an automatic "missed" is invisible to a 0.3.0 cursor and loses to '
      'its later take', () async {
    // A dose generated long ago, pulled by A; the 0.3.0 phone has it too.
    h.core.insertIfAbsent('treatments', [
      {
        'id': 't1',
        'user_id': 'user-a',
        'name': 'Flu',
        'start_date': '2026-03-01',
        'is_active': true,
        'updated_at': '2026-03-01T08:00:00.000Z',
      },
    ]);
    h.core.insertIfAbsent('prescriptions', [
      {
        'id': 'p1',
        'treatment_id': 't1',
        'medication_id': 'm1',
        'dosage': '1',
        'start_time': '2026-03-01T08:00:00',
        'duration_days': 1,
        'updated_at': '2026-03-01T08:00:00.000Z',
      },
    ]);
    h.core.insertIfAbsent('dose_logs', [
      DoseLogModel(
        id: 'd1',
        prescriptionId: 'p1',
        scheduledTime: DateTime.utc(2026, 3, 1, 7),
        updatedAt: DateTime.utc(1970),
      ).toJson(),
    ]);
    await h.a.sync();
    final legacyCursor = DateTime.utc(2026, 3, 5, 7);

    // A's start marks the overdue dose missed and sends it.
    await h.a.run(
      (_) => h.a.doses.markOverduePendingAsMissed(DateTime.utc(2026, 3, 4)),
    );
    expect(h.core.rowsOf('dose_logs')['d1']!['status'], 'missed');
    expect(legacyPull('dose_logs', legacyCursor), isEmpty);

    // The 0.3.0 phone takes it: its stale check sees no newer server copy.
    h.clock = DateTime.utc(2026, 3, 5, 10);
    final legacy = DoseLogModel.fromJson(h.core.rowsOf('dose_logs')['d1']!);
    final serverStamp = DateTime.parse(
      h.core.rowsOf('dose_logs')['d1']!['updated_at'] as String,
    );
    final takeAt = DateTime.utc(2026, 3, 5, 9, 55);
    expect(serverStamp.isAfter(takeAt), isFalse);
    h.core.legacyUpsert(
      'dose_logs',
      DoseLogModel(
        id: legacy.id,
        prescriptionId: legacy.prescriptionId,
        scheduledTime: legacy.scheduledTime,
        status: DoseStatus.taken,
        takenTime: takeAt,
        updatedAt: takeAt,
      ).toJson(),
    );
    await h.a.sync();
    expect((await h.a.row('dose_logs', 'd1'))['status'], 'taken');
  });

  test(
    'a row created offline on 0.4.0 reaches a 0.3.0 cursor that moved on',
    () async {
      h.a.online = false;
      h.clock = DateTime.utc(2026, 3, 5, 8);
      await h.a.run(
        (_) => h.a.treatments.addTreatment(
          Treatment(id: 't2', name: 'Cold', startDate: DateTime(2026, 3, 5)),
        ),
      );
      final legacyCursor = DateTime.utc(2026, 3, 5, 9);
      h.clock = DateTime.utc(2026, 3, 5, 10);
      h.a.online = true;
      await h.a.sync();
      expect(legacyPull('treatments', legacyCursor), contains('t2'));
    },
  );

  test('known limitation: a 0.3.0 absolute quantity replaces a stock change '
      'that landed before it', () async {
    await h.a.run((_) => h.a.medications.updateQuantity('m1', -1));
    expect(h.core.rowsOf('medications')['m1']!['quantity'], 9);
    final legacy = MedicationModel.fromJson(
      h.core.rowsOf('medications')['m1']!,
    ).toJson()..['quantity'] = 10;
    h.clock = DateTime.utc(2026, 3, 5, 9);
    h.core.legacyUpsert('medications', legacy);
    await h.a.sync();
    expect((await h.a.row('medications', 'm1'))['quantity'], 10);
  });
}
```

Run: `fvm flutter test test/services/multi_device_merge_test.dart test/services/mixed_fleet_sync_test.dart test/helpers`
Expected: +12, +8 and `fake_server_test` +8, all passed.

- [ ] **Step 4: The whole suite over HTTP**

Run: `fvm flutter test --dart-define=MEDORA_FAKE_TRANSPORT=http`
Expected: `All tests passed!`, the same count as the plain run.

If a test fails only here, the HTTP path differs from the Dart path. Fix the fake only if it breaks PostgREST's documented behaviour; otherwise the bug is in the app or in the test. The probe found one test that passed on the Dart path by accident (finding 7; already fixed in Task 6).

In `.github/workflows/ci.yml`, job `test`, add after the `TZ=Europe/Rome` step:

```yaml
      # The same suite once more, with every fake table reached through the
      # app's real PostgREST datasources and a fake PostgREST that keeps the
      # server rules (test/helpers/fake_postgrest.dart).
      - name: flutter test (through the real request code)
        run: flutter test --dart-define=MEDORA_FAKE_TRANSPORT=http
```

From this task on, "the gates" include `fvm flutter test --dart-define=MEDORA_FAKE_TRANSPORT=http`.

- [ ] **Step 5: The same scenarios against a real local Supabase**

Apply this patch to `test/integration/sync_convergence_test.dart`. It adds `TwoDeviceRun` (two database files, one open at a time) and two tests:
- **S1:** after both devices sync, both hold `is_active` false, an end date, an end of leave and `CERT-B`. The server holds `[false, 'CERT-B']`.
- **Stock from two devices:** 8 on both devices and the server, and the ledger `[{delta: -1, quantity_after: 9}, {delta: -1, quantity_after: 8}]`.

```diff
--- a/test/integration/sync_convergence_test.dart
+++ b/test/integration/sync_convergence_test.dart
@@ -3,6 +3,8 @@
 /// (the anon key printed by `supabase status`).
 /// Skipped automatically when the defines are absent.
 library;
+
+import 'dart:io';
 
 import 'package:flutter_test/flutter_test.dart';
 import 'package:medora/data/datasources/dose_log_local_datasource.dart';
@@ -20,6 +22,10 @@
 import 'package:medora/data/models/family_member_model.dart';
 import 'package:medora/data/models/family_model.dart';
 import 'package:medora/data/models/medication_model.dart';
+import 'package:medora/data/repositories/medication_repository_impl.dart';
+import 'package:medora/data/repositories/treatment_repository_impl.dart';
+import 'package:medora/domain/entities/medication.dart';
+import 'package:medora/domain/entities/treatment.dart';
 import 'package:medora/services/sync_cursor_store.dart';
 import 'package:medora/services/sync_service.dart';
 import 'package:sqflite_common_ffi/sqflite_ffi.dart';
@@ -113,8 +119,140 @@
     return (client: other, userId: res.user!.id);
   }
 
+  /// Two devices of the signed-in account, each with its own database file
+  /// and cursors; [TwoDeviceRun.on] opens one device's database at a time.
+  Future<TwoDeviceRun> twoDevices() async {
+    final dir = await Directory.systemTemp.createTemp('medora_it_');
+    addTearDown(() async {
+      await AppDatabase.instance.reset();
+      AppDatabase.debugPathOverride = null;
+      await dir.delete(recursive: true);
+    });
+    SyncService service() => SyncService(
+      medicationLocal: MedicationLocalDatasource(),
+      medicationRemote: MedicationRemoteDatasource(client),
+      treatmentLocal: TreatmentLocalDatasource(),
+      treatmentRemote: TreatmentRemoteDatasource(client),
+      prescriptionLocal: PrescriptionLocalDatasource(),
+      prescriptionRemote: PrescriptionRemoteDatasource(client),
+      doseLogLocal: DoseLogLocalDatasource(),
+      doseLogRemote: DoseLogRemoteDatasource(client),
+      familyLocal: FamilyLocalDatasource(),
+      familyRemote: FamilyRemoteDatasource(client),
+      syncState: SyncStateRemoteDatasource(client),
+      cursors: SyncCursorStore.inMemory(),
+      isOnline: () => true,
+      currentUserId: () => userId,
+      onlineStream: const Stream.empty(),
+    );
+    return TwoDeviceRun(
+      paths: ['${dir.path}/a.db', '${dir.path}/b.db'],
+      services: [service(), service()],
+    );
+  }
+
+  const cloudSkip =
+      'Set SUPABASE_URL and SUPABASE_ANON_KEY dart-defines to '
+      'run against a local Supabase';
+
   setUp(setUpTestDatabase);
   tearDown(tearDownTestDatabase);
+
+  test('S1: A ends the illness while B, offline, adds the certificate; both '
+      'changes stay on both devices and the server', () async {
+    final run = await twoDevices();
+    final id = const Uuid().v4();
+    TreatmentRepositoryImpl treatments() => TreatmentRepositoryImpl(
+      localDatasource: TreatmentLocalDatasource(),
+      requestSync: () async {},
+    );
+    await run.on(0, (sync) async {
+      await treatments().addTreatment(
+        Treatment(
+          id: id,
+          name: 'Sinusitis',
+          startDate: DateTime(2026, 3, 2),
+          sickLeaveFrom: DateTime(2026, 3, 2),
+        ),
+      );
+      await sync();
+    });
+    await run.on(1, (sync) => sync());
+    // B, offline: the certificate number.
+    await run.on(1, (_) async {
+      final t = (await treatments().getTreatmentById(id)).dataOrNull!;
+      await treatments().updateTreatment(t.copyWith(sickLeaveRef: 'CERT-B'));
+    });
+    // A ends the illness and syncs first.
+    await run.on(0, (sync) async {
+      await treatments().endTreatment(id, endSickLeave: true);
+      await sync();
+    });
+    await run.on(1, (sync) => sync());
+    await run.on(0, (sync) => sync());
+
+    for (final device in [0, 1]) {
+      await run.on(device, (_) async {
+        final t = (await treatments().getTreatmentById(id)).dataOrNull!;
+        expect(
+          [t.isActive, t.endDate != null, t.sickLeaveTo != null],
+          [false, true, true],
+          reason: 'device $device',
+        );
+        expect(t.sickLeaveRef, 'CERT-B', reason: 'device $device');
+      });
+    }
+    final server = await client
+        .from('treatments')
+        .select('is_active, sick_leave_ref, row_version')
+        .eq('id', id)
+        .single();
+    expect([server['is_active'], server['sick_leave_ref']], [false, 'CERT-B']);
+  }, skip: configured ? false : cloudSkip);
+
+  test('stock from two devices: each takes a tablet offline, 10 -> 8 '
+      'everywhere, one ledger row per change', () async {
+    final run = await twoDevices();
+    final id = const Uuid().v4();
+    MedicationRepositoryImpl medications() => MedicationRepositoryImpl(
+      localDatasource: MedicationLocalDatasource(),
+      requestSync: () async {},
+    );
+    await run.on(0, (sync) async {
+      await medications().addMedication(
+        Medication(id: id, name: 'Ibuprofen 400', quantity: 10),
+      );
+      await sync();
+    });
+    await run.on(1, (sync) => sync());
+    await run.on(1, (_) => medications().updateQuantity(id, -1));
+    await run.on(0, (_) => medications().updateQuantity(id, -1));
+    await run.on(0, (sync) => sync());
+    await run.on(1, (sync) => sync());
+    await run.on(0, (sync) => sync());
+
+    for (final device in [0, 1]) {
+      await run.on(device, (_) async {
+        final m = (await medications().getMedicationById(id)).dataOrNull!;
+        expect(m.quantity, 8, reason: 'device $device');
+      });
+    }
+    final server = await client
+        .from('medications')
+        .select('quantity')
+        .eq('id', id)
+        .single();
+    expect(server['quantity'], 8);
+    final ledger = await client
+        .from('stock_changes')
+        .select('delta, quantity_after')
+        .eq('medication_id', id)
+        .order('quantity_after', ascending: false);
+    expect(ledger, [
+      {'delta': -1, 'quantity_after': 9},
+      {'delta': -1, 'quantity_after': 8},
+    ]);
+  }, skip: configured ? false : cloudSkip);
 
   test(
     'create on A, pull on B, delete on B, gone on A',
@@ -226,3 +364,29 @@
               'against a local Supabase',
   );
 }
+
+/// Two devices, one database open at a time.
+class TwoDeviceRun {
+  TwoDeviceRun({required this.paths, required this.services});
+
+  final List<String> paths;
+  final List<SyncService> services;
+
+  /// Opens device [index]'s database and runs [body] with a function that
+  /// runs one clean sync cycle on that device.
+  Future<void> on(
+    int index,
+    Future<void> Function(Future<void> Function() sync) body,
+  ) async {
+    await AppDatabase.instance.reset();
+    AppDatabase.debugPathOverride = paths[index];
+    await body(() async {
+      final report = (await services[index].syncAll())!;
+      expect(
+        report.isClean,
+        isTrue,
+        reason: '${report.fatal} ${report.failures}',
+      );
+    });
+  }
+}
```

Run: `fvm flutter test test/integration`
Expected: 4 skipped (no defines).

If Docker and the Supabase CLI are available, you may run the suite against a **local** stack. Never point it at a hosted project.
- Work in a scratch worktree, and give it its own project id so its volumes are separate from any local stack the user keeps: `sed -i 's/^project_id = "medora"/project_id = "medora-syncv2-check"/' supabase/config.toml`.
- Start the stack: `supabase start -x studio,edge-runtime,logflare,vector,imgproxy,storage-api,realtime,postgres-meta,mailpit,supavisor`.
- Run: `fvm flutter test test/integration --dart-define=SUPABASE_URL=http://127.0.0.1:54321 --dart-define=SUPABASE_ANON_KEY=<ANON_KEY from supabase status>`.
- Stop the stack: `supabase stop --no-backup --project-id medora-syncv2-check`. The project id limits the stop to that stack's volumes.

Expected: 4 passed. The probe also ran the unchanged v0.3.0 integration suite against this migrated stack: 2 passed. Otherwise, the manual `integration` CI job runs it.

- [ ] **Step 6: Mutation checks (scratch worktree)**

1. In `FakePostgrest._patchById`, pass `ifVersion: null` → with `--dart-define=MEDORA_FAKE_TRANSPORT=http`, these fail: `S1b: A ended it…`, `automatic missed loses to a take made elsewhere` and `same field: the later edit wins…`. The fake enforces the conditional write.
2. In `PostgrestSyncTable.patch`, remove `if (ifStatus != null) query = query.eq('status', ifStatus);`:
   - `table_sync_test` still passes on the Dart path;
   - with `--dart-define=MEDORA_FAKE_TRANSPORT=http`, `a dropped slot is deleted only while pending` fails. This is what the second run is for.

Remove the worktree.

- [ ] **Step 7: Gates and commit**

Run the gates, including the HTTP run. Commit `test(sync): run the suite through a fake PostgREST; two-device and mixed-fleet scenarios` with the test files and `ci.yml`.

---

## Task 9: Documentation, final gates, release hand-over

**Files:**
- Modify: `docs/architecture.md` (the `## Sync` section, rewritten)
- Modify: `docs/release.md` (the checklist, and the hand-written notes for 0.4.0)
- Modify: `docs/superpowers/specs/2026-09-16-sync-v2-design.md` (status line only: "implemented")

**Interfaces:** none.

- [ ] **Step 1: The architecture doc**

In `docs/architecture.md`, replace everything from `## Sync` up to (not including) `## Theme and localization rules` with the text below. It also fixes sick-branch review m-1: the old text said "the edit that reaches the server last wins".

```markdown
## Sync

`SyncService` runs a cycle as check, push, pull, against the sync v2 server
contract (`supabase/migrations/20260918000000_sync_v2.sql`; design in
`docs/superpowers/specs/2026-09-16-sync-v2-design.md`).

**Check.** `medora_sync_state()` returns the schema (2) and a horizon. A
project without the migration (PostgREST `PGRST202`, Postgres `42883`, or a
lower schema) stops the cycle before anything is sent:
`SyncReport.missingMigration` names the file and Settings shows it.

**Bookkeeping.** On the server every synced row carries `sync_xid` (the
transaction that wrote it), `row_version` (+1 per update), `write_id` (the
write attempt; cleared for a writer that sends none or repeats the stored
one) and `edited_at` (when the change was made, capped at the server's
`now()`; `1970-01-01` marks a change the app made on its own). `updated_at`
stays for Medora 0.3.0: an automatic change keeps it, every other write,
inserts included, gets `now()`. Locally (schema v16) each row keeps
`edited_at`, `sync_version` and `sync_base` (the server copy it was last in
step with: the merge base) and `sync_write_id`, stored before a write is sent.

**Push**, in foreign-key order: families, medications, the stock outbox,
treatments, prescriptions, new doses, other doses (`lib/data/sync/
table_sync.dart`). A row with a stored write id is fetched first, so an answer
that never arrived is recognised as this device's own write. An update sends
only the columns changed since the base, conditional on `row_version`; when
the server moved on, the two copies are merged and the rest is sent once more,
otherwise the row waits for the next cycle. A create is inserted where the
server lacks it and read back; another device's copy is merged. New doses go
out **100** per request, then are read back; a batch the server refuses is
sent again row by row, and the doses of a refused prescription wait for it. A
person's delete is a tombstone. A dose dropped by a schedule change is deleted
only while it is still pending on the server, so a dose taken elsewhere
survives and comes back. A row that throws becomes a `SyncFailure`; it is
skipped until `min(2^count minutes, 6 h)` after its last attempt.

**Merge** (`lib/data/sync/row_merge.dart`) is three-way, against the base, per
column group: a treatment's end date and active flag, its sick-leave dates, a
prescription's schedule, its dosage, a dose's status and taken time, a
medication's codes. A group only one side changed takes that side. A group
both changed takes the later `edited_at`; a tie keeps the server's, and an
automatic change never beats a person's. Same-field changes one side lost are
counted in `SyncReport.overwritten`.

**Stock** never travels as a column. Each change waits in `stock_outbox` as a
delta or a counted quantity with its own id, and `apply_stock_change` applies
an id once (ledger `stock_changes`), so a retry never counts twice and changes
from two devices both count, in the order the server receives them. The local
quantity is the server's plus the changes still waiting. A 0.3.0 device still
writes absolute quantities until it is updated.

**Pull** reads each table from its stored key `(sync_xid, id)` up to the
horizon, in keyset pages of **1000** (a hosted project's cap), at most **50**
pages per table per cycle. Every transaction below the horizon has finished,
so a row committed late is never skipped. The key is stored after every fully
applied page; a row that fails to apply holds it for the rest of the cycle; a
key above the horizon starts the table over. A synced local row takes a newer
server copy; a pending one is merged; a local delete wins, except that a
dropped dose taken elsewhere comes back. A tombstone deletes the local row,
unless it is an automatic one and the local row holds a person's change.

**Doses.** Generated doses use the slot's id (`dose_slot.dart`) and the
automatic edit time, and arrive with the pull like any other row. Marking an
overdue dose missed, moving a dose an older build stored at a shifted time
back to its slot, and dropping the pending doses of a changed schedule are
automatic changes: they are pushed and lose to any change a person made
elsewhere. A dose with a change still waiting to be pushed is not swept. On
start and resume the sync runs before the sweep. `DoseScheduleService` still
generates doses for a prescription a pull stored as new or rescheduled.

**Repair.** The first 0.4.0 cycle (`sync.pull_repair.*`, version 2) clears
every pull key and pulls everything once, so every row gets its base; nothing
local is wiped, and a force pull records the repair.

**Force operations.** Force push sends every column with no version condition
and queues every quantity as a count; force pull wipes local rows and the
outbox and re-downloads, aborting if a table cannot be fetched. Families are
pulled separately, through the `join_family` security-definer RPC. Every
request has a **30 s** timeout and fails like a network error. Each cycle
fills a `SyncReport` that Settings renders, offering `discardFailedRow` per
failed row (a stuck stock change is dropped); auto-sync fires **2 s** after
connectivity returns, and a mid-cycle `syncAll()` is queued, up to **3**
re-runs; a sync stopped there retries once **15 s** later.

Schema, RLS, triggers and functions live in `supabase/migrations/`;
`tools/check_supabase_sql.sh` applies them to a throwaway Postgres 15 and
checks the sync rules (CI job `supabase-sql`). The test suite runs a second
time through the real PostgREST datasources against a fake that keeps the
same rules (`--dart-define=MEDORA_FAKE_TRANSPORT=http`).
```

- [ ] **Step 2: The release doc**

In `docs/release.md`, "Release checklist", insert this as the new item 1 and renumber the rest:

```markdown
1. If the release adds a file under `supabase/migrations/`, the project owner
   applies it to the Supabase project **before** the tag is pushed (SQL
   editor or `supabase db push`). Nobody applies it from a development
   session.
```

Under "### Hand-written release notes", append:

```markdown
- **0.4.0 (sync v2)** needs this note, verbatim:

  > **Before you update (cloud sync only):** apply
  > `supabase/migrations/20260918000000_sync_v2.sql` to your Supabase
  > project. Devices still on 0.3.0 keep syncing with it. Without it, 0.4.0
  > stops syncing and Settings names the file.
  >
  > **New: a settings button on every main screen.** Dashboard, Medicines,
  > Treatments and Doses now have the gear at the top right.
  >
  > **Sync keeps both changes.**
  > - Changes to different fields of the same entry on two devices are both
  >   kept. For example, ending an illness on one phone and adding the
  >   certificate number on the other.
  > - If the same field was changed on both, the change made later wins.
  > - A dose taken on one device is never undone by another device marking it
  >   missed.
  > - Stock changes from several devices all count, and a lost connection
  >   never counts one twice.
  > - Doses saved at a shifted time by older versions move back to the right
  >   time, and doses removed from a changed schedule disappear everywhere.
  >
  > **Update every device you sync.** Until the last one is on 0.4.0, stock
  > changed on an older device can still replace a change from a newer one.
  >
  > **The first sync after this update downloads all your data once more.**
  > Your unsynced changes are kept.

  Also in this release: "N more" rows on the Low Stock and Active Treatments
  cards, a message when ending a treatment fails, "ongoing" in lower case in
  the shared episode text, and a week pre-filled when an as-needed
  prescription goes back to a schedule.
```

In the spec's first lines, change `**Status:** proposed.` to `**Status:** implemented.`

- [ ] **Step 3: Final gates**

Run the gates. This includes the HTTP run, then:

```bash
tools/check_supabase_sql.sh
grep -rn "import 'package:medora/services/" lib/data
git status --short                                   # only the files of this task
```

Expected:
- every gate is green;
- the SQL check ends with `sync_v2 checks passed` / `horizon check passed`;
- the grep prints exactly the two older imports the design defers (m-11): `family_repository_impl.dart` → `connectivity_service.dart` and `medication_model.dart` → `photo_storage.dart`. No file this plan touches imports `lib/services/`.

- [ ] **Step 4: Commit**

Commit `docs(sync): describe sync v2 and the 0.4.0 release steps`, with the three docs.

- [ ] **Step 5: Hand over the release (do not run it)**

Report to the user. The release is theirs to run: it touches their Supabase project and pushes a tag. The report contains, in this order:
1. **Merge `sync-v2-settings` into `main`** (review first).
2. **Apply `supabase/migrations/20260918000000_sync_v2.sql`** to the Supabase project (SQL editor, or `supabase db push`). 0.3.0 devices keep working with it.
3. **On `main`, run `tools/release.sh 0.4.0+19`.** It bumps `pubspec.yaml`, commits `chore(release): v0.4.0+19`, tags and pushes. The `Release` workflow builds and publishes.
4. **Paste the 0.4.0 note** from `docs/release.md` into the GitHub release body, above the generated changelog.
5. **Update every synced device.** The first 0.4.0 sync on each device downloads everything once.

Do not run `tools/release.sh`. Do not push. Do not apply the migration. Do not touch any hosted Supabase project.
