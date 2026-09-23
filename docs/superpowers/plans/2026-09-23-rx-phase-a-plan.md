# Prescriptions (Rx) Phase A Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add persons (name, codice fiscale, exemptions) and prescription documents (`Rx`) with items, dispensings, validity/status rules, a pharmacy barcode view, expiry/renewal reminders, backup and cloud sync.

**Architecture:** Three new synced tables (`persons`, `rx`, `rx_dispensings`) follow the existing sync-v2 pattern exactly: repositories write locally as pending and call `requestSync`; `TableSync` merges per column; the server stamps rows with `medora_sync_stamp`. `rx_dispensings` is a child of `rx` (sync parent, tombstone cascade); person/treatment/medication references are soft (no FK, no sync parent). Domain rules (validity, status, tax-code check) are pure Dart. UI lives under `lib/presentation/screens/rx/` and `.../persons/`.

**Tech Stack:** Flutter 3.44.6 via `fvm`, Dart 3.12.2, sqflite (+ ffi in tests), Supabase/PostgREST, Riverpod 3, go_router, flutter_local_notifications, ARB l10n (EN/DE/IT).

**Spec:** `docs/superpowers/specs/2026-09-23-prescription-rx-design.md` (sections 4.1–4.4, 5, 6, 9).

## Global Constraints

- Always use `fvm flutter …` / `fvm dart …` (bare `dart` is 3.13 and formats differently).
- CI gates must pass after every task: `fvm flutter gen-l10n` produces no diff, `fvm dart format --output=none --set-exit-if-changed lib test`, `fvm flutter analyze --fatal-infos`, `fvm flutter test`.
- Every user-visible string goes into `lib/l10n/app_en.arb`, `app_de.arb`, `app_it.arb` (then `fvm flutter gen-l10n`). No hardcoded UI text.
- Every synced write goes through the repository → local datasource (pending) → `requestSyncSoon`. Never push directly.
- Stock changes only via `MedicationRepository.updateQuantity(id, delta)`.
- Local schema: new migration **17** at the end of `kMigrations`, `kSchemaVersion = 17`. Never edit shipped migrations.
- Supabase migration file: `supabase/migrations/20260923000000_rx.sql`; must be applied before devices update; errors must name it.
- Entity name is `Rx` (the existing `Prescription` is the dosing plan). Table names: `persons`, `rx`, `rx_dispensings`.
- Dates that are "date only" are stored as `yyyy-MM-dd` text locally and `date` on the server, like `treatments.start_date`.
- Comment style: doc comments explain *why*, like the surrounding code. Match existing naming.
- Commit after every task with a conventional message (`feat(rx): …`, `test(rx): …`) ending with
  `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`.
- Work in the worktree/branch `rx-phase-a`; agents use their own scratch folder, never copy the repo into `/tmp`.

## File Map

Create:
- `lib/domain/rx/tax_code.dart` — codice fiscale normalise/validate.
- `lib/domain/rx/nre.dart` — NRE normalise/validate.
- `lib/domain/rx/rx_rules.dart` — validity table, book-by hint, status, dispensed packs, pack-size parse.
- `lib/domain/entities/person.dart`, `lib/domain/entities/rx.dart`, `lib/domain/entities/rx_dispensing.dart`.
- `lib/data/models/person_model.dart`, `rx_model.dart`, `rx_dispensing_model.dart`.
- `lib/data/datasources/synced_local_table.dart` — shared pending-write logic for the three new tables.
- `lib/data/datasources/person_local_datasource.dart`, `rx_local_datasource.dart`, `rx_dispensing_local_datasource.dart`.
- `lib/data/datasources/rx_remote_datasource.dart` — the three `PostgrestSyncTable`s.
- `lib/domain/repositories/person_repository.dart`, `rx_repository.dart`.
- `lib/data/repositories/person_repository_impl.dart`, `rx_repository_impl.dart`.
- `lib/presentation/providers/rx_providers.dart`.
- `lib/presentation/screens/persons/person_list_screen.dart`, `person_form_screen.dart`.
- `lib/presentation/screens/rx/rx_list_view.dart`, `rx_form_screen.dart`, `rx_detail_screen.dart`, `pharmacy_screen.dart`, `redeem_sheet.dart`.
- `lib/presentation/widgets/code39.dart` — Code 39 encoder + painter.
- `lib/services/rx_reminders.dart` — rx expiry alert planning.
- `supabase/migrations/20260923000000_rx.sql`.
- Tests mirroring each (paths in tasks).

Modify:
- `lib/data/local/migrations.dart`, `lib/data/local/app_database.dart` (clearAllData).
- `lib/data/sync/sync_meta.dart`, `lib/data/sync/row_merge.dart`, `lib/data/sync/table_sync.dart` (parentsOf), `lib/data/sync/remote_wipe.dart`.
- `lib/services/sync_service.dart`, `lib/presentation/providers/providers.dart`.
- `lib/data/datasources/schema_errors.dart` (missing table).
- `lib/services/stock_expiry_reminders.dart`, `stock_reminder_scheduler.dart`, `reminder_service.dart`, `reminder_port.dart` doc.
- `lib/services/backup_service.dart`, `lib/services/local_upload_marker.dart`, `lib/services/export_service.dart`.
- `lib/presentation/router/app_router.dart`, `screens/treatment/treatment_list_screen.dart`, `treatment_detail_screen.dart`, `settings/settings_screen.dart`, `home/home_screen.dart`.
- `test/helpers/fake_server.dart`.

---

### Task 1: Tax code, NRE and the validity table (with source check)

**Files:**
- Create: `lib/domain/rx/tax_code.dart`, `lib/domain/rx/nre.dart`, `lib/domain/rx/rx_rules.dart` (validity part only)
- Test: `test/domain/rx/tax_code_test.dart`, `test/domain/rx/nre_test.dart`, `test/domain/rx/rx_validity_test.dart`

**Interfaces:**
- Produces:
  - `abstract final class TaxCode { static String normalize(String raw); static bool isValid(String raw); }`
  - `abstract final class Nre { static String normalize(String raw); static bool isValid(String raw); }`
  - `enum RxKind { ssn, white, whiteRepeatable, referral }` with `String get wire` (`ssn`, `white`, `white_repeatable`, `referral`) and `static RxKind fromWire(String?)` (unknown → `ssn`).
  - `enum RxPriority { u, b, d, p }` with `String get wire` (`U`,`B`,`D`,`P`) and `static RxPriority? fromWire(String?)`.
  - `abstract final class RxValidity { static DateTime? defaultValidUntil(RxKind kind, DateTime issuedOn); static int? defaultMaxDispensings(RxKind kind); static DateTime bookBy(RxPriority p, DateTime issuedOn); }`

- [ ] **Step 1: Verify the rule values against sources**

Use WebSearch/WebFetch (Italian: "validità ricetta SSN 30 giorni escluso giorno emissione", "ricetta ripetibile validità 6 mesi 10 confezioni", "classi di priorità U B D P tempi"; also ASDAA/Provincia Bolzano pages "Rezept Gültigkeit Südtirol"). For each of: SSN validity, white non-repeatable validity, white repeatable validity and max dispensings, priority U/B/D/P deadlines — record value + URL. If a source contradicts a value below, use the source's value in the code and the tests, and note the change in the commit message. Expected defaults (to be confirmed):

| Rule | Value | Counting |
|---|---|---|
| SSN | 30 days | issue day excluded → `issuedOn + 30 days` is the last valid day |
| white | 30 days | same |
| white repeatable | 6 months, max 10 dispensings | `issuedOn + 6 months` |
| referral | none (user enters) | — |
| book-by U / B / D / P | 3 / 10 / 30 / 120 days | `issuedOn + n days` |

- [ ] **Step 2: Write the failing tests**

`test/domain/rx/tax_code_test.dart`:
```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/domain/rx/tax_code.dart';

void main() {
  test('accepts valid codes and their normalised forms', () {
    expect(TaxCode.isValid('RSSMRA85T10A562S'), isTrue);
    expect(TaxCode.isValid('rssmra85t10a562s'), isTrue);
    expect(TaxCode.isValid(' RSS MRA 85T10 A562S '), isTrue);
    expect(TaxCode.isValid('MRTMTT25D09F205Z'), isTrue);
  });

  test('rejects a wrong check character', () {
    expect(TaxCode.isValid('RSSMRA85T10A562T'), isFalse);
  });

  test('rejects wrong length and alphabet', () {
    expect(TaxCode.isValid('RSSMRA85T10A562'), isFalse);
    expect(TaxCode.isValid('RSSMRA85T10A56!S'), isFalse);
    expect(TaxCode.isValid(''), isFalse);
  });

  test('accepts omocodia (digits replaced by LMNPQRSTUV)', () {
    // 85 -> RS in the year; check character recomputed for the new code.
    const omocode = 'RSSMRARST10A562S';
    final expected = TaxCode.checkCharacter(omocode.substring(0, 15));
    expect(
      TaxCode.isValid('${omocode.substring(0, 15)}$expected'),
      isTrue,
    );
  });

  test('normalize strips whitespace and upper-cases', () {
    expect(TaxCode.normalize(' rss mra85t10a562s\n'), 'RSSMRA85T10A562S');
  });
}
```

`test/domain/rx/nre_test.dart`:
```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/domain/rx/nre.dart';

void main() {
  test('15 alphanumeric characters are valid', () {
    expect(Nre.isValid('0410A1234567890'), isTrue);
    expect(Nre.isValid('0410a 12345 67890'), isTrue);
  });

  test('other lengths or symbols are not', () {
    expect(Nre.isValid('0410A123456789'), isFalse);
    expect(Nre.isValid('0410A12345678901'), isFalse);
    expect(Nre.isValid('0410A-234567890'), isFalse);
  });

  test('normalize strips whitespace and upper-cases', () {
    expect(Nre.normalize(' 0410a 12345 67890 '), '0410A1234567890');
  });
}
```

`test/domain/rx/rx_validity_test.dart`:
```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/domain/rx/rx_rules.dart';

void main() {
  final issued = DateTime(2026, 9, 23);

  test('SSN and white prescriptions are valid 30 days after issue', () {
    expect(
      RxValidity.defaultValidUntil(RxKind.ssn, issued),
      DateTime(2026, 10, 23),
    );
    expect(
      RxValidity.defaultValidUntil(RxKind.white, issued),
      DateTime(2026, 10, 23),
    );
  });

  test('a repeatable white prescription lasts six months, ten dispensings',
      () {
    expect(
      RxValidity.defaultValidUntil(RxKind.whiteRepeatable, issued),
      DateTime(2027, 3, 23),
    );
    expect(RxValidity.defaultMaxDispensings(RxKind.whiteRepeatable), 10);
    expect(RxValidity.defaultMaxDispensings(RxKind.ssn), isNull);
  });

  test('six months from 31 August clamps to the month end', () {
    expect(
      RxValidity.defaultValidUntil(RxKind.whiteRepeatable, DateTime(2026, 8, 31)),
      DateTime(2027, 2, 28),
    );
  });

  test('a referral has no default validity', () {
    expect(RxValidity.defaultValidUntil(RxKind.referral, issued), isNull);
  });

  test('book-by dates follow the priority class', () {
    expect(RxValidity.bookBy(RxPriority.u, issued), DateTime(2026, 9, 26));
    expect(RxValidity.bookBy(RxPriority.b, issued), DateTime(2026, 10, 3));
    expect(RxValidity.bookBy(RxPriority.d, issued), DateTime(2026, 10, 23));
    expect(RxValidity.bookBy(RxPriority.p, issued), DateTime(2027, 1, 21));
  });

  test('wire names round-trip, unknown kinds read as SSN', () {
    for (final k in RxKind.values) {
      expect(RxKind.fromWire(k.wire), k);
    }
    expect(RxKind.fromWire('nonsense'), RxKind.ssn);
    expect(RxPriority.fromWire('B'), RxPriority.b);
    expect(RxPriority.fromWire(null), isNull);
  });
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `fvm flutter test test/domain/rx/`
Expected: FAIL — `Target of URI doesn't exist: 'package:medora/domain/rx/tax_code.dart'`.

- [ ] **Step 4: Implement**

`lib/domain/rx/tax_code.dart`:
```dart
/// Medora - Italian tax code (codice fiscale) of a person.
///
/// The pharmacy reads it with the prescription number, so a typo means a
/// wasted trip: the check character catches nearly every one.
library;

abstract final class TaxCode {
  /// Upper-case, whitespace removed: how the code is stored and compared.
  static String normalize(String raw) =>
      raw.replaceAll(RegExp(r'\s'), '').toUpperCase();

  /// Letters for the name parts, digits (or their omocodia letters
  /// LMNPQRSTUV) for year, day and municipality number.
  static final _shape = RegExp(
    r'^[A-Z]{6}[0-9LMNPQRSTUV]{2}[ABCDEHLMPRST][0-9LMNPQRSTUV]{2}'
    r'[A-Z][0-9LMNPQRSTUV]{3}[A-Z]$',
  );

  static bool isValid(String raw) {
    final code = normalize(raw);
    if (!_shape.hasMatch(code)) return false;
    return checkCharacter(code.substring(0, 15)) == code[15];
  }

  /// The check character of the first fifteen characters [head].
  static String checkCharacter(String head) {
    var sum = 0;
    for (var i = 0; i < 15; i++) {
      final c = head[i];
      // Positions are counted from 1, so index 0 is an odd position.
      sum += i.isEven ? _odd[c]! : _even(c);
    }
    return String.fromCharCode(0x41 + sum % 26);
  }

  static int _even(String c) {
    final unit = c.codeUnitAt(0);
    return unit <= 0x39 ? unit - 0x30 : unit - 0x41;
  }

  static const _odd = {
    '0': 1, '1': 0, '2': 5, '3': 7, '4': 9, '5': 13, '6': 15, '7': 17, //
    '8': 19, '9': 21, 'A': 1, 'B': 0, 'C': 5, 'D': 7, 'E': 9, 'F': 13, //
    'G': 15, 'H': 17, 'I': 19, 'J': 21, 'K': 2, 'L': 4, 'M': 18, 'N': 20,
    'O': 11, 'P': 3, 'Q': 6, 'R': 8, 'S': 12, 'T': 14, 'U': 16, 'V': 10,
    'W': 22, 'X': 25, 'Y': 24, 'Z': 23,
  };
}
```
(`dart format` will reflow the map; keep the values.)

`lib/domain/rx/nre.dart`:
```dart
/// Medora - Electronic prescription number (NRE, numero di ricetta
/// elettronica).
///
/// Only the shape is checked: the regional prefix varies and a wrong
/// guess about it must never block saving a real prescription.
library;

abstract final class Nre {
  static String normalize(String raw) =>
      raw.replaceAll(RegExp(r'\s'), '').toUpperCase();

  static final _shape = RegExp(r'^[0-9A-Z]{15}$');

  static bool isValid(String raw) => _shape.hasMatch(normalize(raw));
}
```

`lib/domain/rx/rx_rules.dart` (validity part; Task 2 appends status rules):
```dart
/// Medora - Rules of an Italian prescription: how long it is valid, when a
/// referral should be booked, and what state it is in.
///
/// The numbers live here and nowhere else. Sources (checked 2026-09-23):
/// - SSN / white validity: <URL from Task 1 step 1>
/// - repeatable white prescriptions: <URL>
/// - priority classes U/B/D/P: <URL>
library;

enum RxKind {
  ssn('ssn'),
  white('white'),
  whiteRepeatable('white_repeatable'),
  referral('referral');

  const RxKind(this.wire);
  final String wire;

  static RxKind fromWire(String? raw) =>
      values.firstWhere((k) => k.wire == raw, orElse: () => RxKind.ssn);
}

enum RxPriority {
  u('U', 3),
  b('B', 10),
  d('D', 30),
  p('P', 120);

  const RxPriority(this.wire, this.bookWithinDays);
  final String wire;

  /// Days from issue within which the visit should take place.
  final int bookWithinDays;

  static RxPriority? fromWire(String? raw) {
    for (final p in values) {
      if (p.wire == raw) return p;
    }
    return null;
  }
}

abstract final class RxValidity {
  static const _days = {RxKind.ssn: 30, RxKind.white: 30};
  static const _repeatableMonths = 6;
  static const _repeatableDispensings = 10;

  /// The last valid day of a prescription issued on [issuedOn], or null when
  /// the kind has no fixed validity (a referral: the user enters it).
  ///
  /// The issue day does not count, so 30 days from 23 September is
  /// 23 October.
  static DateTime? defaultValidUntil(RxKind kind, DateTime issuedOn) {
    final day = DateTime(issuedOn.year, issuedOn.month, issuedOn.day);
    final days = _days[kind];
    if (days != null) return DateTime(day.year, day.month, day.day + days);
    if (kind == RxKind.whiteRepeatable) {
      return _addMonths(day, _repeatableMonths);
    }
    return null;
  }

  static int? defaultMaxDispensings(RxKind kind) =>
      kind == RxKind.whiteRepeatable ? _repeatableDispensings : null;

  static DateTime bookBy(RxPriority priority, DateTime issuedOn) => DateTime(
    issuedOn.year,
    issuedOn.month,
    issuedOn.day + priority.bookWithinDays,
  );

  /// [months] later, on the same day or the month's last day when that
  /// month is shorter (31 August + 6 months = 28 February).
  static DateTime _addMonths(DateTime day, int months) {
    final firstOfTarget = DateTime(day.year, day.month + months);
    final lastDay = DateTime(firstOfTarget.year, firstOfTarget.month + 1, 0).day;
    return DateTime(
      firstOfTarget.year,
      firstOfTarget.month,
      day.day > lastDay ? lastDay : day.day,
    );
  }
}
```
Replace the three `<URL …>` markers with the URLs recorded in Step 1.

- [ ] **Step 5: Run tests to verify they pass**

Run: `fvm flutter test test/domain/rx/`
Expected: PASS (all).

- [ ] **Step 6: Format, analyze, commit**

```bash
fvm dart format lib/domain/rx test/domain/rx
fvm flutter analyze --fatal-infos
git add lib/domain/rx test/domain/rx
git commit -m "feat(rx): tax code, NRE and prescription validity rules"
```

---

### Task 2: Entities and status rules

**Files:**
- Create: `lib/domain/entities/person.dart`, `lib/domain/entities/rx.dart`, `lib/domain/entities/rx_dispensing.dart`
- Modify: `lib/domain/rx/rx_rules.dart` (append status + pack size)
- Test: `test/domain/rx/rx_status_test.dart`

**Interfaces:**
- Consumes: `RxKind`, `RxPriority`, `RxValidity` (Task 1).
- Produces:
  - `class Person { id, userId?, name, taxCode?, exemptions (List<String>), notes?, createdAt?, updatedAt?; copyWith(...) }`
  - `class RxItem { id, medicationId?, aic?, description, packs (int), nonSubstitutable (bool); Map<String,Object?> toJson(); factory RxItem.fromJson(Map); copyWith }`
  - `class Rx { id, userId?, personId?, treatmentId?, kind, nre?, issuedOn, validUntil?, doctor?, exemptionCode?, priority?, maxDispensings?, items (List<RxItem>), closedOn?, cancelled, notes?, createdAt?, updatedAt?; copyWith }`
  - `class RxDispensing { id, userId?, rxId, itemId, packs, dispensedOn, pharmacy?, unitsAdded, createdAt?, updatedAt? }`
  - `enum RxStatus { open, partial, redeemed, expired, cancelled }`
  - `abstract final class RxRules { static Map<String,int> dispensedPacks(List<RxDispensing>); static RxStatus statusOf(Rx rx, List<RxDispensing> dispensings, DateTime now); static int? daysLeft(Rx rx, DateTime now); static int? packSizeOf(String description); }`

- [ ] **Step 1: Write the failing test**

`test/domain/rx/rx_status_test.dart`:
```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/domain/entities/rx.dart';
import 'package:medora/domain/entities/rx_dispensing.dart';
import 'package:medora/domain/rx/rx_rules.dart';

void main() {
  final now = DateTime(2026, 9, 23, 10);
  const item = RxItem(id: 'i1', description: 'Tachipirina 20 compresse', packs: 2);
  const other = RxItem(id: 'i2', description: 'Brufen', packs: 1);
  final rx = Rx(
    id: 'r1',
    kind: RxKind.ssn,
    issuedOn: DateTime(2026, 9, 20),
    validUntil: DateTime(2026, 10, 20),
    items: const [item, other],
  );
  RxDispensing give(String itemId, int packs) => RxDispensing(
    id: '$itemId-$packs',
    rxId: 'r1',
    itemId: itemId,
    packs: packs,
    dispensedOn: DateTime(2026, 9, 22),
  );

  test('no dispensing: open', () {
    expect(RxRules.statusOf(rx, const [], now), RxStatus.open);
  });

  test('some packs dispensed: partial', () {
    expect(RxRules.statusOf(rx, [give('i1', 1)], now), RxStatus.partial);
  });

  test('every item fully dispensed: redeemed', () {
    expect(
      RxRules.statusOf(rx, [give('i1', 1), give('i1', 1), give('i2', 1)], now),
      RxStatus.redeemed,
    );
  });

  test('closed by hand: redeemed, even without dispensings', () {
    expect(
      RxRules.statusOf(rx.copyWith(closedOn: DateTime(2026, 9, 21)), const [], now),
      RxStatus.redeemed,
    );
  });

  test('past its last valid day: expired; the last day itself is valid', () {
    expect(
      RxRules.statusOf(rx, const [], DateTime(2026, 10, 20, 23, 59)),
      RxStatus.open,
    );
    expect(
      RxRules.statusOf(rx, const [], DateTime(2026, 10, 21)),
      RxStatus.expired,
    );
  });

  test('cancelled wins over everything', () {
    expect(
      RxRules.statusOf(rx.copyWith(cancelled: true), [give('i1', 2)], now),
      RxStatus.cancelled,
    );
  });

  test('redeemed wins over expired', () {
    expect(
      RxRules.statusOf(
        rx,
        [give('i1', 2), give('i2', 1)],
        DateTime(2026, 12, 1),
      ),
      RxStatus.redeemed,
    );
  });

  test('a repeatable prescription is redeemed after its max dispensings', () {
    final rep = rx.copyWith(kind: RxKind.whiteRepeatable, maxDispensings: 2);
    expect(RxRules.statusOf(rep, [give('i1', 1)], now), RxStatus.partial);
    expect(
      RxRules.statusOf(rep, [give('i1', 1), give('i2', 1)], now),
      RxStatus.redeemed,
    );
  });

  test('an rx without items and without closedOn stays open', () {
    final referral = Rx(
      id: 'r2',
      kind: RxKind.referral,
      issuedOn: DateTime(2026, 9, 20),
    );
    expect(RxRules.statusOf(referral, const [], now), RxStatus.open);
  });

  test('dispensedPacks sums per item', () {
    expect(RxRules.dispensedPacks([give('i1', 1), give('i1', 1), give('i2', 1)]),
        {'i1': 2, 'i2': 1});
  });

  test('daysLeft counts calendar days to the last valid day', () {
    expect(RxRules.daysLeft(rx, now), 27);
    expect(RxRules.daysLeft(rx, DateTime(2026, 10, 20, 22)), 0);
    expect(
      RxRules.daysLeft(
        Rx(id: 'x', kind: RxKind.referral, issuedOn: DateTime(2026, 9, 1)),
        now,
      ),
      isNull,
    );
  });

  test('packSizeOf reads the count in a pack description', () {
    expect(RxRules.packSizeOf('Tachipirina 500 mg 20 compresse'), 20);
    expect(RxRules.packSizeOf('Brufen 400mg 30 cpr rivestite'), 30);
    expect(RxRules.packSizeOf('Aspirin 20 Tabletten'), 20);
    expect(RxRules.packSizeOf('Sciroppo 150 ml'), isNull);
    expect(RxRules.packSizeOf('Brufen'), isNull);
  });
}
```

- [ ] **Step 2: Run to verify failure**

Run: `fvm flutter test test/domain/rx/rx_status_test.dart`
Expected: FAIL — missing `package:medora/domain/entities/rx.dart`.

- [ ] **Step 3: Implement entities**

`lib/domain/entities/person.dart`:
```dart
/// Medora - A person prescriptions are written for.
///
/// Treatments name patients by free-text tag; a person adds what a
/// pharmacy needs (the tax code) and what changes the cost (exemptions).
/// The two meet by name only, so tags keep working unchanged.
library;

class Person {
  const Person({
    required this.id,
    this.userId,
    required this.name,
    this.taxCode,
    this.exemptions = const [],
    this.notes,
    this.createdAt,
    this.updatedAt,
  });

  final String id;
  final String? userId;
  final String name;

  /// Normalised codice fiscale (see `TaxCode.normalize`), or null.
  final String? taxCode;

  /// Exemption codes (esenzioni), e.g. "E01", "048".
  final List<String> exemptions;
  final String? notes;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  /// True when [tag] (a treatment's patient tag) names this person.
  bool matchesTag(String tag) =>
      tag.trim().toLowerCase() == name.trim().toLowerCase();

  /// A null argument keeps the current value (codebase convention).
  Person copyWith({
    String? id,
    String? userId,
    String? name,
    String? taxCode,
    List<String>? exemptions,
    String? notes,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) => Person(
    id: id ?? this.id,
    userId: userId ?? this.userId,
    name: name ?? this.name,
    taxCode: taxCode ?? this.taxCode,
    exemptions: exemptions ?? this.exemptions,
    notes: notes ?? this.notes,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );
}
```

`lib/domain/entities/rx.dart`:
```dart
/// Medora - A prescription document (Rezept / ricetta).
///
/// Not to be confused with `Prescription`, which is a dosing plan inside a
/// treatment. An [Rx] is the paper or electronic prescription a pharmacy
/// dispenses against.
library;

import 'package:medora/domain/rx/rx_rules.dart';

class RxItem {
  const RxItem({
    required this.id,
    this.medicationId,
    this.aic,
    required this.description,
    this.packs = 1,
    this.nonSubstitutable = false,
  });

  factory RxItem.fromJson(Map<String, dynamic> json) => RxItem(
    id: json['id'] as String,
    medicationId: json['medication_id'] as String?,
    aic: json['aic'] as String?,
    description: json['description'] as String? ?? '',
    packs: (json['packs'] as num?)?.toInt() ?? 1,
    nonSubstitutable: json['non_substitutable'] == true,
  );

  final String id;

  /// Soft reference to a medication in the cabinet (may dangle).
  final String? medicationId;
  final String? aic;
  final String description;
  final int packs;

  /// "Non sostituibile": the pharmacy may not hand out a generic.
  final bool nonSubstitutable;

  Map<String, Object?> toJson() => {
    'id': id,
    'medication_id': medicationId,
    'aic': aic,
    'description': description,
    'packs': packs,
    'non_substitutable': nonSubstitutable,
  };

  RxItem copyWith({
    String? medicationId,
    String? aic,
    String? description,
    int? packs,
    bool? nonSubstitutable,
  }) => RxItem(
    id: id,
    medicationId: medicationId ?? this.medicationId,
    aic: aic ?? this.aic,
    description: description ?? this.description,
    packs: packs ?? this.packs,
    nonSubstitutable: nonSubstitutable ?? this.nonSubstitutable,
  );
}

class Rx {
  const Rx({
    required this.id,
    this.userId,
    this.personId,
    this.treatmentId,
    required this.kind,
    this.nre,
    required this.issuedOn,
    this.validUntil,
    this.doctor,
    this.exemptionCode,
    this.priority,
    this.maxDispensings,
    this.items = const [],
    this.closedOn,
    this.cancelled = false,
    this.notes,
    this.createdAt,
    this.updatedAt,
  });

  final String id;
  final String? userId;

  /// Soft references: a deleted person or treatment leaves them dangling.
  final String? personId;
  final String? treatmentId;
  final RxKind kind;

  /// Normalised NRE; null for a white prescription.
  final String? nre;

  /// Date only.
  final DateTime issuedOn;

  /// Last valid day (date only); null when unknown (a referral).
  final DateTime? validUntil;
  final String? doctor;
  final String? exemptionCode;

  /// Referral priority class; null for other kinds.
  final RxPriority? priority;

  /// Repeatable white prescriptions only.
  final int? maxDispensings;
  final List<RxItem> items;

  /// Set when the user marks the prescription done by hand (a referral
  /// used, a prescription collected elsewhere).
  final DateTime? closedOn;
  final bool cancelled;
  final String? notes;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  /// A null argument keeps the current value (codebase convention); build a
  /// new [Rx] to clear a field.
  Rx copyWith({
    String? id,
    String? userId,
    String? personId,
    String? treatmentId,
    RxKind? kind,
    String? nre,
    DateTime? issuedOn,
    DateTime? validUntil,
    String? doctor,
    String? exemptionCode,
    RxPriority? priority,
    int? maxDispensings,
    List<RxItem>? items,
    DateTime? closedOn,
    bool? cancelled,
    String? notes,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) => Rx(
    id: id ?? this.id,
    userId: userId ?? this.userId,
    personId: personId ?? this.personId,
    treatmentId: treatmentId ?? this.treatmentId,
    kind: kind ?? this.kind,
    nre: nre ?? this.nre,
    issuedOn: issuedOn ?? this.issuedOn,
    validUntil: validUntil ?? this.validUntil,
    doctor: doctor ?? this.doctor,
    exemptionCode: exemptionCode ?? this.exemptionCode,
    priority: priority ?? this.priority,
    maxDispensings: maxDispensings ?? this.maxDispensings,
    items: items ?? this.items,
    closedOn: closedOn ?? this.closedOn,
    cancelled: cancelled ?? this.cancelled,
    notes: notes ?? this.notes,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );
}
```

`lib/domain/entities/rx_dispensing.dart`:
```dart
/// Medora - One collection of packs at a pharmacy against an [Rx] item.
///
/// Its own row, never a counter on the item: two devices recording a
/// collection at once both keep theirs (a counter would lose one to the
/// whole-row merge).
library;

class RxDispensing {
  const RxDispensing({
    required this.id,
    this.userId,
    required this.rxId,
    required this.itemId,
    required this.packs,
    required this.dispensedOn,
    this.pharmacy,
    this.unitsAdded = 0,
    this.createdAt,
    this.updatedAt,
  });

  final String id;
  final String? userId;
  final String rxId;

  /// `RxItem.id` within the prescription's items.
  final String itemId;
  final int packs;

  /// Date only.
  final DateTime dispensedOn;
  final String? pharmacy;

  /// Units put into the medication's stock when collected (0 = none).
  final int unitsAdded;
  final DateTime? createdAt;
  final DateTime? updatedAt;
}
```

- [ ] **Step 4: Append the status rules to `lib/domain/rx/rx_rules.dart`**

Add imports at the top (after `library;`):
```dart
import 'package:medora/core/clock.dart';
import 'package:medora/domain/entities/rx.dart';
import 'package:medora/domain/entities/rx_dispensing.dart';
```
Append:
```dart
enum RxStatus { open, partial, redeemed, expired, cancelled }

abstract final class RxRules {
  /// Packs collected per item id.
  static Map<String, int> dispensedPacks(List<RxDispensing> dispensings) {
    final sums = <String, int>{};
    for (final d in dispensings) {
      sums[d.itemId] = (sums[d.itemId] ?? 0) + d.packs;
    }
    return sums;
  }

  /// The state of [rx] at [now], given its [dispensings]. Never stored:
  /// "expired" changes with the date alone.
  ///
  /// Order matters: a cancelled prescription is cancelled whatever was
  /// collected, and one fully collected is redeemed even after its last
  /// valid day.
  static RxStatus statusOf(
    Rx rx,
    List<RxDispensing> dispensings,
    DateTime now,
  ) {
    if (rx.cancelled) return RxStatus.cancelled;
    if (rx.closedOn != null || _fullyDispensed(rx, dispensings)) {
      return RxStatus.redeemed;
    }
    final left = daysLeft(rx, now);
    if (left != null && left < 0) return RxStatus.expired;
    return dispensings.isEmpty ? RxStatus.open : RxStatus.partial;
  }

  static bool _fullyDispensed(Rx rx, List<RxDispensing> dispensings) {
    final max = rx.maxDispensings;
    if (max != null) return dispensings.length >= max;
    if (rx.items.isEmpty) return false;
    final given = dispensedPacks(dispensings);
    return rx.items.every((i) => (given[i.id] ?? 0) >= i.packs);
  }

  /// Calendar days from [now] to the last valid day: 0 on that day,
  /// negative once it has passed, null when no validity is known.
  static int? daysLeft(Rx rx, DateTime now) {
    final until = rx.validUntil;
    return until == null ? null : calendarDaysBetween(now, until);
  }

  /// Units in one pack, read from a pack description ("20 compresse",
  /// "30 cpr", "20 Tabletten"); null for volumes or when none is named.
  static int? packSizeOf(String description) {
    final match = _packCount.firstMatch(description.toLowerCase());
    return match == null ? null : int.tryParse(match.group(1)!);
  }

  static final _packCount = RegExp(
    r'(\d+)\s*(?:compresse|compressa|cpr|cp|capsule|caps|cps|bustine|'
    r'tabletten|tabl|kapseln|stück|stk|tablets|capsules|pz|pezzi)\b',
  );
}
```
`calendarDaysBetween(from, to)` (`lib/core/clock.dart:18`) returns `to - from` in calendar days, ignoring the time of day.

- [ ] **Step 5: Run tests**

Run: `fvm flutter test test/domain/rx/`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
fvm dart format lib/domain test/domain
fvm flutter analyze --fatal-infos
git add lib/domain test/domain
git commit -m "feat(rx): person, prescription and dispensing entities with status rules"
```

---

### Task 3: Local schema, models and local datasources

**Files:**
- Modify: `lib/data/local/migrations.dart`, `lib/data/local/app_database.dart:244-254`
- Create: `lib/data/models/person_model.dart`, `lib/data/models/rx_model.dart`, `lib/data/models/rx_dispensing_model.dart`, `lib/data/datasources/synced_local_table.dart`, `lib/data/datasources/person_local_datasource.dart`, `lib/data/datasources/rx_local_datasource.dart`, `lib/data/datasources/rx_dispensing_local_datasource.dart`
- Test: `test/data/local/app_database_test.dart` (add a case), `test/data/datasources/rx_local_datasource_test.dart`

**Interfaces:**
- Consumes: entities from Task 2.
- Produces:
  - Models with `fromJson` (server row), `fromLocalMap` (sqlite row), `toJson` (wire copy, keys = server columns), `toDomain()`, `fromDomain(entity)`, `copyWith`, field `deletedAt`.
  - `class SyncedLocalTable<M>` with `upsert(M, {required String syncStatus})`, `markDeleted(String id)`, `getById(String id)`, `getAll({String? where, List<Object?>? whereArgs, String? orderBy})`, `hardDelete`, `clearAll`.
  - `PersonLocalDatasource`, `RxLocalDatasource`, `RxDispensingLocalDatasource`, each with `static Map<String, dynamic> rowOf(Model, String syncStatus, {Now now})` and `static Map<String, Object?> wireOf(Map<String, Object?> row)` (used by sync_meta in Task 4), plus:
    - Person: `getPersons()`, `getPersonById(id)`, `getByTaxCode(code)`.
    - Rx: `getAll()`, `getById(id)`, `getByNre(nre)`, `getForTreatment(treatmentId)`.
    - Dispensing: `getForRx(rxId)`, `getForRxIds(List<String>)`.

- [ ] **Step 1: Write the failing migration test**

Add to `test/data/local/app_database_test.dart` (inside `main`, reuse its setup helpers):
```dart
  test('migration 17 creates the prescription tables', () async {
    await setUpTestDatabase();
    final db = await AppDatabase.instance.database;
    for (final table in ['persons', 'rx', 'rx_dispensings']) {
      final columns = (await db.rawQuery('PRAGMA table_info($table)'))
          .map((c) => c['name'])
          .toSet();
      expect(
        columns,
        containsAll(<String>[
          'id',
          'user_id',
          'created_at',
          'updated_at',
          'deleted_at',
          'sync_status',
          'edited_at',
          'field_edited_at',
          'sync_version',
          'sync_base',
          'sync_write_id',
        ]),
        reason: table,
      );
    }
    final fks = await db.rawQuery('PRAGMA foreign_key_list(rx_dispensings)');
    expect(fks.single['table'], 'rx');
    expect(fks.single['on_delete'], 'CASCADE');
    await tearDownTestDatabase();
  });
```
(If the file uses a different setup style, follow it; the assertions stay.)

- [ ] **Step 2: Run to verify it fails**

Run: `fvm flutter test test/data/local/app_database_test.dart`
Expected: FAIL — `no such table: persons` (empty column set).

- [ ] **Step 3: Add migration 17**

In `lib/data/local/migrations.dart` set `const int kSchemaVersion = 17;` and append to `kMigrations`:
```dart
  // v17: prescriptions (spec 2026-09-23 §4). Persons and prescriptions are
  // roots; a dispensing belongs to its prescription and goes with it. A
  // prescription names its person, treatment and medications without a
  // foreign key: deleting one of those must never take a prescription with
  // it. Created with every sync-v2 bookkeeping column from the start.
  Migration(17, (db) async {
    const sync = '''
        created_at TEXT,
        updated_at TEXT,
        deleted_at TEXT,
        sync_status TEXT NOT NULL DEFAULT 'synced',
        edited_at TEXT,
        field_edited_at TEXT,
        sync_version INTEGER,
        sync_base TEXT,
        sync_write_id TEXT''';
    await db.execute('''
      CREATE TABLE persons (
        id TEXT PRIMARY KEY,
        user_id TEXT,
        name TEXT NOT NULL,
        tax_code TEXT,
        exemptions TEXT,
        notes TEXT,
$sync
      )
    ''');
    await db.execute('''
      CREATE TABLE rx (
        id TEXT PRIMARY KEY,
        user_id TEXT,
        person_id TEXT,
        treatment_id TEXT,
        kind TEXT NOT NULL,
        nre TEXT,
        issued_on TEXT NOT NULL,
        valid_until TEXT,
        doctor TEXT,
        exemption_code TEXT,
        priority TEXT,
        max_dispensings INTEGER,
        items TEXT NOT NULL DEFAULT '[]',
        closed_on TEXT,
        cancelled INTEGER NOT NULL DEFAULT 0,
        notes TEXT,
$sync
      )
    ''');
    await db.execute('CREATE INDEX idx_local_rx_nre ON rx(nre)');
    await db.execute('CREATE INDEX idx_local_rx_treatment ON rx(treatment_id)');
    await db.execute('''
      CREATE TABLE rx_dispensings (
        id TEXT PRIMARY KEY,
        user_id TEXT,
        rx_id TEXT NOT NULL REFERENCES rx(id) ON DELETE CASCADE,
        item_id TEXT NOT NULL,
        packs INTEGER NOT NULL,
        dispensed_on TEXT NOT NULL,
        pharmacy TEXT,
        units_added INTEGER NOT NULL DEFAULT 0,
$sync
      )
    ''');
    await db.execute(
      'CREATE INDEX idx_local_rx_disp_rx ON rx_dispensings(rx_id)',
    );
  }),
```
In `AppDatabase.clearAllData()` add, before `await db.delete('medications');`:
```dart
    await db.delete('rx_dispensings');
    await db.delete('rx');
    await db.delete('persons');
```

- [ ] **Step 4: Run migration test**

Run: `fvm flutter test test/data/local/app_database_test.dart`
Expected: PASS.

- [ ] **Step 5: Write the failing datasource test**

`test/data/datasources/rx_local_datasource_test.dart`:
```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/data/datasources/person_local_datasource.dart';
import 'package:medora/data/datasources/rx_dispensing_local_datasource.dart';
import 'package:medora/data/datasources/rx_local_datasource.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/models/person_model.dart';
import 'package:medora/data/models/rx_dispensing_model.dart';
import 'package:medora/data/models/rx_model.dart';
import 'package:medora/domain/entities/rx.dart';
import 'package:medora/domain/rx/rx_rules.dart';

import '../../helpers/test_database.dart';

void main() {
  setUp(setUpTestDatabase);
  tearDown(tearDownTestDatabase);

  final at = DateTime(2026, 9, 23, 9);
  final rx = RxModel(
    id: 'r1',
    personId: 'p1',
    kind: RxKind.ssn,
    nre: '0410A1234567890',
    issuedOn: DateTime(2026, 9, 20),
    validUntil: DateTime(2026, 10, 20),
    priority: null,
    items: const [
      RxItem(id: 'i1', description: 'Tachipirina 20 cpr', packs: 2, nonSubstitutable: true),
    ],
    createdAt: at,
    updatedAt: at,
  );

  test('an rx round-trips through the local table, items included', () async {
    final local = RxLocalDatasource(now: () => at);
    await local.upsert(rx, syncStatus: SyncStatus.pendingCreate);
    final back = (await local.getById('r1'))!;
    expect(back.nre, '0410A1234567890');
    expect(back.issuedOn, DateTime(2026, 9, 20));
    expect(back.validUntil, DateTime(2026, 10, 20));
    expect(back.items.single.nonSubstitutable, isTrue);
    expect(back.items.single.packs, 2);
    expect((await local.getByNre('0410A1234567890'))?.id, 'r1');
  });

  test('the wire copy of a stored row equals the model wire copy', () async {
    final local = RxLocalDatasource(now: () => at);
    await local.upsert(rx, syncStatus: SyncStatus.pendingCreate);
    final db = await AppDatabase.instance.database;
    final row = (await db.query('rx', where: 'id = ?', whereArgs: ['r1'])).single;
    expect(RxLocalDatasource.wireOf(row), rx.toJson());
  });

  test('a pending write stamps edited_at and field times', () async {
    final local = RxLocalDatasource(now: () => at);
    await local.upsert(rx, syncStatus: SyncStatus.pendingCreate);
    await local.upsert(
      rx.copyWith(doctor: 'Dr. Rossi', updatedAt: at.add(const Duration(minutes: 1))),
      syncStatus: SyncStatus.pendingUpdate,
    );
    final db = await AppDatabase.instance.database;
    final row = (await db.query('rx')).single;
    expect(row['edited_at'], isNotNull);
    expect(row['field_edited_at'] as String?, contains('doctor'));
  });

  test('markDeleted leaves a pending tombstone that getAll hides', () async {
    final local = RxLocalDatasource(now: () => at);
    await local.upsert(rx, syncStatus: SyncStatus.synced);
    await local.markDeleted('r1');
    expect(await local.getAll(), isEmpty);
    expect((await local.getById('r1'))!.deletedAt, isNotNull);
  });

  test('deleting an rx row cascades to its dispensings', () async {
    final local = RxLocalDatasource(now: () => at);
    final disp = RxDispensingLocalDatasource(now: () => at);
    await local.upsert(rx, syncStatus: SyncStatus.synced);
    await disp.upsert(
      RxDispensingModel(
        id: 'd1',
        rxId: 'r1',
        itemId: 'i1',
        packs: 1,
        dispensedOn: DateTime(2026, 9, 22),
        unitsAdded: 20,
      ),
      syncStatus: SyncStatus.pendingCreate,
    );
    expect((await disp.getForRx('r1')).single.unitsAdded, 20);
    await local.hardDelete('r1');
    expect(await disp.getForRx('r1'), isEmpty);
  });

  test('a person is found by tax code', () async {
    final persons = PersonLocalDatasource(now: () => at);
    await persons.upsert(
      const PersonModel(
        id: 'p1',
        name: 'Ben',
        taxCode: 'RSSMRA85T10A562S',
        exemptions: ['E01'],
      ),
      syncStatus: SyncStatus.pendingCreate,
    );
    final p = (await persons.getByTaxCode('RSSMRA85T10A562S'))!;
    expect(p.exemptions, ['E01']);
  });
}
```

- [ ] **Step 6: Run to verify failure**

Run: `fvm flutter test test/data/datasources/rx_local_datasource_test.dart`
Expected: FAIL — missing imports.

- [ ] **Step 7: Implement models**

`lib/data/models/person_model.dart`:
```dart
/// Medora - Person Model
library;

import 'dart:convert';

import 'package:medora/data/models/medication_model.dart';
import 'package:medora/domain/entities/person.dart';

class PersonModel {
  const PersonModel({
    required this.id,
    this.userId,
    required this.name,
    this.taxCode,
    this.exemptions = const [],
    this.notes,
    this.createdAt,
    this.updatedAt,
    this.deletedAt,
  });

  final String id;
  final String? userId;
  final String name;
  final String? taxCode;
  final List<String> exemptions;
  final String? notes;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  /// Tombstone: non-null when the row is deleted.
  final DateTime? deletedAt;

  /// A server row.
  factory PersonModel.fromJson(Map<String, dynamic> json) => PersonModel(
    id: json['id'] as String,
    userId: json['user_id'] as String?,
    name: json['name'] as String,
    taxCode: json['tax_code'] as String?,
    exemptions: MedicationModel.parseTags(json['exemptions']),
    notes: json['notes'] as String?,
    createdAt: _time(json['created_at']),
    updatedAt: _time(json['updated_at']),
    deletedAt: _time(json['deleted_at']),
  );

  /// A local SQLite row; same keys as the server's.
  factory PersonModel.fromLocalMap(Map<String, dynamic> map) =>
      PersonModel.fromJson(map);

  /// The wire copy: the server's columns this app writes.
  Map<String, dynamic> toJson() => {
    'id': id,
    'user_id': userId,
    'name': name,
    'tax_code': taxCode,
    'exemptions': jsonEncode(exemptions),
    'notes': notes,
    'updated_at': updatedAt?.toUtc().toIso8601String(),
    if (deletedAt != null) 'deleted_at': deletedAt!.toUtc().toIso8601String(),
  };

  Person toDomain() => Person(
    id: id,
    userId: userId,
    name: name,
    taxCode: taxCode,
    exemptions: exemptions,
    notes: notes,
    createdAt: createdAt,
    updatedAt: updatedAt,
  );

  factory PersonModel.fromDomain(Person p) => PersonModel(
    id: p.id,
    userId: p.userId,
    name: p.name,
    taxCode: p.taxCode,
    exemptions: p.exemptions,
    notes: p.notes,
    createdAt: p.createdAt,
    updatedAt: p.updatedAt,
  );

  PersonModel copyWith({DateTime? updatedAt, DateTime? deletedAt}) =>
      PersonModel(
        id: id,
        userId: userId,
        name: name,
        taxCode: taxCode,
        exemptions: exemptions,
        notes: notes,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
        deletedAt: deletedAt ?? this.deletedAt,
      );

  static DateTime? _time(Object? raw) =>
      raw is String ? DateTime.tryParse(raw) : null;
}
```
Note: `exemptions` is `text` holding a JSON list on the server too (same as `patient_tags`), so `toJson` sends the encoded string; `parseTags` reads both a string and a list.

`lib/data/models/rx_model.dart`:
```dart
/// Medora - Rx Model (prescription document).
library;

import 'dart:convert';

import 'package:medora/domain/entities/rx.dart';
import 'package:medora/domain/rx/rx_rules.dart';

class RxModel {
  const RxModel({
    required this.id,
    this.userId,
    this.personId,
    this.treatmentId,
    required this.kind,
    this.nre,
    required this.issuedOn,
    this.validUntil,
    this.doctor,
    this.exemptionCode,
    this.priority,
    this.maxDispensings,
    this.items = const [],
    this.closedOn,
    this.cancelled = false,
    this.notes,
    this.createdAt,
    this.updatedAt,
    this.deletedAt,
  });

  final String id;
  final String? userId;
  final String? personId;
  final String? treatmentId;
  final RxKind kind;
  final String? nre;
  final DateTime issuedOn;
  final DateTime? validUntil;
  final String? doctor;
  final String? exemptionCode;
  final RxPriority? priority;
  final int? maxDispensings;
  final List<RxItem> items;
  final DateTime? closedOn;
  final bool cancelled;
  final String? notes;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final DateTime? deletedAt;

  /// A server row: `items` arrives as a JSON array (jsonb), `cancelled` as
  /// a bool.
  factory RxModel.fromJson(Map<String, dynamic> json) => RxModel(
    id: json['id'] as String,
    userId: json['user_id'] as String?,
    personId: json['person_id'] as String?,
    treatmentId: json['treatment_id'] as String?,
    kind: RxKind.fromWire(json['kind'] as String?),
    nre: json['nre'] as String?,
    issuedOn: DateTime.parse(json['issued_on'] as String),
    validUntil: _date(json['valid_until']),
    doctor: json['doctor'] as String?,
    exemptionCode: json['exemption_code'] as String?,
    priority: RxPriority.fromWire(json['priority'] as String?),
    maxDispensings: (json['max_dispensings'] as num?)?.toInt(),
    items: parseItems(json['items']),
    closedOn: _date(json['closed_on']),
    cancelled: json['cancelled'] == true || json['cancelled'] == 1,
    notes: json['notes'] as String?,
    createdAt: _time(json['created_at']),
    updatedAt: _time(json['updated_at']),
    deletedAt: _time(json['deleted_at']),
  );

  /// A local row: `items` is JSON text, `cancelled` 0/1.
  factory RxModel.fromLocalMap(Map<String, dynamic> map) =>
      RxModel.fromJson(map);

  /// Items from a JSON array or its text.
  static List<RxItem> parseItems(Object? raw) {
    final decoded = raw is String && raw.isNotEmpty ? jsonDecode(raw) : raw;
    if (decoded is! List) return const [];
    return [
      for (final e in decoded)
        if (e is Map) RxItem.fromJson(e.cast<String, dynamic>()),
    ];
  }

  /// The wire copy. `items` is a list here (jsonb on the server); the merge
  /// compares it as a whole.
  Map<String, dynamic> toJson() => {
    'id': id,
    'user_id': userId,
    'person_id': personId,
    'treatment_id': treatmentId,
    'kind': kind.wire,
    'nre': nre,
    'issued_on': _dateText(issuedOn),
    'valid_until': validUntil == null ? null : _dateText(validUntil!),
    'doctor': doctor,
    'exemption_code': exemptionCode,
    'priority': priority?.wire,
    'max_dispensings': maxDispensings,
    'items': [for (final i in items) i.toJson()],
    'closed_on': closedOn == null ? null : _dateText(closedOn!),
    'cancelled': cancelled,
    'notes': notes,
    'updated_at': updatedAt?.toUtc().toIso8601String(),
    if (deletedAt != null) 'deleted_at': deletedAt!.toUtc().toIso8601String(),
  };

  Rx toDomain() => Rx(
    id: id,
    userId: userId,
    personId: personId,
    treatmentId: treatmentId,
    kind: kind,
    nre: nre,
    issuedOn: issuedOn,
    validUntil: validUntil,
    doctor: doctor,
    exemptionCode: exemptionCode,
    priority: priority,
    maxDispensings: maxDispensings,
    items: items,
    closedOn: closedOn,
    cancelled: cancelled,
    notes: notes,
    createdAt: createdAt,
    updatedAt: updatedAt,
  );

  factory RxModel.fromDomain(Rx r) => RxModel(
    id: r.id,
    userId: r.userId,
    personId: r.personId,
    treatmentId: r.treatmentId,
    kind: r.kind,
    nre: r.nre,
    issuedOn: r.issuedOn,
    validUntil: r.validUntil,
    doctor: r.doctor,
    exemptionCode: r.exemptionCode,
    priority: r.priority,
    maxDispensings: r.maxDispensings,
    items: r.items,
    closedOn: r.closedOn,
    cancelled: r.cancelled,
    notes: r.notes,
    createdAt: r.createdAt,
    updatedAt: r.updatedAt,
  );

  RxModel copyWith({
    String? doctor,
    DateTime? updatedAt,
    DateTime? deletedAt,
  }) => RxModel(
    id: id,
    userId: userId,
    personId: personId,
    treatmentId: treatmentId,
    kind: kind,
    nre: nre,
    issuedOn: issuedOn,
    validUntil: validUntil,
    doctor: doctor ?? this.doctor,
    exemptionCode: exemptionCode,
    priority: priority,
    maxDispensings: maxDispensings,
    items: items,
    closedOn: closedOn,
    cancelled: cancelled,
    notes: notes,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    deletedAt: deletedAt ?? this.deletedAt,
  );

  static String _dateText(DateTime d) => d.toIso8601String().split('T').first;
  static DateTime? _date(Object? raw) =>
      raw is String ? DateTime.tryParse(raw) : null;
  static DateTime? _time(Object? raw) =>
      raw is String ? DateTime.tryParse(raw) : null;
}
```

`lib/data/models/rx_dispensing_model.dart`:
```dart
/// Medora - Rx Dispensing Model
library;

import 'package:medora/domain/entities/rx_dispensing.dart';

class RxDispensingModel {
  const RxDispensingModel({
    required this.id,
    this.userId,
    required this.rxId,
    required this.itemId,
    required this.packs,
    required this.dispensedOn,
    this.pharmacy,
    this.unitsAdded = 0,
    this.createdAt,
    this.updatedAt,
    this.deletedAt,
  });

  final String id;
  final String? userId;
  final String rxId;
  final String itemId;
  final int packs;
  final DateTime dispensedOn;
  final String? pharmacy;
  final int unitsAdded;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final DateTime? deletedAt;

  factory RxDispensingModel.fromJson(Map<String, dynamic> json) =>
      RxDispensingModel(
        id: json['id'] as String,
        userId: json['user_id'] as String?,
        rxId: json['rx_id'] as String,
        itemId: json['item_id'] as String,
        packs: (json['packs'] as num).toInt(),
        dispensedOn: DateTime.parse(json['dispensed_on'] as String),
        pharmacy: json['pharmacy'] as String?,
        unitsAdded: (json['units_added'] as num?)?.toInt() ?? 0,
        createdAt: _time(json['created_at']),
        updatedAt: _time(json['updated_at']),
        deletedAt: _time(json['deleted_at']),
      );

  factory RxDispensingModel.fromLocalMap(Map<String, dynamic> map) =>
      RxDispensingModel.fromJson(map);

  Map<String, dynamic> toJson() => {
    'id': id,
    'user_id': userId,
    'rx_id': rxId,
    'item_id': itemId,
    'packs': packs,
    'dispensed_on': dispensedOn.toIso8601String().split('T').first,
    'pharmacy': pharmacy,
    'units_added': unitsAdded,
    'updated_at': updatedAt?.toUtc().toIso8601String(),
    if (deletedAt != null) 'deleted_at': deletedAt!.toUtc().toIso8601String(),
  };

  RxDispensing toDomain() => RxDispensing(
    id: id,
    userId: userId,
    rxId: rxId,
    itemId: itemId,
    packs: packs,
    dispensedOn: dispensedOn,
    pharmacy: pharmacy,
    unitsAdded: unitsAdded,
    createdAt: createdAt,
    updatedAt: updatedAt,
  );

  factory RxDispensingModel.fromDomain(RxDispensing d) => RxDispensingModel(
    id: d.id,
    userId: d.userId,
    rxId: d.rxId,
    itemId: d.itemId,
    packs: d.packs,
    dispensedOn: d.dispensedOn,
    pharmacy: d.pharmacy,
    unitsAdded: d.unitsAdded,
    createdAt: d.createdAt,
    updatedAt: d.updatedAt,
  );

  static DateTime? _time(Object? raw) =>
      raw is String ? DateTime.tryParse(raw) : null;
}
```

- [ ] **Step 8: Implement the shared local table and the three datasources**

`lib/data/datasources/synced_local_table.dart`:
```dart
/// Medora - The local side of a table synced by sync v2, for the tables
/// added after it (persons, rx, rx_dispensings).
///
/// The four original tables each spell this out in their own datasource;
/// the newer ones share it. A write stored as pending is stamped the way
/// the sync cycle expects (`edited_at`, per-column `field_edited_at`); a
/// row stored as synced comes from the server and keeps the stamps the
/// cycle gives it.
library;

import 'package:medora/core/clock.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/local/edit_time.dart';
import 'package:medora/data/local/field_times.dart';
import 'package:sqflite/sqflite.dart';

class SyncedLocalTable<M> {
  SyncedLocalTable({
    required this.table,
    required this.rowOf,
    required this.wireOf,
    required this.fromRow,
    required this.updatedAtOf,
    required Now now,
  }) : _now = now;

  final String table;

  /// The stored row of a model (data columns, `sync_status`, and
  /// `edited_at` for a pending write).
  final Map<String, dynamic> Function(M model, String syncStatus, {Now now})
  rowOf;

  /// The wire copy of a stored row, which the edit times compare.
  final Map<String, Object?> Function(Map<String, Object?> row) wireOf;
  final M Function(Map<String, dynamic> row) fromRow;
  final DateTime? Function(M model) updatedAtOf;
  final Now _now;

  Future<Database> get _db => AppDatabase.instance.database;

  Future<void> upsert(M model, {required String syncStatus}) async {
    final db = await _db;
    final at = _now();
    final row = rowOf(model, syncStatus, now: () => at);
    final id = row['id'] as String;
    if (syncStatus == SyncStatus.synced) {
      await _store(db, id, row);
      return;
    }
    await db.transaction((txn) async {
      row['field_edited_at'] = fieldTimesAfterWrite(
        previous: await _stored(txn, id),
        after: row,
        wireOf: wireOf,
        at: editedAtOf(updatedAtOf(model) ?? at, at),
      );
      await _store(txn, id, row);
    });
  }

  /// UPDATE first: INSERT OR REPLACE deletes the row first and would
  /// cascade-delete its children (an rx's dispensings).
  Future<void> _store(
    DatabaseExecutor db,
    String id,
    Map<String, Object?> row,
  ) async {
    final updated = await db.update(
      table,
      row,
      where: 'id = ?',
      whereArgs: [id],
    );
    if (updated == 0) {
      await db.insert(table, row, conflictAlgorithm: ConflictAlgorithm.ignore);
    }
  }

  Future<Map<String, Object?>?> _stored(DatabaseExecutor db, String id) async {
    final rows = await db.query(table, where: 'id = ?', whereArgs: [id]);
    return rows.isEmpty ? null : rows.first;
  }

  /// Marks the row for deletion (pending push, local tombstone). A row
  /// already deleted keeps its stamps.
  Future<void> markDeleted(String id) async {
    final db = await _db;
    final now = _now();
    await db.update(
      table,
      {
        'sync_status': SyncStatus.pendingDelete,
        'deleted_at': now.toIso8601String(),
        'edited_at': editedAtText(now, now),
      },
      where: 'id = ? AND sync_status != ?',
      whereArgs: [id, SyncStatus.pendingDelete],
    );
  }

  /// The row [id], tombstone included, or null.
  Future<M?> getById(String id) async {
    final rows = await (await _db).query(
      table,
      where: 'id = ?',
      whereArgs: [id],
    );
    return rows.isEmpty ? null : fromRow(rows.first);
  }

  /// Live rows (a pending delete is hidden) matching [where].
  Future<List<M>> getAll({
    String? where,
    List<Object?>? whereArgs,
    String? orderBy,
  }) async {
    final rows = await (await _db).query(
      table,
      where: where == null ? 'sync_status != ?' : '($where) AND sync_status != ?',
      whereArgs: [...?whereArgs, SyncStatus.pendingDelete],
      orderBy: orderBy,
    );
    return rows.map(fromRow).toList();
  }

  Future<void> hardDelete(String id) async =>
      (await _db).delete(table, where: 'id = ?', whereArgs: [id]);

  Future<void> clearAll() async => (await _db).delete(table);

  /// Stamp shared by every `rowOf`: the pending write's `edited_at`.
  static Map<String, Object?> pendingStamp(
    String syncStatus,
    DateTime? updatedAt,
    DateTime at,
  ) => {
    'sync_status': syncStatus,
    if (syncStatus != SyncStatus.synced)
      'edited_at': editedAtText(updatedAt ?? at, at),
  };
}
```
Check `fieldTimesAfterWrite`'s exact parameter types in `lib/data/local/field_times.dart:211` and match them (the treatment datasource calls it with the same four named arguments).

`lib/data/datasources/rx_local_datasource.dart`:
```dart
/// Medora - Rx Local Datasource
library;

import 'dart:convert';

import 'package:medora/core/clock.dart';
import 'package:medora/data/datasources/synced_local_table.dart';
import 'package:medora/data/models/rx_model.dart';

class RxLocalDatasource {
  RxLocalDatasource({Now now = systemNow})
    : _table = SyncedLocalTable<RxModel>(
        table: 'rx',
        rowOf: rowOf,
        wireOf: wireOf,
        fromRow: RxModel.fromLocalMap,
        updatedAtOf: (m) => m.updatedAt,
        now: now,
      );

  final SyncedLocalTable<RxModel> _table;

  Future<void> upsert(RxModel model, {required String syncStatus}) =>
      _table.upsert(model, syncStatus: syncStatus);
  Future<void> markDeleted(String id) => _table.markDeleted(id);
  Future<void> hardDelete(String id) => _table.hardDelete(id);
  Future<RxModel?> getById(String id) => _table.getById(id);

  /// Every live prescription, newest issue first.
  Future<List<RxModel>> getAll() =>
      _table.getAll(orderBy: 'issued_on DESC, created_at DESC');

  Future<RxModel?> getByNre(String nre) async {
    final rows = await _table.getAll(where: 'nre = ?', whereArgs: [nre]);
    return rows.isEmpty ? null : rows.first;
  }

  Future<List<RxModel>> getForTreatment(String treatmentId) => _table.getAll(
    where: 'treatment_id = ?',
    whereArgs: [treatmentId],
    orderBy: 'issued_on DESC',
  );

  static Map<String, Object?> wireOf(Map<String, Object?> row) =>
      RxModel.fromLocalMap(row).toJson();

  static Map<String, dynamic> rowOf(
    RxModel m,
    String syncStatus, {
    Now now = systemNow,
  }) {
    final at = now();
    final wire = m.toJson();
    return {
      ...wire,
      'items': jsonEncode(wire['items']),
      'cancelled': m.cancelled ? 1 : 0,
      'created_at': (m.createdAt ?? at).toIso8601String(),
      'updated_at': (m.updatedAt ?? at).toIso8601String(),
      'deleted_at': m.deletedAt?.toIso8601String(),
      ...SyncedLocalTable.pendingStamp(syncStatus, m.updatedAt, at),
    };
  }
}
```

`lib/data/datasources/person_local_datasource.dart`:
```dart
/// Medora - Person Local Datasource
library;

import 'package:medora/core/clock.dart';
import 'package:medora/data/datasources/synced_local_table.dart';
import 'package:medora/data/models/person_model.dart';

class PersonLocalDatasource {
  PersonLocalDatasource({Now now = systemNow})
    : _table = SyncedLocalTable<PersonModel>(
        table: 'persons',
        rowOf: rowOf,
        wireOf: wireOf,
        fromRow: PersonModel.fromLocalMap,
        updatedAtOf: (m) => m.updatedAt,
        now: now,
      );

  final SyncedLocalTable<PersonModel> _table;

  Future<void> upsert(PersonModel model, {required String syncStatus}) =>
      _table.upsert(model, syncStatus: syncStatus);
  Future<void> markDeleted(String id) => _table.markDeleted(id);
  Future<PersonModel?> getPersonById(String id) => _table.getById(id);
  Future<List<PersonModel>> getPersons() =>
      _table.getAll(orderBy: 'name COLLATE NOCASE');

  Future<PersonModel?> getByTaxCode(String taxCode) async {
    final rows = await _table.getAll(where: 'tax_code = ?', whereArgs: [taxCode]);
    return rows.isEmpty ? null : rows.first;
  }

  static Map<String, Object?> wireOf(Map<String, Object?> row) =>
      PersonModel.fromLocalMap(row).toJson();

  static Map<String, dynamic> rowOf(
    PersonModel m,
    String syncStatus, {
    Now now = systemNow,
  }) {
    final at = now();
    return {
      ...m.toJson(),
      'created_at': (m.createdAt ?? at).toIso8601String(),
      'updated_at': (m.updatedAt ?? at).toIso8601String(),
      'deleted_at': m.deletedAt?.toIso8601String(),
      ...SyncedLocalTable.pendingStamp(syncStatus, m.updatedAt, at),
    };
  }
}
```

`lib/data/datasources/rx_dispensing_local_datasource.dart`:
```dart
/// Medora - Rx Dispensing Local Datasource
library;

import 'package:medora/core/clock.dart';
import 'package:medora/data/datasources/synced_local_table.dart';
import 'package:medora/data/models/rx_dispensing_model.dart';

class RxDispensingLocalDatasource {
  RxDispensingLocalDatasource({Now now = systemNow})
    : _table = SyncedLocalTable<RxDispensingModel>(
        table: 'rx_dispensings',
        rowOf: rowOf,
        wireOf: wireOf,
        fromRow: RxDispensingModel.fromLocalMap,
        updatedAtOf: (m) => m.updatedAt,
        now: now,
      );

  final SyncedLocalTable<RxDispensingModel> _table;

  Future<void> upsert(RxDispensingModel model, {required String syncStatus}) =>
      _table.upsert(model, syncStatus: syncStatus);
  Future<void> markDeleted(String id) => _table.markDeleted(id);

  Future<List<RxDispensingModel>> getForRx(String rxId) => _table.getAll(
    where: 'rx_id = ?',
    whereArgs: [rxId],
    orderBy: 'dispensed_on',
  );

  Future<List<RxDispensingModel>> getForRxIds(List<String> rxIds) {
    if (rxIds.isEmpty) return Future.value(const []);
    final marks = List.filled(rxIds.length, '?').join(',');
    return _table.getAll(where: 'rx_id IN ($marks)', whereArgs: rxIds);
  }

  static Map<String, Object?> wireOf(Map<String, Object?> row) =>
      RxDispensingModel.fromLocalMap(row).toJson();

  static Map<String, dynamic> rowOf(
    RxDispensingModel m,
    String syncStatus, {
    Now now = systemNow,
  }) {
    final at = now();
    return {
      ...m.toJson(),
      'created_at': (m.createdAt ?? at).toIso8601String(),
      'updated_at': (m.updatedAt ?? at).toIso8601String(),
      'deleted_at': m.deletedAt?.toIso8601String(),
      ...SyncedLocalTable.pendingStamp(syncStatus, m.updatedAt, at),
    };
  }
}
```

- [ ] **Step 9: Run tests**

Run: `fvm flutter test test/data/datasources/rx_local_datasource_test.dart test/data/local/`
Expected: PASS. If `wireOf(row) == toJson()` fails on `updated_at` (local stores local ISO, wire sends UTC), compare after `RxModel.fromLocalMap` normalisation — both sides go through `toJson`, so equality must hold; if it does not, fix `_time` parsing, not the test.

- [ ] **Step 10: Commit**

```bash
fvm dart format lib test
fvm flutter analyze --fatal-infos
git add lib/data test/data
git commit -m "feat(rx): local tables, models and datasources for persons and prescriptions"
```

---

### Task 4: Teach the row sync the three new tables

**Files:**
- Modify: `lib/data/sync/sync_meta.dart`, `lib/data/sync/row_merge.dart:256-261`, `lib/data/sync/table_sync.dart:68-84`, `test/helpers/fake_server.dart` (schema map + `_cascade` + parent-deleted check around line 360)
- Test: `test/data/sync/rx_table_sync_test.dart`

**Interfaces:**
- Consumes: `PersonLocalDatasource.rowOf/wireOf`, `RxLocalDatasource.rowOf/wireOf`, `RxDispensingLocalDatasource.rowOf/wireOf`, models' `fromJson/fromLocalMap/toJson` (Task 3).
- Produces: `syncedTables` = `['medications','treatments','prescriptions','dose_logs','persons','rx','rx_dispensings']`; `mergePolicyOf('persons'|'rx'|'rx_dispensings')`; `parentsOf('rx_dispensings', row)` → `[('rx', rx_id)]`.

- [ ] **Step 1: Write the failing test**

`test/data/sync/rx_table_sync_test.dart` (modelled on `table_sync_test.dart`; `FakeSyncTable.seed/get/editFromOtherDevice` and `writeLocalChange` are the existing helpers):
```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/sync/table_sync.dart';
import 'package:sqflite/sqflite.dart';

import '../../helpers/fake_server.dart';
import '../../helpers/local_write.dart';
import '../../helpers/test_database.dart';

void main() {
  late DateTime now;
  late FakeServerCore core;
  var ids = 0;
  final remotes = <String, FakeSyncTable>{};

  FakeSyncTable remote(String table) =>
      remotes.putIfAbsent(table, () => FakeSyncTable(core, table));

  TableSync syncOf(String table) => TableSync(
    table: table,
    remote: remote(table),
    newWriteId: () => 'w${ids++}',
    now: () => now,
  );

  setUp(() async {
    ids = 0;
    remotes.clear();
    await setUpTestDatabase();
    now = DateTime.utc(2026, 9, 23, 12);
    core = FakeServerCore(() => now);
  });
  tearDown(tearDownTestDatabase);

  Future<Database> db() => AppDatabase.instance.database;

  Map<String, Object?> rxRow(String id, {String status = 'pending_create'}) => {
    'id': id,
    'kind': 'ssn',
    'nre': '0410A1234567890',
    'issued_on': '2026-09-20',
    'items':
        '[{"id":"i1","description":"Brufen","packs":1,"non_substitutable":false}]',
    'cancelled': 0,
    'created_at': '2026-09-23T12:00:00.000Z',
    'updated_at': '2026-09-23T12:00:00.000Z',
    'edited_at': '2026-09-23T12:00:00.000Z',
    'sync_status': status,
  };

  test('a new rx is pushed and settles', () async {
    await (await db()).insert('rx', rxRow('r1'));
    final row = (await (await db()).query('rx')).single;
    final result = await syncOf('rx').pushRow(row, userId: 'u1', force: false);
    expect(result.outcome, PushOutcome.settled);
    expect(remote('rx').get('r1')!['user_id'], 'u1');
    expect(remote('rx').get('r1')!['items'], isA<List<dynamic>>());
    final local = (await (await db()).query('rx')).single;
    expect(local['sync_status'], SyncStatus.synced);
  });

  test('a pulled rx is stored with its items as text', () async {
    final server = remote('rx').seed({
      'id': 'r2',
      'user_id': 'u1',
      'kind': 'white_repeatable',
      'issued_on': '2026-09-01',
      'max_dispensings': 10,
      'items': [
        {'id': 'i1', 'description': 'X', 'packs': 1, 'non_substitutable': true},
      ],
      'cancelled': false,
    });
    final applied = await syncOf('rx').applyPulled(server);
    expect(applied.outcome, PullOutcome.inserted);
    final local = (await (await db()).query('rx')).single;
    expect(local['items'], contains('"non_substitutable":true'));
    expect(local['max_dispensings'], 10);
  });

  test('a dispensing under an rx deleted here goes with it', () async {
    await (await db()).insert('rx', {
      ...rxRow('r3', status: SyncStatus.pendingDelete),
      'deleted_at': '2026-09-23T12:00:00.000Z',
    });
    final server = remote('rx_dispensings').seed({
      'id': 'd1',
      'user_id': 'u1',
      'rx_id': 'r3',
      'item_id': 'i1',
      'packs': 1,
      'dispensed_on': '2026-09-22',
      'units_added': 0,
    });
    final applied = await syncOf('rx_dispensings').applyPulled(server);
    expect(applied.outcome, PullOutcome.kept);
    expect(await (await db()).query('rx_dispensings'), isEmpty);
  });

  test('a dispensing whose rx has not arrived yet is orphaned', () async {
    final server = remote('rx_dispensings').seed({
      'id': 'd2',
      'user_id': 'u1',
      'rx_id': 'missing',
      'item_id': 'i1',
      'packs': 1,
      'dispensed_on': '2026-09-22',
      'units_added': 0,
    });
    final applied = await syncOf('rx_dispensings').applyPulled(server);
    expect(applied.outcome, PullOutcome.orphaned);
  });

  test('a person edited on both sides merges by column', () async {
    final sync = syncOf('persons');
    await sync.applyPulled(
      remote('persons').seed({
        'id': 'p1',
        'user_id': 'u1',
        'name': 'Ben',
        'exemptions': '[]',
      }),
    );
    now = now.add(const Duration(minutes: 1));
    final server = remote('persons').editFromOtherDevice('p1', {
      'tax_code': 'RSSMRA85T10A562S',
    })!;
    await writeLocalChange(await db(), 'persons', 'p1', {
      'notes': 'Allergie: Penicillin',
      'sync_status': SyncStatus.pendingUpdate,
      'edited_at': now.toIso8601String(),
      'updated_at': now.toIso8601String(),
    }, at: now);
    await sync.applyPulled(server);
    final local = (await (await db()).query('persons')).single;
    expect(local['tax_code'], 'RSSMRA85T10A562S');
    expect(local['notes'], 'Allergie: Penicillin');
  });
}
```
Check `seed`'s return (line ~955 of `fake_server.dart`: returns the stored row) and `editFromOtherDevice`'s signature (line ~966) before running; adjust only the call shape, never the assertions.

- [ ] **Step 2: Run to verify it fails**

Run: `fvm flutter test test/data/sync/rx_table_sync_test.dart`
Expected: FAIL — `ArgumentError: not a merged table` for `rx`.

- [ ] **Step 3: Wire the tables**

`lib/data/sync/sync_meta.dart`:
- Imports: add `person_local_datasource.dart`, `rx_local_datasource.dart`, `rx_dispensing_local_datasource.dart`, `person_model.dart`, `rx_model.dart`, `rx_dispensing_model.dart`.
- `syncedTables`: append `'persons', 'rx', 'rx_dispensings'` (in that order; FK order).
- `canonicalWire`: add
  ```dart
      'persons' => PersonModel.fromJson(json).toJson(),
      'rx' => RxModel.fromJson(json).toJson(),
      'rx_dispensings' => RxDispensingModel.fromJson(json).toJson(),
  ```
- `localWire`: add (all three carry `user_id`)
  ```dart
  'persons' => PersonModel.fromLocalMap({
    ...row,
    'user_id': userId ?? row['user_id'],
  }).toJson(),
  'rx' => RxModel.fromLocalMap({
    ...row,
    'user_id': userId ?? row['user_id'],
  }).toJson(),
  'rx_dispensings' => RxDispensingModel.fromLocalMap({
    ...row,
    'user_id': userId ?? row['user_id'],
  }).toJson(),
  ```
- `localRowOf`: add
  ```dart
  'persons' => PersonLocalDatasource.rowOf(PersonModel.fromJson(json), syncStatus),
  'rx' => RxLocalDatasource.rowOf(RxModel.fromJson(json), syncStatus),
  'rx_dispensings' => RxDispensingLocalDatasource.rowOf(
    RxDispensingModel.fromJson(json),
    syncStatus,
  ),
  ```
- Update the library doc: "every local row of the synced tables".

`lib/data/sync/row_merge.dart` — add policies before `mergePolicyOf` and the cases:
```dart
/// A person's tax code and exemptions are independent columns; nothing
/// needs to move together.
const personMerge = MergePolicy(groups: []);

/// Validity follows the kind and the issue date, so the three move
/// together; the items list merges as one value.
const rxMerge = MergePolicy(
  groups: [
    {'kind', 'issued_on', 'valid_until', 'max_dispensings', 'priority'},
    {'closed_on', 'cancelled'},
  ],
);

/// A dispensing is written once and only ever deleted.
const rxDispensingMerge = MergePolicy(groups: []);
```
```dart
  'persons' => personMerge,
  'rx' => rxMerge,
  'rx_dispensings' => rxDispensingMerge,
```
Check that `MergePolicy` accepts `groups: []` (const empty list) — `serverOwned` defaults to empty; if the constructor requires it, pass `serverOwned: {}`.

`lib/data/sync/table_sync.dart` `parentsOf` switch: add
```dart
      'rx_dispensings' => [parent('rx', 'rx_id')],
```

`test/helpers/fake_server.dart`:
- Add schema entries for `persons`, `rx`, `rx_dispensings` next to `'dose_logs'` with every server column and its default (`'items': const <Object?>[]`, `'cancelled': false`, `'units_added': 0`, `'exemptions': null`, `created_at/updated_at: _nowDefault`, `deleted_at: null`, `..._syncColumns`).
- `_cascade`: add `'rx': ('rx_dispensings', 'rx_id'),`.
- Parent-deleted check (the `switch` near line 360): add `'rx_dispensings' => deletedAt('rx', row['rx_id']),`.
- The table list near line 716 (tables in delete-all order): add `'rx_dispensings', 'rx', 'persons'` at the front.

- [ ] **Step 4: Run tests**

Run: `fvm flutter test test/data/sync/`
Expected: PASS, including the untouched existing sync tests.

- [ ] **Step 5: Commit**

```bash
fvm dart format lib test
fvm flutter analyze --fatal-infos
git add lib/data/sync test/helpers/fake_server.dart test/data/sync/rx_table_sync_test.dart
git commit -m "feat(rx): row sync merges persons, prescriptions and dispensings"
```

---
### Task 5: Supabase migration and the sync cycle

**Files:**
- Create: `supabase/migrations/20260923000000_rx.sql`, `lib/data/datasources/rx_remote_datasource.dart`, `test/services/rx_sync_test.dart`
- Modify: `lib/data/datasources/schema_errors.dart`, `lib/data/datasources/sync_table.dart` (`PostgrestSyncTable`), `lib/services/sync_service.dart` (constructor, `_tables`, `_pushPendingChanges`, `_pullAll`, `_childTables`, `discardFailedRow`), `lib/data/sync/remote_wipe.dart:40`, `lib/services/local_upload_marker.dart` (both table lists), `lib/presentation/providers/providers.dart` (remote provider + pass to `SyncService`), `test/helpers/fake_remotes.dart` (`FakeServer.rx`, `FakeRxRemote`), `test/helpers/fake_postgrest.dart` (tables at ~line 73 and ~182), `test/services/sync_service_test.dart` (`Harness` passes `rxRemote`)

**Interfaces:**
- Consumes: Task 4 sync wiring.
- Produces:
  - `const rxMigration = 'supabase/migrations/20260923000000_rx.sql';`
  - `class RxRemoteDatasource { RxRemoteDatasource(SupabaseClient); final SyncTable persons; final SyncTable rx; final SyncTable dispensings; }`
  - `SyncService({…, RxRemoteDatasource? rxRemote})` — optional; null skips the three tables (local-only and old tests unchanged).
  - `class MissingTableException implements Exception { table, migration, cause }`.
  - `final rxRemoteDatasourceProvider = Provider<RxRemoteDatasource?>`.

- [ ] **Step 1: Write the server migration**

`supabase/migrations/20260923000000_rx.sql`:
```sql
-- ============================================================
-- Medora - Prescriptions (spec 2026-09-23): persons, prescription
-- documents (rx) and their dispensings, synced like every other table
-- (sync v2 columns, the stamp trigger, owner-scoped RLS).
--
-- Apply after 20260918000000_sync_v2.sql and BEFORE any device runs
-- Medora 0.6.0. Older app versions never touch these tables. Every
-- statement can be run again.
-- ============================================================

set local lock_timeout = '5s';

-- 1. Tables -----------------------------------------------------------------
--
-- A prescription names its person, treatment and medications without a
-- foreign key: deleting one of those never deletes a prescription. A
-- dispensing belongs to its prescription.

create table if not exists public.persons (
  id              text primary key,
  user_id         uuid not null references auth.users(id) on delete cascade,
  name            text not null,
  tax_code        text,
  exemptions      text,
  notes           text,
  created_at      timestamptz default now(),
  updated_at      timestamptz default now(),
  deleted_at      timestamptz,
  sync_xid        bigint not null default 0,
  row_version     bigint not null default 1,
  write_id        uuid,
  edited_at       timestamptz,
  field_edited_at jsonb not null default '{}'::jsonb
);

create table if not exists public.rx (
  id              text primary key,
  user_id         uuid not null references auth.users(id) on delete cascade,
  person_id       text,
  treatment_id    text,
  kind            text not null
                  check (kind in ('ssn', 'white', 'white_repeatable', 'referral')),
  nre             text,
  issued_on       date not null,
  valid_until     date,
  doctor          text,
  exemption_code  text,
  priority        text check (priority in ('U', 'B', 'D', 'P')),
  max_dispensings integer check (max_dispensings > 0),
  items           jsonb not null default '[]'::jsonb,
  closed_on       date,
  cancelled       boolean not null default false,
  notes           text,
  created_at      timestamptz default now(),
  updated_at      timestamptz default now(),
  deleted_at      timestamptz,
  sync_xid        bigint not null default 0,
  row_version     bigint not null default 1,
  write_id        uuid,
  edited_at       timestamptz,
  field_edited_at jsonb not null default '{}'::jsonb
);

create table if not exists public.rx_dispensings (
  id              text primary key,
  user_id         uuid not null references auth.users(id) on delete cascade,
  rx_id           text not null references public.rx(id) on delete cascade,
  item_id         text not null,
  packs           integer not null check (packs > 0),
  dispensed_on    date not null,
  pharmacy        text,
  units_added     integer not null default 0 check (units_added >= 0),
  created_at      timestamptz default now(),
  updated_at      timestamptz default now(),
  deleted_at      timestamptz,
  sync_xid        bigint not null default 0,
  row_version     bigint not null default 1,
  write_id        uuid,
  edited_at       timestamptz,
  field_edited_at jsonb not null default '{}'::jsonb
);

create index if not exists idx_persons_sync on public.persons (user_id, sync_xid, id);
create index if not exists idx_rx_sync      on public.rx (user_id, sync_xid, id);
create index if not exists idx_rx_disp_sync on public.rx_dispensings (user_id, sync_xid, id);
create index if not exists idx_rx_disp_rx   on public.rx_dispensings (rx_id);

-- 2. Row-level security: the owner only ----------------------------------

alter table public.persons        enable row level security;
alter table public.rx             enable row level security;
alter table public.rx_dispensings enable row level security;

do $$
declare
  t text;
begin
  foreach t in array array['persons', 'rx', 'rx_dispensings'] loop
    execute format('drop policy if exists "%1$s_select" on public.%1$s', t);
    execute format('create policy "%1$s_select" on public.%1$s for select using (user_id = auth.uid())', t);
    execute format('drop policy if exists "%1$s_insert" on public.%1$s', t);
    execute format('create policy "%1$s_insert" on public.%1$s for insert with check (user_id = auth.uid())', t);
    execute format('drop policy if exists "%1$s_update" on public.%1$s', t);
    execute format('create policy "%1$s_update" on public.%1$s for update using (user_id = auth.uid()) with check (user_id = auth.uid())', t);
    execute format('drop policy if exists "%1$s_delete" on public.%1$s', t);
    execute format('create policy "%1$s_delete" on public.%1$s for delete using (user_id = auth.uid())', t);
  end loop;
end;
$$;

-- A dispensing may only name a prescription of the same owner.
drop policy if exists "rx_dispensings_insert" on public.rx_dispensings;
create policy "rx_dispensings_insert" on public.rx_dispensings
  for insert with check (
    user_id = auth.uid()
    and exists (select 1 from public.rx r where r.id = rx_id)
  );

revoke truncate, trigger, references
  on public.persons, public.rx, public.rx_dispensings
  from anon, authenticated;

-- 3. Triggers ---------------------------------------------------------------
--
-- The same stamp and updated_at triggers as the other synced tables. The
-- stamp trigger's parent check knows only the original tables, so a
-- second BEFORE trigger stores a live dispensing under a deleted
-- prescription deleted, as the app's own change. Its name sorts after
-- `_sync_stamp` and before `_updated_at`, so it runs between them (BEFORE
-- triggers of one event fire in name order).

do $$
declare
  t text;
begin
  foreach t in array array['persons', 'rx', 'rx_dispensings'] loop
    execute format('drop trigger if exists %1$s_sync_stamp on public.%1$s', t);
    execute format('create trigger %1$s_sync_stamp before insert or update on public.%1$s for each row execute function public.medora_sync_stamp()', t);
    execute format('drop trigger if exists %1$s_updated_at on public.%1$s', t);
    execute format('create trigger %1$s_updated_at before update on public.%1$s for each row execute function public.update_updated_at()', t);
  end loop;
end;
$$;

create or replace function public.medora_rx_dispensing_parent()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v_parent_deleted timestamptz;
begin
  if new.deleted_at is null then
    -- FOR SHARE: see the note on the parent check in medora_sync_stamp.
    select r.deleted_at into v_parent_deleted
      from public.rx r where r.id = new.rx_id for share;
    if v_parent_deleted is not null then
      new.deleted_at := v_parent_deleted;
      new.edited_at := timestamptz '1970-01-01 00:00:00+00';
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists rx_dispensings_sync_stamp_parent on public.rx_dispensings;
create trigger rx_dispensings_sync_stamp_parent
  before insert or update on public.rx_dispensings
  for each row execute function public.medora_rx_dispensing_parent();

-- A prescription's tombstone takes its dispensings with it.
create or replace function public.cascade_tombstone_rx()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if new.deleted_at is not null and old.deleted_at is null then
    update public.rx_dispensings set deleted_at = new.deleted_at
     where rx_id = new.id and deleted_at is null;
  end if;
  return new;
end;
$$;

drop trigger if exists rx_tombstone_cascade on public.rx;
create trigger rx_tombstone_cascade
  after update of deleted_at on public.rx
  for each row execute function public.cascade_tombstone_rx();

revoke all on function public.medora_rx_dispensing_parent() from public, anon, authenticated;
revoke all on function public.cascade_tombstone_rx() from public, anon, authenticated;

-- 4. "Delete all data" covers the new tables -----------------------------
--
-- Same function as in 20260918000000_sync_v2.sql, section 8, with the three
-- deletes added before the medications.

create or replace function public.medora_delete_all_data()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid        uuid := auth.uid();
  v_at         timestamptz := now();
  v_generation bigint;
begin
  if v_uid is null then
    raise exception 'not authenticated' using errcode = '28000';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('medora-wipe:' || v_uid::text, 0));
  insert into public.sync_wipes as w (user_id, generation, wiped_at)
    values (v_uid, 1, v_at)
    on conflict (user_id) do update
      set generation = w.generation + 1, wiped_at = excluded.wiped_at
    returning w.generation into v_generation;
  delete from public.dose_logs d
   using public.prescriptions p, public.treatments t
   where d.prescription_id = p.id and p.treatment_id = t.id and t.user_id = v_uid;
  delete from public.prescriptions p
   using public.treatments t
   where p.treatment_id = t.id and t.user_id = v_uid;
  delete from public.treatments where user_id = v_uid;
  delete from public.rx_dispensings where user_id = v_uid;
  delete from public.rx where user_id = v_uid;
  delete from public.persons where user_id = v_uid;
  delete from public.medications where user_id = v_uid;
  return jsonb_build_object('generation', v_generation, 'wiped_at', v_at);
end;
$$;

revoke all on function public.medora_delete_all_data() from public, anon;
grant execute on function public.medora_delete_all_data() to authenticated;
```
Before committing, diff the `medora_delete_all_data` body against the one in `20260918000000_sync_v2.sql` (and any later migration that redefines it: `grep -l medora_delete_all_data supabase/migrations/*`) — only the three `delete` lines may differ.

- [ ] **Step 2: Apply it to a local Supabase**

```bash
supabase start
supabase db reset
```
Expected: all migrations apply without error. Then:
```bash
supabase stop
```

- [ ] **Step 3: Missing table error**

In `lib/data/datasources/schema_errors.dart` append:
```dart
/// A Supabase project without the table [table], which [migration] creates.
/// PostgREST answers `PGRST205` for a table not in its schema cache,
/// Postgres `42P01` for one that does not exist.
class MissingTableException implements Exception {
  const MissingTableException({
    required this.table,
    required this.migration,
    required this.cause,
  });

  final String table;
  final String migration;
  final PostgrestException cause;

  @override
  String toString() =>
      'The Supabase project has no $table table. '
      'Apply $migration to the project, then sync again '
      '(server: ${cause.message}).';
}

/// [error] read as a missing [table], else null.
MissingTableException? missingTable(
  Object error, {
  required String table,
  required String migration,
}) {
  if (error is! PostgrestException) return null;
  if (error.code != 'PGRST205' && error.code != '42P01') return null;
  return MissingTableException(table: table, migration: migration, cause: error);
}
```
In `PostgrestSyncTable` (`sync_table.dart`) add a constructor flag `this.tableMigration` (`final String? tableMigration;` — the migration that creates the table itself) and a read guard used by `page`, `fetch`, `fetchMany`; also call it first in `_write`'s catch:
```dart
  Future<T> _read<T>(Future<T> Function() send) async {
    try {
      return await send();
    } on PostgrestException catch (e) {
      final missing = tableMigration == null
          ? null
          : missingTable(e, table: table, migration: tableMigration!);
      if (missing != null) throw missing;
      rethrow;
    }
  }
```
In `_write`'s `on PostgrestException catch (e)` block, before `missingColumn`:
```dart
      final noTable = tableMigration == null
          ? null
          : missingTable(e, table: table, migration: tableMigration!);
      if (noTable != null) throw noTable;
```
Wrap `page`, `fetch` and `fetchMany` bodies in `_read(() async => …)`.

Add a unit test in `test/data/datasources/schema_errors_test.dart` (create if absent):
```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/data/datasources/schema_errors.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  test('PGRST205 and 42P01 name the migration that creates the table', () {
    for (final code in ['PGRST205', '42P01']) {
      final e = missingTable(
        PostgrestException(message: 'no table', code: code),
        table: 'rx',
        migration: 'supabase/migrations/20260923000000_rx.sql',
      );
      expect(e, isNotNull);
      expect(e.toString(), contains('20260923000000_rx.sql'));
    }
  });

  test('other errors are not a missing table', () {
    expect(
      missingTable(
        const PostgrestException(message: 'x', code: '23505'),
        table: 'rx',
        migration: 'm',
      ),
      isNull,
    );
  });
}
```

- [ ] **Step 4: Remote datasource**

`lib/data/datasources/rx_remote_datasource.dart`:
```dart
/// Medora - The server tables of prescriptions (sync v2).
library;

import 'package:medora/data/datasources/sync_table.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// The migration that creates `persons`, `rx` and `rx_dispensings`.
const rxMigration = 'supabase/migrations/20260923000000_rx.sql';

class RxRemoteDatasource {
  RxRemoteDatasource(SupabaseClient client)
    : persons = PostgrestSyncTable(
        client,
        'persons',
        migration: rxMigration,
        tableMigration: rxMigration,
      ),
      rx = PostgrestSyncTable(
        client,
        'rx',
        migration: rxMigration,
        tableMigration: rxMigration,
      ),
      dispensings = PostgrestSyncTable(
        client,
        'rx_dispensings',
        migration: rxMigration,
        tableMigration: rxMigration,
      );

  final SyncTable persons;
  final SyncTable rx;
  final SyncTable dispensings;
}
```

- [ ] **Step 5: Write the failing sync-cycle test**

First extend the fakes:
- `test/helpers/fake_remotes.dart`: import `rx_remote_datasource.dart`; add
  ```dart
  class FakeRxRemote implements RxRemoteDatasource {
    FakeRxRemote(FakeServerCore core, {FakeTransport? transport})
      : persons = FakeSyncTable(core, 'persons', transport: transport),
        rx = FakeSyncTable(core, 'rx', transport: transport),
        dispensings = FakeSyncTable(core, 'rx_dispensings', transport: transport);

    @override
    final FakeSyncTable persons;
    @override
    final FakeSyncTable rx;
    @override
    final FakeSyncTable dispensings;
  }
  ```
  and in `FakeServer`: `late final FakeRxRemote rx;` set in the constructor with `rx = FakeRxRemote(core, transport: transport);`.
- `test/helpers/fake_postgrest.dart`: add `'persons'`, `'rx'`, `'rx_dispensings'` to the not-null column map (~line 73: `'persons': {'id', 'name', 'user_id'}`, `'rx': {'id', 'kind', 'issued_on', 'user_id'}`, `'rx_dispensings': {'id', 'rx_id', 'item_id', 'packs', 'dispensed_on', 'user_id'}`) and to the table map (~line 182) using `RxRemoteDatasource(_client).persons/.rx/.dispensings`.
- `test/services/sync_service_test.dart` `Harness`: pass `rxRemote: this.server.rx` to `SyncService(...)`, and expose `late FakeRxRemote rx;` set from `this.server.rx`.

`test/services/rx_sync_test.dart`:
```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/data/local/app_database.dart';

import '../helpers/test_database.dart';
import 'sync_service_test.dart' show Harness;

void main() {
  setUp(setUpTestDatabase);
  tearDown(tearDownTestDatabase);

  Future<void> insertLocal(String table, Map<String, Object?> row) async =>
      (await AppDatabase.instance.database).insert(table, {
        'created_at': '2026-03-04T12:00:00.000Z',
        'updated_at': '2026-03-04T12:00:00.000Z',
        'edited_at': '2026-03-04T12:00:00.000Z',
        'sync_status': SyncStatus.pendingCreate,
        ...row,
      });

  test('a person, an rx and a dispensing made here reach the server', () async {
    final h = Harness();
    await insertLocal('persons', {'id': 'p1', 'name': 'Ben', 'exemptions': '[]'});
    await insertLocal('rx', {
      'id': 'r1',
      'person_id': 'p1',
      'kind': 'ssn',
      'issued_on': '2026-03-01',
      'items': '[{"id":"i1","description":"Brufen","packs":1}]',
      'cancelled': 0,
    });
    await insertLocal('rx_dispensings', {
      'id': 'd1',
      'rx_id': 'r1',
      'item_id': 'i1',
      'packs': 1,
      'dispensed_on': '2026-03-02',
      'units_added': 0,
    });
    await h.service.syncAll();
    expect(h.rx.persons.get('p1')?['name'], 'Ben');
    expect(h.rx.rx.get('r1')?['person_id'], 'p1');
    expect(h.rx.dispensings.get('d1')?['rx_id'], 'r1');
  });

  test('rows made on another device arrive here, dispensings after their rx',
      () async {
    final h = Harness();
    h.rx.dispensings.seed({
      'id': 'd9',
      'user_id': 'user-a',
      'rx_id': 'r9',
      'item_id': 'i1',
      'packs': 1,
      'dispensed_on': '2026-03-02',
      'units_added': 0,
    });
    h.rx.rx.seed({
      'id': 'r9',
      'user_id': 'user-a',
      'kind': 'white',
      'issued_on': '2026-03-01',
      'items': <Object?>[],
      'cancelled': false,
    });
    await h.service.syncAll();
    final db = await AppDatabase.instance.database;
    expect((await db.query('rx')).single['id'], 'r9');
    expect((await db.query('rx_dispensings')).single['id'], 'd9');
  });

  test('deleting an rx here deletes its dispensings on the server', () async {
    final h = Harness();
    await insertLocal('rx', {
      'id': 'r1',
      'kind': 'ssn',
      'issued_on': '2026-03-01',
      'items': '[]',
      'cancelled': 0,
    });
    await insertLocal('rx_dispensings', {
      'id': 'd1',
      'rx_id': 'r1',
      'item_id': 'i1',
      'packs': 1,
      'dispensed_on': '2026-03-02',
      'units_added': 0,
    });
    await h.service.syncAll();
    final db = await AppDatabase.instance.database;
    await db.update(
      'rx',
      {
        'sync_status': SyncStatus.pendingDelete,
        'deleted_at': '2026-03-05T12:00:00.000Z',
        'edited_at': '2026-03-05T12:00:00.000Z',
      },
      where: 'id = ?',
      whereArgs: ['r1'],
    );
    await h.service.syncAll();
    expect(h.rx.rx.get('r1')?['deleted_at'], isNotNull);
    expect(h.rx.dispensings.get('d1')?['deleted_at'], isNotNull);
  });
}
```
If `Harness` is not importable from `sync_service_test.dart` (a test file's top-level `main` makes the import awkward but legal), move `Harness` into `test/helpers/sync_harness.dart` first in a separate commit (`test: move the sync harness into helpers`) and import it from both files.

- [ ] **Step 6: Run to verify failure**

Run: `fvm flutter test test/services/rx_sync_test.dart`
Expected: FAIL — `No named parameter with the name 'rxRemote'`.

- [ ] **Step 7: Wire the cycle**

`lib/services/sync_service.dart`:
1. Import `rx_remote_datasource.dart`. Constructor: add `this.rxRemote,` (optional). Field:
   ```dart
   /// The prescription tables; null in local-only mode, and in a build or
   /// test that does not sync them.
   final RxRemoteDatasource? rxRemote;
   ```
2. `_tables`: append
   ```dart
    if (rxRemote != null) ...{
      'persons': _tableSync('persons', rxRemote!.persons),
      'rx': _tableSync('rx', rxRemote!.rx),
      'rx_dispensings': _tableSync('rx_dispensings', rxRemote!.dispensings),
    },
   ```
3. `_pushPendingChanges`: after the final `_pushTable('dose_logs', …)` call append
   ```dart
    // Prescriptions stand apart from the dosing tables: persons and rx
    // name nothing the server checks, and a dispensing follows its rx.
    if (rxRemote != null) {
      for (final table in const ['persons', 'rx', 'rx_dispensings']) {
        await _pushTable(table, report, userId, forceAll: forceAll);
      }
    }
   ```
   Update the "FK order" comment to mention them.
4. `_pullAll`: before `final hook = onPrescriptionsPulled;` add
   ```dart
    var rxTables = true;
    if (rxRemote != null) {
      final roots = await Future.wait([
        _pullTable('persons', report, force: force, horizon: horizon),
        _pullTable('rx', report, force: force, horizon: horizon),
      ]);
      final dispensings = await _pullTable(
        'rx_dispensings',
        report,
        force: force,
        horizon: horizon,
      );
      rxTables = !roots.contains(false) && dispensings;
    }
   ```
   and change the return to `… && prescriptions && doses && rxTables;`.
5. `_childTables`: add `'persons': <String>[], 'rx': ['rx_dispensings'], 'rx_dispensings': <String>[],`.
6. `discardFailedRow`: extend the first case to `case 'medications' || 'treatments' || 'prescriptions' || 'dose_logs' || 'persons' || 'rx' || 'rx_dispensings':`.
7. Search the file for any other hard-coded list of the four tables (`grep -n "'dose_logs'" lib/services/sync_service.dart`) and decide per hit: lists meaning "all synced tables" get the three new ones; dose-specific logic stays.

`lib/data/sync/remote_wipe.dart:40`: `const tables = ['medications', 'treatments', 'prescriptions', 'dose_logs', 'persons', 'rx', 'rx_dispensings'];` — dispensings are deleted with their rx by the local FK; deleting an already-gone row is a no-op, so the order is safe.

`lib/services/local_upload_marker.dart`: add `'persons', 'rx', 'rx_dispensings'` to `tables` and to the bases-clearing list inside `markAllForUpload`.

`lib/presentation/providers/providers.dart`:
```dart
final rxRemoteDatasourceProvider = Provider<RxRemoteDatasource?>((ref) {
  final client = ref.watch(supabaseClientProvider);
  return client == null ? null : RxRemoteDatasource(client);
});
```
and pass `rxRemote: ref.watch(rxRemoteDatasourceProvider),` in `syncServiceProvider`.

- [ ] **Step 8: Run tests**

Run: `fvm flutter test test/services/ test/data/`
Expected: PASS, including `local_upload_marker_test.dart`, `remote_wipe_test.dart`, `multi_device_wipe_sync_test.dart`. If a wipe test counts rows per table, extend its expectations for the new (empty) tables rather than excluding them.

- [ ] **Step 9: Commit**

```bash
fvm dart format lib test
fvm flutter analyze --fatal-infos
git add supabase/migrations/20260923000000_rx.sql lib test
git commit -m "feat(rx): server tables and sync cycle for prescriptions"
```

---

### Task 6: Repositories and providers

**Files:**
- Create: `lib/domain/repositories/person_repository.dart`, `lib/domain/repositories/rx_repository.dart`, `lib/data/repositories/person_repository_impl.dart`, `lib/data/repositories/rx_repository_impl.dart`, `lib/presentation/providers/rx_providers.dart`
- Modify: `lib/presentation/providers/providers.dart` (local datasource providers)
- Test: `test/data/repositories/rx_repository_test.dart`

**Interfaces:**
- Consumes: local datasources (Task 3), `MedicationRepository.updateQuantity`, `RequestSync`, `requestSyncSoon`, `nextUpdatedAt`.
- Produces:
  ```dart
  abstract class PersonRepository {
    Future<Result<List<Person>>> getPersons();
    Future<Result<Person?>> getByTaxCode(String taxCode);
    Future<Result<Person>> savePerson(Person person); // add or update
    Future<Result<void>> deletePerson(String id);
  }

  class RxWithDispensings {
    const RxWithDispensings(this.rx, this.dispensings);
    final Rx rx;
    final List<RxDispensing> dispensings;
    RxStatus statusAt(DateTime now) => RxRules.statusOf(rx, dispensings, now);
  }

  /// The save was refused because another live prescription has this NRE.
  class DuplicateNre implements Exception { const DuplicateNre(this.existingId); final String existingId; }

  abstract class RxRepository {
    Future<Result<List<RxWithDispensings>>> getAll();
    Future<Result<RxWithDispensings>> getById(String id);
    Future<Result<List<RxWithDispensings>>> getForTreatment(String treatmentId);
    /// Fails with message `duplicate_nre:<existingId>` when another live rx has the NRE.
    Future<Result<Rx>> saveRx(Rx rx);
    Future<Result<void>> deleteRx(String id);
    Future<Result<void>> redeem(String rxId, List<RxDispensing> dispensings);
    Future<Result<void>> undoDispensing(String dispensingId);
  }
  ```
  Providers — in `providers.dart` (so the stock reminder scheduler there can read them without an import cycle): `personLocalDatasourceProvider`, `rxLocalDatasourceProvider`, `rxDispensingLocalDatasourceProvider`, `personRepositoryProvider`, `rxRepositoryProvider`. In `rx_providers.dart` (imports `providers.dart`, never the other way): `personsProvider` (`FutureProvider<List<Person>>`), `rxListProvider` (`FutureProvider<List<RxWithDispensings>>`), `rxByIdProvider` (`FutureProvider.family<RxWithDispensings, String>`), `rxForTreatmentProvider` (`FutureProvider.family<List<RxWithDispensings>, String>`), `invalidateRx(WidgetRef)`.

The duplicate-NRE failure uses the `Result.failure` message `duplicate_nre:<id>` (the codebase's `Result` carries only a message); expose `const duplicateNrePrefix = 'duplicate_nre:';` in `rx_repository.dart` so the UI can parse it.

- [ ] **Step 1: Write the failing test**

`test/data/repositories/rx_repository_test.dart`:
```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/core/result.dart';
import 'package:medora/data/datasources/rx_dispensing_local_datasource.dart';
import 'package:medora/data/datasources/rx_local_datasource.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/repositories/rx_repository_impl.dart';
import 'package:medora/domain/entities/medication.dart';
import 'package:medora/domain/entities/rx.dart';
import 'package:medora/domain/entities/rx_dispensing.dart';
import 'package:medora/domain/repositories/rx_repository.dart';
import 'package:medora/domain/rx/rx_rules.dart';

import '../../helpers/failing_medication_repo.dart';
import '../../helpers/test_database.dart';

/// Records stock changes and fails them: the dispensing must be kept
/// whatever the stock does.
class _StockSpy extends FailingMedicationRepo {
  final calls = <(String, int)>[];
  @override
  Future<Result<Medication>> updateQuantity(String id, int delta) async {
    calls.add((id, delta));
    return const Result.failure('not needed');
  }
}

void main() {
  setUp(setUpTestDatabase);
  tearDown(tearDownTestDatabase);

  final now = DateTime(2026, 9, 23, 10);
  late _StockSpy stock;
  late RxRepositoryImpl repo;
  var syncs = 0;

  setUp(() {
    syncs = 0;
    stock = _StockSpy();
    repo = RxRepositoryImpl(
      rxLocal: RxLocalDatasource(now: () => now),
      dispensingLocal: RxDispensingLocalDatasource(now: () => now),
      medications: stock,
      requestSync: () async => syncs++,
      now: () => now,
    );
  });

  Rx rx(String id, {String? nre = '0410A1234567890'}) => Rx(
    id: id,
    kind: RxKind.ssn,
    nre: nre,
    issuedOn: DateTime(2026, 9, 20),
    validUntil: DateTime(2026, 10, 20),
    items: const [RxItem(id: 'i1', medicationId: 'm1', description: 'X', packs: 2)],
  );

  test('saving stores the rx as pending and asks for a sync', () async {
    final saved = await repo.saveRx(rx('r1'));
    expect(saved.isSuccess, isTrue);
    final db = await AppDatabase.instance.database;
    expect((await db.query('rx')).single['sync_status'], SyncStatus.pendingCreate);
    await Future<void>.delayed(Duration.zero);
    expect(syncs, 1);
  });

  test('a second rx with the same NRE is refused, naming the first', () async {
    await repo.saveRx(rx('r1'));
    final second = await repo.saveRx(rx('r2'));
    expect(second.isFailure, isTrue);
    second.when(
      success: (_) => fail('saved'),
      failure: (m) => expect(m, '${duplicateNrePrefix}r1'),
    );
  });

  test('editing the same rx keeps its NRE without a duplicate error', () async {
    await repo.saveRx(rx('r1'));
    final again = await repo.saveRx(rx('r1').copyWith(doctor: 'Dr. B'));
    expect(again.isSuccess, isTrue);
    final db = await AppDatabase.instance.database;
    expect((await db.query('rx')).single['sync_status'], SyncStatus.pendingUpdate);
  });

  test('an rx without NRE never collides', () async {
    expect((await repo.saveRx(rx('r1', nre: null))).isSuccess, isTrue);
    expect((await repo.saveRx(rx('r2', nre: null))).isSuccess, isTrue);
  });

  test('redeeming records dispensings and adds their units to stock', () async {
    await repo.saveRx(rx('r1'));
    final result = await repo.redeem('r1', [
      RxDispensing(
        id: 'd1',
        rxId: 'r1',
        itemId: 'i1',
        packs: 1,
        dispensedOn: DateTime(2026, 9, 23),
        unitsAdded: 20,
      ),
    ]);
    expect(result.isSuccess, isTrue);
    expect(stock.calls, [('m1', 20)]);
    final back = (await repo.getById('r1')).dataOrNull!;
    expect(back.dispensings.single.packs, 1);
    expect(back.statusAt(now), RxStatus.partial);
  });

  test('a dispensing with no units added leaves the stock alone', () async {
    await repo.saveRx(rx('r1'));
    await repo.redeem('r1', [
      RxDispensing(
        id: 'd1',
        rxId: 'r1',
        itemId: 'i1',
        packs: 2,
        dispensedOn: DateTime(2026, 9, 23),
      ),
    ]);
    expect(stock.calls, isEmpty);
    expect((await repo.getById('r1')).dataOrNull!.statusAt(now), RxStatus.redeemed);
  });

  test('undoing a dispensing removes it; the stock stays as the user left it',
      () async {
    await repo.saveRx(rx('r1'));
    await repo.redeem('r1', [
      RxDispensing(
        id: 'd1',
        rxId: 'r1',
        itemId: 'i1',
        packs: 1,
        dispensedOn: DateTime(2026, 9, 23),
        unitsAdded: 20,
      ),
    ]);
    await repo.undoDispensing('d1');
    expect((await repo.getById('r1')).dataOrNull!.dispensings, isEmpty);
    expect(stock.calls, [('m1', 20)]);
  });
}
```
`FailingMedicationRepo` (`test/helpers/failing_medication_repo.dart`) implements every `MedicationRepository` method with a failure; the spy overrides only `updateQuantity`.

- [ ] **Step 2: Run to verify failure**

Run: `fvm flutter test test/data/repositories/rx_repository_test.dart`
Expected: FAIL — missing `rx_repository_impl.dart`.

- [ ] **Step 3: Implement**

`lib/domain/repositories/rx_repository.dart`:
```dart
/// Medora - Prescription (Rx) Repository Interface
library;

import 'package:medora/core/result.dart';
import 'package:medora/domain/entities/rx.dart';
import 'package:medora/domain/entities/rx_dispensing.dart';
import 'package:medora/domain/rx/rx_rules.dart';

/// Prefix of the failure message when a save is refused because another
/// live prescription already has the NRE; the existing id follows.
const duplicateNrePrefix = 'duplicate_nre:';

class RxWithDispensings {
  const RxWithDispensings(this.rx, this.dispensings);
  final Rx rx;
  final List<RxDispensing> dispensings;

  RxStatus statusAt(DateTime now) => RxRules.statusOf(rx, dispensings, now);
}

abstract class RxRepository {
  Future<Result<List<RxWithDispensings>>> getAll();
  Future<Result<RxWithDispensings>> getById(String id);
  Future<Result<List<RxWithDispensings>>> getForTreatment(String treatmentId);

  /// Adds or updates [rx]. Refused ([duplicateNrePrefix]) when another live
  /// prescription has the same NRE.
  Future<Result<Rx>> saveRx(Rx rx);
  Future<Result<void>> deleteRx(String id);

  /// Records [dispensings] of [rxId]; each with `unitsAdded > 0` and an
  /// item linked to a medication adds those units to its stock.
  Future<Result<void>> redeem(String rxId, List<RxDispensing> dispensings);

  /// Removes a dispensing recorded by mistake. The stock is not touched:
  /// the user may already have counted it.
  Future<Result<void>> undoDispensing(String dispensingId);
}
```

`lib/data/repositories/rx_repository_impl.dart`:
```dart
/// Medora - Prescription (Rx) Repository (offline-first).
///
/// Same rules as the other repositories: write locally as pending, then ask
/// for a sync cycle, which is the only push path.
library;

import 'package:flutter/foundation.dart';
import 'package:medora/core/clock.dart';
import 'package:medora/core/result.dart';
import 'package:medora/data/datasources/rx_dispensing_local_datasource.dart';
import 'package:medora/data/datasources/rx_local_datasource.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/models/rx_dispensing_model.dart';
import 'package:medora/data/models/rx_model.dart';
import 'package:medora/data/sync/request_sync.dart';
import 'package:medora/domain/entities/rx.dart';
import 'package:medora/domain/entities/rx_dispensing.dart';
import 'package:medora/domain/repositories/medication_repository.dart';
import 'package:medora/domain/repositories/rx_repository.dart';

class RxRepositoryImpl implements RxRepository {
  RxRepositoryImpl({
    required this.rxLocal,
    required this.dispensingLocal,
    required this.medications,
    RequestSync? requestSync,
    Now now = systemNow,
  }) : _requestSync = requestSync,
       _now = now;

  final RxLocalDatasource rxLocal;
  final RxDispensingLocalDatasource dispensingLocal;
  final MedicationRepository medications;
  final RequestSync? _requestSync;
  final Now _now;

  Future<List<RxWithDispensings>> _withDispensings(List<RxModel> rows) async {
    final all = await dispensingLocal.getForRxIds([for (final r in rows) r.id]);
    return [
      for (final r in rows)
        RxWithDispensings(r.toDomain(), [
          for (final d in all)
            if (d.rxId == r.id) d.toDomain(),
        ]),
    ];
  }

  @override
  Future<Result<List<RxWithDispensings>>> getAll() async {
    try {
      return Result.success(await _withDispensings(await rxLocal.getAll()));
    } catch (e, st) {
      return Result.failure('Failed to load prescriptions: $e', st);
    }
  }

  @override
  Future<Result<RxWithDispensings>> getById(String id) async {
    try {
      final row = await rxLocal.getById(id);
      if (row == null || row.deletedAt != null) {
        return const Result.failure('Prescription not found');
      }
      return Result.success((await _withDispensings([row])).single);
    } catch (e, st) {
      return Result.failure('Failed to load prescription: $e', st);
    }
  }

  @override
  Future<Result<List<RxWithDispensings>>> getForTreatment(
    String treatmentId,
  ) async {
    try {
      return Result.success(
        await _withDispensings(await rxLocal.getForTreatment(treatmentId)),
      );
    } catch (e, st) {
      return Result.failure('Failed to load prescriptions: $e', st);
    }
  }

  @override
  Future<Result<Rx>> saveRx(Rx rx) async {
    try {
      final nre = rx.nre;
      if (nre != null) {
        final other = await rxLocal.getByNre(nre);
        if (other != null && other.id != rx.id) {
          return Result.failure('$duplicateNrePrefix${other.id}');
        }
      }
      final previous = await rxLocal.getById(rx.id);
      if (previous?.deletedAt != null) {
        return const Result.failure('Prescription was deleted');
      }
      final now = _now();
      final model = RxModel.fromDomain(
        rx.copyWith(
          createdAt: rx.createdAt ?? previous?.createdAt ?? now,
          updatedAt: nextUpdatedAt(previous?.updatedAt, now),
        ),
      );
      await rxLocal.upsert(
        model,
        syncStatus: previous == null
            ? SyncStatus.pendingCreate
            : SyncStatus.pendingUpdate,
      );
      _syncSoon();
      return Result.success(model.toDomain());
    } catch (e, st) {
      return Result.failure('Failed to save prescription: $e', st);
    }
  }

  @override
  Future<Result<void>> deleteRx(String id) async {
    try {
      // The local FK removes the dispensings only on a hard delete; mark
      // them too, so this device shows none and the server gets their
      // tombstones even if its cascade has not run yet.
      for (final d in await dispensingLocal.getForRx(id)) {
        await dispensingLocal.markDeleted(d.id);
      }
      await rxLocal.markDeleted(id);
      _syncSoon();
      return const Result.success(null);
    } catch (e, st) {
      return Result.failure('Failed to delete prescription: $e', st);
    }
  }

  @override
  Future<Result<void>> redeem(
    String rxId,
    List<RxDispensing> dispensings,
  ) async {
    try {
      final rx = await rxLocal.getById(rxId);
      if (rx == null || rx.deletedAt != null) {
        return const Result.failure('Prescription not found');
      }
      final now = _now();
      for (final d in dispensings) {
        await dispensingLocal.upsert(
          RxDispensingModel.fromDomain(d).copyWithStamps(
            createdAt: now,
            updatedAt: now,
          ),
          syncStatus: SyncStatus.pendingCreate,
        );
      }
      _syncSoon();
      // Stock after the dispensings are safe: a failed stock change must
      // not lose the record of what was collected.
      final byItem = {for (final i in rx.items) i.id: i};
      for (final d in dispensings) {
        final medicationId = byItem[d.itemId]?.medicationId;
        if (medicationId == null || d.unitsAdded <= 0) continue;
        final added = await medications.updateQuantity(
          medicationId,
          d.unitsAdded,
        );
        if (added.isFailure) {
          debugPrint('Rx: stock not updated for $medicationId');
        }
      }
      return const Result.success(null);
    } catch (e, st) {
      return Result.failure('Failed to record dispensing: $e', st);
    }
  }

  @override
  Future<Result<void>> undoDispensing(String dispensingId) async {
    try {
      await dispensingLocal.markDeleted(dispensingId);
      _syncSoon();
      return const Result.success(null);
    } catch (e, st) {
      return Result.failure('Failed to undo dispensing: $e', st);
    }
  }

  void _syncSoon() => requestSyncSoon(_requestSync, 'prescription');
}
```
Add to `RxDispensingModel` (Task 3 file):
```dart
  RxDispensingModel copyWithStamps({DateTime? createdAt, DateTime? updatedAt}) =>
      RxDispensingModel(
        id: id,
        userId: userId,
        rxId: rxId,
        itemId: itemId,
        packs: packs,
        dispensedOn: dispensedOn,
        pharmacy: pharmacy,
        unitsAdded: unitsAdded,
        createdAt: createdAt ?? this.createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
        deletedAt: deletedAt,
      );
```
`MedicationRepository.updateQuantity` returns `Result<Medication>`; `added.isFailure` works on any `Result`.

`lib/domain/repositories/person_repository.dart`:
```dart
/// Medora - Person Repository Interface
library;

import 'package:medora/core/result.dart';
import 'package:medora/domain/entities/person.dart';

abstract class PersonRepository {
  Future<Result<List<Person>>> getPersons();
  Future<Result<Person?>> getByTaxCode(String taxCode);

  /// Adds or updates [person].
  Future<Result<Person>> savePerson(Person person);
  Future<Result<void>> deletePerson(String id);
}
```

`lib/data/repositories/person_repository_impl.dart`:
```dart
/// Medora - Person Repository (offline-first).
library;

import 'package:medora/core/clock.dart';
import 'package:medora/core/result.dart';
import 'package:medora/data/datasources/person_local_datasource.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/models/person_model.dart';
import 'package:medora/data/sync/request_sync.dart';
import 'package:medora/domain/entities/person.dart';
import 'package:medora/domain/repositories/person_repository.dart';

class PersonRepositoryImpl implements PersonRepository {
  PersonRepositoryImpl({
    required this.local,
    RequestSync? requestSync,
    Now now = systemNow,
  }) : _requestSync = requestSync,
       _now = now;

  final PersonLocalDatasource local;
  final RequestSync? _requestSync;
  final Now _now;

  @override
  Future<Result<List<Person>>> getPersons() async {
    try {
      final rows = await local.getPersons();
      return Result.success([for (final r in rows) r.toDomain()]);
    } catch (e, st) {
      return Result.failure('Failed to load persons: $e', st);
    }
  }

  @override
  Future<Result<Person?>> getByTaxCode(String taxCode) async {
    try {
      return Result.success((await local.getByTaxCode(taxCode))?.toDomain());
    } catch (e, st) {
      return Result.failure('Failed to load person: $e', st);
    }
  }

  @override
  Future<Result<Person>> savePerson(Person person) async {
    try {
      final previous = await local.getPersonById(person.id);
      if (previous?.deletedAt != null) {
        return const Result.failure('Person was deleted');
      }
      final now = _now();
      final model = PersonModel.fromDomain(
        person.copyWith(
          createdAt: person.createdAt ?? previous?.createdAt ?? now,
          updatedAt: nextUpdatedAt(previous?.updatedAt, now),
        ),
      );
      await local.upsert(
        model,
        syncStatus: previous == null
            ? SyncStatus.pendingCreate
            : SyncStatus.pendingUpdate,
      );
      requestSyncSoon(_requestSync, 'person');
      return Result.success(model.toDomain());
    } catch (e, st) {
      return Result.failure('Failed to save person: $e', st);
    }
  }

  @override
  Future<Result<void>> deletePerson(String id) async {
    try {
      await local.markDeleted(id);
      requestSyncSoon(_requestSync, 'person');
      return const Result.success(null);
    } catch (e, st) {
      return Result.failure('Failed to delete person: $e', st);
    }
  }
}
```

In `lib/presentation/providers/providers.dart` (next to the other repository providers; add the imports):
```dart
final personLocalDatasourceProvider = Provider<PersonLocalDatasource>(
  (ref) => PersonLocalDatasource(now: ref.watch(nowProvider)),
);

final rxLocalDatasourceProvider = Provider<RxLocalDatasource>(
  (ref) => RxLocalDatasource(now: ref.watch(nowProvider)),
);

final rxDispensingLocalDatasourceProvider =
    Provider<RxDispensingLocalDatasource>(
      (ref) => RxDispensingLocalDatasource(now: ref.watch(nowProvider)),
    );

final personRepositoryProvider = Provider<PersonRepository>(
  (ref) => PersonRepositoryImpl(
    local: ref.watch(personLocalDatasourceProvider),
    requestSync: _requestSyncInCloud(
      ref,
      ref.watch(rxRemoteDatasourceProvider),
    ),
    now: ref.watch(nowProvider),
  ),
);

final rxRepositoryProvider = Provider<RxRepository>(
  (ref) => RxRepositoryImpl(
    rxLocal: ref.watch(rxLocalDatasourceProvider),
    dispensingLocal: ref.watch(rxDispensingLocalDatasourceProvider),
    medications: ref.watch(medicationRepositoryProvider),
    requestSync: _requestSyncInCloud(
      ref,
      ref.watch(rxRemoteDatasourceProvider),
    ),
    now: ref.watch(nowProvider),
  ),
);
```

`lib/presentation/providers/rx_providers.dart`:
```dart
/// Medora - What the screens show of persons and prescriptions.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:medora/domain/entities/person.dart';
import 'package:medora/domain/repositories/rx_repository.dart';
import 'package:medora/presentation/providers/providers.dart';

final personsProvider = FutureProvider<List<Person>>((ref) async {
  final result = await ref.watch(personRepositoryProvider).getPersons();
  return result.when(success: (p) => p, failure: (m) => throw Exception(m));
});

final rxListProvider = FutureProvider<List<RxWithDispensings>>((ref) async {
  final result = await ref.watch(rxRepositoryProvider).getAll();
  return result.when(success: (r) => r, failure: (m) => throw Exception(m));
});

final rxByIdProvider = FutureProvider.family<RxWithDispensings, String>((
  ref,
  id,
) async {
  final result = await ref.watch(rxRepositoryProvider).getById(id);
  return result.when(success: (r) => r, failure: (m) => throw Exception(m));
});

final rxForTreatmentProvider =
    FutureProvider.family<List<RxWithDispensings>, String>((ref, id) async {
      final result = await ref.watch(rxRepositoryProvider).getForTreatment(id);
      return result.when(success: (r) => r, failure: (m) => throw Exception(m));
    });

/// Refresh everything that shows prescriptions, after a write.
void invalidateRx(WidgetRef ref) {
  ref.invalidate(rxListProvider);
  ref.invalidate(rxByIdProvider);
  ref.invalidate(rxForTreatmentProvider);
}
```
(`nowProvider` lives in `lib/presentation/providers/now_provider.dart`, which `providers.dart` already imports.)

Also add a repository test for persons (append to the same test file or `person_repository_test.dart`): save → pendingCreate; save again → pendingUpdate; delete → hidden from `getPersons`.

- [ ] **Step 4: Run tests**

Run: `fvm flutter test test/data/repositories/`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
fvm dart format lib test
fvm flutter analyze --fatal-infos
git add lib test
git commit -m "feat(rx): person and prescription repositories"
```

---
### Task 7: Strings (EN/DE/IT)

**Files:**
- Modify: `lib/l10n/app_en.arb`, `lib/l10n/app_de.arb`, `lib/l10n/app_it.arb`, generated `lib/l10n/generated/*`

**Interfaces:**
- Produces the `AppLocalizations` getters used by Tasks 8–11 (names below). Reused existing keys: `save`, `delete`, `cancel`, `edit`, `add`, `undo`, `name`, `notes`, `required`, `treatment`, `doctorLabel`, `doctorHint`, `genericError`.

- [ ] **Step 1: Add the keys**

Append before the closing `}` of each ARB (keep the file's existing formatting; put a comma after the previous last entry). English (`app_en.arb`):
```json
  "rxTab": "Prescriptions",
  "rxNew": "New prescription",
  "rxEdit": "Edit prescription",
  "rxNoneYet": "No prescriptions yet",
  "rxNoneYetHint": "Keep the number, validity and what is left to collect at hand",
  "rxAdd": "Add prescription",
  "rxKind": "Type",
  "rxKindSsn": "National health service (SSN)",
  "rxKindWhite": "Private (white)",
  "rxKindWhiteRepeatable": "Private, repeatable",
  "rxKindReferral": "Referral",
  "rxKindShortSsn": "SSN",
  "rxKindShortWhite": "White",
  "rxKindShortWhiteRepeatable": "Repeatable",
  "rxKindShortReferral": "Referral",
  "rxNre": "Prescription number (NRE)",
  "rxNreInvalid": "15 letters or digits",
  "rxNreDuplicate": "This prescription number is already saved",
  "rxOpenExisting": "Open",
  "rxIssuedOn": "Issued on",
  "rxValidUntil": "Valid until",
  "rxExemption": "Exemption code",
  "rxPriority": "Priority",
  "rxPriorityU": "U – within 72 hours",
  "rxPriorityB": "B – within 10 days",
  "rxPriorityD": "D – within 30 days",
  "rxPriorityP": "P – within 120 days",
  "rxMaxDispensings": "Max. collections",
  "rxPerson": "Person",
  "rxNoPerson": "No person",
  "rxUnknownPerson": "Unknown person",
  "rxItems": "Medicines",
  "rxAddItem": "Add medicine",
  "rxItemDescription": "Medicine",
  "rxItemPacks": "Packs",
  "rxNonSubstitutable": "Not substitutable",
  "rxStatusOpen": "Open",
  "rxStatusPartial": "Partly collected",
  "rxStatusRedeemed": "Collected",
  "rxStatusExpired": "Expired",
  "rxStatusCancelled": "Cancelled",
  "rxGroupDone": "Done & expired",
  "rxDaysLeft": "{days, plural, =0{Last day} =1{1 day left} other{{days} days left}}",
  "@rxDaysLeft": { "placeholders": { "days": { "type": "int" } } },
  "rxBookBy": "Book by {date}",
  "@rxBookBy": { "placeholders": { "date": { "type": "String" } } },
  "rxShowAtPharmacy": "Show at pharmacy",
  "rxTaxCode": "Tax code",
  "rxTaxCodeInvalid": "Not a valid tax code",
  "rxRedeem": "Collect",
  "rxRedeemTitle": "Collect at the pharmacy",
  "rxPharmacy": "Pharmacy",
  "rxAddToStock": "Add to stock",
  "rxUnitsToAdd": "Units to add",
  "rxCollectedOn": "Collected on",
  "rxCollections": "Collections",
  "rxRemoveCollection": "Remove",
  "rxMarkDone": "Mark as done",
  "rxCancelRx": "Cancel prescription",
  "rxDelete": "Delete prescription",
  "rxDeleteConfirm": "Delete this prescription and its collections?",
  "rxShare": "Share number",
  "rxShareText": "Prescription {nre}\nTax code {taxCode}",
  "@rxShareText": { "placeholders": { "nre": { "type": "String" }, "taxCode": { "type": "String" } } },
  "rxExpiringTitle": "Prescriptions expiring",
  "rxNothingLeft": "Nothing left to collect",
  "notificationRxExpiryTitle": "Prescription expiring",
  "notificationRxExpiryBody": "{days, plural, =0{{name}: last valid day} =1{{name}: valid until tomorrow} other{{name}: valid {days} more days}}",
  "@notificationRxExpiryBody": { "placeholders": { "name": { "type": "String" }, "days": { "type": "int" } } },
  "notificationAskForRx": "Ask your doctor for a new prescription",
  "persons": "Persons",
  "personsHint": "Tax codes and exemptions for prescriptions",
  "personNew": "New person",
  "personEdit": "Edit person",
  "personExemptions": "Exemption codes",
  "personExemptionsHint": "e.g. E01, 048",
  "personDelete": "Delete person",
  "personDeleteConfirm": "Delete {name}? Prescriptions stay.",
  "@personDeleteConfirm": { "placeholders": { "name": { "type": "String" } } },
  "personNoneYet": "No persons yet"
```
German (`app_de.arb`):
```json
  "rxTab": "Rezepte",
  "rxNew": "Neues Rezept",
  "rxEdit": "Rezept bearbeiten",
  "rxNoneYet": "Noch keine Rezepte",
  "rxNoneYetHint": "Nummer, Gültigkeit und was noch abzuholen ist, immer griffbereit",
  "rxAdd": "Rezept hinzufügen",
  "rxKind": "Art",
  "rxKindSsn": "Sanitätsbetrieb (SSN)",
  "rxKindWhite": "Privat (weiß)",
  "rxKindWhiteRepeatable": "Privat, wiederholbar",
  "rxKindReferral": "Überweisung",
  "rxKindShortSsn": "SSN",
  "rxKindShortWhite": "Weiß",
  "rxKindShortWhiteRepeatable": "Wiederholbar",
  "rxKindShortReferral": "Überweisung",
  "rxNre": "Rezeptnummer (NRE)",
  "rxNreInvalid": "15 Buchstaben oder Ziffern",
  "rxNreDuplicate": "Diese Rezeptnummer ist schon gespeichert",
  "rxOpenExisting": "Öffnen",
  "rxIssuedOn": "Ausgestellt am",
  "rxValidUntil": "Gültig bis",
  "rxExemption": "Befreiungscode",
  "rxPriority": "Priorität",
  "rxPriorityU": "U – innerhalb 72 Stunden",
  "rxPriorityB": "B – innerhalb 10 Tagen",
  "rxPriorityD": "D – innerhalb 30 Tagen",
  "rxPriorityP": "P – innerhalb 120 Tagen",
  "rxMaxDispensings": "Max. Abholungen",
  "rxPerson": "Person",
  "rxNoPerson": "Keine Person",
  "rxUnknownPerson": "Unbekannte Person",
  "rxItems": "Medikamente",
  "rxAddItem": "Medikament hinzufügen",
  "rxItemDescription": "Medikament",
  "rxItemPacks": "Packungen",
  "rxNonSubstitutable": "Nicht substituierbar",
  "rxStatusOpen": "Offen",
  "rxStatusPartial": "Teilweise eingelöst",
  "rxStatusRedeemed": "Eingelöst",
  "rxStatusExpired": "Abgelaufen",
  "rxStatusCancelled": "Storniert",
  "rxGroupDone": "Erledigt & abgelaufen",
  "rxDaysLeft": "{days, plural, =0{Letzter Tag} =1{Noch 1 Tag} other{Noch {days} Tage}}",
  "@rxDaysLeft": { "placeholders": { "days": { "type": "int" } } },
  "rxBookBy": "Buchen bis {date}",
  "@rxBookBy": { "placeholders": { "date": { "type": "String" } } },
  "rxShowAtPharmacy": "In der Apotheke zeigen",
  "rxTaxCode": "Steuernummer",
  "rxTaxCodeInvalid": "Keine gültige Steuernummer",
  "rxRedeem": "Einlösen",
  "rxRedeemTitle": "In der Apotheke einlösen",
  "rxPharmacy": "Apotheke",
  "rxAddToStock": "Zum Bestand hinzufügen",
  "rxUnitsToAdd": "Einheiten hinzufügen",
  "rxCollectedOn": "Eingelöst am",
  "rxCollections": "Einlösungen",
  "rxRemoveCollection": "Entfernen",
  "rxMarkDone": "Als erledigt markieren",
  "rxCancelRx": "Rezept stornieren",
  "rxDelete": "Rezept löschen",
  "rxDeleteConfirm": "Dieses Rezept und seine Einlösungen löschen?",
  "rxShare": "Nummer teilen",
  "rxShareText": "Rezept {nre}\nSteuernummer {taxCode}",
  "@rxShareText": { "placeholders": { "nre": { "type": "String" }, "taxCode": { "type": "String" } } },
  "rxExpiringTitle": "Rezepte laufen ab",
  "rxNothingLeft": "Nichts mehr abzuholen",
  "notificationRxExpiryTitle": "Rezept läuft ab",
  "notificationRxExpiryBody": "{days, plural, =0{{name}: letzter gültiger Tag} =1{{name}: gültig bis morgen} other{{name}: noch {days} Tage gültig}}",
  "@notificationRxExpiryBody": { "placeholders": { "name": { "type": "String" }, "days": { "type": "int" } } },
  "notificationAskForRx": "Beim Arzt ein neues Rezept anfragen",
  "persons": "Personen",
  "personsHint": "Steuernummern und Befreiungen für Rezepte",
  "personNew": "Neue Person",
  "personEdit": "Person bearbeiten",
  "personExemptions": "Befreiungscodes",
  "personExemptionsHint": "z. B. E01, 048",
  "personDelete": "Person löschen",
  "personDeleteConfirm": "{name} löschen? Rezepte bleiben erhalten.",
  "@personDeleteConfirm": { "placeholders": { "name": { "type": "String" } } },
  "personNoneYet": "Noch keine Personen"
```
Italian (`app_it.arb`):
```json
  "rxTab": "Ricette",
  "rxNew": "Nuova ricetta",
  "rxEdit": "Modifica ricetta",
  "rxNoneYet": "Nessuna ricetta",
  "rxNoneYetHint": "Numero, validità e cosa resta da ritirare sempre a portata di mano",
  "rxAdd": "Aggiungi ricetta",
  "rxKind": "Tipo",
  "rxKindSsn": "Servizio sanitario (SSN)",
  "rxKindWhite": "Bianca",
  "rxKindWhiteRepeatable": "Bianca ripetibile",
  "rxKindReferral": "Impegnativa",
  "rxKindShortSsn": "SSN",
  "rxKindShortWhite": "Bianca",
  "rxKindShortWhiteRepeatable": "Ripetibile",
  "rxKindShortReferral": "Impegnativa",
  "rxNre": "Numero ricetta (NRE)",
  "rxNreInvalid": "15 lettere o cifre",
  "rxNreDuplicate": "Questo numero di ricetta è già salvato",
  "rxOpenExisting": "Apri",
  "rxIssuedOn": "Emessa il",
  "rxValidUntil": "Valida fino al",
  "rxExemption": "Codice esenzione",
  "rxPriority": "Priorità",
  "rxPriorityU": "U – entro 72 ore",
  "rxPriorityB": "B – entro 10 giorni",
  "rxPriorityD": "D – entro 30 giorni",
  "rxPriorityP": "P – entro 120 giorni",
  "rxMaxDispensings": "Ritiri massimi",
  "rxPerson": "Persona",
  "rxNoPerson": "Nessuna persona",
  "rxUnknownPerson": "Persona sconosciuta",
  "rxItems": "Farmaci",
  "rxAddItem": "Aggiungi farmaco",
  "rxItemDescription": "Farmaco",
  "rxItemPacks": "Confezioni",
  "rxNonSubstitutable": "Non sostituibile",
  "rxStatusOpen": "Aperta",
  "rxStatusPartial": "Ritirata in parte",
  "rxStatusRedeemed": "Ritirata",
  "rxStatusExpired": "Scaduta",
  "rxStatusCancelled": "Annullata",
  "rxGroupDone": "Concluse e scadute",
  "rxDaysLeft": "{days, plural, =0{Ultimo giorno} =1{Ancora 1 giorno} other{Ancora {days} giorni}}",
  "@rxDaysLeft": { "placeholders": { "days": { "type": "int" } } },
  "rxBookBy": "Prenotare entro il {date}",
  "@rxBookBy": { "placeholders": { "date": { "type": "String" } } },
  "rxShowAtPharmacy": "Mostra in farmacia",
  "rxTaxCode": "Codice fiscale",
  "rxTaxCodeInvalid": "Codice fiscale non valido",
  "rxRedeem": "Ritira",
  "rxRedeemTitle": "Ritiro in farmacia",
  "rxPharmacy": "Farmacia",
  "rxAddToStock": "Aggiungi alle scorte",
  "rxUnitsToAdd": "Unità da aggiungere",
  "rxCollectedOn": "Ritirata il",
  "rxCollections": "Ritiri",
  "rxRemoveCollection": "Rimuovi",
  "rxMarkDone": "Segna come conclusa",
  "rxCancelRx": "Annulla ricetta",
  "rxDelete": "Elimina ricetta",
  "rxDeleteConfirm": "Eliminare questa ricetta e i suoi ritiri?",
  "rxShare": "Condividi numero",
  "rxShareText": "Ricetta {nre}\nCodice fiscale {taxCode}",
  "@rxShareText": { "placeholders": { "nre": { "type": "String" }, "taxCode": { "type": "String" } } },
  "rxExpiringTitle": "Ricette in scadenza",
  "rxNothingLeft": "Niente da ritirare",
  "notificationRxExpiryTitle": "Ricetta in scadenza",
  "notificationRxExpiryBody": "{days, plural, =0{{name}: ultimo giorno di validità} =1{{name}: valida fino a domani} other{{name}: valida ancora {days} giorni}}",
  "@notificationRxExpiryBody": { "placeholders": { "name": { "type": "String" }, "days": { "type": "int" } } },
  "notificationAskForRx": "Chiedi al medico una nuova ricetta",
  "persons": "Persone",
  "personsHint": "Codici fiscali ed esenzioni per le ricette",
  "personNew": "Nuova persona",
  "personEdit": "Modifica persona",
  "personExemptions": "Codici di esenzione",
  "personExemptionsHint": "es. E01, 048",
  "personDelete": "Elimina persona",
  "personDeleteConfirm": "Eliminare {name}? Le ricette restano.",
  "@personDeleteConfirm": { "placeholders": { "name": { "type": "String" } } },
  "personNoneYet": "Nessuna persona"
```
If `app_de.arb`/`app_it.arb` carry no `@key` metadata elsewhere (only the English template does), drop the `@…` entries from those two files.

- [ ] **Step 2: Generate and verify**

```bash
fvm flutter gen-l10n
fvm flutter analyze --fatal-infos
fvm flutter test test/presentation/l10n_sweep_test.dart
```
Expected: no errors; the German wording is reviewed by the user at the end (they read German).

- [ ] **Step 3: Commit**

```bash
git add lib/l10n
git commit -m "feat(rx): strings for prescriptions and persons (en, de, it)"
```

---

### Task 8: Persons screens

**Files:**
- Create: `lib/presentation/screens/persons/person_list_screen.dart`, `lib/presentation/screens/persons/person_form_screen.dart`
- Modify: `lib/presentation/router/app_router.dart` (routes `persons`, `addPerson`, `editPerson`), `lib/presentation/screens/settings/settings_screen.dart` (entry tile)
- Test: `test/presentation/screens/persons/person_form_screen_test.dart`

**Interfaces:**
- Consumes: `personRepositoryProvider`, `personsProvider` (Task 6), `TaxCode` (Task 1), strings (Task 7).
- Produces: routes `AppRoutes.persons = '/persons'`, `AppRoutes.addPerson = '/persons/add'`, `AppRoutes.editPerson = '/persons/:id/edit'`; `PersonFormScreen({String? personId})`.

- [ ] **Step 1: Write the failing widget test**

`test/presentation/screens/persons/person_form_screen_test.dart`:
```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/core/result.dart';
import 'package:medora/domain/entities/person.dart';
import 'package:medora/domain/repositories/person_repository.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/presentation/providers/providers.dart';
import 'package:medora/presentation/screens/persons/person_form_screen.dart';

class _Repo implements PersonRepository {
  final saved = <Person>[];
  @override
  Future<Result<Person>> savePerson(Person p) async {
    saved.add(p);
    return Result.success(p);
  }

  @override
  Future<Result<List<Person>>> getPersons() async => Result.success(saved);
  @override
  Future<Result<Person?>> getByTaxCode(String t) async =>
      const Result.success(null);
  @override
  Future<Result<void>> deletePerson(String id) async =>
      const Result.success(null);
}

void main() {
  Future<_Repo> pump(WidgetTester tester) async {
    final repo = _Repo();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [personRepositoryProvider.overrideWithValue(repo)],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: Locale('en'),
          home: PersonFormScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return repo;
  }

  testWidgets('an invalid tax code blocks saving', (tester) async {
    final repo = await pump(tester);
    await tester.enterText(find.byKey(const Key('person_name')), 'Ben');
    await tester.enterText(
      find.byKey(const Key('person_tax_code')),
      'RSSMRA85T10A562T',
    );
    await tester.tap(find.byKey(const Key('person_save')));
    await tester.pumpAndSettle();
    expect(find.text('Not a valid tax code'), findsOneWidget);
    expect(repo.saved, isEmpty);
  });

  testWidgets('a valid person is saved normalised', (tester) async {
    final repo = await pump(tester);
    await tester.enterText(find.byKey(const Key('person_name')), 'Ben');
    await tester.enterText(
      find.byKey(const Key('person_tax_code')),
      'rss mra85t10a562s',
    );
    await tester.enterText(
      find.byKey(const Key('person_exemptions')),
      'e01, 048',
    );
    await tester.tap(find.byKey(const Key('person_save')));
    await tester.pumpAndSettle();
    expect(repo.saved.single.taxCode, 'RSSMRA85T10A562S');
    expect(repo.saved.single.exemptions, ['E01', '048']);
  });
}
```
Note: `PersonFormScreen` pops via `context.pop()` from go_router after saving; wrap the pop in `if (context.canPop()) context.pop();` (use `Navigator.of(context).maybePop()`) so the test's plain `MaterialApp` works.

- [ ] **Step 2: Run to verify failure**

Run: `fvm flutter test test/presentation/screens/persons/`
Expected: FAIL — missing `person_form_screen.dart`.

- [ ] **Step 3: Implement the form**

`lib/presentation/screens/persons/person_form_screen.dart`:
```dart
/// Medora - Add or edit a person (name, tax code, exemptions).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:medora/domain/entities/person.dart';
import 'package:medora/domain/rx/tax_code.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/presentation/providers/providers.dart';
import 'package:medora/presentation/providers/rx_providers.dart';
import 'package:uuid/uuid.dart';

class PersonFormScreen extends ConsumerStatefulWidget {
  const PersonFormScreen({super.key, this.personId});

  final String? personId;

  @override
  ConsumerState<PersonFormScreen> createState() => _PersonFormScreenState();
}

class _PersonFormScreenState extends ConsumerState<PersonFormScreen> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _taxCode = TextEditingController();
  final _exemptions = TextEditingController();
  final _notes = TextEditingController();
  Person? _existing;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final id = widget.personId;
    if (id != null) _load(id);
  }

  Future<void> _load(String id) async {
    final persons = await ref.read(personsProvider.future);
    final p = persons.where((p) => p.id == id).firstOrNull;
    if (p == null || !mounted) return;
    setState(() {
      _existing = p;
      _name.text = p.name;
      _taxCode.text = p.taxCode ?? '';
      _exemptions.text = p.exemptions.join(', ');
      _notes.text = p.notes ?? '';
    });
  }

  @override
  void dispose() {
    _name.dispose();
    _taxCode.dispose();
    _exemptions.dispose();
    _notes.dispose();
    super.dispose();
  }

  /// "e01, 048 ;E02" → ["E01", "048", "E02"].
  static List<String> _parseExemptions(String raw) => [
    for (final part in raw.split(RegExp(r'[,;\s]+')))
      if (part.trim().isNotEmpty) part.trim().toUpperCase(),
  ];

  Future<void> _save() async {
    if (_saving || !_form.currentState!.validate()) return;
    setState(() => _saving = true);
    final taxCode = _taxCode.text.trim();
    final notes = _notes.text.trim();
    final person = Person(
      id: _existing?.id ?? const Uuid().v4(),
      userId: _existing?.userId,
      name: _name.text.trim(),
      taxCode: taxCode.isEmpty ? null : TaxCode.normalize(taxCode),
      exemptions: _parseExemptions(_exemptions.text),
      notes: notes.isEmpty ? null : notes,
      createdAt: _existing?.createdAt,
      updatedAt: _existing?.updatedAt,
    );
    final result = await ref.read(personRepositoryProvider).savePerson(person);
    if (!mounted) return;
    setState(() => _saving = false);
    result.when(
      success: (_) {
        ref.invalidate(personsProvider);
        Navigator.of(context).maybePop();
      },
      failure: (_) => ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppLocalizations.of(context).genericError)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(_existing == null ? l10n.personNew : l10n.personEdit),
      ),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextFormField(
              key: const Key('person_name'),
              controller: _name,
              textCapitalization: TextCapitalization.words,
              decoration: InputDecoration(labelText: l10n.name),
              validator: (v) =>
                  (v ?? '').trim().isEmpty ? l10n.required : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              key: const Key('person_tax_code'),
              controller: _taxCode,
              textCapitalization: TextCapitalization.characters,
              decoration: InputDecoration(labelText: l10n.rxTaxCode),
              validator: (v) {
                final raw = (v ?? '').trim();
                if (raw.isEmpty) return null;
                return TaxCode.isValid(raw) ? null : l10n.rxTaxCodeInvalid;
              },
            ),
            const SizedBox(height: 12),
            TextFormField(
              key: const Key('person_exemptions'),
              controller: _exemptions,
              textCapitalization: TextCapitalization.characters,
              decoration: InputDecoration(
                labelText: l10n.personExemptions,
                hintText: l10n.personExemptionsHint,
              ),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _notes,
              maxLines: 3,
              decoration: InputDecoration(labelText: l10n.notes),
            ),
            const SizedBox(height: 24),
            FilledButton(
              key: const Key('person_save'),
              onPressed: _saving ? null : _save,
              child: Text(l10n.save),
            ),
          ],
        ),
      ),
    );
  }
}
```

`lib/presentation/screens/persons/person_list_screen.dart`:
```dart
/// Medora - The persons prescriptions are written for.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:medora/domain/entities/person.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/presentation/providers/providers.dart';
import 'package:medora/presentation/providers/rx_providers.dart';
import 'package:medora/presentation/router/app_router.dart';
import 'package:medora/presentation/widgets/async_value_view.dart';
import 'package:medora/presentation/widgets/shared_widgets.dart';

class PersonListScreen extends ConsumerWidget {
  const PersonListScreen({super.key});

  Future<void> _delete(BuildContext context, WidgetRef ref, Person p) async {
    final l10n = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.personDelete),
        content: Text(l10n.personDeleteConfirm(p.name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.delete),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(personRepositoryProvider).deletePerson(p.id);
    ref.invalidate(personsProvider);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.persons)),
      body: AsyncValueView<List<Person>>(
        value: ref.watch(personsProvider),
        onRetry: () async => ref.invalidate(personsProvider),
        emptyWhen: (p) => p.isEmpty,
        empty: EmptyStateWidget(
          icon: Icons.badge_outlined,
          title: l10n.personNoneYet,
          subtitle: l10n.personsHint,
          actionLabel: l10n.personNew,
          onAction: () => context.push(AppRoutes.addPerson),
        ),
        data: (persons) => ListView(
          children: [
            for (final p in persons)
              ListTile(
                leading: const Icon(Icons.person_outline),
                title: Text(p.name),
                subtitle: p.taxCode == null && p.exemptions.isEmpty
                    ? null
                    : Text(
                        [
                          ?p.taxCode,
                          if (p.exemptions.isNotEmpty) p.exemptions.join(', '),
                        ].join(' · '),
                      ),
                onTap: () => context.push(
                  AppRoutes.editPerson.replaceFirst(':id', p.id),
                ),
                trailing: IconButton(
                  icon: const Icon(Icons.delete_outline),
                  tooltip: l10n.personDelete,
                  onPressed: () => _delete(context, ref, p),
                ),
              ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        tooltip: l10n.personNew,
        onPressed: () => context.push(AppRoutes.addPerson),
        child: const Icon(Icons.add),
      ),
    );
  }
}
```
(`?p.taxCode` is Dart 3.8+ null-aware element syntax, already used in this codebase, e.g. `column: ?(…)` in `sync_meta.dart`.)

Router: add to `AppRoutes`:
```dart
  static const persons = '/persons';
  static const addPerson = '/persons/add';
  static const editPerson = '/persons/:id/edit';
```
and inside the `ShellRoute.routes` list (put `addPerson` before `editPerson`):
```dart
          GoRoute(
            path: AppRoutes.persons,
            builder: (_, _) => const PersonListScreen(),
          ),
          GoRoute(
            path: AppRoutes.addPerson,
            builder: (_, _) => const PersonFormScreen(),
          ),
          GoRoute(
            path: AppRoutes.editPerson,
            builder: (_, state) =>
                PersonFormScreen(personId: state.pathParameters['id']),
          ),
```
Settings: add, right after the color-scheme `ListTile` (line ~105–110), a tile:
```dart
              ListTile(
                leading: const Icon(Icons.badge_outlined),
                title: Text(l10n.persons),
                subtitle: Text(l10n.personsHint),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => context.push(AppRoutes.persons),
              ),
```

- [ ] **Step 4: Run tests**

Run: `fvm flutter test test/presentation/`
Expected: PASS (including `l10n_sweep_test`).

- [ ] **Step 5: Commit**

```bash
fvm dart format lib test
fvm flutter analyze --fatal-infos
git add lib test
git commit -m "feat(rx): persons list and form"
```

---

### Task 9: Prescription list and form

**Files:**
- Create: `lib/presentation/screens/rx/rx_list_view.dart`, `lib/presentation/screens/rx/rx_form_screen.dart`, `lib/presentation/screens/rx/rx_labels.dart`
- Modify: `lib/presentation/screens/treatment/treatment_list_screen.dart` (segment + FAB), `lib/presentation/router/app_router.dart` (routes)
- Test: `test/presentation/screens/rx/rx_form_screen_test.dart`, `test/presentation/screens/rx/rx_list_view_test.dart`

**Interfaces:**
- Consumes: `rxRepositoryProvider`, `rxListProvider`, `personsProvider`, `invalidateRx`, `RxValidity`, `Nre`, `duplicateNrePrefix`, `treatmentListProvider`.
- Produces:
  - Routes: `AppRoutes.addRx = '/rx/add'` (query `treatmentId`, `personId`), `AppRoutes.rxDetail = '/rx/:id'`, `AppRoutes.editRx = '/rx/:id/edit'`.
  - `RxFormScreen({String? rxId, String? treatmentId, String? personId})`.
  - `RxListView()` — body widget with no Scaffold.
  - `rx_labels.dart`: `String rxKindLabel(AppLocalizations, RxKind)`, `String rxKindShort(AppLocalizations, RxKind)`, `String rxStatusLabel(AppLocalizations, RxStatus)`, `String rxPriorityLabel(AppLocalizations, RxPriority)`.

- [ ] **Step 1: Write the failing tests**

`test/presentation/screens/rx/rx_form_screen_test.dart`:
```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/core/result.dart';
import 'package:medora/domain/entities/person.dart';
import 'package:medora/domain/entities/rx.dart';
import 'package:medora/domain/entities/rx_dispensing.dart';
import 'package:medora/domain/repositories/rx_repository.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/presentation/providers/now_provider.dart';
import 'package:medora/presentation/providers/providers.dart';
import 'package:medora/presentation/providers/rx_providers.dart';
import 'package:medora/presentation/screens/rx/rx_form_screen.dart';

class _Repo implements RxRepository {
  _Repo({this.refuse});
  final String? refuse;
  final saved = <Rx>[];

  @override
  Future<Result<Rx>> saveRx(Rx rx) async {
    if (refuse != null) return Result.failure('$duplicateNrePrefix$refuse');
    saved.add(rx);
    return Result.success(rx);
  }

  @override
  Future<Result<List<RxWithDispensings>>> getAll() async =>
      const Result.success([]);
  @override
  Future<Result<RxWithDispensings>> getById(String id) async =>
      const Result.failure('none');
  @override
  Future<Result<List<RxWithDispensings>>> getForTreatment(String id) async =>
      const Result.success([]);
  @override
  Future<Result<void>> deleteRx(String id) async => const Result.success(null);
  @override
  Future<Result<void>> redeem(String id, List<RxDispensing> d) async =>
      const Result.success(null);
  @override
  Future<Result<void>> undoDispensing(String id) async =>
      const Result.success(null);
}

void main() {
  Future<_Repo> pump(WidgetTester tester, {String? refuse}) async {
    final repo = _Repo(refuse: refuse);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          rxRepositoryProvider.overrideWithValue(repo),
          personsProvider.overrideWith(
            (ref) async => const [Person(id: 'p1', name: 'Ben')],
          ),
          nowProvider.overrideWithValue(() => DateTime(2026, 9, 23, 10)),
        ],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: Locale('en'),
          home: RxFormScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return repo;
  }

  testWidgets('an SSN prescription gets a 30-day validity by default',
      (tester) async {
    final repo = await pump(tester);
    await tester.enterText(find.byKey(const Key('rx_nre')), '0410A1234567890');
    await tester.tap(find.byKey(const Key('rx_save')));
    await tester.pumpAndSettle();
    final rx = repo.saved.single;
    expect(rx.issuedOn, DateTime(2026, 9, 23));
    expect(rx.validUntil, DateTime(2026, 10, 23));
    expect(rx.nre, '0410A1234567890');
  });

  testWidgets('a malformed NRE is refused', (tester) async {
    final repo = await pump(tester);
    await tester.enterText(find.byKey(const Key('rx_nre')), '12345');
    await tester.tap(find.byKey(const Key('rx_save')));
    await tester.pumpAndSettle();
    expect(find.text('15 letters or digits'), findsOneWidget);
    expect(repo.saved, isEmpty);
  });

  testWidgets('a duplicate NRE shows a message with a link', (tester) async {
    await pump(tester, refuse: 'r0');
    await tester.enterText(find.byKey(const Key('rx_nre')), '0410A1234567890');
    await tester.tap(find.byKey(const Key('rx_save')));
    await tester.pumpAndSettle();
    expect(find.text('This prescription number is already saved'), findsOneWidget);
    expect(find.text('Open'), findsOneWidget);
  });

  testWidgets('an item can be added with packs', (tester) async {
    final repo = await pump(tester);
    await tester.enterText(find.byKey(const Key('rx_nre')), '0410A1234567890');
    await tester.tap(find.byKey(const Key('rx_add_item')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('rx_item_description_0')), 'Brufen 400');
    await tester.enterText(find.byKey(const Key('rx_item_packs_0')), '2');
    await tester.ensureVisible(find.byKey(const Key('rx_save')));
    await tester.tap(find.byKey(const Key('rx_save')));
    await tester.pumpAndSettle();
    expect(repo.saved.single.items.single.description, 'Brufen 400');
    expect(repo.saved.single.items.single.packs, 2);
  });
}
```

`test/presentation/screens/rx/rx_list_view_test.dart`:
```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/domain/entities/person.dart';
import 'package:medora/domain/entities/rx.dart';
import 'package:medora/domain/repositories/rx_repository.dart';
import 'package:medora/domain/rx/rx_rules.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/presentation/providers/now_provider.dart';
import 'package:medora/presentation/providers/rx_providers.dart';
import 'package:medora/presentation/screens/rx/rx_list_view.dart';

void main() {
  testWidgets('open prescriptions come first, soonest to expire on top; '
      'expired ones sit in the done group', (tester) async {
    Rx rx(String id, DateTime until) => Rx(
      id: id,
      personId: 'p1',
      kind: RxKind.ssn,
      nre: id.padRight(15, '0').toUpperCase(),
      issuedOn: DateTime(2026, 9, 1),
      validUntil: until,
      items: [RxItem(id: 'i', description: 'Med $id', packs: 1)],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          nowProvider.overrideWithValue(() => DateTime(2026, 9, 23, 10)),
          personsProvider.overrideWith(
            (ref) async => const [Person(id: 'p1', name: 'Ben')],
          ),
          rxListProvider.overrideWith(
            (ref) async => [
              RxWithDispensings(rx('late', DateTime(2026, 10, 20)), const []),
              RxWithDispensings(rx('soon', DateTime(2026, 9, 25)), const []),
              RxWithDispensings(rx('gone', DateTime(2026, 9, 1)), const []),
            ],
          ),
        ],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: Locale('en'),
          home: Scaffold(body: RxListView()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final soon = tester.getTopLeft(find.text('Med soon')).dy;
    final late = tester.getTopLeft(find.text('Med late')).dy;
    expect(soon, lessThan(late));
    expect(find.text('Done & expired'), findsOneWidget);
    expect(find.text('2 days left'), findsOneWidget);
  });
}
```

- [ ] **Step 2: Run to verify failure**

Run: `fvm flutter test test/presentation/screens/rx/`
Expected: FAIL — missing files.

- [ ] **Step 3: Implement labels, list and form**

`lib/presentation/screens/rx/rx_labels.dart`:
```dart
/// Medora - Display names of prescription kinds, states and priorities.
library;

import 'package:medora/domain/rx/rx_rules.dart';
import 'package:medora/l10n/generated/app_localizations.dart';

String rxKindLabel(AppLocalizations l10n, RxKind kind) => switch (kind) {
  RxKind.ssn => l10n.rxKindSsn,
  RxKind.white => l10n.rxKindWhite,
  RxKind.whiteRepeatable => l10n.rxKindWhiteRepeatable,
  RxKind.referral => l10n.rxKindReferral,
};

String rxKindShort(AppLocalizations l10n, RxKind kind) => switch (kind) {
  RxKind.ssn => l10n.rxKindShortSsn,
  RxKind.white => l10n.rxKindShortWhite,
  RxKind.whiteRepeatable => l10n.rxKindShortWhiteRepeatable,
  RxKind.referral => l10n.rxKindShortReferral,
};

String rxStatusLabel(AppLocalizations l10n, RxStatus status) =>
    switch (status) {
      RxStatus.open => l10n.rxStatusOpen,
      RxStatus.partial => l10n.rxStatusPartial,
      RxStatus.redeemed => l10n.rxStatusRedeemed,
      RxStatus.expired => l10n.rxStatusExpired,
      RxStatus.cancelled => l10n.rxStatusCancelled,
    };

String rxPriorityLabel(AppLocalizations l10n, RxPriority p) => switch (p) {
  RxPriority.u => l10n.rxPriorityU,
  RxPriority.b => l10n.rxPriorityB,
  RxPriority.d => l10n.rxPriorityD,
  RxPriority.p => l10n.rxPriorityP,
};
```

`lib/presentation/screens/rx/rx_list_view.dart`:
```dart
/// Medora - The prescriptions, grouped: open, partly collected, then done.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:medora/core/extensions.dart';
import 'package:medora/domain/entities/person.dart';
import 'package:medora/domain/repositories/rx_repository.dart';
import 'package:medora/domain/rx/rx_rules.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/presentation/providers/now_provider.dart';
import 'package:medora/presentation/providers/rx_providers.dart';
import 'package:medora/presentation/router/app_router.dart';
import 'package:medora/presentation/screens/rx/rx_labels.dart';
import 'package:medora/presentation/widgets/async_value_view.dart';
import 'package:medora/presentation/widgets/shared_widgets.dart';

class RxListView extends ConsumerWidget {
  const RxListView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final now = ref.watch(nowProvider)();
    final persons = {
      for (final p in ref.watch(personsProvider).value ?? const <Person>[])
        p.id: p,
    };
    return AsyncValueView<List<RxWithDispensings>>(
      value: ref.watch(rxListProvider),
      onRetry: () async => ref.invalidate(rxListProvider),
      emptyWhen: (list) => list.isEmpty,
      empty: EmptyStateWidget(
        icon: Icons.receipt_long_outlined,
        title: l10n.rxNoneYet,
        subtitle: l10n.rxNoneYetHint,
        actionLabel: l10n.rxAdd,
        onAction: () => context.push(AppRoutes.addRx),
      ),
      data: (list) {
        final open = <RxWithDispensings>[];
        final partial = <RxWithDispensings>[];
        final done = <RxWithDispensings>[];
        for (final r in list) {
          switch (r.statusAt(now)) {
            case RxStatus.open:
              open.add(r);
            case RxStatus.partial:
              partial.add(r);
            case RxStatus.redeemed ||
                RxStatus.expired ||
                RxStatus.cancelled:
              done.add(r);
          }
        }
        // Soonest last valid day first; unknown validity last.
        int byExpiry(RxWithDispensings a, RxWithDispensings b) {
          final x = a.rx.validUntil, y = b.rx.validUntil;
          if (x == null) return y == null ? 0 : 1;
          if (y == null) return -1;
          return x.compareTo(y);
        }

        open.sort(byExpiry);
        partial.sort(byExpiry);
        Widget tile(RxWithDispensings r) =>
            _RxTile(item: r, person: persons[r.rx.personId], now: now);
        return ListView(
          padding: const EdgeInsets.only(bottom: 88),
          children: [
            for (final r in open) tile(r),
            if (partial.isNotEmpty) _Header(l10n.rxStatusPartial),
            for (final r in partial) tile(r),
            if (done.isNotEmpty)
              ExpansionTile(
                title: Text(l10n.rxGroupDone),
                children: [for (final r in done) tile(r)],
              ),
          ],
        );
      },
    );
  }
}

class _Header extends StatelessWidget {
  const _Header(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
    child: Text(text, style: Theme.of(context).textTheme.titleSmall),
  );
}

class _RxTile extends StatelessWidget {
  const _RxTile({required this.item, required this.person, required this.now});

  final RxWithDispensings item;
  final Person? person;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final rx = item.rx;
    final status = item.statusAt(now);
    final left = RxRules.daysLeft(rx, now);
    final priority = rx.priority;
    final validity = switch (status) {
      RxStatus.open || RxStatus.partial when left != null =>
        l10n.rxDaysLeft(left),
      RxStatus.open || RxStatus.partial when priority != null =>
        l10n.rxBookBy(RxValidity.bookBy(priority, rx.issuedOn).formatted),
      RxStatus.open || RxStatus.partial => null,
      _ => rxStatusLabel(l10n, status),
    };
    final title = rx.items.isEmpty
        ? rxKindLabel(l10n, rx.kind)
        : rx.items.map((i) => i.description).join(', ');
    return ListTile(
      leading: Chip(
        label: Text(rxKindShort(l10n, rx.kind)),
        visualDensity: VisualDensity.compact,
      ),
      title: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        [
          person?.name ??
              (rx.personId == null ? null : l10n.rxUnknownPerson),
          ?validity,
        ].nonNulls.join(' · '),
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: () =>
          context.push(AppRoutes.rxDetail.replaceFirst(':id', rx.id)),
    );
  }
}
```
Person filter (spec §6.2): make `RxListView` a `ConsumerStatefulWidget` holding `String? _personFilter`; when `persons.length > 1`, put a `DropdownButton<String?>` (items: `l10n.all` for null, then each person's name) as the first child of the `ListView`, and drop entries whose `rx.personId != _personFilter` before grouping. Add a widget-test case: two persons, filter to one, the other's item text disappears.

Note `[… ].nonNulls` needs the first element typed `String?`; if the analyzer complains about the mixed `?validity` element, write the list as `<String?>[person name expr, validity].nonNulls.join(' · ')`.

`lib/presentation/screens/rx/rx_form_screen.dart`:
```dart
/// Medora - Add or edit a prescription.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:medora/domain/entities/person.dart';
import 'package:medora/domain/entities/rx.dart';
import 'package:medora/domain/repositories/rx_repository.dart';
import 'package:medora/domain/rx/nre.dart';
import 'package:medora/domain/rx/rx_rules.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/presentation/providers/now_provider.dart';
import 'package:medora/presentation/providers/providers.dart';
import 'package:medora/presentation/providers/rx_providers.dart';
import 'package:medora/presentation/router/app_router.dart';
import 'package:medora/presentation/screens/rx/rx_labels.dart';
import 'package:medora/presentation/widgets/forms/date_picker_field.dart';
import 'package:uuid/uuid.dart';

class RxFormScreen extends ConsumerStatefulWidget {
  const RxFormScreen({super.key, this.rxId, this.treatmentId, this.personId});

  final String? rxId;
  final String? treatmentId;
  final String? personId;

  @override
  ConsumerState<RxFormScreen> createState() => _RxFormScreenState();
}

/// One editable item row.
class _ItemDraft {
  _ItemDraft(this.id, {String description = '', int packs = 1})
    : description = TextEditingController(text: description),
      packs = TextEditingController(text: '$packs');

  final String id;
  final TextEditingController description;
  final TextEditingController packs;
  String? medicationId;
  String? aic;
  bool nonSubstitutable = false;

  void dispose() {
    description.dispose();
    packs.dispose();
  }
}

class _RxFormScreenState extends ConsumerState<RxFormScreen> {
  static const _uuid = Uuid();
  final _form = GlobalKey<FormState>();
  final _nre = TextEditingController();
  final _doctor = TextEditingController();
  final _exemption = TextEditingController();
  final _notes = TextEditingController();
  final _maxDispensings = TextEditingController();
  final _items = <_ItemDraft>[];

  Rx? _existing;
  RxKind _kind = RxKind.ssn;
  RxPriority? _priority;
  String? _personId;
  late DateTime _issuedOn;

  /// Null until the user picks one: then it follows the kind and date.
  DateTime? _validUntilPicked;
  String? _nreError;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final now = ref.read(nowProvider)();
    _issuedOn = DateTime(now.year, now.month, now.day);
    _personId = widget.personId;
    final id = widget.rxId;
    if (id != null) _load(id);
  }

  Future<void> _load(String id) async {
    final r = (await ref.read(rxByIdProvider(id).future)).rx;
    if (!mounted) return;
    setState(() {
      _existing = r;
      _kind = r.kind;
      _priority = r.priority;
      _personId = r.personId;
      _issuedOn = r.issuedOn;
      _validUntilPicked = r.validUntil;
      _nre.text = r.nre ?? '';
      _doctor.text = r.doctor ?? '';
      _exemption.text = r.exemptionCode ?? '';
      _notes.text = r.notes ?? '';
      _maxDispensings.text = r.maxDispensings?.toString() ?? '';
      for (final i in r.items) {
        _items.add(
          _ItemDraft(i.id, description: i.description, packs: i.packs)
            ..medicationId = i.medicationId
            ..aic = i.aic
            ..nonSubstitutable = i.nonSubstitutable,
        );
      }
    });
  }

  @override
  void dispose() {
    for (final c in [_nre, _doctor, _exemption, _notes, _maxDispensings]) {
      c.dispose();
    }
    for (final i in _items) {
      i.dispose();
    }
    super.dispose();
  }

  DateTime? get _validUntil =>
      _validUntilPicked ?? RxValidity.defaultValidUntil(_kind, _issuedOn);

  String? _text(TextEditingController c) {
    final t = c.text.trim();
    return t.isEmpty ? null : t;
  }

  Future<void> _save() async {
    setState(() => _nreError = null);
    if (_saving || !_form.currentState!.validate()) return;
    setState(() => _saving = true);
    final l10n = AppLocalizations.of(context);
    final nre = _text(_nre);
    final rx = Rx(
      id: _existing?.id ?? _uuid.v4(),
      userId: _existing?.userId,
      personId: _personId,
      treatmentId: _existing?.treatmentId ?? widget.treatmentId,
      kind: _kind,
      nre: nre == null ? null : Nre.normalize(nre),
      issuedOn: _issuedOn,
      validUntil: _validUntil,
      doctor: _text(_doctor),
      exemptionCode: _text(_exemption)?.toUpperCase(),
      priority: _kind == RxKind.referral ? _priority : null,
      maxDispensings: _kind == RxKind.whiteRepeatable
          ? int.tryParse(_maxDispensings.text.trim()) ??
                RxValidity.defaultMaxDispensings(_kind)
          : null,
      items: [
        for (final i in _items)
          if (i.description.text.trim().isNotEmpty)
            RxItem(
              id: i.id,
              medicationId: i.medicationId,
              aic: i.aic,
              description: i.description.text.trim(),
              packs: int.tryParse(i.packs.text.trim()) ?? 1,
              nonSubstitutable: i.nonSubstitutable,
            ),
      ],
      closedOn: _existing?.closedOn,
      cancelled: _existing?.cancelled ?? false,
      notes: _text(_notes),
      createdAt: _existing?.createdAt,
      updatedAt: _existing?.updatedAt,
    );
    final result = await ref.read(rxRepositoryProvider).saveRx(rx);
    if (!mounted) return;
    setState(() => _saving = false);
    result.when(
      success: (_) {
        invalidateRx(ref);
        Navigator.of(context).maybePop();
      },
      failure: (message) {
        if (message.startsWith(duplicateNrePrefix)) {
          final existing = message.substring(duplicateNrePrefix.length);
          setState(() => _nreError = l10n.rxNreDuplicate);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(l10n.rxNreDuplicate),
              action: SnackBarAction(
                label: l10n.rxOpenExisting,
                onPressed: () => context.push(
                  AppRoutes.rxDetail.replaceFirst(':id', existing),
                ),
              ),
            ),
          );
        } else {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(l10n.genericError)));
        }
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final now = ref.watch(nowProvider)();
    final persons = ref.watch(personsProvider).value ?? const <Person>[];
    final person = persons.where((p) => p.id == _personId).firstOrNull;
    return Scaffold(
      appBar: AppBar(title: Text(_existing == null ? l10n.rxNew : l10n.rxEdit)),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            DropdownButtonFormField<String?>(
              initialValue: _personId,
              decoration: InputDecoration(labelText: l10n.rxPerson),
              items: [
                DropdownMenuItem(value: null, child: Text(l10n.rxNoPerson)),
                for (final p in persons)
                  DropdownMenuItem(value: p.id, child: Text(p.name)),
              ],
              onChanged: (id) => setState(() => _personId = id),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<RxKind>(
              initialValue: _kind,
              decoration: InputDecoration(labelText: l10n.rxKind),
              items: [
                for (final k in RxKind.values)
                  DropdownMenuItem(value: k, child: Text(rxKindLabel(l10n, k))),
              ],
              onChanged: (k) => setState(() {
                _kind = k ?? RxKind.ssn;
                _validUntilPicked = null;
              }),
            ),
            const SizedBox(height: 12),
            TextFormField(
              key: const Key('rx_nre'),
              controller: _nre,
              textCapitalization: TextCapitalization.characters,
              decoration: InputDecoration(
                labelText: l10n.rxNre,
                errorText: _nreError,
              ),
              validator: (v) {
                final raw = (v ?? '').trim();
                if (raw.isEmpty) return null;
                return Nre.isValid(raw) ? null : l10n.rxNreInvalid;
              },
            ),
            const SizedBox(height: 12),
            DatePickerField(
              label: l10n.rxIssuedOn,
              icon: Icons.event_outlined,
              date: _issuedOn,
              now: now,
              onDateSelected: (d) => setState(() {
                if (d != null) _issuedOn = d;
                _validUntilPicked = null;
              }),
            ),
            const SizedBox(height: 12),
            DatePickerField(
              label: l10n.rxValidUntil,
              icon: Icons.event_available_outlined,
              date: _validUntil,
              now: now,
              firstDate: _issuedOn,
              onDateSelected: (d) => setState(() => _validUntilPicked = d),
            ),
            if (_kind == RxKind.referral) ...[
              const SizedBox(height: 12),
              DropdownButtonFormField<RxPriority?>(
                initialValue: _priority,
                decoration: InputDecoration(labelText: l10n.rxPriority),
                items: [
                  const DropdownMenuItem(value: null, child: Text('–')), // l10n-exempt
                  for (final p in RxPriority.values)
                    DropdownMenuItem(
                      value: p,
                      child: Text(rxPriorityLabel(l10n, p)),
                    ),
                ],
                onChanged: (p) => setState(() => _priority = p),
              ),
            ],
            if (_kind == RxKind.whiteRepeatable) ...[
              const SizedBox(height: 12),
              TextFormField(
                controller: _maxDispensings,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: l10n.rxMaxDispensings,
                  hintText: '${RxValidity.defaultMaxDispensings(_kind)}',
                ),
              ),
            ],
            const SizedBox(height: 12),
            TextFormField(
              controller: _doctor,
              decoration: InputDecoration(
                labelText: l10n.doctorLabel,
                hintText: l10n.doctorHint,
              ),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _exemption,
              textCapitalization: TextCapitalization.characters,
              decoration: InputDecoration(
                labelText: l10n.rxExemption,
                // The person's codes, as a hint: which one applies is the
                // doctor's call and printed on the prescription.
                hintText: person?.exemptions.join(', '),
              ),
            ),
            const SizedBox(height: 20),
            Text(l10n.rxItems, style: Theme.of(context).textTheme.titleSmall),
            for (final (index, item) in _items.indexed)
              _ItemRow(
                index: index,
                item: item,
                onRemove: () => setState(() => _items.removeAt(index).dispose()),
                onChanged: () => setState(() {}),
              ),
            TextButton.icon(
              key: const Key('rx_add_item'),
              onPressed: () => setState(() => _items.add(_ItemDraft(_uuid.v4()))),
              icon: const Icon(Icons.add),
              label: Text(l10n.rxAddItem),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _notes,
              maxLines: 3,
              decoration: InputDecoration(labelText: l10n.notes),
            ),
            const SizedBox(height: 24),
            FilledButton(
              key: const Key('rx_save'),
              onPressed: _saving ? null : _save,
              child: Text(l10n.save),
            ),
          ],
        ),
      ),
    );
  }
}

class _ItemRow extends StatelessWidget {
  const _ItemRow({
    required this.index,
    required this.item,
    required this.onRemove,
    required this.onChanged,
  });

  final int index;
  final _ItemDraft item;
  final VoidCallback onRemove;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    key: Key('rx_item_description_$index'),
                    controller: item.description,
                    decoration: InputDecoration(
                      labelText: l10n.rxItemDescription,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 72,
                  child: TextFormField(
                    key: Key('rx_item_packs_$index'),
                    controller: item.packs,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(labelText: l10n.rxItemPacks),
                    validator: (v) {
                      final n = int.tryParse((v ?? '').trim());
                      return n == null || n < 1 ? l10n.required : null;
                    },
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  tooltip: l10n.delete,
                  onPressed: onRemove,
                ),
              ],
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: item.nonSubstitutable,
              title: Text(l10n.rxNonSubstitutable),
              onChanged: (v) {
                item.nonSubstitutable = v ?? false;
                onChanged();
              },
            ),
          ],
        ),
      ),
    );
  }
}
```
Linking an item to a cabinet medication (`medicationId`) is done in the detail's redeem sheet (Task 10) — the form keeps the free-text description only, which is what a paper prescription shows. Check `DropdownButtonFormField`'s `initialValue` parameter exists in this Flutter version (3.44 renamed `value` → `initialValue`); if not, use `value`.

Router — `AppRoutes`:
```dart
  static const addRx = '/rx/add';
  static const rxDetail = '/rx/:id';
  static const editRx = '/rx/:id/edit';
```
Routes (inside the shell, `addRx` before `rxDetail` so `/rx/add` is not read as an id):
```dart
          GoRoute(
            path: AppRoutes.addRx,
            builder: (_, state) => RxFormScreen(
              treatmentId: state.uri.queryParameters['treatmentId'],
              personId: state.uri.queryParameters['personId'],
            ),
          ),
          GoRoute(
            path: AppRoutes.editRx,
            builder: (_, state) =>
                RxFormScreen(rxId: state.pathParameters['id']),
          ),
          GoRoute(
            path: AppRoutes.rxDetail,
            builder: (_, state) =>
                RxDetailScreen(rxId: state.pathParameters['id']!),
          ),
```
(`RxDetailScreen` comes in Task 10; until then register only `addRx`/`editRx` and add `rxDetail` in Task 10.)

Treatment tab segment — in `treatment_list_screen.dart`:
1. Add `enum _TreatmentsPane { treatments, prescriptions }` and state `_TreatmentsPane _pane = _TreatmentsPane.treatments;`.
2. In `body: Column(children: [...])`, insert first:
```dart
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: SegmentedButton<_TreatmentsPane>(
              segments: [
                ButtonSegment(
                  value: _TreatmentsPane.treatments,
                  label: Text(l10n.treatments),
                  icon: const Icon(Icons.healing_outlined),
                ),
                ButtonSegment(
                  value: _TreatmentsPane.prescriptions,
                  label: Text(l10n.rxTab),
                  icon: const Icon(Icons.receipt_long_outlined),
                ),
              ],
              selected: {_pane},
              onSelectionChanged: (s) => setState(() => _pane = s.first),
            ),
          ),
```
3. Wrap the existing filter chips + divider + list in `if (_pane == _TreatmentsPane.treatments) ...[ … ]` and add `if (_pane == _TreatmentsPane.prescriptions) const Expanded(child: RxListView()),`.
4. Hide the search action while the prescriptions pane shows (`if (_pane == _TreatmentsPane.treatments)` around the search `IconButton`).
5. FAB: `onPressed: () => context.push(_pane == _TreatmentsPane.treatments ? AppRoutes.addTreatment : AppRoutes.addRx)`, `tooltip: _pane == … ? l10n.addTreatment : l10n.rxAdd`.

- [ ] **Step 4: Run tests**

Run: `fvm flutter test test/presentation/`
Expected: PASS. Run the existing goldens too (`fvm flutter test test/goldens`); the treatments tab is not in a golden, so none should change. If one does, inspect it before regenerating with `--update-goldens`.

- [ ] **Step 5: Commit**

```bash
fvm dart format lib test
fvm flutter analyze --fatal-infos
git add lib test
git commit -m "feat(rx): prescription list in the treatments tab and the prescription form"
```

---

### Task 10: Prescription detail, pharmacy view and collecting

**Files:**
- Create: `lib/presentation/widgets/code39.dart`, `lib/presentation/screens/rx/rx_detail_screen.dart`, `lib/presentation/screens/rx/pharmacy_screen.dart`, `lib/presentation/screens/rx/redeem_sheet.dart`
- Modify: `lib/presentation/router/app_router.dart` (`rxDetail` route), `lib/presentation/screens/treatment/treatment_detail_screen.dart` (prescriptions-document section)
- Test: `test/presentation/widgets/code39_test.dart`, `test/presentation/screens/rx/redeem_sheet_test.dart`

**Interfaces:**
- Consumes: Task 6 repository/providers, Task 9 labels, `medicationListProvider` (`lib/presentation/providers/medication_providers.dart`).
- Produces:
  - `abstract final class Code39 { static List<bool>? encode(String data); }` (bars: `true` = dark module; narrow = 1 module, wide = 3; null if a character is not encodable).
  - `class Code39Barcode extends StatelessWidget { const Code39Barcode(this.data, {super.key, this.height = 96}); }`
  - `RxDetailScreen({required String rxId})`, `PharmacyScreen({required String nre, required String? taxCode, required String title})`, `Future<void> showRedeemSheet(BuildContext, WidgetRef, RxWithDispensings)`.
  - Pure helper in `redeem_sheet.dart`: `int proposedUnits(RxItem item, int packs)` = `packs * (RxRules.packSizeOf(item.description) ?? 1)`.

- [ ] **Step 1: Write the failing tests**

`test/presentation/widgets/code39_test.dart`:
```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/presentation/widgets/code39.dart';

void main() {
  test('encodes start/stop and one character per 9 elements + gap', () {
    final bars = Code39.encode('A')!;
    // "*A*": 3 characters × (6 narrow + 3 wide = 6 + 9 = 15 modules) + 2 gaps.
    expect(bars.length, 3 * 15 + 2);
    // A character starts and ends with a bar.
    expect(bars.first, isTrue);
    expect(bars.last, isTrue);
  });

  test('A encodes as 100001001 (bar and space alternate, 1 = wide)', () {
    final bars = Code39.encode('A')!;
    // Skip "*" (15 modules) and its gap (1 module).
    final a = bars.sublist(16, 31);
    // A = 100001001 → bar W, sp N, bar N, sp N, bar N, sp W, bar N, sp N, bar W
    expect(a, [
      true, true, true, false, true, false, true, false, false, false, //
      true, false, true, true, true,
    ]);
  });

  test('digits and upper-case letters of an NRE and a tax code encode', () {
    expect(Code39.encode('0410A1234567890'), isNotNull);
    expect(Code39.encode('RSSMRA85T10A562S'), isNotNull);
  });

  test('lower case and unsupported symbols do not', () {
    expect(Code39.encode('a'), isNull);
    expect(Code39.encode('#'), isNull);
  });
}
```

`test/presentation/screens/rx/redeem_sheet_test.dart`:
```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/domain/entities/rx.dart';
import 'package:medora/presentation/screens/rx/redeem_sheet.dart';

void main() {
  test('proposed units multiply packs by the pack size in the description',
      () {
    const item = RxItem(id: 'i', description: 'Tachipirina 20 compresse');
    expect(proposedUnits(item, 2), 40);
  });

  test('without a pack size the packs themselves are proposed', () {
    const item = RxItem(id: 'i', description: 'Sciroppo 150 ml');
    expect(proposedUnits(item, 2), 2);
  });
}
```

- [ ] **Step 2: Run to verify failure**

Run: `fvm flutter test test/presentation/widgets/code39_test.dart test/presentation/screens/rx/redeem_sheet_test.dart`
Expected: FAIL — missing files.

- [ ] **Step 3: Implement Code 39**

`lib/presentation/widgets/code39.dart`:
```dart
/// Medora - Code 39 barcodes, as printed on an Italian prescription
/// reminder: the pharmacy scans the NRE and the tax code from the phone
/// screen the same way it scans them from paper.
///
/// Code 39 needs no check digit and no library: each character is nine
/// elements (five bars, four spaces), three of them wide.
library;

import 'package:flutter/material.dart';

abstract final class Code39 {
  /// Each character's nine elements, bar first, `1` = wide.
  static const _patterns = {
    '0': '000110100', '1': '100100001', '2': '001100001', '3': '101100000',
    '4': '000110001', '5': '100110000', '6': '001110000', '7': '000100101',
    '8': '100100100', '9': '001100100', 'A': '100001001', 'B': '001001001',
    'C': '101001000', 'D': '000011001', 'E': '100011000', 'F': '001011000',
    'G': '000001101', 'H': '100001100', 'I': '001001100', 'J': '000011100',
    'K': '100000011', 'L': '001000011', 'M': '101000010', 'N': '000010011',
    'O': '100010010', 'P': '001010010', 'Q': '000000111', 'R': '100000110',
    'S': '001000110', 'T': '000010110', 'U': '110000001', 'V': '011000001',
    'W': '111000000', 'X': '010010001', 'Y': '110010000', 'Z': '011010000',
    '-': '010000101', '.': '110000100', ' ': '011000100', '*': '010010100',
  };

  static const _wide = 3;

  /// The modules of `*data*` (dark = true), a narrow space between
  /// characters; null when [data] holds a character Code 39 lacks.
  static List<bool>? encode(String data) {
    final modules = <bool>[];
    final chars = '*$data*'.split('');
    for (var c = 0; c < chars.length; c++) {
      final pattern = _patterns[chars[c]];
      if (pattern == null) return null;
      for (var e = 0; e < 9; e++) {
        final dark = e.isEven;
        final width = pattern[e] == '1' ? _wide : 1;
        for (var w = 0; w < width; w++) {
          modules.add(dark);
        }
      }
      if (c < chars.length - 1) modules.add(false);
    }
    return modules;
  }
}

class Code39Barcode extends StatelessWidget {
  const Code39Barcode(this.data, {super.key, this.height = 96});

  final String data;
  final double height;

  @override
  Widget build(BuildContext context) {
    final modules = Code39.encode(data);
    if (modules == null) return const SizedBox.shrink();
    // Always black on white, whatever the theme: a scanner needs contrast
    // and a quiet zone, not the app's colours.
    return ColoredBox(
      color: Colors.white,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: SizedBox(
          height: height,
          width: double.infinity,
          child: CustomPaint(painter: _Code39Painter(modules)),
        ),
      ),
    );
  }
}

class _Code39Painter extends CustomPainter {
  _Code39Painter(this.modules);
  final List<bool> modules;

  @override
  void paint(Canvas canvas, Size size) {
    final module = size.width / modules.length;
    final paint = Paint()..color = Colors.black;
    for (var i = 0; i < modules.length; i++) {
      if (!modules[i]) continue;
      canvas.drawRect(
        Rect.fromLTWH(i * module, 0, module, size.height),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_Code39Painter old) => old.modules != modules;
}
```
Verify the table against a reference (e.g. the Wikipedia "Code 39" table) while implementing — the tests pin `A`, and a scan with the phone's own camera (Step 7) checks the rest.

- [ ] **Step 4: Implement the pharmacy screen, redeem sheet and detail**

`lib/presentation/screens/rx/pharmacy_screen.dart`:
```dart
/// Medora - What the pharmacy scans: the prescription number and the tax
/// code, as barcodes and in large type, on a white page.
library;

import 'package:flutter/material.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/presentation/widgets/code39.dart';

class PharmacyScreen extends StatelessWidget {
  const PharmacyScreen({
    super.key,
    required this.nre,
    required this.taxCode,
    required this.title,
  });

  final String nre;
  final String? taxCode;
  final String title;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    const big = TextStyle(
      color: Colors.black,
      fontSize: 26,
      fontWeight: FontWeight.w600,
      letterSpacing: 2,
      fontFeatures: [FontFeature.tabularFigures()],
    );
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        foregroundColor: Colors.black,
        title: Text(title),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(vertical: 24),
          children: [
            _Label(l10n.rxNre),
            Code39Barcode(nre),
            Center(child: SelectableText(nre, style: big)),
            if (taxCode != null) ...[
              const SizedBox(height: 32),
              _Label(l10n.rxTaxCode),
              Code39Barcode(taxCode!),
              Center(child: SelectableText(taxCode!, style: big)),
            ],
          ],
        ),
      ),
    );
  }
}

class _Label extends StatelessWidget {
  const _Label(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
    child: Text(text, style: const TextStyle(color: Colors.black54)),
  );
}
```
Screen brightness: the spec asks for maximum brightness. That needs a plugin (`screen_brightness`); **do not add it in this phase** — a white page at the user's brightness scans fine in practice. Record it as a follow-up in the final report.

`lib/presentation/screens/rx/redeem_sheet.dart`:
```dart
/// Medora - Record what was collected at the pharmacy.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:medora/domain/entities/rx.dart';
import 'package:medora/domain/entities/rx_dispensing.dart';
import 'package:medora/domain/repositories/rx_repository.dart';
import 'package:medora/domain/rx/rx_rules.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/presentation/providers/medication_providers.dart';
import 'package:medora/presentation/providers/now_provider.dart';
import 'package:medora/presentation/providers/providers.dart';
import 'package:medora/presentation/providers/rx_providers.dart';
import 'package:uuid/uuid.dart';

/// Units a collection of [packs] of [item] is proposed to add to stock.
int proposedUnits(RxItem item, int packs) =>
    packs * (RxRules.packSizeOf(item.description) ?? 1);

Future<void> showRedeemSheet(
  BuildContext context,
  WidgetRef ref,
  RxWithDispensings entry,
) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (_) => _RedeemSheet(entry: entry),
);

class _Line {
  _Line(this.item, int packs, {required this.addToStock})
    : packs = TextEditingController(text: '$packs'),
      units = TextEditingController(text: '${proposedUnits(item, packs)}');

  final RxItem item;
  final TextEditingController packs;
  final TextEditingController units;
  bool selected = true;
  bool addToStock;
}

class _RedeemSheet extends ConsumerStatefulWidget {
  const _RedeemSheet({required this.entry});
  final RxWithDispensings entry;

  @override
  ConsumerState<_RedeemSheet> createState() => _RedeemSheetState();
}

class _RedeemSheetState extends ConsumerState<_RedeemSheet> {
  final _pharmacy = TextEditingController();
  late final List<_Line> _lines;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final given = RxRules.dispensedPacks(widget.entry.dispensings);
    _lines = [
      for (final i in widget.entry.rx.items)
        if ((given[i.id] ?? 0) < i.packs ||
            widget.entry.rx.maxDispensings != null)
          _Line(
            i,
            widget.entry.rx.maxDispensings != null
                ? i.packs
                : i.packs - (given[i.id] ?? 0),
            addToStock: i.medicationId != null,
          ),
    ];
  }

  @override
  void dispose() {
    _pharmacy.dispose();
    for (final l in _lines) {
      l.packs.dispose();
      l.units.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final now = ref.read(nowProvider)();
    final today = DateTime(now.year, now.month, now.day);
    final pharmacy = _pharmacy.text.trim();
    final rx = widget.entry.rx;
    final dispensings = [
      for (final l in _lines)
        if (l.selected && (int.tryParse(l.packs.text) ?? 0) > 0)
          RxDispensing(
            id: const Uuid().v4(),
            rxId: rx.id,
            itemId: l.item.id,
            packs: int.parse(l.packs.text),
            dispensedOn: today,
            pharmacy: pharmacy.isEmpty ? null : pharmacy,
            unitsAdded: l.addToStock && l.item.medicationId != null
                ? int.tryParse(l.units.text) ?? 0
                : 0,
          ),
    ];
    final result = await ref
        .read(rxRepositoryProvider)
        .redeem(rx.id, dispensings);
    if (!mounted) return;
    invalidateRx(ref);
    ref.invalidate(medicationListProvider);
    result.when(
      success: (_) => Navigator.of(context).pop(),
      failure: (_) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppLocalizations.of(context).genericError)),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        bottom: MediaQuery.viewInsetsOf(context).bottom + 16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(l10n.rxRedeemTitle, style: Theme.of(context).textTheme.titleLarge),
          if (_lines.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Text(l10n.rxNothingLeft),
            ),
          for (final l in _lines)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Column(
                  children: [
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      value: l.selected,
                      title: Text(l.item.description),
                      onChanged: (v) => setState(() => l.selected = v ?? false),
                    ),
                    Row(
                      children: [
                        SizedBox(
                          width: 88,
                          child: TextField(
                            controller: l.packs,
                            keyboardType: TextInputType.number,
                            decoration: InputDecoration(
                              labelText: l10n.rxItemPacks,
                            ),
                            onChanged: (v) => l.units.text =
                                '${proposedUnits(l.item, int.tryParse(v) ?? 0)}',
                          ),
                        ),
                        const SizedBox(width: 12),
                        if (l.item.medicationId != null)
                          Expanded(
                            child: TextField(
                              controller: l.units,
                              enabled: l.addToStock,
                              keyboardType: TextInputType.number,
                              decoration: InputDecoration(
                                labelText: l10n.rxUnitsToAdd,
                              ),
                            ),
                          ),
                      ],
                    ),
                    if (l.item.medicationId != null)
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        value: l.addToStock,
                        title: Text(l10n.rxAddToStock),
                        onChanged: (v) => setState(() => l.addToStock = v),
                      ),
                  ],
                ),
              ),
            ),
          TextField(
            controller: _pharmacy,
            decoration: InputDecoration(labelText: l10n.rxPharmacy),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _saving || _lines.isEmpty ? null : _save,
            child: Text(l10n.rxRedeem),
          ),
        ],
      ),
    );
  }
}
```
`medicationListProvider` (an `AsyncNotifierProvider<…, List<Medication>>`) lives in `lib/presentation/providers/medication_providers.dart`; import that file in `redeem_sheet.dart` and `rx_detail_screen.dart` (instead of, or besides, `providers.dart`).

Item → medication linking: on the detail screen each item without `medicationId` shows a "link" `IconButton` (`Icons.link`) opening a simple dialog listing cabinet medications (from `medicationListProvider`) filtered by the item's first word; picking one saves `rx.copyWith(items: …)` via `saveRx`. Implement it as `_linkMedication(context, ref, rx, item)` inside `rx_detail_screen.dart` below.

`lib/presentation/screens/rx/rx_detail_screen.dart`:
```dart
/// Medora - One prescription: what it is, what is left, and the actions.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:medora/core/extensions.dart';
import 'package:medora/domain/entities/medication.dart';
import 'package:medora/domain/entities/person.dart';
import 'package:medora/domain/entities/rx.dart';
import 'package:medora/domain/repositories/rx_repository.dart';
import 'package:medora/domain/rx/rx_rules.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/presentation/providers/medication_providers.dart';
import 'package:medora/presentation/providers/now_provider.dart';
import 'package:medora/presentation/providers/providers.dart';
import 'package:medora/presentation/providers/rx_providers.dart';
import 'package:medora/presentation/router/app_router.dart';
import 'package:medora/presentation/screens/rx/pharmacy_screen.dart';
import 'package:medora/presentation/screens/rx/redeem_sheet.dart';
import 'package:medora/presentation/screens/rx/rx_labels.dart';
import 'package:medora/presentation/widgets/async_value_view.dart';
import 'package:medora/presentation/widgets/shared_widgets.dart';
import 'package:share_plus/share_plus.dart';

enum _Action { edit, markDone, cancelRx, delete }

class RxDetailScreen extends ConsumerWidget {
  const RxDetailScreen({super.key, required this.rxId});

  final String rxId;

  Future<void> _onAction(
    BuildContext context,
    WidgetRef ref,
    Rx rx,
    _Action action,
  ) async {
    final repo = ref.read(rxRepositoryProvider);
    final now = ref.read(nowProvider)();
    switch (action) {
      case _Action.edit:
        await context.push(AppRoutes.editRx.replaceFirst(':id', rx.id));
      case _Action.markDone:
        await repo.saveRx(
          rx.copyWith(closedOn: DateTime(now.year, now.month, now.day)),
        );
      case _Action.cancelRx:
        await repo.saveRx(rx.copyWith(cancelled: true));
      case _Action.delete:
        final l10n = AppLocalizations.of(context);
        final ok = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(l10n.rxDelete),
            content: Text(l10n.rxDeleteConfirm),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(l10n.cancel),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(l10n.delete),
              ),
            ],
          ),
        );
        if (ok != true) return;
        await repo.deleteRx(rx.id);
        if (context.mounted) Navigator.of(context).maybePop();
    }
    invalidateRx(ref);
  }

  Future<void> _share(BuildContext context, Rx rx, Person? person) async {
    final l10n = AppLocalizations.of(context);
    final box = context.findRenderObject() as RenderBox?;
    await SharePlus.instance.share(
      ShareParams(
        text: l10n.rxShareText(rx.nre ?? '', person?.taxCode ?? ''),
        sharePositionOrigin: box == null
            ? null
            : box.localToGlobal(Offset.zero) & box.size,
      ),
    );
  }

  Future<void> _linkMedication(
    BuildContext context,
    WidgetRef ref,
    Rx rx,
    RxItem item,
  ) async {
    final meds = await ref.read(medicationListProvider.future);
    if (!context.mounted) return;
    final word = item.description.split(' ').first.toLowerCase();
    final sorted = [...meds]
      ..sort((a, b) {
        final am = a.name.toLowerCase().contains(word) ? 0 : 1;
        final bm = b.name.toLowerCase().contains(word) ? 0 : 1;
        return am != bm ? am - bm : a.name.compareTo(b.name);
      });
    final picked = await showDialog<Medication>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(item.description),
        children: [
          for (final m in sorted)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, m),
              child: Text(m.name),
            ),
        ],
      ),
    );
    if (picked == null) return;
    await ref.read(rxRepositoryProvider).saveRx(
      rx.copyWith(
        items: [
          for (final i in rx.items)
            i.id == item.id ? i.copyWith(medicationId: picked.id) : i,
        ],
      ),
    );
    invalidateRx(ref);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final now = ref.watch(nowProvider)();
    final persons = ref.watch(personsProvider).value ?? const <Person>[];
    return AsyncValueView<RxWithDispensings>(
      value: ref.watch(rxByIdProvider(rxId)),
      onRetry: () async => ref.invalidate(rxByIdProvider(rxId)),
      data: (entry) {
        final rx = entry.rx;
        final person = persons.where((p) => p.id == rx.personId).firstOrNull;
        final status = entry.statusAt(now);
        final given = RxRules.dispensedPacks(entry.dispensings);
        final left = RxRules.daysLeft(rx, now);
        final canCollect =
            status == RxStatus.open || status == RxStatus.partial;
        return Scaffold(
          appBar: AppBar(
            title: Text(rxKindLabel(l10n, rx.kind)),
            actions: [
              if (rx.nre != null)
                IconButton(
                  icon: const Icon(Icons.share_outlined),
                  tooltip: l10n.rxShare,
                  onPressed: () => _share(context, rx, person),
                ),
              PopupMenuButton<_Action>(
                onSelected: (a) => _onAction(context, ref, rx, a),
                itemBuilder: (_) => [
                  PopupMenuItem(value: _Action.edit, child: Text(l10n.edit)),
                  if (canCollect)
                    PopupMenuItem(
                      value: _Action.markDone,
                      child: Text(l10n.rxMarkDone),
                    ),
                  if (canCollect)
                    PopupMenuItem(
                      value: _Action.cancelRx,
                      child: Text(l10n.rxCancelRx),
                    ),
                  PopupMenuItem(value: _Action.delete, child: Text(l10n.rxDelete)),
                ],
              ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Chip(label: Text(rxStatusLabel(l10n, status))),
              if (canCollect && left != null) Text(l10n.rxDaysLeft(left)),
              if (canCollect && left == null && rx.priority != null)
                Text(
                  l10n.rxBookBy(
                    RxValidity.bookBy(rx.priority!, rx.issuedOn).formatted,
                  ),
                ),
              const SizedBox(height: 8),
              if (person != null || rx.personId != null)
                DetailRow(
                  icon: Icons.person_outline,
                  label: l10n.rxPerson,
                  value: person?.name ?? l10n.rxUnknownPerson,
                ),
              if (rx.nre != null)
                DetailRow(icon: Icons.tag, label: l10n.rxNre, value: rx.nre!),
              DetailRow(
                icon: Icons.event_outlined,
                label: l10n.rxIssuedOn,
                value: rx.issuedOn.formatted,
              ),
              if (rx.validUntil != null)
                DetailRow(
                  icon: Icons.event_available_outlined,
                  label: l10n.rxValidUntil,
                  value: rx.validUntil!.formatted,
                ),
              if (rx.priority != null)
                DetailRow(
                  icon: Icons.flag_outlined,
                  label: l10n.rxPriority,
                  value: rxPriorityLabel(l10n, rx.priority!),
                ),
              if (rx.doctor != null)
                DetailRow(
                  icon: Icons.medical_services_outlined,
                  label: l10n.doctorLabel,
                  value: rx.doctor!,
                ),
              if (rx.exemptionCode != null)
                DetailRow(
                  icon: Icons.verified_outlined,
                  label: l10n.rxExemption,
                  value: rx.exemptionCode!,
                ),
              if (rx.notes != null)
                DetailRow(
                  icon: Icons.notes,
                  label: l10n.notes,
                  value: rx.notes!,
                ),
              const SizedBox(height: 16),
              if (rx.nre != null && canCollect)
                FilledButton.icon(
                  key: const Key('rx_show_pharmacy'),
                  icon: const Icon(Icons.qr_code_2),
                  label: Text(l10n.rxShowAtPharmacy),
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => PharmacyScreen(
                        nre: rx.nre!,
                        taxCode: person?.taxCode,
                        title: person?.name ?? rxKindLabel(l10n, rx.kind),
                      ),
                    ),
                  ),
                ),
              if (canCollect && rx.items.isNotEmpty)
                OutlinedButton.icon(
                  key: const Key('rx_redeem'),
                  icon: const Icon(Icons.local_pharmacy_outlined),
                  label: Text(l10n.rxRedeem),
                  onPressed: () => showRedeemSheet(context, ref, entry),
                ),
              const SizedBox(height: 16),
              Text(l10n.rxItems, style: Theme.of(context).textTheme.titleSmall),
              for (final i in rx.items)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(i.description),
                  subtitle: Text(
                    [
                      '${given[i.id] ?? 0} / ${i.packs}',
                      if (i.nonSubstitutable) l10n.rxNonSubstitutable,
                    ].join(' · '),
                  ),
                  trailing: i.medicationId == null
                      ? IconButton(
                          icon: const Icon(Icons.link),
                          tooltip: l10n.rxAddToStock,
                          onPressed: () =>
                              _linkMedication(context, ref, rx, i),
                        )
                      : const Icon(Icons.inventory_2_outlined),
                ),
              if (entry.dispensings.isNotEmpty) ...[
                const SizedBox(height: 16),
                Text(
                  l10n.rxCollections,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                for (final d in entry.dispensings)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      rx.items
                              .where((i) => i.id == d.itemId)
                              .firstOrNull
                              ?.description ??
                          '',
                    ),
                    subtitle: Text(
                      [
                        d.dispensedOn.formatted,
                        '${d.packs}×',
                        ?d.pharmacy,
                      ].join(' · '),
                    ),
                    trailing: IconButton(
                      icon: const Icon(Icons.undo),
                      tooltip: l10n.rxRemoveCollection,
                      onPressed: () async {
                        await ref
                            .read(rxRepositoryProvider)
                            .undoDispensing(d.id);
                        invalidateRx(ref);
                      },
                    ),
                  ),
              ],
            ],
          ),
        );
      },
    );
  }
}
```
Register the `rxDetail` route now (Task 9 note).

Treatment detail: in `treatment_detail_screen.dart`, after the dosing-plan (`Prescription`) section's `AsyncValueView` (line ~404), add a second section titled `l10n.rxTab` with an add button pushing `'${AppRoutes.addRx}?treatmentId=${widget.treatmentId}'` plus `&personId=<id>` when exactly one person matches a patient tag (`persons.where((p) => treatment.patientTags.any(p.matchesTag))`), and a list of `ListTile`s from `ref.watch(rxForTreatmentProvider(widget.treatmentId))` showing `rxKindShort` + items + `rxStatusLabel`, each tapping to `AppRoutes.rxDetail`. Follow the existing section's `Wrap` header pattern (its comment explains the text-scale overflow).

- [ ] **Step 5: Run tests**

Run: `fvm flutter test test/presentation/`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
fvm dart format lib test
fvm flutter analyze --fatal-infos
git add lib test
git commit -m "feat(rx): prescription detail, pharmacy barcodes and collecting"
```

- [ ] **Step 7: Check the barcodes on a device**

Build and install a debug build on the test phone (Samsung SM-A346B via adb):
```bash
fvm flutter run -d $(adb devices | awk 'NR==2{print $1}')
```
Create a prescription with NRE `0410A1234567890` and a person with tax code `RSSMRA85T10A562S`, open **Show at pharmacy**, and scan both barcodes with a second phone's barcode reader (or Medora's own scanner on another device). Expected: both decode to the exact text. Record the result in the task report; a mismatch means a wrong entry in `_patterns`.

---
### Task 11: Expiry and renewal reminders, home card

**Files:**
- Create: `lib/services/rx_reminders.dart`
- Modify: `lib/services/stock_expiry_reminders.dart` (kind `rxExpiry`, `askForRx`, id offset, `needsRx` param), `lib/services/stock_reminder_scheduler.dart` (optional rx inputs), `lib/services/reminder_service.dart` (title/body, `_isStockAlertId`, payload), `lib/services/reminder_port.dart` (doc: offsets 8–10), `lib/presentation/providers/providers.dart` (`stockReminderSchedulerProvider` passes the inputs), `lib/presentation/screens/home/home_screen.dart` (card)
- Test: `test/services/rx_reminders_test.dart`, extend `test/services/stock_expiry_reminders_test.dart`, `test/services/stock_alert_text_test.dart`, `test/services/reminder_ids_test.dart`

**Interfaces:**
- Consumes: `RxWithDispensings`, `RxRules`, `Person`, `PrescriptionRepository.getActivePrescriptions()`.
- Produces:
  - `enum StockAlertKind { expiry, lowStock, rxExpiry }` — for `rxExpiry`, `StockAlert.medicationId` holds the **prescription** id and `medicationName` the prescription's label (documented on the fields).
  - `StockAlert.askForRx` (bool, default false; part of `fingerprint`).
  - `stockAlertId(String id, StockAlertKind kind)` → offsets `0x8` expiry, `0x9` lowStock, `0xA` rxExpiry.
  - `List<StockAlert> stockAlertsFor(List<Medication>, DateTime now, {…, Set<String> needsRx = const {}})`.
  - `List<StockAlert> rxExpiryAlertsFor(List<RxWithDispensings> rx, Map<String, Person> persons, DateTime now, {int leadDays = rxExpiryLeadDays})` with `const rxExpiryLeadDays = 3`.
  - `Set<String> medicationsNeedingRx({required List<Medication> lowStock, required Set<String> planned, required List<RxWithDispensings> rx, required DateTime now})`.
  - `class RxReminderInputs { const RxReminderInputs({required this.rx, required this.persons, required this.plannedMedicationIds}); … }` and `StockReminderScheduler({…, Future<RxReminderInputs?> Function()? rxInputs})`.

- [ ] **Step 1: Write the failing tests**

`test/services/rx_reminders_test.dart`:
```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/domain/entities/medication.dart';
import 'package:medora/domain/entities/person.dart';
import 'package:medora/domain/entities/rx.dart';
import 'package:medora/domain/entities/rx_dispensing.dart';
import 'package:medora/domain/repositories/rx_repository.dart';
import 'package:medora/domain/rx/rx_rules.dart';
import 'package:medora/services/rx_reminders.dart';
import 'package:medora/services/stock_expiry_reminders.dart';

void main() {
  final now = DateTime(2026, 9, 23, 10);
  RxWithDispensings entry(
    String id,
    DateTime? until, {
    List<RxDispensing> given = const [],
    String? medicationId,
  }) => RxWithDispensings(
    Rx(
      id: id,
      personId: 'p1',
      kind: RxKind.ssn,
      issuedOn: DateTime(2026, 9, 1),
      validUntil: until,
      items: [
        RxItem(id: 'i1', medicationId: medicationId, description: 'Brufen', packs: 1),
      ],
    ),
    given,
  );
  const persons = {'p1': Person(id: 'p1', name: 'Ben')};

  test('an open rx is reminded three days before its last day at 09:00', () {
    final alerts = rxExpiryAlertsFor([entry('r1', DateTime(2026, 10, 1))], persons, now);
    expect(alerts.single.kind, StockAlertKind.rxExpiry);
    expect(alerts.single.when, DateTime(2026, 9, 28, 9));
    expect(alerts.single.days, 3);
    expect(alerts.single.medicationName, 'Ben – Brufen');
  });

  test('inside the three days: the next 09:00, then the last day', () {
    final a = rxExpiryAlertsFor([entry('r1', DateTime(2026, 9, 25))], persons, now);
    expect(a.single.when, DateTime(2026, 9, 24, 9));
    expect(a.single.days, 1);
  });

  test('past 09:00 on the last day: nothing left to remind', () {
    final a = rxExpiryAlertsFor(
      [entry('r1', DateTime(2026, 9, 23))],
      persons,
      DateTime(2026, 9, 23, 10),
    );
    expect(a, isEmpty);
  });

  test('collected, expired or without validity: no alert', () {
    final given = [
      RxDispensing(id: 'd', rxId: 'r1', itemId: 'i1', packs: 1, dispensedOn: DateTime(2026, 9, 2)),
    ];
    expect(
      rxExpiryAlertsFor([
        entry('r1', DateTime(2026, 10, 1), given: given),
        entry('r2', DateTime(2026, 9, 1)),
        entry('r3', null),
      ], persons, now),
      isEmpty,
    );
  });

  test('a low, planned medication without an open rx needs one', () {
    final low = [
      Medication(id: 'm1', name: 'Brufen', quantity: 2, minimumStockLevel: 5),
      Medication(id: 'm2', name: 'Tachipirina', quantity: 1, minimumStockLevel: 5),
      Medication(id: 'm3', name: 'Aspirin', quantity: 0, minimumStockLevel: 5),
    ];
    final needs = medicationsNeedingRx(
      lowStock: low,
      planned: {'m1', 'm2'},
      rx: [entry('r1', DateTime(2026, 10, 1), medicationId: 'm2')],
      now: now,
    );
    // m1: planned, low, no rx. m2: covered by an open rx. m3: not planned.
    expect(needs, {'m1'});
  });
}
```
`Medication` requires only `id`, `name`, `quantity`; `isLowStock` is `quantity <= minimumStockLevel`, true for all three.

Append to `test/services/stock_expiry_reminders_test.dart`:
```dart
  test('a low-stock alert that needs a prescription says so, and its '
      'fingerprint changes with it', () {
    final low = _med(id: 'a', quantity: 1, minimumStockLevel: 5);
    final plain = stockAlertsFor([low], DateTime(2026, 9, 1, 10)).single;
    final asking = stockAlertsFor(
      [low],
      DateTime(2026, 9, 1, 10),
      needsRx: {'a'},
    ).single;
    expect(plain.askForRx, isFalse);
    expect(asking.askForRx, isTrue);
    expect(asking.fingerprint, isNot(plain.fingerprint));
  });
```
(`_med` in that file already takes `quantity` and `minimumStockLevel`.)

Append to `test/services/reminder_ids_test.dart`:
```dart
  test('prescription expiry ids use offset 10 of the block', () {
    final id = stockAlertId('r1', StockAlertKind.rxExpiry);
    expect(id & 0xF, 0xA);
    expect(id, isNot(stockAlertId('r1', StockAlertKind.expiry)));
  });
```
Append to `test/services/stock_alert_text_test.dart` a case asserting the English `stockAlertBody` of an `askForRx` low-stock alert ends with `Ask your doctor for a new prescription`, and that an `rxExpiry` alert with `days: 3` reads `Ben – Brufen: valid 3 more days` (follow the file's pattern for loading `AppLocalizations`).

- [ ] **Step 2: Run to verify failure**

Run: `fvm flutter test test/services/rx_reminders_test.dart test/services/stock_expiry_reminders_test.dart test/services/reminder_ids_test.dart test/services/stock_alert_text_test.dart`
Expected: FAIL — missing `rx_reminders.dart`, `askForRx`, `rxExpiry`.

- [ ] **Step 3: Implement**

`lib/services/stock_expiry_reminders.dart`:
- `enum StockAlertKind { expiry, lowStock, rxExpiry }`.
- `StockAlert`: add `this.askForRx = false` and
  ```dart
  /// A low-stock alert for a medication taken on a schedule with no open
  /// prescription left: the notification also says to ask for one.
  final bool askForRx;
  ```
  Document on `medicationId`/`medicationName`: "For [StockAlertKind.rxExpiry], the prescription's id and label."
  `fingerprint`: append `|${askForRx ? 1 : 0}`.
- `stockAlertId`: `return (hash & 0x7FFFFFF0) | switch (kind) { StockAlertKind.expiry => 0x8, StockAlertKind.lowStock => 0x9, StockAlertKind.rxExpiry => 0xA };` and update its doc ("offsets 8, 9 and 10").
- Make `_nextAlertTime` public as `nextAlertTime` (the rx planner reuses it); update its call sites.
- `stockAlertsFor`: add named `Set<String> needsRx = const {}` and pass `askForRx: needsRx.contains(m.id)` to the low-stock `StockAlert`.

`lib/services/rx_reminders.dart`:
```dart
/// Medora - Which prescription notifications should exist.
///
/// Planned like the stock and expiry alerts (same hour, same id block,
/// booked by the same scheduler), so the two never disturb each other.
library;

import 'package:medora/core/clock.dart';
import 'package:medora/domain/entities/medication.dart';
import 'package:medora/domain/entities/person.dart';
import 'package:medora/domain/repositories/rx_repository.dart';
import 'package:medora/domain/rx/rx_rules.dart';
import 'package:medora/services/stock_expiry_reminders.dart';

/// Days before its last valid day that an open prescription is reminded.
const int rxExpiryLeadDays = 3;

/// One alert per open prescription with a known last day: the first of
/// "three days before" and "the last day" still ahead of [now].
///
/// One id per prescription, so only one of the two is booked at a time.
/// The scheduler runs on every launch and resume, so once the first has
/// fired the next run books the second.
List<StockAlert> rxExpiryAlertsFor(
  List<RxWithDispensings> rx,
  Map<String, Person> persons,
  DateTime now, {
  int leadDays = rxExpiryLeadDays,
}) {
  final alerts = <StockAlert>[];
  for (final entry in rx) {
    final status = entry.statusAt(now);
    if (status != RxStatus.open && status != RxStatus.partial) continue;
    final until = entry.rx.validUntil;
    if (until == null) continue;
    final last = DateTime(until.year, until.month, until.day, stockAlertHour);
    final lead = DateTime(
      until.year,
      until.month,
      until.day - leadDays,
      stockAlertHour,
    );
    final when = nextAlertTime(lead, now);
    if (when.isAfter(last)) continue;
    alerts.add(
      StockAlert(
        id: stockAlertId(entry.rx.id, StockAlertKind.rxExpiry),
        medicationId: entry.rx.id,
        medicationName: _label(entry, persons),
        kind: StockAlertKind.rxExpiry,
        when: when,
        days: calendarDaysBetween(when, until),
        quantity: 0,
      ),
    );
  }
  return alerts;
}

/// "Ben – Brufen, Tachipirina": who it is for and what it is for.
String _label(RxWithDispensings entry, Map<String, Person> persons) {
  final person = persons[entry.rx.personId]?.name;
  final items = entry.rx.items.map((i) => i.description).join(', ');
  return [?person, if (items.isNotEmpty) items].join(' – ');
}

/// Low-stock medications taken on a schedule ([planned]) that no open
/// prescription covers: the ones to ask the doctor about.
Set<String> medicationsNeedingRx({
  required List<Medication> lowStock,
  required Set<String> planned,
  required List<RxWithDispensings> rx,
  required DateTime now,
}) {
  final covered = <String>{
    for (final entry in rx)
      if (entry.statusAt(now) case RxStatus.open || RxStatus.partial)
        for (final item in entry.rx.items) ?item.medicationId,
  };
  return {
    for (final m in lowStock)
      if (m.isLowStock && planned.contains(m.id) && !covered.contains(m.id))
        m.id,
  };
}
```
Use `stockAlertHour` / `nextAlertTime` from `stock_expiry_reminders.dart`.

`lib/services/stock_reminder_scheduler.dart`:
```dart
/// What the prescription reminders need, read once per reconcile.
class RxReminderInputs {
  const RxReminderInputs({
    required this.rx,
    required this.persons,
    required this.plannedMedicationIds,
  });

  final List<RxWithDispensings> rx;
  final Map<String, Person> persons;

  /// Medications of active dosing plans.
  final Set<String> plannedMedicationIds;
}
```
Constructor: add `Future<RxReminderInputs?> Function()? rxInputs` stored as `_rxInputs`. In `_reconcileOnce`, after `medications` is loaded:
```dart
    // Null (no inputs, or they failed to load) plans no prescription alerts
    // but keeps every stock alert: a prescription read must never cost the
    // cabinet its reminders.
    RxReminderInputs? rx;
    try {
      rx = await _rxInputs?.call();
    } catch (e) {
      debugPrint('Stock reminders: could not load prescriptions: $e');
    }
    final now = _now();
    final needsRx = rx == null
        ? const <String>{}
        : medicationsNeedingRx(
            lowStock: medications,
            planned: rx.plannedMedicationIds,
            rx: rx.rx,
            now: now,
          );
    final desired = {
      for (final alert in [
        ...stockAlertsFor(medications, now, needsRx: needsRx),
        if (rx != null) ...rxExpiryAlertsFor(rx.rx, rx.persons, now),
      ])
        alert.id: alert,
    };
```
(replacing the existing `desired` map). **Budget:** `stockAlertsFor` already caps at `kStockNotificationBudget`; cap the merged list the same way (sort by `when`, then id; take the budget) so the pending-notification pool never grows. Extract the sort-and-cap into a helper used by both.

`lib/services/reminder_service.dart`:
- `stockAlertTitle`: switch on the kind; `rxExpiry` → `strings.notificationRxExpiryTitle` (fallback `'Prescription expiring'`).
- `stockAlertBody`: `rxExpiry` → `strings.notificationRxExpiryBody(name, alert.days)` (fallbacks mirroring the plural: `'$name: last valid day'`, `'$name: valid until tomorrow'`, `'$name: valid ${alert.days} more days'`); low stock with `askForRx` → the existing body + `'\n'` + `strings.notificationAskForRx` (fallback `'Ask your doctor for a new prescription'`).
- `_isStockAlertId`: `const {0x8, 0x9, 0xA}.contains(id & 0xF)`; update its doc.
- `scheduleStockAlert` payload: `alert.kind == StockAlertKind.rxExpiry ? 'rx:${alert.medicationId}' : 'medication:${alert.medicationId}'`.
- `lib/services/reminder_port.dart` doc: "offsets 8, 9 and 10".

`providers.dart` `stockReminderSchedulerProvider`: pass
```dart
    rxInputs: () async {
      final rx = await ref.read(rxRepositoryProvider).getAll();
      final persons = await ref.read(personRepositoryProvider).getPersons();
      final plans = await ref
          .read(prescriptionRepositoryProvider)
          .getActivePrescriptions();
      final list = rx.dataOrNull;
      if (list == null) return null;
      return RxReminderInputs(
        rx: list,
        persons: {for (final p in persons.dataOrNull ?? const []) p.id: p},
        plannedMedicationIds: {
          for (final p in plans.dataOrNull ?? const []) p.medicationId,
        },
      );
    },
```
After any rx write the stock scheduler should re-plan: in `invalidateRx` (`rx_providers.dart`), also call `unawaited(ref.read(stockReminderSchedulerProvider).reconcile());` (import `dart:async`).

Home card (`home_screen.dart`): add `_RxExpiringCard` (ConsumerWidget) after the low-stock card, shown only when there are open/partial prescriptions with `daysLeft` between 0 and 7:
```dart
class _RxExpiringCard extends ConsumerWidget {
  const _RxExpiringCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final now = ref.watch(nowProvider)();
    final list = ref.watch(rxListProvider).value ?? const [];
    final soon = [
      for (final e in list)
        if (e.statusAt(now) case RxStatus.open || RxStatus.partial)
          if (RxRules.daysLeft(e.rx, now) case final d? when d <= 7) e,
    ]..sort((a, b) => a.rx.validUntil!.compareTo(b.rx.validUntil!));
    if (soon.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 16),
        _SectionHeader(
          title: l10n.rxExpiringTitle,
          onSeeAll: () => MainShellScope.of(context)?.switchTab(2),
        ),
        Card(
          child: Column(
            children: [
              for (final e in soon.take(3))
                ListTile(
                  leading: const Icon(Icons.receipt_long_outlined),
                  title: Text(
                    e.rx.items.map((i) => i.description).join(', '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(l10n.rxDaysLeft(RxRules.daysLeft(e.rx, now)!)),
                  onTap: () => context.push(
                    AppRoutes.rxDetail.replaceFirst(':id', e.rx.id),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
```
Insert `const _RxExpiringCard(),` after `const _LowStockCard(),`. "See all" switches to the treatments tab; it opens on the treatments pane — acceptable for phase A (the segment is one tap away); note it in the report.

- [ ] **Step 4: Run tests**

Run: `fvm flutter test test/services/ test/presentation/ test/goldens/`
Expected: PASS. The home golden (`home_golden_test.dart`) must be unchanged: its fixture has no prescriptions, so the card renders nothing. If the golden test's `ProviderScope` does not override `rxListProvider`, the provider hits the test database — add an override returning `[]` in `test/goldens/golden_config.dart` if the golden fails for that reason.

- [ ] **Step 5: Commit**

```bash
fvm dart format lib test
fvm flutter analyze --fatal-infos
git add lib test
git commit -m "feat(rx): expiry and renewal reminders, home card"
```

---

### Task 12: Backup and export

**Files:**
- Modify: `lib/services/backup_service.dart` (`tables`, `_insertOrder`, `_versioned`), `lib/services/export_service.dart` (`buildEpisodeSummary` gets the linked prescriptions), `lib/presentation/screens/treatment/treatment_detail_screen.dart:~463` (passes them)
- Test: extend `test/services/backup_service_test.dart`, `test/services/export_service_test.dart`

**Interfaces:**
- Consumes: local tables (Task 3), `rxForTreatmentProvider` (Task 6), `rxKindShort` (Task 9).
- Produces: backups carry `persons`, `rx`, `rx_dispensings` (envelope `formatVersion` stays 1: the new tables are additive; `restore` iterates its own `_insertOrder`, so an old backup simply has none of them). `buildEpisodeSummary({…, List<Rx> rx = const [], String Function(Rx)? rxText})`.

- [ ] **Step 1: Write the failing tests**

In `test/services/backup_service_test.dart`, next to the existing round-trip tests (they call `makeService().exportToFile(outDir)` and `makeService().restore(file, mode: …)`), add:
```dart
  test('persons, prescriptions and dispensings survive a backup round trip',
      () async {
    final db = await AppDatabase.instance.database;
    const stamps = {
      'created_at': '2026-09-23T10:00:00.000',
      'updated_at': '2026-09-23T10:00:00.000',
      'sync_status': 'synced',
    };
    await db.insert('persons', {
      'id': 'p1',
      'name': 'Ben',
      'tax_code': 'RSSMRA85T10A562S',
      'exemptions': '["E01"]',
      ...stamps,
    });
    await db.insert('rx', {
      'id': 'r1',
      'person_id': 'p1',
      'kind': 'ssn',
      'nre': '0410A1234567890',
      'issued_on': '2026-09-20',
      'items': '[{"id":"i1","description":"Brufen","packs":1}]',
      'cancelled': 0,
      ...stamps,
    });
    await db.insert('rx_dispensings', {
      'id': 'd1',
      'rx_id': 'r1',
      'item_id': 'i1',
      'packs': 1,
      'dispensed_on': '2026-09-22',
      'units_added': 0,
      ...stamps,
    });
    final file = await makeService().exportToFile(outDir);
    await AppDatabase.instance.clearAllData();
    await makeService().restore(file, mode: RestoreMode.replace);
    expect((await db.query('persons')).single['tax_code'], 'RSSMRA85T10A562S');
    expect((await db.query('rx')).single['nre'], '0410A1234567890');
    expect((await db.query('rx_dispensings')).single['rx_id'], 'r1');
  });
```
(`outDir` and `makeService` are the file's existing fixtures.)

In `test/services/export_service_test.dart`, next to the existing `buildEpisodeSummary` tests, add:
```dart
  test('the episode lists its prescriptions after the medicines', () {
    final text = buildEpisodeSummary(
      treatment: episode, // the file's existing fixture
      prescriptions: const [],
      doses: const [],
      labels: labels, // the file's existing EpisodeLabels fixture
      now: now,
      grace: Duration.zero,
      dosageText: (_) => '',
      rx: [
        Rx(
          id: 'r1',
          kind: RxKind.ssn,
          nre: '0410A1234567890',
          issuedOn: DateTime(2026, 3, 2),
          items: const [RxItem(id: 'i1', description: 'Brufen 400')],
        ),
      ],
      rxText: (r) => 'SSN ${r.nre} – ${r.items.first.description}',
    );
    expect(text, contains('SSN 0410A1234567890 – Brufen 400'));
  });
```
Use the fixture names the file actually defines for the treatment, labels and clock.

- [ ] **Step 2: Run to verify failure**

Run: `fvm flutter test test/services/backup_service_test.dart test/services/export_service_test.dart`
Expected: FAIL — `no such table` rows missing after restore; `No named parameter with the name 'rx'`.

- [ ] **Step 3: Implement**

`backup_service.dart`:
- `tables`: append `'persons', 'rx', 'rx_dispensings'`.
- `_insertOrder`: append `'persons', 'rx', 'rx_dispensings'` (after `dose_logs`; the replace-mode delete runs it reversed, so dispensings go before their rx).
- `_versioned`: add the three (they carry `updated_at`).

`export_service.dart` `buildEpisodeSummary`: add parameters
```dart
  List<Rx> rx = const [],
  String Function(Rx)? rxText,
```
and, right after the medicines block (before notes), append:
```dart
  if (rx.isNotEmpty && rxText != null) {
    for (final r in rx) {
      lines.add('- ${rxText(r)}');
    }
  }
```
Document both parameters in the function's doc comment ("the prescription documents linked to the episode; [rxText] formats one — the caller passes a presentation-layer formatter, like [dosageText]").

`treatment_detail_screen.dart` (the share handler at ~line 455): before `buildEpisodeSummary`, read
```dart
      final rx = await ref
          .read(rxForTreatmentProvider(widget.treatmentId).future)
          .then<List<RxWithDispensings>>((r) => r, onError: (_) => const []);
```
and pass
```dart
        rx: [for (final e in rx) e.rx],
        rxText: (r) => [
          rxKindShort(l10n, r.kind),
          ?r.nre,
          if (r.items.isNotEmpty) '– ${r.items.map((i) => i.description).join(', ')}',
          '(${labels.date(r.issuedOn)})',
        ].join(' '),
```

- [ ] **Step 4: Run tests**

Run: `fvm flutter test test/services/ test/presentation/`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
fvm dart format lib test
fvm flutter analyze --fatal-infos
git add lib test
git commit -m "feat(rx): prescriptions in backups and the episode summary"
```

---

### Task 13: Integration test against Supabase, docs, whole-branch review

**Files:**
- Create: `test/integration/rx_rls_test.dart`
- Modify: `docs/architecture.md` (new tables, soft references, reminder id offset 10), `docs/release.md` (migration `20260923000000_rx.sql` must be applied before 0.6.0 devices update)

- [ ] **Step 1: Write the integration test**

Model it on the existing tests in `test/integration/` (they skip without `SUPABASE_URL`/`SUPABASE_ANON_KEY` dart-defines). Cases:
1. User A inserts a person, an rx and a dispensing through `RxRemoteDatasource`; reading them back as A returns all three with `row_version = 1`.
2. User B (second sign-up) `select`s A's rows → empty; B inserting a dispensing with A's `rx_id` → error (RLS `insert` check).
3. A sets `deleted_at` on the rx → A's dispensing gets `deleted_at` (cascade) and `edited_at` is 1970 on the dispensing.
4. A inserts a live dispensing under the deleted rx → it lands with `deleted_at` set (parent trigger).
5. A calls `medora_delete_all_data` → A's persons/rx/dispensings are gone.

- [ ] **Step 2: Run it against a local Supabase**

```bash
supabase start
supabase db reset
fvm flutter test test/integration/rx_rls_test.dart \
  --dart-define=SUPABASE_URL=http://127.0.0.1:54321 \
  --dart-define=SUPABASE_ANON_KEY=$(supabase status -o env | sed -n 's/^ANON_KEY="\(.*\)"/\1/p')
supabase stop
```
Expected: PASS (5 tests). Always run `supabase stop` afterwards, even on failure.

- [ ] **Step 3: Docs**

`docs/architecture.md`: add a "Prescriptions (Rx)" section: tables, `rx_dispensings` as the only sync child, soft references and why, items as a JSON column merged as a whole, reminders sharing the stock scheduler (offset 10, payload `rx:<id>`), the pharmacy view (Code 39, no brightness control yet).
`docs/release.md`: under the migration checklist, add `supabase/migrations/20260923000000_rx.sql` before 0.6.0; note that without it every sync reports `MissingTableException` naming the file, and nothing else breaks.

- [ ] **Step 4: Full verification**

```bash
fvm flutter gen-l10n && git diff --exit-code lib/l10n/generated
fvm dart format --output=none --set-exit-if-changed lib test
fvm flutter analyze --fatal-infos
fvm flutter test
```
Expected: all green.

- [ ] **Step 5: Commit, then whole-branch review**

```bash
git add test/integration/rx_rls_test.dart docs
git commit -m "test(rx): row-level security and cascades on a real Supabase; docs"
```
Then run a whole-branch review (superpowers:requesting-code-review) over `main..rx-phase-a`. Previous phases always found cross-task bugs at this point; fix every Critical/Important finding before merging. Release (`tools/release.sh 0.6.0+24`) is a separate step the user triggers after applying the Supabase migration.

---

## Self-review notes (for the executor)

- Spec §6.2 "filter by person": in Task 9 (see the note after `rx_list_view.dart`).
- Spec §6.4 "max brightness": deferred (needs a plugin); report it.
- Spec §4.1 tag matching: used in Task 10 (treatment detail prefill).
- Everything in phase B (attachments) and C (scan) is out of scope here.
