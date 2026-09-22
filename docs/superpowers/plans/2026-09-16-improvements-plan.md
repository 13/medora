# Medora improvements (scanner accuracy, register freshness, reminders, refactor) — Implementation Plan

> **Status: a record, not a checklist.** The work in this plan has shipped.
> The `- [ ]` boxes below were never ticked as it went and are not a progress
> record — they are the plan's original step markers, left as written. What
> actually landed is in the git history for the files each step names, and in
> `docs/architecture.md` for the shape it settled into.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the photo scanner read and show the *right* code (corrected supplement codes, barcode stripes, a user-driven zoom-and-rescan, three named misread rules), keep the offline registers fresh and say so, add low-stock/expiry reminders, EAN memory and register name search, and leave the four largest screens split into testable widget files — without changing any golden.

**Architecture:** Pure Dart first, UI last. Every new decision (misread rules, register resolution, stripe crops, rotation mapping, alert scheduling) lands as a pure function in `lib/services/` with a unit test, and the screens only wire it. The scanner's camera and ML Kit dependencies move behind three small ports provided through Riverpod, which is what finally makes `BarcodeScannerScreen` widget-testable; the big-screen split runs last, after every feature has landed in those files, so it moves final code instead of racing it.

**Tech Stack:** Flutter 3.44.6 / Dart 3.12 via `fvm`, flutter_riverpod 3, go_router 18, sqflite (+ `sqflite_common_ffi` in tests), `google_mlkit_text_recognition` 0.17.1, `google_mlkit_barcode_scanning` 0.16.1, `camera` ^0.12, `image_picker` ^1.1, `flutter_local_notifications` ^22.3, `http`, `shared_preferences`, Python 3 + `poppler-utils` + `gh` for the register pipeline, systemd user units, `adb` for the phone check.

## Global Constraints

- `fvm dart format --set-exit-if-changed .` clean; `fvm flutter analyze --fatal-infos` clean; `fvm flutter test` green.
- `flutter gen-l10n` produces no diff; every user-visible string in en/de/it ARB; `untranslated.txt` is `{}`.
- Guard tests stay green: theme_sweep (no hardcoded colors), l10n_sweep, clock_sweep (no `DateTime.now()` in lib/presentation or lib/domain; use the injected clock).
- The 6 committed golden PNGs stay unchanged unless a task explicitly regenerates one and says why.
- Local SQLite schema changes only via a new ordered migration in the existing migration list; never edit an applied migration.
- No new pub dependencies unless the task names it and justifies it.
- Commits end with the two lines `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>` and `Claude-Session: https://claude.ai/code/session_01BAjdzp9JhksW2XbhM6CPBS`.

**Baseline measured on `improvements` at v0.2.3+15:** `fvm flutter test` = **609 passed, 2 skipped** (the two Supabase integration tests). Six golden PNGs under `test/goldens/`. Local `kSchemaVersion` = **13**.

---

## Findings: what already exists (checked before planning)

Read this before starting — four of the fourteen requested items are partly built already, and one of them cannot be built safely without a second migration.

1. **A scanned EAN already opens the cabinet medication.** `_openEan` (`lib/presentation/screens/scanner/barcode_scanner_screen.dart:712`) calls `getMedicationByBarcode` and pushes `AppRoutes.medicationDetail` with the `scanMedicationInCabinet` snackbar, else Add Medication. It has **no test**. Task 7 therefore only adds the separate `ean` column, remembers it on create/edit, and makes matching read both fields; Task 9 covers `_openEan` with a widget test.
2. **The update sheet already shows the GitHub release body.** `ReleaseInfo.notes` (`lib/services/app_update_service.dart:143-206`) is the GitHub `body`, and `UpdateSheet` renders it in a scrollable block (`lib/presentation/widgets/update_sheet.dart:103-112`). Missing: markdown → readable plain text, the collapse/expand, the length cap, and an actual changelog in the body — `.github/workflows/release.yml:61` uses `--generate-notes`, and `tools/release.sh` writes no body at all. That is Task 5.
3. **The supplement register tile already shows `sourceUpdated`** (`settings_screen.dart:1518-1519`, ARB `supplementRegisterUpdated`). There is **no** staleness warning in either tile, and `AifaCacheService` has no source date at all (only `getLastSyncDate()`/`getCachedCount()`). Task 4 adds the 45-day warning + action to both, keyed on `sourceUpdated` for the register and on last sync for AIFA.
4. **Low-stock and expiry reminders do not exist.** `Medication` already has `minimumStockLevel`, `expiryDate`, `isLowStock`, `isExpiringSoon({days = 30})`, `expiredAt`, and the UI has `lowStockProvider` / `expiringSoonProvider` (`lib/presentation/providers/medication_providers.dart:117,131`), but nothing in `lib/services/` ever schedules a notification for them, and `settings_providers.dart` has exactly one reminder toggle (`reminders_enabled`). Task 8 is new work end to end and reuses the existing `ReminderPort` seam.
5. **There is no `ean` column anywhere.** `medications` has a single `barcode TEXT` column (`app_database.dart:120`, index `idx_local_med_barcode` at `:213`) that carries AIC, MINSAN and EAN alike. Because `MedicationRemoteDatasource` ships `model.toJson()` wholesale (`:80,:85,:92`), adding a local column **without** a matching Supabase column breaks cloud insert — Task 7 adds `supabase/migrations/20260916000000_medication_ean.sql` as well. `BackupService` dumps tables raw (`:171-185`), so the new column rides along with no mapping change, but a *newer* backup restored on an older build is already refused by the `schemaVersion` check (`:346`).
6. **No cleanup of `scan_region_*` exists.** The scanner deletes its own crop dir in `finally` (`barcode_scanner_screen.dart:498`), but a crash orphans it; nothing sweeps the temp dir. That is Task 3.
7. **Settings is not a golden screen.** The 6 PNGs come from `home_golden_test.dart`, `add_medication_golden_test.dart`, `doses_golden_test.dart`, `doses_take_all_golden_test.dart` (light + dark). The settings split in Task 10 cannot move a golden; the Add Medication and Dose Schedule splits can, and must not.

---

## Task order, and why

Scanner correctness (Tasks 1–3) comes first because it is pure logic plus thin wiring: it is the work most likely to need a second pass on device, and every later scanner change builds on the candidate model it settles. Tasks 4–8 are the independent features, and they all land **before** the big-screen split because each one edits exactly the files the split will carve up — `settings_screen.dart` (Tasks 4, 8), `add_medication_screen.dart` (Tasks 6, 7), `barcode_scanner_screen.dart` (Tasks 1–3, 7) — so doing the split first would guarantee conflicts on every one of them. Task 9 (the camera/ML Kit ports) comes after the features but before the split for the same reason in reverse: it restructures the scanner screen's dependencies, and the split should carve the *final* shape; it also buys the split a safety net, since after Task 9 the scanner has widget tests that a pure move must keep green. Task 10 (the split) is therefore last of the code work, Task 11 (phone check) is tooling that touches no app code and can slot anywhere after Task 3, and Task 12 is the controller's gate-and-release pass.

---

## File structure

| Path | Responsibility |
|---|---|
| `lib/services/code_candidates.dart` (modify) | The three new misread rules: letter prefix before a labelled code, code must follow the label directly, re-read junk dropped. |
| `lib/services/supplement_resolution.dart` (new) | `resolveSupplementCandidates` — rewrite a supplement candidate to the register code that actually matched, before the review renders. |
| `lib/services/scan_region.dart` (modify) | `barcodeStripeCrop`, `unrotateBox`, `unrotateCandidates`, `rescanAreaCrop`. |
| `lib/services/image_size.dart` (modify) | `writeImageCrop(..., quarterTurns:)` — rotated crops under the existing 4096 px cap. |
| `lib/services/scan_temp_cleanup.dart` (new) | `cleanScanTempDirs` — sweep orphaned `scan_region_*` / `scan_stripe_*` / `scan_area_*` dirs in the app temp dir only. |
| `lib/services/scanner_ports.dart` (new) | `ScanImage`, `TextRecognitionPort`, `BarcodeScanPort`, `CameraPort`, `GalleryPort` — the widget-test seams. |
| `lib/services/mlkit_scanner_ports.dart` (new) | The ML Kit + `camera` + `image_picker` implementations of those ports. |
| `lib/services/stock_expiry_reminders.dart` (new) | `StockAlert`, `StockAlertKind`, `stockAlertsFor`, `stockAlertId` — pure alert planning. |
| `lib/services/stock_reminder_scheduler.dart` (new) | `StockReminderScheduler.reconcile()` — diffing scheduler for stock/expiry alerts. |
| `lib/services/release_notes.dart` (new) | `releaseNotesToPlainText` — markdown → readable text, capped. |
| `lib/services/register_freshness.dart` (new) | `RegisterFreshness`, `registerFreshness` — the 45-day rule for both registers. |
| `lib/presentation/screens/scanner/scan_review_view.dart` (modify) | Area selection (drag rectangle) + rescan affordance. |
| `lib/presentation/screens/scanner/barcode_scanner_screen.dart` (modify) | Stripe pass, rescan-area pass, register resolution, ports, EAN capture; split in Task 10. |
| `lib/presentation/screens/medication/supplement_search_sheet.dart` (new) | Register name search sheet, mirroring `aifa_search_sheet.dart`. |
| `lib/presentation/screens/settings/widgets/*.dart` (new, Task 10) | `settings_group.dart`, `aifa_database_tile.dart`, `supplement_register_tile.dart`, `settings_data_section.dart`, `settings_cloud_section.dart`, `settings_dialogs.dart`. |
| `lib/presentation/screens/dose/widgets/*.dart` (new, Task 10) | `dose_card.dart`, `dose_summary_header.dart`, `date_strip.dart`, `time_groups.dart`. |
| `lib/presentation/screens/medication/widgets/*.dart` (new, Task 10) | `medication_stock_section.dart`, `medication_details_section.dart`, `medication_photo_section.dart`. |
| `lib/data/local/migrations.dart`, `app_database.dart`, `medication_local_datasource.dart`, `medication_model.dart`, `medication.dart` (modify) | The `ean` column, end to end. |
| `supabase/migrations/20260916000000_medication_ean.sql` (new) | The same column server-side (the remote datasource ships `toJson()` wholesale). |
| `tools/refresh_supplements_data.sh`, `tools/systemd/medora-supplements.{service,timer}` (new) | Monthly register refresh on this machine (installed by the controller, never by the plan). |
| `tools/phone_check/run.sh`, `tools/phone_check/README.md` (new) | Repeatable on-device scanner check. Never run in CI. |

---

### Task 1: The scanner reads and shows the right code

Three misread rules in the pure candidate finder, plus resolving a supplement candidate against the already-cached register **before** the review list renders — so the chip shows the code the lookup will use, and the confirm dialog is left for the case where the register was not available at review time.

**Files:**
- Modify: `lib/services/code_candidates.dart`
- Create: `lib/services/supplement_resolution.dart`
- Create: `test/services/supplement_resolution_test.dart`
- Modify: `test/services/code_candidates_test.dart` (add cases; **every existing case must stay green**)
- Modify: `lib/presentation/screens/scanner/barcode_scanner_screen.dart` (call the resolver after recognition)

**Interfaces:**
- Consumes: `CodeCandidate`, `CodeKind`, `findCodeCandidates` (existing); `SupplementRegistryService.findByCode`, `hasData` (existing); `PlatformCapabilities.hasSupplementRegister`.
- Produces:
```dart
// lib/services/code_candidates.dart — new public constants
/// The longest supplement code a repaired reading may claim on its own.
/// The register holds ~86,100 six-digit codes and only ~65 longer ones, so a
/// leading letter read as a digit is far more likely to be a prefix.
const int maxRepairedSupplementDigits = 6;

/// The longest AIC code: nine digits after an optional letter prefix.
const int maxRepairedAicDigits = 9;

// lib/services/supplement_resolution.dart
/// Rewrites each supplement candidate to the register code that actually
/// matched it — itself, else the first of its [CodeCandidate.alternatives]
/// with a match — so the review list shows the code the lookup will use and
/// no confirmation is needed later. Candidates that matched as read, that
/// matched nothing, and every other kind come back unchanged (identical
/// instances). A rewrite that collides with a supplement candidate already
/// in the list is dropped. Call only when the register is cached.
Future<List<CodeCandidate>> resolveSupplementCandidates(
  List<CodeCandidate> candidates,
  Future<List<SupplementEntry>> Function(String code) findByCode,
);
```

- [ ] **Step 1: Write the failing tests for rule A (letter prefix)** — append to the `digit lookalikes after a label` group in `test/services/code_candidates_test.dart`:

```dart
    test('a leading letter before a labelled code is a prefix, not a digit', () {
      // Review: `IT07O18` repaired whole is 1707018 — a seven-digit code the
      // register almost never holds. `I` is a prefix; `T07O18` is the code.
      final result = findCodeCandidates([_line('COD MINSAN: IT07O18', 0)]);
      expect(describe(result), 'supplement:707018');
      expect(result.single.alternatives, ['107018', '1707018', '1107018']);
    });

    test('the prefix rule keeps a six-digit reading over a seven-digit one', () {
      final result = findCodeCandidates([_line('COD MINSAN: I070180', 0)]);
      expect(describe(result), 'supplement:070180');
      expect(result.single.alternatives, ['1070180']);
    });

    test('an AIC prefix letter is not repaired into a tenth digit', () {
      final result = findCodeCandidates([_line('AIC n. IO34567891', 0)]);
      expect(describe(result), 'aic:034567891');
      expect(result.single.alternatives, isEmpty);
    });

    test('a token one character too long for the rule is repaired whole', () {
      // 9 chars: dropping one leaves 8, not 6 — the existing behaviour.
      final result = findCodeCandidates([_line('COD MINSAN: TlBG12345', 0)]);
      expect(result.single.code, '718612345');
    });

    test('a printed seven-digit code is untouched', () {
      final result = findCodeCandidates([_line('COD MINSAN: 1070180', 0)]);
      expect(describe(result), 'supplement:1070180');
    });
```

- [ ] **Step 2: Run them and watch them fail**

Run: `fvm flutter test test/services/code_candidates_test.dart -N 'leading letter'`
Expected: FAIL — `supplement:1707018` is produced instead of `supplement:707018`.

- [ ] **Step 3: Implement rule A**

In `code_candidates.dart`, add the two public constants above, then change `_repairCodeTokens` to record prefixes and to hand the kind's maximum in. Replace the existing signature and `repair` body:

```dart
({String text, Map<int, String> repairs, Map<int, String> prefixes})
_repairCodeTokens(String text) {
  final repairs = <int, String>{};
  final prefixes = <int, String>{};
  final labels = [
    if (_supplementLabel.firstMatch(text) case final m?)
      (end: m.end, aic: false),
    if (_aicLabel.firstMatch(text) case final m?) (end: m.end, aic: true),
  ];
  if (labels.isEmpty) {
    return (text: text, repairs: repairs, prefixes: prefixes);
  }
  final chars = text.split('');

  void repair(int start, String token, int maxDigits) {
    // A leading letter before a label's code (`IT07O18`) is a prefix, not a
    // digit: repairing it whole would claim a run longer than this kind's
    // codes, while dropping it leaves exactly that length.
    if (token.length == maxDigits + 1 &&
        !_digit.hasMatch(token[0]) &&
        _digitLookalikes.containsKey(token[0])) {
      prefixes[start] = _digitLookalikes[token[0]]!;
      repair(start + 1, token.substring(1), maxDigits);
      return;
    }
    final digits = _digit.allMatches(token).length;
    if (digits < 3 || digits * 2 < token.length) return;
    if (token.length > 9 || digits == token.length) return;
    for (var k = 0; k < token.length; k++) {
      final c = token[k];
      if (_digit.hasMatch(c)) continue;
      final unit = _quantitySuffix.matchAsPrefix(text, start + k);
      final repairable =
          _digitLookalikes.containsKey(c) &&
          (unit == null || unit.end < start + token.length);
      if (!repairable) return;
    }
    for (var k = 0; k < token.length; k++) {
      final digit = _digitLookalikes[token[k]];
      if (digit == null) continue;
      chars[start + k] = digit;
      repairs[start + k] = token[k];
    }
  }

  for (final (:end, :aic) in labels) {
    final maxDigits = aic ? maxRepairedAicDigits : maxRepairedSupplementDigits;
    for (final m in _nonSpaceRun.allMatches(text, end).take(2)) {
      final raw = m[0]!;
      final leading = _edgePunctuation.matchAsPrefix(raw)?.end ?? 0;
      final token = raw.replaceAll(_edgePunctuation, '');
      repair(m.start + leading, token, maxDigits);
      // After an AIC label only the first token with a digit is the code.
      if (aic && _digit.hasMatch(token)) break;
    }
  }
  return (text: text, repairs: repairs, prefixes: prefixes);
}
```

Note the prefix character itself is left in `chars` unrepaired, so spans and element boxes still line up.

In `findCodeCandidates`, destructure the third field and pass `prefixes` down:

```dart
    final (:text, :repairs, :prefixes) = _repairCodeTokens(line.text);
```

and in the local `add` closure:

```dart
        alternatives: codeOf == null
            ? const []
            : _alternativeCodes(text, span, repairs, prefixes, code, codeOf),
```

Extend `_alternativeCodes` with the prefix readings — supplement only, because an AIC with a tenth digit is no AIC:

```dart
List<String> _alternativeCodes(
  String text,
  _Span span,
  Map<int, String> repairs,
  Map<int, String> prefixes,
  String code,
  String Function(String) codeOf,
) {
  final positions = [
    for (var i = span.start; i < span.end; i++)
      if (_ambiguousLookalikes.containsKey(repairs[i])) i,
  ];
  final prefix = prefixes[span.start - 1];
  if (positions.isEmpty && prefix == null) return const [];
  final result = <String>{};
  if (positions.isNotEmpty) {
    // Every non-empty subset of positions, as bit masks, fewest bits first;
    // ties keep the order in which lower positions change first.
    final masks = [for (var m = 1; m < 1 << positions.length; m++) m];
    int bits(int m) => m.toRadixString(2).replaceAll('0', '').length;
    int reversed(int m) {
      var r = 0;
      for (var b = 0; b < positions.length; b++) {
        if (m & (1 << b) != 0) r |= 1 << (positions.length - 1 - b);
      }
      return r;
    }

    masks.sort((a, b) {
      final cmp = bits(a).compareTo(bits(b));
      return cmp != 0 ? cmp : reversed(b).compareTo(reversed(a));
    });
    for (final mask in masks) {
      final chars = text.substring(span.start, span.end).split('');
      for (var b = 0; b < positions.length; b++) {
        if (mask & (1 << b) == 0) continue;
        final i = positions[b];
        chars[i - span.start] = _ambiguousLookalikes[repairs[i]]!;
      }
      final alternative = codeOf(chars.join());
      if (alternative != code) result.add(alternative);
      if (result.length == maxCodeAlternatives) break;
    }
  }
  // The prefix read as its digit after all: the same readings, one digit
  // longer. Only for codes whose length is not fixed (not AIC).
  if (prefix != null && code.length != maxRepairedAicDigits) {
    for (final reading in [code, ...result.toList()]) {
      if (result.length == maxCodeAlternatives) break;
      final alternative = codeOf('$prefix$reading');
      if (alternative != code) result.add(alternative);
    }
  }
  return result.toList();
}
```

The `_Span` of the code now starts after the prefix, so `_labelledCode` must skip a recorded prefix — that is Step 6, and until then rule A's tests stay red for the supplement cases. Run `fvm flutter test test/services/code_candidates_test.dart -N 'AIC prefix letter'` and expect PASS (the AIC case needs no span change).

- [ ] **Step 4: Write the failing tests for rule B (the code must follow the label)** — append to the `supplements and EAN` group:

```dart
    test('a number further along the row is not the labelled code', () {
      // Review: `30 compresse 450` next to the label produced supplement 450.
      final result = findCodeCandidates([_line('COD MINSAN: 30 compresse 450', 0)]);
      expect(_ofKind(result, CodeKind.supplement), isEmpty);
    });

    test('a partner line must start with its code', () {
      final result = findCodeCandidates([
        const OcrLine('COD MINSAN:', Rect.fromLTWH(0, 100, 240, 40)),
        const OcrLine('30 compresse 450', Rect.fromLTWH(260, 100, 300, 40)),
      ]);
      expect(_ofKind(result, CodeKind.supplement), isEmpty);
    });

    test('an "n." between label and code is allowed', () {
      for (final text in [
        'COD MINSAN n. 107018',
        'COD MINSAN nr 107018',
        'COD MINSAN N° 107018',
      ]) {
        final result = findCodeCandidates([_line(text, 0)]);
        expect(_ofKind(result, CodeKind.supplement).map((c) => c.code), [
          '107018',
        ], reason: text);
      }
    });
```

- [ ] **Step 5: Run them and watch them fail**

Run: `fvm flutter test test/services/code_candidates_test.dart -N 'further along the row'`
Expected: FAIL — `supplement:450` is produced.

- [ ] **Step 6: Implement rule B (and finish rule A's span)**

Add the separator pattern next to `_labelledDigitRun` and rewrite `_labelledCode` so the code must sit at the label's edge:

```dart
/// What may stand between a label (or the start of a partner line) and the
/// code: separators, and an "n."-style number word. Anything else — a word
/// like `compresse`, another number — means the number is not the code.
final _afterLabel = RegExp(
  r'^[\s.:,;\-–—#°]*(?:n(?:r|o|um)?[.°:]?\s*)?',
  caseSensitive: false,
);

/// The supplement code directly after [from] in [text]: only [_afterLabel]
/// separators (and a prefix letter recorded by [_repairCodeTokens]) may
/// stand in front of it. Null when the run there is no [_labelledDigitRun],
/// is [claimed], or is a quantity or date ([_quantitySuffix]).
_Span? _labelledCode(
  String text,
  int from,
  List<_Span> claimed, {
  Map<int, String> prefixes = const {},
}) {
  var start = _afterLabel.matchAsPrefix(text, from)?.end ?? from;
  if (prefixes.containsKey(start)) start += 1;
  final m = _labelledDigitRun.matchAsPrefix(text, start);
  if (m == null) return null;
  final span = _Span(m.start, m.end);
  if (claimed.any((c) => c.overlaps(span))) return null;
  if (_quantitySuffix.matchAsPrefix(text, m.end) != null) return null;
  return span;
}
```

Pass `prefixes` at both call sites inside the per-line loop of `findCodeCandidates`:

```dart
    var supplement = label == null
        ? null
        : _labelledCode(text, label.end, claimed, prefixes: prefixes);
    if (supplement == null && labelPartners.contains(lineIndex)) {
      supplement = _labelledCode(text, 0, claimed, prefixes: prefixes);
    }
```

`_labelPartners` calls `_labelledCode` twice on repaired text; give it the same treatment by repairing each line it inspects (`final repaired = _repairCodeTokens(line.text);`) and passing `repaired.prefixes`.

- [ ] **Step 7: Run the whole candidate suite**

Run: `fvm flutter test test/services/code_candidates_test.dart`
Expected: PASS — all pre-existing cases plus the new rule A and rule B cases.

- [ ] **Step 8: Write the failing tests for rule C (re-read junk)** — append to the `two recognition passes` group:

```dart
    test('first-pass junk the region pass re-read properly is dropped', () {
      final result = findCodeCandidates(
        const [OcrLine('8 057737 14183G', Rect.fromLTWH(800, 2000, 1200, 180))],
        regionLines: const [
          OcrLine('8 057737 141836', Rect.fromLTWH(810, 2005, 1190, 175)),
        ],
      );
      expect(describe(result), 'ean:8057737141836');
    });

    test('first-pass junk elsewhere on the pack is kept', () {
      final result = findCodeCandidates(
        const [OcrLine('Lotto 14183G7', Rect.fromLTWH(0, 100, 400, 60))],
        regionLines: const [
          OcrLine('8 057737 141836', Rect.fromLTWH(810, 2005, 1190, 175)),
        ],
      );
      expect(describe(result), 'ean:8057737141836 other:14183G7');
    });

    test('a decoded barcode drops the junk read over it', () {
      final result = findCodeCandidates(
        const [OcrLine('8 057737 14183G', Rect.fromLTWH(800, 2000, 1200, 180))],
        barcodes: [
          CodeCandidate.eanFromBarcode(
            '8057737141836',
            const Rect.fromLTWH(820, 2010, 1150, 160),
          )!,
        ],
      );
      expect(describe(result), 'ean:8057737141836');
    });

    test('two "other" readings of the same area both survive', () {
      final result = findCodeCandidates(
        const [OcrLine('Lotto 4R5T21', Rect.fromLTWH(0, 100, 400, 60))],
        regionLines: const [
          OcrLine('Lotto 4R5T27', Rect.fromLTWH(5, 102, 395, 58)),
        ],
      );
      expect(describe(result), 'other:4R5T21 other:4R5T27');
    });
```

- [ ] **Step 9: Run them and watch them fail**

Run: `fvm flutter test test/services/code_candidates_test.dart -N 'region pass re-read properly'`
Expected: FAIL — `other:14183G` survives next to the EAN.

- [ ] **Step 10: Implement rule C**

Add `import 'dart:math' as math;` at the top of `code_candidates.dart`, record which merged entries came from a barcode, and drop re-read junk right after `_dropConflictingReadings`:

```dart
/// How much of the smaller box two readings must share to count as readings
/// of the same printing.
const double _rereadOverlap = 0.5;

double _overlapFraction(Rect a, Rect b) {
  final i = a.intersect(b);
  if (i.width <= 0 || i.height <= 0) return 0;
  final smaller = math.min(a.width * a.height, b.width * b.height);
  return smaller <= 0 ? 0 : (i.width * i.height) / smaller;
}

/// Drops the garbled "other" tokens of the photo pass that a later, better
/// reading covers: a photo-pass `other` (line index < [regionStart]) whose
/// box shares at least [_rereadOverlap] of the smaller box with a
/// region-pass candidate of another kind, or with any decoded barcode, is
/// OCR noise from the same printing — the region pass read it at a higher
/// resolution and the barcode scanner read it from the bars.
void _dropRereadJunk(
  List<CodeCandidate> found,
  Map<CodeCandidate, int> lineOf,
  Set<CodeCandidate> fromBarcode,
  int regionStart,
) {
  final better = [
    for (final c in found)
      if (fromBarcode.contains(c) ||
          (c.kind != CodeKind.other && (lineOf[c] ?? -1) >= regionStart))
        c,
  ];
  if (better.isEmpty) return;
  found.removeWhere(
    (c) =>
        c.kind == CodeKind.other &&
        (lineOf[c] ?? regionStart) < regionStart &&
        better.any((b) => _overlapFraction(c.box, b.box) >= _rereadOverlap),
  );
}
```

In the barcode merge loop, collect the merged entries:

```dart
  final fromBarcode = <CodeCandidate>{};
  for (final barcode in barcodes) {
    if (barcode.kind == CodeKind.ean) {
      (eanAreas[barcode.code] ??= []).add(barcode.box);
    }
    final index = found.indexWhere(
      (c) => c.kind == barcode.kind && c.code == barcode.code,
    );
    if (index < 0) {
      found.add(barcode);
      fromBarcode.add(barcode);
    } else {
      final ocrText = found[index].sourceText;
      found[index] = CodeCandidate(
        code: barcode.code,
        kind: barcode.kind,
        sourceText: ocrText.isEmpty ? barcode.sourceText : ocrText,
        box: barcode.box,
        alternatives: found[index].alternatives,
      );
      fromBarcode.add(found[index]);
    }
  }
```

and call the new pass right after the existing one:

```dart
  _dropConflictingReadings(found, repairCounts, lineOf, lines.length);
  _dropRereadJunk(found, lineOf, fromBarcode, lines.length);
```

- [ ] **Step 11: Run the candidate suite**

Run: `fvm flutter test test/services/code_candidates_test.dart`
Expected: PASS (all pre-existing cases plus rules A, B, C).

- [ ] **Step 12: Commit the rules**

```bash
git add lib/services/code_candidates.dart test/services/code_candidates_test.dart
git commit -m "$(cat <<'EOF'
fix(scanner): prefix letters, label-adjacent codes and re-read junk

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01BAjdzp9JhksW2XbhM6CPBS
EOF
)"
```

- [ ] **Step 13: Write the failing test for the register resolver** — `test/services/supplement_resolution_test.dart`:

```dart
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:medora/services/code_candidates.dart';
import 'package:medora/services/supplement_resolution.dart';
import 'package:medora/services/supplement_registry_service.dart';

const _zinco = SupplementEntry(
  code: '107018',
  product: 'ZINCO-C',
  company: 'SYGNUM SRL',
);

CodeCandidate _supplement(
  String code, {
  List<String> alternatives = const [],
  Rect box = const Rect.fromLTWH(0, 0, 100, 20),
}) => CodeCandidate(
  code: code,
  kind: CodeKind.supplement,
  sourceText: 'COD MINSAN: $code',
  box: box,
  alternatives: alternatives,
);

void main() {
  final asked = <String>[];
  Future<List<SupplementEntry>> find(String code) async {
    asked.add(code);
    return SupplementRegistryService.codeKey(code) ==
            SupplementRegistryService.codeKey('107018')
        ? [_zinco]
        : const [];
  }

  setUp(asked.clear);

  test('an alternative that matches becomes the candidate code', () async {
    final result = await resolveSupplementCandidates([
      _supplement('707018', alternatives: ['107018']),
    ], find);
    expect(result.single.code, '107018');
    expect(result.single.alternatives, isEmpty);
    expect(result.single.kind, CodeKind.supplement);
    expect(result.single.sourceText, 'COD MINSAN: 707018');
    expect(result.single.box, const Rect.fromLTWH(0, 0, 100, 20));
    expect(asked, ['707018', '107018']);
  });

  test('a code that matches as read is untouched', () async {
    final input = [_supplement('107018', alternatives: ['707018'])];
    final result = await resolveSupplementCandidates(input, find);
    expect(identical(result.single, input.single), isTrue);
    expect(asked, ['107018']);
  });

  test('no match anywhere leaves the candidate and its alternatives', () async {
    final input = [_supplement('999999', alternatives: ['888888'])];
    final result = await resolveSupplementCandidates(input, find);
    expect(identical(result.single, input.single), isTrue);
    expect(result.single.alternatives, ['888888']);
    expect(asked, ['999999', '888888']);
  });

  test('other kinds are never looked up', () async {
    final input = [
      CodeCandidate(
        code: '034567891',
        kind: CodeKind.aic,
        sourceText: 'AIC 034567891',
        box: const Rect.fromLTWH(0, 0, 10, 10),
        alternatives: const ['134567891'],
      ),
    ];
    final result = await resolveSupplementCandidates(input, find);
    expect(identical(result.single, input.single), isTrue);
    expect(asked, isEmpty);
  });

  test('a rewrite that collides with an existing chip is dropped', () async {
    final result = await resolveSupplementCandidates([
      _supplement('107018'),
      _supplement('707018', alternatives: ['107018'],
          box: const Rect.fromLTWH(0, 40, 100, 20)),
    ], find);
    expect(result.map((c) => c.code), ['107018']);
  });

  test('order is preserved', () async {
    final result = await resolveSupplementCandidates([
      _supplement('999999'),
      _supplement('707018', alternatives: ['107018']),
    ], find);
    expect(result.map((c) => c.code), ['999999', '107018']);
  });
}
```

- [ ] **Step 14: Run it to verify it fails**

Run: `fvm flutter test test/services/supplement_resolution_test.dart`
Expected: FAIL — `Error: Couldn't resolve the package 'medora'... supplement_resolution.dart` (the file does not exist).

- [ ] **Step 15: Implement the resolver** — `lib/services/supplement_resolution.dart`:

```dart
/// Medora - resolving a scanned supplement code against the cached register
///
/// OCR may read `T07018` where the pack prints `107018`. The candidate keeps
/// the alternative readings; when the register is already on the device we
/// can settle which one is real *before* the review list renders, so the
/// chip shows the code the lookup will use and the user is not asked to
/// confirm a code they never saw. Without a cached register the scanner
/// falls back to asking at selection time (`confirmAlternativeCode`).
library;

import 'package:medora/services/code_candidates.dart';
import 'package:medora/services/supplement_registry_service.dart';

/// See the library doc. Non-supplement candidates, candidates that match as
/// read and candidates that match nothing come back as the same instances.
Future<List<CodeCandidate>> resolveSupplementCandidates(
  List<CodeCandidate> candidates,
  Future<List<SupplementEntry>> Function(String code) findByCode,
) async {
  final resolved = <CodeCandidate>[];
  final codes = <String>{
    for (final c in candidates)
      if (c.kind == CodeKind.supplement) c.code,
  };
  for (final candidate in candidates) {
    if (candidate.kind != CodeKind.supplement) {
      resolved.add(candidate);
      continue;
    }
    String? match;
    for (final code in [candidate.code, ...candidate.alternatives]) {
      if ((await findByCode(code)).isNotEmpty) {
        match = code;
        break;
      }
    }
    if (match == null || match == candidate.code) {
      resolved.add(candidate);
      continue;
    }
    if (!codes.add(match)) continue; // already on the list as read
    resolved.add(
      CodeCandidate(
        code: match,
        kind: candidate.kind,
        sourceText: candidate.sourceText,
        box: candidate.box,
      ),
    );
  }
  return resolved;
}
```

- [ ] **Step 16: Run it to verify it passes**

Run: `fvm flutter test test/services/supplement_resolution_test.dart`
Expected: PASS (6 tests).

- [ ] **Step 17: Wire it into the scanner**

In `barcode_scanner_screen.dart`, inside `_recognize`, after the region pass has produced `candidates` and before `scanLog(...)`:

```dart
      candidates = await _resolveAgainstRegister(candidates);
      if (!mounted || _photoPath != path) return;
```

and add the helper next to `_openSupplement`:

```dart
  /// Supplement chips corrected to the register code that matches them,
  /// when the register is already on the device. Without it (or on any
  /// error) the chips stay as read and `_openSupplement` asks the user to
  /// confirm an alternative at selection time.
  Future<List<CodeCandidate>> _resolveAgainstRegister(
    List<CodeCandidate> candidates,
  ) async {
    if (!candidates.any((c) => c.kind == CodeKind.supplement)) return candidates;
    if (!ref.read(platformCapabilitiesProvider).hasSupplementRegister) {
      return candidates;
    }
    try {
      final service = ref.read(supplementRegistryServiceProvider);
      if (!await service.hasData()) return candidates;
      return await resolveSupplementCandidates(candidates, service.findByCode);
    } catch (e) {
      debugPrint('[scan] register resolution skipped: $e');
      return candidates;
    }
  }
```

Import `package:medora/services/supplement_resolution.dart`. `_openSupplement` needs **no** change: a resolved chip matches as read, so `found.code == code` and `confirmAlternativeCode` is never reached; an unresolved one still goes through the dialog.

- [ ] **Step 18: Verify the gates and commit**

Run: `fvm dart format --set-exit-if-changed . && fvm flutter analyze --fatal-infos && fvm flutter test`
Expected: format clean, analyze "No issues found!", tests `+615 ~2` or more, 0 failures.

```bash
git add lib/services/supplement_resolution.dart test/services/supplement_resolution_test.dart lib/presentation/screens/scanner/barcode_scanner_screen.dart
git commit -m "$(cat <<'EOF'
feat(scanner): show the register's code for a misread supplement chip

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01BAjdzp9JhksW2XbhM6CPBS
EOF
)"
```

---

### Task 2: Barcode stripe pass — crop the bars above the digits, try four rotations

When nothing decoded, the bars are usually right above the human-readable digits OCR *did* read. Crop there and run the barcode scanner on that crop at 0°/90°/180°/270°, under the existing 4096 px decode cap, mapping boxes back to photo pixels.

**Files:**
- Modify: `lib/services/image_size.dart` (rotated crop), `lib/services/scan_region.dart` (stripe crop + unrotate), `lib/presentation/screens/scanner/barcode_scanner_screen.dart`
- Modify: `test/services/scan_region_test.dart`, `test/services/image_size_test.dart`

**Interfaces:**
- Consumes: `writeImageCrop`, `regionMaxDecodeSide`, `cropDecodeScale`, `CodeCandidate`, `isValidEan` (existing).
- Produces:
```dart
// lib/services/scan_region.dart
/// Side margin of a stripe crop, as a fraction of the digits' width.
const double stripeSideFraction = 0.10;
/// How far above the digits the bars are looked for, in digit-line heights.
const double stripeAboveFactor = 2.5;
/// How far below, for packs that print the digits above the bars.
const double stripeBelowFactor = 0.5;

/// The crop that should hold the bars of a barcode whose digits OCR read at
/// [digits] (photo pixels), clamped to [imageSize]; null when [digits] is
/// empty or the crop degenerates.
Rect? barcodeStripeCrop(Rect digits, Size imageSize);

/// The boxes worth a stripe pass, best first: candidates whose code is an
/// 8- or 13-digit run (an EAN read by OCR, or a digit run that failed its
/// checksum), at most [limit].
List<Rect> barcodeStripeTargets(List<CodeCandidate> candidates, {int limit = 2});

/// Maps [box] in a PNG written from [crop] at [scale] with [quarterTurns]
/// clockwise rotations back to photo pixels.
Rect unrotateBox(Rect box, {required int quarterTurns, required Rect crop, required double scale});

/// [candidates] with their boxes mapped back by [unrotateBox].
List<CodeCandidate> unrotateCandidates(List<CodeCandidate> candidates, {required int quarterTurns, required Rect crop, required double scale});

// lib/services/image_size.dart — extended signature
Future<({ui.Rect crop, double scale})?> writeImageCrop(
  String path, ui.Rect crop, String outPath,
  {int maxDecodeSide = regionMaxDecodeSide, int quarterTurns = 0});
```

- [ ] **Step 1: Write the failing pure tests** — append to `test/services/scan_region_test.dart`:

```dart
  group('barcodeStripeCrop', () {
    test('grows sideways and mostly upwards from the digits', () {
      final crop = barcodeStripeCrop(
        const Rect.fromLTWH(100, 500, 200, 20),
        const Size(1000, 1000),
      );
      // side 0.10*200 = 20, above 2.5*20 = 50, below 0.5*20 = 10
      expect(crop, const Rect.fromLTRB(80, 450, 320, 530));
    });

    test('clamps to the image', () {
      final crop = barcodeStripeCrop(
        const Rect.fromLTWH(0, 0, 200, 20),
        const Size(150, 100),
      );
      expect(crop, const Rect.fromLTRB(0, 0, 150, 30));
    });

    test('an empty box has no crop', () {
      expect(
        barcodeStripeCrop(const Rect.fromLTWH(10, 10, 0, 0), const Size(100, 100)),
        isNull,
      );
    });
  });

  group('barcodeStripeTargets', () {
    test('picks 8- and 13-digit runs, at most the limit, in order', () {
      CodeCandidate c(String code, CodeKind kind, double top) => CodeCandidate(
        code: code,
        kind: kind,
        sourceText: code,
        box: Rect.fromLTWH(0, top, 100, 20),
      );
      final targets = barcodeStripeTargets([
        c('COD12', CodeKind.other, 0),
        c('8057737141836', CodeKind.ean, 100),
        c('80577371418', CodeKind.other, 200),
        c('96385074', CodeKind.other, 300),
        c('12345678', CodeKind.other, 400),
      ]);
      expect(targets, [
        const Rect.fromLTWH(0, 100, 100, 20),
        const Rect.fromLTWH(0, 300, 100, 20),
      ]);
    });
  });

  group('unrotateBox', () {
    const crop = Rect.fromLTRB(100, 200, 300, 260); // 200 x 60 photo pixels

    test('no rotation, no scaling, is a shift', () {
      expect(
        unrotateBox(const Rect.fromLTWH(10, 5, 20, 8),
            quarterTurns: 0, crop: crop, scale: 1),
        const Rect.fromLTWH(110, 205, 20, 8),
      );
    });

    test('a quarter turn clockwise maps back', () {
      // PNG is 60 x 200; (x, y) in it came from (y, 60 - x) in the crop.
      expect(
        unrotateBox(const Rect.fromLTRB(10, 20, 30, 50),
            quarterTurns: 1, crop: crop, scale: 1),
        const Rect.fromLTRB(120, 230, 150, 250),
      );
    });

    test('a half turn maps back', () {
      expect(
        unrotateBox(const Rect.fromLTRB(10, 20, 30, 50),
            quarterTurns: 2, crop: crop, scale: 1),
        const Rect.fromLTRB(270, 210, 290, 240),
      );
    });

    test('three quarter turns map back', () {
      expect(
        unrotateBox(const Rect.fromLTRB(10, 20, 30, 50),
            quarterTurns: 3, crop: crop, scale: 1),
        const Rect.fromLTRB(150, 210, 180, 230),
      );
    });

    test('a downscaled crop divides by the scale first', () {
      expect(
        unrotateBox(const Rect.fromLTWH(10, 5, 20, 8),
            quarterTurns: 0, crop: crop, scale: 0.5),
        const Rect.fromLTWH(120, 210, 40, 16),
      );
    });
  });
```

- [ ] **Step 2: Run them to verify they fail**

Run: `fvm flutter test test/services/scan_region_test.dart`
Expected: FAIL — `barcodeStripeCrop` / `barcodeStripeTargets` / `unrotateBox` are not defined.

- [ ] **Step 3: Implement the pure helpers** in `lib/services/scan_region.dart`:

```dart
const double stripeSideFraction = 0.10;
const double stripeAboveFactor = 2.5;
const double stripeBelowFactor = 0.5;

Rect? barcodeStripeCrop(Rect digits, Size imageSize) {
  if (imageSize.isEmpty || digits.width <= 0 || digits.height <= 0) return null;
  final dx = digits.width * stripeSideFraction;
  final left = math.max(0.0, (digits.left - dx).floorToDouble());
  final right = math.min(imageSize.width, (digits.right + dx).ceilToDouble());
  final top = math.max(
    0.0,
    (digits.top - digits.height * stripeAboveFactor).floorToDouble(),
  );
  final bottom = math.min(
    imageSize.height,
    (digits.bottom + digits.height * stripeBelowFactor).ceilToDouble(),
  );
  if (right <= left || bottom <= top) return null;
  return Rect.fromLTRB(left, top, right, bottom);
}

final _digitsOnly = RegExp(r'^[0-9]+$');

List<Rect> barcodeStripeTargets(
  List<CodeCandidate> candidates, {
  int limit = 2,
}) {
  final targets = <Rect>[];
  for (final c in candidates) {
    if (!_digitsOnly.hasMatch(c.code)) continue;
    if (c.code.length != 8 && c.code.length != 13) continue;
    if (c.box.width <= 0 || c.box.height <= 0) continue;
    targets.add(c.box);
    if (targets.length == limit) break;
  }
  return targets;
}

Rect unrotateBox(
  Rect box, {
  required int quarterTurns,
  required Rect crop,
  required double scale,
}) {
  final w = crop.width * scale; // PNG width before rotation
  final h = crop.height * scale; // PNG height before rotation
  Offset back(Offset p) => switch (quarterTurns % 4) {
    0 => p,
    1 => Offset(p.dy, h - p.dx),
    2 => Offset(w - p.dx, h - p.dy),
    _ => Offset(w - p.dy, p.dx),
  };
  final a = back(box.topLeft);
  final b = back(box.bottomRight);
  final unrotated = Rect.fromPoints(a, b);
  return Rect.fromLTRB(
    crop.left + unrotated.left / scale,
    crop.top + unrotated.top / scale,
    crop.left + unrotated.right / scale,
    crop.top + unrotated.bottom / scale,
  );
}

List<CodeCandidate> unrotateCandidates(
  List<CodeCandidate> candidates, {
  required int quarterTurns,
  required Rect crop,
  required double scale,
}) => [
  for (final c in candidates)
    CodeCandidate(
      code: c.code,
      kind: c.kind,
      sourceText: c.sourceText,
      box: unrotateBox(
        c.box,
        quarterTurns: quarterTurns,
        crop: crop,
        scale: scale,
      ),
      alternatives: c.alternatives,
    ),
];
```

- [ ] **Step 4: Run them to verify they pass**

Run: `fvm flutter test test/services/scan_region_test.dart`
Expected: PASS.

- [ ] **Step 5: Add the rotation to `writeImageCrop`**

In `lib/services/image_size.dart`, add the `quarterTurns` parameter (documented: "clockwise rotations applied to the written PNG, so a barcode printed sideways can be decoded; map boxes back with `unrotateBox`") and replace the recording block:

```dart
    final turns = quarterTurns % 4;
    final baseWidth = math.max(1, (written.width * scale).round());
    final baseHeight = math.max(1, (written.height * scale).round());
    final outWidth = turns.isEven ? baseWidth : baseHeight;
    final outHeight = turns.isEven ? baseHeight : baseWidth;
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    switch (turns) {
      case 1:
        canvas.translate(outWidth.toDouble(), 0);
        canvas.rotate(math.pi / 2);
      case 2:
        canvas.translate(outWidth.toDouble(), outHeight.toDouble());
        canvas.rotate(math.pi);
      case 3:
        canvas.translate(0, outHeight.toDouble());
        canvas.rotate(-math.pi / 2);
    }
    canvas.drawImageRect(
      image,
      src,
      ui.Rect.fromLTWH(0, 0, baseWidth.toDouble(), baseHeight.toDouble()),
      ui.Paint(),
    );
    picture = recorder.endRecording();
    cropped = await picture.toImage(outWidth, outHeight);
```

- [ ] **Step 6: Test the rotated write** — append to `test/services/image_size_test.dart`, in that file's style: the committed `test/fixtures/exif_orientation_6.jpg` (stored 40×20, upright **20×40**), `testWidgets` + `tester.runAsync` (the crop needs a live engine), and the PNG read back with `readImageSize`:

```dart
  testWidgets('a quarter turn swaps the written PNG dimensions', (
    tester,
  ) async {
    const path = 'test/fixtures/exif_orientation_6.jpg'; // upright 20x40
    final dir = Directory.systemTemp.createTempSync('scan_rot_test_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final out = '${dir.path}/rot.png';

    final written = await tester.runAsync(
      () => writeImageCrop(
        path,
        const Rect.fromLTRB(0, 0, 20, 40),
        out,
        quarterTurns: 1,
      ),
    );
    // The crop stays in photo pixels; only the PNG is turned.
    expect(written?.crop, const Rect.fromLTRB(0, 0, 20, 40));
    expect(written?.scale, 1.0);
    final size = await tester.runAsync(() => readImageSize(out));
    expect(size, const Size(40, 20));
  });

  testWidgets('a rotated crop obeys the decode cap', (tester) async {
    const path = 'test/fixtures/exif_orientation_6.jpg';
    final dir = Directory.systemTemp.createTempSync('scan_rot_test_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final out = '${dir.path}/rot.png';

    final written = await tester.runAsync(
      () => writeImageCrop(
        path,
        const Rect.fromLTRB(0, 0, 20, 40),
        out,
        maxDecodeSide: 20,
        quarterTurns: 3,
      ),
    );
    expect(written?.crop, const Rect.fromLTRB(0, 0, 20, 40));
    expect(written?.scale, 0.5);
    final size = await tester.runAsync(() => readImageSize(out));
    expect(size, const Size(20, 10));
  });
```

Run: `fvm flutter test test/services/image_size_test.dart` — expected PASS.

- [ ] **Step 7: Wire the stripe pass into the scanner**

In `barcode_scanner_screen.dart`, add the constant `static const Duration _stripeTimeout = Duration(seconds: 15);` and, in `_recognize`, right after the region pass block and before the register resolution:

```dart
      if (barcodes.isEmpty) {
        final stripes = await _scanBarcodeStripes(path, size, candidates);
        if (!mounted || _photoPath != path) return;
        if (stripes.isNotEmpty) {
          barcodes = [...barcodes, ...stripes];
          candidates = findCodeCandidates(
            photoLines,
            regionLines: regionLines,
            barcodes: barcodes,
          );
        }
      }
```

(keep `regionLines` in a local `var regionLines = const <OcrLine>[];` set by the region pass, so this re-merge does not lose it), and add:

```dart
  /// A barcode pass on the bars above the digits OCR read: for each target
  /// (see [barcodeStripeTargets]) the crop is written as a PNG under the
  /// [regionMaxDecodeSide] cap and scanned at 0°, 90°, 180° and 270°,
  /// stopping at the first rotation that decodes. Boxes come back in photo
  /// pixels. Empty when nothing decodes, the crop times out or the pass
  /// fails (logged); the photo's own passes stand.
  Future<List<CodeCandidate>> _scanBarcodeStripes(
    String path,
    Size size,
    List<CodeCandidate> candidates,
  ) async {
    final found = <CodeCandidate>[];
    for (final target in barcodeStripeTargets(candidates)) {
      final crop = barcodeStripeCrop(target, size);
      if (crop == null) continue;
      Directory? dir;
      try {
        dir = await (await getTemporaryDirectory()).createTemp('scan_stripe_');
        for (var turns = 0; turns < 4; turns++) {
          final out = p.join(dir.path, 'stripe_$turns.png');
          final written = await writeImageCrop(
            path,
            crop,
            out,
            quarterTurns: turns,
          ).timeout(_stripeTimeout);
          if (written == null) break;
          final decoded = await _scanBarcodes(
            InputImage.fromFilePath(out),
            pass: 'stripe ${turns * 90}°',
          );
          if (decoded == null || decoded.isEmpty) continue;
          found.addAll(
            unrotateCandidates(
              decoded,
              quarterTurns: turns,
              crop: written.crop,
              scale: written.scale,
            ),
          );
          break;
        }
      } catch (e, stack) {
        debugPrint('[scan] stripe pass failed: $e\n$stack');
      } finally {
        if (dir != null) await _deleteDirectory(dir);
      }
      if (found.isNotEmpty) break;
    }
    return found;
  }
```

- [ ] **Step 8: Verify the gates and commit**

Run: `fvm dart format --set-exit-if-changed . && fvm flutter analyze --fatal-infos && fvm flutter test`
Expected: clean, clean, 0 failures.

```bash
git add lib/services/scan_region.dart lib/services/image_size.dart lib/presentation/screens/scanner/barcode_scanner_screen.dart test/services/scan_region_test.dart test/services/image_size_test.dart
git commit -m "$(cat <<'EOF'
feat(scanner): decode the bars above the digits, in four rotations

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01BAjdzp9JhksW2XbhM6CPBS
EOF
)"
```

---

### Task 3: Zoom-and-rescan a selected area, and sweep orphaned crop folders

The user drags a rectangle on the review photo and rescans just that area (text + barcode), merging the new candidates. The same task sweeps leftover `scan_*` folders at startup, since this adds a third kind of them.

**Files:**
- Create: `lib/services/scan_temp_cleanup.dart`, `test/services/scan_temp_cleanup_test.dart`
- Modify: `lib/services/scan_region.dart` (+ its test), `lib/presentation/screens/scanner/scan_review_view.dart`, `lib/presentation/screens/scanner/barcode_scanner_screen.dart`, `lib/presentation/providers/providers.dart`, `test/presentation/screens/scan_review_view_test.dart`, ARB ×3

**Interfaces:**
- Consumes: `writeImageCrop`, `offsetOcrLines`, `offsetCandidates`, `findCodeCandidates`, `AppStartupTasks` (existing).
- Produces:
```dart
// lib/services/scan_region.dart
/// The photo-pixel crop for a user-selected [selection] (fractions of the
/// displayed photo, 0..1), clamped to [imageSize] and never smaller than
/// [minRescanSide] pixels on a side; null when the selection is degenerate.
const double minRescanSide = 24;
Rect? rescanAreaCrop(Rect selection, Size imageSize);

// lib/services/scan_temp_cleanup.dart
const List<String> scanTempPrefixes = ['scan_region_', 'scan_stripe_', 'scan_area_'];
/// Deletes leftover scanner crop directories directly inside [tempDir].
Future<int> cleanScanTempDirs(Directory tempDir);

// lib/presentation/screens/scanner/scan_review_view.dart — added parameters
ScanReviewView({..., this.onRescanArea, this.selecting = false, this.onToggleSelecting});
final ValueChanged<Rect>? onRescanArea; // selection in 0..1 fractions of the photo
final bool selecting;
final VoidCallback? onToggleSelecting;
```

- [ ] **Step 1: Write the failing test for the sweep** — `test/services/scan_temp_cleanup_test.dart`:

```dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:medora/services/scan_temp_cleanup.dart';

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('cleanup_test_');
  });
  tearDown(() async {
    if (temp.existsSync()) await temp.delete(recursive: true);
  });

  test('deletes only scanner crop folders', () async {
    await Directory('${temp.path}/scan_region_abc').create();
    await Directory('${temp.path}/scan_stripe_def').create();
    await Directory('${temp.path}/scan_area_ghi').create();
    await Directory('${temp.path}/image_picker_xyz').create();
    await File('${temp.path}/scan_region_file.png').writeAsString('x');

    expect(await cleanScanTempDirs(temp), 3);

    final left = temp.listSync().map((e) => e.path.split('/').last).toSet();
    expect(left, {'image_picker_xyz', 'scan_region_file.png'});
  });

  test('deletes a folder with contents', () async {
    final dir = await Directory('${temp.path}/scan_region_abc').create();
    await File('${dir.path}/region.png').writeAsString('x');
    expect(await cleanScanTempDirs(temp), 1);
    expect(dir.existsSync(), isFalse);
  });

  test('a missing temp directory is not an error', () async {
    final gone = Directory('${temp.path}/nope');
    expect(await cleanScanTempDirs(gone), 0);
  });
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `fvm flutter test test/services/scan_temp_cleanup_test.dart`
Expected: FAIL — the library does not exist.

- [ ] **Step 3: Implement the sweep** — `lib/services/scan_temp_cleanup.dart`:

```dart
/// Medora - sweeping the scanner's leftover crop folders
///
/// The scanner writes each second-pass crop into a fresh directory under the
/// app's temporary directory and deletes it in a `finally`. A crash (or the
/// system killing the app mid-scan) leaves one behind. This sweeps them at
/// startup — only direct children of the app's own temporary directory whose
/// name starts with one of [scanTempPrefixes], never a file, never anything
/// else in there (the image picker keeps its copies alongside).
library;

import 'dart:io';

import 'package:flutter/foundation.dart';

const List<String> scanTempPrefixes = [
  'scan_region_',
  'scan_stripe_',
  'scan_area_',
];

/// Deletes leftover scanner crop directories in [tempDir]; returns how many
/// were removed. A missing directory, or one that cannot be read or deleted,
/// is logged and counted as nothing.
Future<int> cleanScanTempDirs(Directory tempDir) async {
  var removed = 0;
  try {
    if (!await tempDir.exists()) return 0;
    await for (final entry in tempDir.list(followLinks: false)) {
      if (entry is! Directory) continue;
      final name = entry.uri.pathSegments.where((s) => s.isNotEmpty).last;
      if (!scanTempPrefixes.any(name.startsWith)) continue;
      try {
        await entry.delete(recursive: true);
        removed++;
      } on FileSystemException catch (e) {
        debugPrint('[scan] leftover crop folder not deleted: $e');
      }
    }
  } on FileSystemException catch (e) {
    debugPrint('[scan] temporary directory not swept: $e');
  }
  return removed;
}
```

- [ ] **Step 4: Run it to verify it passes**

Run: `fvm flutter test test/services/scan_temp_cleanup_test.dart`
Expected: PASS (3 tests).

- [ ] **Step 5: Run the sweep at startup**

`AppStartupTasks` takes fixed closures, so extend the *maintenance* closure rather than its signature — that keeps `test/services/app_startup_tasks_test.dart` green. In `lib/presentation/providers/providers.dart`, inside `appStartupTasksProvider`, change the `maintenance:` closure's last line to also sweep:

```dart
    maintenance: () async {
      final grace = Duration(minutes: ref.read(missedGraceMinutesProvider));
      final changed = await ref
          .read(doseMaintenanceProvider)
          .markOverdueAsMissed(grace: grace);
      if (changed > 0) {
        await ref.read(todaysDoseLogsProvider.notifier).refresh();
        ref.read(doseDataVersionProvider.notifier).bump();
      }
      // Crop folders orphaned by a crash mid-scan (see scan_temp_cleanup).
      if (!kIsWeb) await cleanScanTempDirs(await getTemporaryDirectory());
    },
```

Import `package:flutter/foundation.dart` (for `kIsWeb`), `package:path_provider/path_provider.dart` and the new service.

- [ ] **Step 6: Write the failing widget tests for area selection** — append to `test/presentation/screens/scan_review_view_test.dart`:

```dart
  testWidgets('dragging in selection mode reports the selected fractions', (
    tester,
  ) async {
    Rect? selected;
    await pumpMedoraApp(
      tester,
      Scaffold(
        body: ScanReviewView(
          image: MemoryImage(_png), // the file's existing 1x1 PNG fixture
          imageSize: const Size(1000, 1000),
          candidates: const [],
          onSelected: (_) {},
          onRetake: () {},
          onManualEntry: () {},
          selecting: true,
          onToggleSelecting: () {},
          onRescanArea: (area) => selected = area,
        ),
      ),
    );
    final photo = find.byKey(const ValueKey('scanPhoto'));
    final box = tester.getRect(photo);
    await tester.timedDrag(
      photo,
      Offset(box.width / 4, box.height / 4),
      const Duration(milliseconds: 200),
      pointerDownLocation: box.topLeft + Offset(box.width / 4, box.height / 4),
    );
    await tester.tap(find.byKey(const ValueKey('scanRescanArea')));
    await tester.pumpAndSettle();
    expect(selected, isNotNull);
    expect(selected!.left, closeTo(0.25, 0.02));
    expect(selected!.top, closeTo(0.25, 0.02));
    expect(selected!.right, closeTo(0.5, 0.02));
    expect(selected!.bottom, closeTo(0.5, 0.02));
  });

  testWidgets('the select-area button toggles the mode', (tester) async {
    var toggled = 0;
    await pumpMedoraApp(
      tester,
      Scaffold(
        body: ScanReviewView(
          image: MemoryImage(_png),
          imageSize: const Size(1000, 1000),
          candidates: const [],
          onSelected: (_) {},
          onRetake: () {},
          onManualEntry: () {},
          onToggleSelecting: () => toggled++,
          onRescanArea: (_) {},
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('scanSelectArea')));
    expect(toggled, 1);
  });

  testWidgets('without a rescan callback the button is absent', (tester) async {
    await pumpMedoraApp(
      tester,
      Scaffold(
        body: ScanReviewView(
          image: MemoryImage(_png),
          imageSize: const Size(1000, 1000),
          candidates: const [],
          onSelected: (_) {},
          onRetake: () {},
          onManualEntry: () {},
        ),
      ),
    );
    expect(find.byKey(const ValueKey('scanSelectArea')), findsNothing);
  });
```

- [ ] **Step 7: Run them to verify they fail**

Run: `fvm flutter test test/presentation/screens/scan_review_view_test.dart`
Expected: FAIL — `selecting`/`onRescanArea` are not parameters of `ScanReviewView`.

- [ ] **Step 8: Implement selection in `ScanReviewView`**

Turn `ScanReviewView` into a `StatefulWidget` keeping the same constructor plus the three new parameters. State holds `Rect? _selection` in fractions of the photo box and a `TransformationController _zoom`.

- Give the photo's `AspectRatio` child the key `ValueKey('scanPhoto')`.
- `_Photo` gains `selecting`, `selection` and `onSelectionChanged`. When `selecting` is true: `InteractiveViewer(panEnabled: false, scaleEnabled: true, transformationController: _zoom, ...)` so pinch still zooms but a drag draws instead of panning; wrap the stack in a `GestureDetector` with `onPanStart/onPanUpdate/onPanEnd` that converts the local offset to scene coordinates with `Matrix4.inverted(_zoom.value)` (via `MatrixUtils.transformPoint`) and then to fractions by dividing by the laid-out photo size, clamped to 0..1. Paint the selection with a `CustomPaint` using `scheme.primary` for the border and `scheme.primary.withValues(alpha: 0.12)` for the fill (theme tokens only — the sweep forbids `Colors.*`).
- Under the photo, when `onRescanArea != null`, a row with `TextButton.icon(key: ValueKey('scanSelectArea'), icon: Icon(Icons.crop), label: Text(l10n.scanSelectArea), onPressed: busy ? null : onToggleSelecting)` and, once a selection exists and `selecting` is true, `FilledButton.icon(key: ValueKey('scanRescanArea'), icon: Icon(Icons.search), label: Text(l10n.scanRescanArea), onPressed: busy || _selection == null ? null : () => onRescanArea!(_selection!))`. While `selecting`, show `l10n.scanSelectAreaHint` above the list.

- [ ] **Step 9: Add the ARB strings** (en / de / it), then run `fvm flutter gen-l10n`:

- `scanSelectArea`: "Select area" / "Bereich wählen" / "Seleziona area"
- `scanRescanArea`: "Scan selection" / "Auswahl scannen" / "Scansiona selezione"
- `scanSelectAreaHint`: "Drag a box around the code, then scan the selection." / "Ziehe einen Rahmen um den Code und scanne die Auswahl." / "Trascina un riquadro attorno al codice, poi scansiona la selezione."
- `scanRescanNothingNew`: "No new code found in that area." / "In diesem Bereich wurde kein neuer Code gefunden." / "Nessun nuovo codice in quell'area."

- [ ] **Step 10: Run the widget tests to verify they pass**

Run: `fvm flutter test test/presentation/screens/scan_review_view_test.dart`
Expected: PASS.

- [ ] **Step 11: Implement the rescan in the screen**

`_BarcodeScannerScreenState` keeps the accumulated inputs so a rescan merges rather than replaces: add fields `List<OcrLine> _photoLines = const []; List<OcrLine> _extraLines = const []; List<CodeCandidate> _barcodes = const []; bool _selectingArea = false;` and set them in `_recognize`. Add:

```dart
  /// Text recognition and barcode scanning on the area the user selected on
  /// the review photo ([selection] in 0..1 fractions), merged into the
  /// candidates already found. The crop is a PNG in a fresh `scan_area_`
  /// directory, deleted when done.
  Future<void> _rescanArea(Rect selection) async {
    final path = _photoPath;
    if (path == null || _isSearching) return;
    final crop = rescanAreaCrop(selection, _imageSize);
    if (crop == null) return;
    setState(() => _isSearching = true);
    Directory? dir;
    final before = _candidates.length;
    try {
      dir = await (await getTemporaryDirectory()).createTemp('scan_area_');
      final out = p.join(dir.path, 'area.png');
      final written = await writeImageCrop(
        path,
        crop,
        out,
      ).timeout(_regionCropTimeout);
      if (written == null || !mounted || _photoPath != path) return;
      final input = InputImage.fromFilePath(out);
      final (lines, found) = await (
        _recognizeText(
          input,
          offset: written.crop.topLeft,
          scale: written.scale,
          pass: 'area',
        ),
        _scanBarcodes(input, pass: 'area'),
      ).wait;
      if (!mounted || _photoPath != path) return;
      _extraLines = [..._extraLines, ...?lines];
      _barcodes = [
        ..._barcodes,
        ...offsetCandidates(
          found ?? const [],
          written.crop.topLeft,
          scale: written.scale,
        ),
      ];
      var candidates = findCodeCandidates(
        _photoLines,
        regionLines: _extraLines,
        barcodes: _barcodes,
      );
      candidates = await _resolveAgainstRegister(candidates);
      if (!mounted || _photoPath != path) return;
      setState(() {
        _candidates = candidates;
        _selectingArea = false;
      });
      if (candidates.length == before && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppLocalizations.of(context).scanRescanNothingNew)),
        );
      }
    } catch (e, stack) {
      debugPrint('[scan] area rescan failed: $e\n$stack');
      if (mounted) _showError();
    } finally {
      if (dir != null) await _deleteDirectory(dir);
      if (mounted) setState(() => _isSearching = false);
    }
  }
```

Pass it to the review view: `onRescanArea: _rescanArea, selecting: _selectingArea, onToggleSelecting: () => setState(() => _selectingArea = !_selectingArea)`.

Implement `rescanAreaCrop` in `scan_region.dart`:

```dart
const double minRescanSide = 24;

Rect? rescanAreaCrop(Rect selection, Size imageSize) {
  if (imageSize.isEmpty) return null;
  final raw = Rect.fromLTRB(
    selection.left * imageSize.width,
    selection.top * imageSize.height,
    selection.right * imageSize.width,
    selection.bottom * imageSize.height,
  );
  final left = math.max(0.0, raw.left.floorToDouble());
  final top = math.max(0.0, raw.top.floorToDouble());
  final right = math.min(imageSize.width, raw.right.ceilToDouble());
  final bottom = math.min(imageSize.height, raw.bottom.ceilToDouble());
  if (right - left < minRescanSide || bottom - top < minRescanSide) return null;
  return Rect.fromLTRB(left, top, right, bottom);
}
```

with tests in `scan_region_test.dart`: a half-size selection of a 1000×800 photo → `Rect.fromLTRB(250, 200, 500, 400)`; a 1 % selection → null; a selection beyond the edges clamps.

- [ ] **Step 12: Verify the gates and commit**

Run: `fvm dart format --set-exit-if-changed . && fvm flutter analyze --fatal-infos && fvm flutter test`
Expected: clean, clean, 0 failures, goldens unchanged (`git status` shows no PNG modified).

```bash
git add -A
git commit -m "$(cat <<'EOF'
feat(scanner): rescan a selected area; sweep orphaned crop folders

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01BAjdzp9JhksW2XbhM6CPBS
EOF
)"
```

---

### Task 4: Register freshness — monthly refresh on this machine, and an in-app age warning

Two halves of one promise: the data gets rebuilt monthly here, and the app says so when it has not.

**Files:**
- Create: `tools/refresh_supplements_data.sh`, `tools/systemd/medora-supplements.service`, `tools/systemd/medora-supplements.timer`
- Create: `lib/services/register_freshness.dart`, `test/services/register_freshness_test.dart`
- Modify: `lib/presentation/screens/settings/settings_screen.dart` (both tiles), `lib/presentation/screens/scanner/barcode_scanner_screen.dart` (review banner), `docs/release.md`, ARB ×3
- Modify: `test/presentation/screens/supplement_register_tile_test.dart`

**Interfaces:**
- Consumes: `SupplementRegistryService.sourceUpdated()/lastSync()/count()`, `AifaCacheService.getLastSyncDate()/getCachedCount()`, `nowProvider`.
- Produces:
```dart
// lib/services/register_freshness.dart
/// How old a register may get before the app asks for an update.
const int registerStaleDays = 45;

@immutable
class RegisterFreshness {
  const RegisterFreshness({required this.days, required this.isStale, required this.isMissing});
  final int? days;      // null when the register was never downloaded
  final bool isStale;   // days >= registerStaleDays
  final bool isMissing; // nothing cached at all
}

/// How fresh a register is at [now]: [sourceUpdated] when the source dates
/// itself (the supplement register), else [lastSync] (the AIFA cache).
RegisterFreshness registerFreshness({
  required DateTime now,
  DateTime? sourceUpdated,
  DateTime? lastSync,
  int count = 0,
});
```

- [ ] **Step 1: Write the failing freshness tests** — `test/services/register_freshness_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/services/register_freshness.dart';

void main() {
  final now = DateTime(2026, 9, 16, 10);

  test('the source date wins over the sync date', () {
    final f = registerFreshness(
      now: now,
      sourceUpdated: DateTime(2026, 9, 1),
      lastSync: DateTime(2026, 9, 15),
      count: 100,
    );
    expect(f.days, 15);
    expect(f.isStale, isFalse);
    expect(f.isMissing, isFalse);
  });

  test('without a source date the sync date is used', () {
    final f = registerFreshness(
      now: now,
      lastSync: DateTime(2026, 7, 1),
      count: 100,
    );
    expect(f.days, 77);
    expect(f.isStale, isTrue);
  });

  test('exactly 45 days is stale', () {
    final f = registerFreshness(
      now: now,
      sourceUpdated: now.subtract(const Duration(days: 45)),
      count: 1,
    );
    expect(f.days, 45);
    expect(f.isStale, isTrue);
  });

  test('44 days is not stale', () {
    final f = registerFreshness(
      now: now,
      sourceUpdated: now.subtract(const Duration(days: 44)),
      count: 1,
    );
    expect(f.isStale, isFalse);
  });

  test('nothing cached is missing, not stale', () {
    final f = registerFreshness(now: now);
    expect(f.isMissing, isTrue);
    expect(f.isStale, isFalse);
    expect(f.days, isNull);
  });

  test('rows cached but no date at all counts as stale', () {
    final f = registerFreshness(now: now, count: 100);
    expect(f.isMissing, isFalse);
    expect(f.isStale, isTrue);
    expect(f.days, isNull);
  });

  test('days ignore the time of day', () {
    final f = registerFreshness(
      now: DateTime(2026, 9, 16, 23, 59),
      sourceUpdated: DateTime(2026, 9, 15, 0, 1),
      count: 1,
    );
    expect(f.days, 1);
  });
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `fvm flutter test test/services/register_freshness_test.dart`
Expected: FAIL — library not found.

- [ ] **Step 3: Implement it** — `lib/services/register_freshness.dart`:

```dart
/// Medora - how old a cached register is
///
/// The supplement register dates itself (`sourceUpdated`, the Ministry's
/// "aggiornato al"), which is what the user cares about; the AIFA cache does
/// not, so its download date stands in. Both are compared in whole calendar
/// days, like every other date rule in the app.
library;

import 'package:flutter/foundation.dart';
import 'package:medora/core/clock.dart';

/// How old a register may get before the app asks for an update.
const int registerStaleDays = 45;

@immutable
class RegisterFreshness {
  const RegisterFreshness({
    required this.days,
    required this.isStale,
    required this.isMissing,
  });

  /// Whole days since the register's date, null when it has none.
  final int? days;
  final bool isStale;
  final bool isMissing;
}

/// See the library doc. [count] is the number of cached rows: zero means the
/// register was never downloaded, which is "missing", not "stale". Rows
/// without any date are treated as stale — the app cannot tell how old they
/// are, and offering the update is the safe answer.
RegisterFreshness registerFreshness({
  required DateTime now,
  DateTime? sourceUpdated,
  DateTime? lastSync,
  int count = 0,
}) {
  if (count <= 0) {
    return const RegisterFreshness(days: null, isStale: false, isMissing: true);
  }
  final dated = sourceUpdated ?? lastSync;
  if (dated == null) {
    return const RegisterFreshness(days: null, isStale: true, isMissing: false);
  }
  final days = calendarDaysBetween(dated, now);
  return RegisterFreshness(
    days: days,
    isStale: days >= registerStaleDays,
    isMissing: false,
  );
}
```

- [ ] **Step 4: Run it to verify it passes**

Run: `fvm flutter test test/services/register_freshness_test.dart`
Expected: PASS (7 tests).

- [ ] **Step 5: Add the ARB strings** (en / de / it), then `fvm flutter gen-l10n`:

- `registerStale` with `{days}` (`"type": "int"`): "Last updated {days} days ago" / "Zuletzt vor {days} Tagen aktualisiert" / "Aggiornato {days} giorni fa"
- `registerStaleUnknown`: "Age unknown — update recommended" / "Alter unbekannt – Aktualisierung empfohlen" / "Età sconosciuta — aggiornamento consigliato"
- `registerUpdateNow`: "Update now" / "Jetzt aktualisieren" / "Aggiorna ora"

- [ ] **Step 6: Show the warning in both Settings tiles**

In `_SupplementRegisterTile` (`settings_screen.dart:1427-1543`), `_loadStatus` already reads `count`, `lastSync` and `sourceUpdated`; compute `registerFreshness(now: ref.read(nowProvider)(), sourceUpdated: _sourceUpdated, lastSync: _lastSync, count: _count)` in `build` and, when `isStale`, render under the existing status line a row with `Icon(Icons.warning_amber_rounded, color: context.colors.error, size: 18)` and `Text(freshness.days == null ? l10n.registerStaleUnknown : l10n.registerStale(freshness.days!), style: TextStyle(color: context.colors.error))`, plus the tile's existing update button relabelled `l10n.registerUpdateNow` while stale. Do the same in `_AifaDatabaseTile` (`:1313-1423`) using `lastSync` only (it has no source date).

- [ ] **Step 7: Show it in the scanner**

In `_recognize`, after the candidates are settled, read the same freshness (guarded by `hasSupplementRegister`) into a new `RegisterFreshness? _registerFreshness` field, and render a dismissible `MaterialBanner`-style row above the candidate list in the review stage when `isStale`: the warning text plus a `TextButton(l10n.registerUpdateNow)` that runs the same download dialog as the first-use path (`confirmAndDownloadSupplementRegister`) and, on success, re-resolves the candidates through `_resolveAgainstRegister`.

- [ ] **Step 8: Extend the tile test**

In `test/presentation/screens/supplement_register_tile_test.dart`, add: a fake register whose `sourceUpdated()` is 60 days before an overridden `nowProvider` renders `registerStale(60)` and the `registerUpdateNow` action; one 10 days old renders neither.

Run: `fvm flutter test test/presentation/screens/supplement_register_tile_test.dart` — expected PASS.

- [ ] **Step 9: Write the refresh script** — `tools/refresh_supplements_data.sh` (`chmod +x`):

```bash
#!/usr/bin/env bash
# tools/refresh_supplements_data.sh
# Rebuilds and publishes the food-supplement register data (see
# docs/release.md). Run monthly from a machine in Italy; the systemd user
# timer in tools/systemd/ does exactly that. Logs to
# ~/.local/state/medora/refresh-supplements.log and exits non-zero on failure.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOG_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/medora"
LOG="$LOG_DIR/refresh-supplements.log"
mkdir -p "$LOG_DIR"

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$LOG"; }

log "refresh starting (repo $ROOT)"
if ! command -v pdftotext > /dev/null; then
  log "FAIL: pdftotext (poppler-utils) is not installed"
  exit 1
fi
if ! command -v gh > /dev/null; then
  log "FAIL: gh is not installed"
  exit 1
fi
if ! gh auth status >> "$LOG" 2>&1; then
  log "FAIL: gh is not authenticated"
  exit 1
fi

cd "$ROOT"
if "$ROOT/tools/build_supplements_data.py" --publish >> "$LOG" 2>&1; then
  log "refresh finished OK"
else
  status=$?
  log "FAIL: build_supplements_data.py exited $status"
  exit "$status"
fi
```

- [ ] **Step 10: Write the systemd user units** (committed only — **do not install them**; the controller installs after merge)

`tools/systemd/medora-supplements.service`:

```ini
[Unit]
Description=Rebuild and publish Medora's food-supplement register data
Documentation=https://github.com/13/medora/blob/main/docs/release.md
After=network-online.target

[Service]
Type=oneshot
ExecStart=%h/repo/medora/tools/refresh_supplements_data.sh
# The Ministry site can be slow; the PDF is ~4,100 pages.
TimeoutStartSec=3600
```

`tools/systemd/medora-supplements.timer`:

```ini
[Unit]
Description=Monthly refresh of Medora's food-supplement register data

[Timer]
OnCalendar=*-*-04 06:00:00
Persistent=true
RandomizedDelaySec=1800

[Install]
WantedBy=timers.target
```

- [ ] **Step 11: Document install/uninstall in `docs/release.md`**

Replace the "Optional automation (documented only, nothing is installed)" block in the *Food supplement register data* section with the committed units:

````markdown
### Monthly refresh on a developer machine

`tools/refresh_supplements_data.sh` runs `tools/build_supplements_data.py
--publish`, appends to `~/.local/state/medora/refresh-supplements.log` and
exits non-zero when `pdftotext`, `gh`, the download or the row guard fails.
`tools/systemd/` holds a **user** service and timer for it (4th of each month,
06:00, `Persistent=true` so a machine that was off catches up):

```bash
mkdir -p ~/.config/systemd/user
ln -sf ~/repo/medora/tools/systemd/medora-supplements.service ~/.config/systemd/user/
ln -sf ~/repo/medora/tools/systemd/medora-supplements.timer   ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now medora-supplements.timer
systemctl --user list-timers medora-supplements.timer   # check the next run
systemctl --user start medora-supplements.service       # run it once now
journalctl --user -u medora-supplements.service -n 50   # or the log file above
```

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
````

- [ ] **Step 12: Check the script without publishing**

Run: `bash -n tools/refresh_supplements_data.sh && tools/build_supplements_data.py --self-test`
Expected: no syntax errors; the self-test passes. **Do not run `--publish` and do not install the timer.**

- [ ] **Step 13: Verify the gates and commit**

Run: `fvm dart format --set-exit-if-changed . && fvm flutter analyze --fatal-infos && fvm flutter test`

```bash
git add -A
git commit -m "$(cat <<'EOF'
feat(register): monthly refresh units and a 45-day staleness warning

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01BAjdzp9JhksW2XbhM6CPBS
EOF
)"
```

---

### Task 5: "What's new" from the release body, and a real changelog in it

The sheet already prints `release.notes` raw. Make it readable (markdown stripped to plain text with simple structure), collapsible and capped, and make the body worth reading by writing a grouped changelog at release time. No new dependency — the renderer is ~60 lines of pure Dart.

**Files:**
- Create: `lib/services/release_notes.dart`, `test/services/release_notes_test.dart`
- Modify: `lib/presentation/widgets/update_sheet.dart`, `test/presentation/widgets/update_sheet_test.dart`, `tools/release.sh`, `.github/workflows/release.yml`, ARB ×3

**Interfaces:**
- Consumes: `ReleaseInfo.notes` (existing).
- Produces:
```dart
// lib/services/release_notes.dart
/// The longest "what's new" the sheet shows before collapsing.
const int releaseNotesCollapsedChars = 400;
/// The most it ever shows, expanded.
const int releaseNotesMaxChars = 4000;

/// GitHub release markdown as plain text: headings lose their `#` and keep
/// their words, list items become `• `, links become their text, inline
/// code/emphasis markers are dropped, `<!-- -->` comments, images and the
/// auto-generated "**Full Changelog**" trailer are removed, and runs of
/// blank lines collapse to one. Never longer than [releaseNotesMaxChars]
/// (cut at a line boundary, with a trailing `…`).
String releaseNotesToPlainText(String markdown);
```

- [ ] **Step 1: Write the failing tests** — `test/services/release_notes_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/services/release_notes.dart';

void main() {
  test('headings keep their words', () {
    expect(releaseNotesToPlainText('## What changed\ntext'), 'What changed\ntext');
  });

  test('list markers become bullets', () {
    expect(
      releaseNotesToPlainText('- one\n* two\n+ three\n1. four'),
      '• one\n• two\n• three\n• four',
    );
  });

  test('links keep their text', () {
    expect(
      releaseNotesToPlainText('see [the PR](https://example.com/pr/1)'),
      'see the PR',
    );
  });

  test('emphasis and code markers are dropped', () {
    expect(
      releaseNotesToPlainText('**bold** _it_ `code` ~~gone~~'),
      'bold it code gone',
    );
  });

  test('images, comments and the changelog trailer are removed', () {
    expect(
      releaseNotesToPlainText(
        'real\n![shot](https://x/y.png)\n<!-- hidden -->\n'
        '**Full Changelog**: https://github.com/13/medora/compare/v1...v2',
      ),
      'real',
    );
  });

  test('blank line runs collapse', () {
    expect(releaseNotesToPlainText('a\n\n\n\nb'), 'a\n\nb');
  });

  test('empty or marker-only input yields an empty string', () {
    expect(releaseNotesToPlainText('   \n\n'), '');
    expect(releaseNotesToPlainText('---'), '');
  });

  test('very long notes are cut at a line boundary with an ellipsis', () {
    final long = List.generate(600, (i) => 'line $i').join('\n');
    final text = releaseNotesToPlainText(long);
    expect(text.length, lessThanOrEqualTo(releaseNotesMaxChars + 1));
    expect(text, endsWith('…'));
    expect(text, contains('line 0'));
  });
}
```

- [ ] **Step 2: Run to verify failure**

Run: `fvm flutter test test/services/release_notes_test.dart`
Expected: FAIL — library not found.

- [ ] **Step 3: Implement `releaseNotesToPlainText`**

```dart
/// Medora - GitHub release notes as readable text
///
/// The update sheet shows the release body, which is markdown. Rendering it
/// properly would mean a markdown dependency for one paragraph of text, so
/// this strips it to plain text instead: the words survive, the syntax does
/// not. Pure Dart, unit-tested directly.
library;

const int releaseNotesCollapsedChars = 400;
const int releaseNotesMaxChars = 4000;

final _comment = RegExp(r'<!--.*?-->', dotAll: true);
final _image = RegExp(r'!\[[^\]]*\]\([^)]*\)');
final _link = RegExp(r'\[([^\]]*)\]\([^)]*\)');
final _heading = RegExp(r'^\s{0,3}#{1,6}\s*');
final _bullet = RegExp(r'^\s*(?:[-*+]|\d+[.)])\s+');
final _rule = RegExp(r'^\s*(?:[-*_]\s*){3,}$');
final _trailer = RegExp(r'^\*{0,2}Full Changelog\*{0,2}\s*:', caseSensitive: false);
final _emphasis = RegExp(r'(\*{1,3}|_{1,3}|~~|`+)');
final _blockQuote = RegExp(r'^\s*>\s?');

String releaseNotesToPlainText(String markdown) {
  var text = markdown.replaceAll(_comment, '').replaceAll(_image, '');
  text = text.replaceAllMapped(_link, (m) => m[1] ?? '');
  final lines = <String>[];
  for (final raw in text.split('\n')) {
    var line = raw.replaceAll('\r', '');
    if (_rule.hasMatch(line)) continue;
    if (_trailer.hasMatch(line.trim())) continue;
    line = line.replaceFirst(_blockQuote, '');
    final isBullet = _bullet.hasMatch(line);
    line = line.replaceFirst(_heading, '').replaceFirst(_bullet, '');
    line = line.replaceAll(_emphasis, '').trimRight();
    if (isBullet && line.trim().isNotEmpty) line = '• ${line.trim()}';
    lines.add(line.trimLeft());
  }
  // Collapse blank runs.
  final out = <String>[];
  for (final line in lines) {
    if (line.trim().isEmpty && (out.isEmpty || out.last.isEmpty)) continue;
    out.add(line.trim().isEmpty ? '' : line);
  }
  while (out.isNotEmpty && out.last.isEmpty) {
    out.removeLast();
  }
  final joined = out.join('\n');
  if (joined.length <= releaseNotesMaxChars) return joined;
  final cut = joined.lastIndexOf('\n', releaseNotesMaxChars);
  return '${joined.substring(0, cut > 0 ? cut : releaseNotesMaxChars).trimRight()}…';
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `fvm flutter test test/services/release_notes_test.dart`
Expected: PASS (8 tests).

- [ ] **Step 5: Add the ARB strings** and `fvm flutter gen-l10n`:

- `updateWhatsNew`: "What's new" / "Neu in dieser Version" / "Novità"
- `updateShowMore`: "Show more" / "Mehr anzeigen" / "Mostra altro"
- `updateShowLess`: "Show less" / "Weniger anzeigen" / "Mostra meno"

- [ ] **Step 6: Write the failing sheet tests**

In `test/presentation/widgets/update_sheet_test.dart`, using the existing `updateOverrides` helper with a release whose `notes` is `'## Fixed\n- **Scanner** reads the code\n' + ('x' * 600)`:

- The sheet shows `updateWhatsNew`, shows `Scanner reads the code` without `**`, and shows `updateShowMore`.
- Tapping `updateShowMore` reveals the rest and swaps the label to `updateShowLess`.
- A release with empty `notes` shows neither the heading nor the toggle.
- Notes shorter than `releaseNotesCollapsedChars` show no toggle.

Run them: expected FAIL (no `updateWhatsNew` in the tree).

- [ ] **Step 7: Render it in `UpdateSheet`**

Replace the `release.notes.trim()` block (`update_sheet.dart:103-112`) with a `_WhatsNew` stateful widget: `final text = releaseNotesToPlainText(release.notes);` — render nothing when empty; otherwise `Text(l10n.updateWhatsNew, style: titleSmall)` and `Text(expanded || text.length <= releaseNotesCollapsedChars ? text : '${text.substring(0, releaseNotesCollapsedChars).trimRight()}…')` inside the existing scroll area, plus a `TextButton(onPressed: () => setState(...), child: Text(expanded ? l10n.updateShowLess : l10n.updateShowMore))` shown only when the text is longer than the collapsed cap.

Run: `fvm flutter test test/presentation/widgets/update_sheet_test.dart` — expected PASS.

- [ ] **Step 8: Write the changelog at release time**

In `tools/release.sh`, after the tag is created and before `git push`, build the notes file so both the workflow and a manual release use the same text:

```bash
PREV="$(git describe --tags --abbrev=0 "v$NEW^" 2> /dev/null || true)"
RANGE="${PREV:+$PREV..}v$NEW"
{
  echo "## What's new in $NEW"
  echo
  for group in "feat:Features" "fix:Fixes"; do
    prefix="${group%%:*}"; title="${group##*:}"
    subjects="$(git log --no-merges --pretty=%s "$RANGE" | grep -E "^$prefix(\(.+\))?: " | sed -E "s/^$prefix(\(.+\))?: //" || true)"
    [ -n "$subjects" ] || continue
    echo "### $title"
    echo "$subjects" | sed 's/^/- /'
    echo
  done
} > dist-notes.md
echo "release notes written to dist-notes.md"
```

Commit `dist-notes.md` to `.gitignore` (it is a build artifact). The workflow regenerates it itself so a hand-pushed tag still gets notes: in `.github/workflows/release.yml`, before the "Create GitHub release" step, add a step that runs the same loop over `git log` for the pushed tag, and change the final command to:

```bash
          gh release create "$GITHUB_REF_NAME" dist/* --title "Medora $V ($B)" --notes-file dist-notes.md
```

with a fallback: `test -s dist-notes.md || echo "See the commit log." > dist-notes.md`. Add `fetch-depth: 0` to that job's `actions/checkout@v4` so `git log` sees history.

- [ ] **Step 9: Dry-run the changelog generation**

Run: `git log --no-merges --pretty=%s ceb60ed~5..ceb60ed | grep -E '^(feat|fix)(\(.+\))?: '`
Expected: prints the scanner `fix:`/`feat:` subjects — confirms the grouping expression matches this repository's commit style.

- [ ] **Step 10: Verify the gates and commit**

```bash
git add -A
git commit -m "$(cat <<'EOF'
feat(update): readable "what's new" and a grouped release changelog

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01BAjdzp9JhksW2XbhM6CPBS
EOF
)"
```

---

### Task 6: Search the supplement register by name from Add Medication

Next to "AIFA-Datenbank durchsuchen" (`searchAifaByName`), a second entry point that searches the register by product name and prefills exactly like the scanner's supplement path.

**Files:**
- Create: `lib/presentation/screens/medication/supplement_search_sheet.dart`, `test/presentation/screens/supplement_search_sheet_test.dart`
- Modify: `lib/presentation/screens/medication/add_medication_screen.dart`, ARB ×3

**Interfaces:**
- Consumes: `SupplementRegistryService.searchByName(String, {int limit})`, `supplementRegistryServiceProvider`, `SupplementEntry`, `_applySupplementEntry` (existing, `add_medication_screen.dart:156`), `PlatformCapabilities.hasSupplementRegister`.
- Produces:
```dart
// lib/presentation/screens/medication/supplement_search_sheet.dart
/// A modal search over the cached supplement register; returns the chosen
/// product, or null when dismissed. Requires the register to be cached —
/// the caller offers the download first (confirmAndDownloadSupplementRegister).
Future<SupplementEntry?> showSupplementSearchSheet(
  BuildContext context,
  SupplementRegistryService service,
);
```

- [ ] **Step 1: Write the failing widget tests** — `test/presentation/screens/supplement_search_sheet_test.dart`, reusing `test/helpers/fake_supplement_registry.dart`:

- Typing `zinc` shows the two matching products with their company as the subtitle, after the debounce; `await tester.pump(const Duration(milliseconds: 350))`.
- Tapping a row pops the sheet with that `SupplementEntry`.
- A query with no matches shows `supplementSearchNoResults`.
- A one-character query never calls `searchByName` (the service's minimum is two).
- At 360×800 nothing overflows.

- [ ] **Step 2: Run to verify failure**

Run: `fvm flutter test test/presentation/screens/supplement_search_sheet_test.dart`
Expected: FAIL — `showSupplementSearchSheet` is undefined.

- [ ] **Step 3: Implement the sheet**

Mirror `aifa_search_sheet.dart` (same `showModalBottomSheet` + `DraggableScrollableSheet` + drag handle + `ListTile` shape) with: a `TextField` (`labelText: l10n.supplementSearchHint`, autofocus), a 300 ms debounce timer, `service.searchByName(query)` for queries of two characters or more, a `CircularProgressIndicator` while searching, `Text(l10n.supplementSearchNoResults)` when empty, and rows `ListTile(title: Text(entry.product), subtitle: Text('${entry.company} · ${entry.code}'), onTap: () => Navigator.pop(ctx, entry))`. Theme tokens only.

- [ ] **Step 4: Add the ARB strings** and `fvm flutter gen-l10n`:

- `searchSupplementByName`: "Search the supplement register" / "Nahrungsergänzungsmittel-Register durchsuchen" / "Cerca nel registro integratori"
- `supplementSearchHint`: "Product name" / "Produktname" / "Nome del prodotto"
- `supplementSearchNoResults`: "No products found" / "Keine Produkte gefunden" / "Nessun prodotto trovato"

- [ ] **Step 5: Run the sheet tests to verify they pass**

Run: `fvm flutter test test/presentation/screens/supplement_search_sheet_test.dart`
Expected: PASS.

- [ ] **Step 6: Wire it into Add Medication**

Next to the existing `searchAifaByName` button (`add_medication_screen.dart:508`), add a second `OutlinedButton.icon` with `Icons.eco_outlined`, label `l10n.searchSupplementByName`, rendered only when `ref.watch(platformCapabilitiesProvider).hasSupplementRegister`, calling:

```dart
  Future<void> _showSupplementSearch(BuildContext context) async {
    final service = ref.read(supplementRegistryServiceProvider);
    if (!await service.hasData()) {
      if (!mounted) return;
      final downloaded = await confirmAndDownloadSupplementRegister(
        context,
        service,
      );
      if (!mounted || downloaded == null || !downloaded) return;
    }
    if (!mounted) return;
    final entry = await showSupplementSearchSheet(context, service);
    if (entry == null || !mounted) return;
    setState(() => _applySupplementEntry(entry));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(AppLocalizations.of(context).autoFilledFromBarcode)),
    );
  }
```

`_applySupplementEntry` already fills name, manufacturer, the supplement category and the barcode when empty — selecting therefore prefills exactly like the scanner path.

- [ ] **Step 7: Test the entry point**

In `test/presentation/screens/add_medication_supplement_test.dart`, add: with a cached fake register overridden on `supplementRegistryServiceProvider`, the button labelled `searchSupplementByName` is present; tapping it and choosing `ZINCO-C` fills the name field with `ZINCO-C` and the manufacturer with `SYGNUM SRL`. With `PlatformCapabilities.web` the button is absent.

- [ ] **Step 8: Verify the gates and commit**

Run: `fvm dart format --set-exit-if-changed . && fvm flutter analyze --fatal-infos && fvm flutter test`

```bash
git add -A
git commit -m "$(cat <<'EOF'
feat(medications): search the supplement register by product name

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01BAjdzp9JhksW2XbhM6CPBS
EOF
)"
```

---

### Task 7: EAN memory — remember the pack's barcode next to its code

A medication created from a scan that saw both a label code (AIC/MINSAN) and an EAN keeps both, and a later scan of either finds it. Needs a local migration **and** a Supabase column, because `MedicationRemoteDatasource` ships `model.toJson()` wholesale.

**Files:**
- Modify: `lib/data/local/migrations.dart` (Migration 14, `kSchemaVersion = 14`), `lib/data/local/app_database.dart` (index only), `lib/data/datasources/medication_local_datasource.dart` (`_fromRow`, `_toRow`, the barcode query), `lib/data/models/medication_model.dart`, `lib/domain/entities/medication.dart`, `lib/presentation/screens/medication/add_medication_screen.dart`, `lib/presentation/screens/scanner/barcode_scanner_screen.dart`, `lib/presentation/screens/scanner/scan_result.dart`, `lib/presentation/screens/scanner/supplement_routing.dart`, `lib/presentation/router/app_router.dart`
- Create: `supabase/migrations/20260916000000_medication_ean.sql`
- Modify: `test/data/local/app_database_test.dart`, `test/services/backup_service_test.dart`, `test/presentation/screens/add_medication_scan_test.dart`

**Interfaces:**
- Consumes: `Medication`, `MedicationModel`, `getMedicationByBarcode` (existing).
- Produces:
```dart
// lib/domain/entities/medication.dart — new field
/// The EAN barcode printed on the pack, when a scan saw one next to the
/// label code in [barcode]. Matching a scanned code checks both.
final String? ean;

// lib/presentation/screens/scanner/scan_result.dart — new field
const ScanResult(this.code, this.kind, {this.alternatives = const [], this.ean});
final String? ean;

// lib/presentation/screens/scanner/supplement_routing.dart
/// Add Medication with [code] in the barcode field and, when the same photo
/// carried one, [ean] remembered alongside it.
String addMedicationWithBarcode(String code, {String? ean});
```

- [ ] **Step 1: Write the failing migration test** — in `test/data/local/app_database_test.dart`:

```dart
    test('migration 14 adds the ean column and its index', () async {
      final db = await AppDatabase.instance.database;
      expect(await columnsOf(db, 'medications'), contains('ean'));
      final indexes = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'medications'",
      );
      expect(
        indexes.map((r) => r['name']),
        contains('idx_local_med_ean'),
      );
    });
```

and update the three hard-coded `[11, 12, 13]` expectations (`:83`, `:88`, `:140`, `:203`) to `[11, 12, 13, 14]`.

- [ ] **Step 2: Run to verify failure**

Run: `fvm flutter test test/data/local/app_database_test.dart`
Expected: FAIL — `ean` is not a column of `medications`.

- [ ] **Step 3: Add the migration** — append to `kMigrations` in `lib/data/local/migrations.dart` and set `const int kSchemaVersion = 14;`:

```dart
  // v14: the EAN barcode of the pack, next to the label code in `barcode`.
  // A scan that reads both remembers both, and a later scan of either finds
  // the medication.
  Migration(14, (db) async {
    await db.execute('ALTER TABLE medications ADD COLUMN ean TEXT');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_local_med_ean ON medications(ean)',
    );
  }),
```

Do **not** touch `createBaseSchema` — it creates the v10 shape and the ledger runs on top of it.

- [ ] **Step 4: Run to verify it passes**

Run: `fvm flutter test test/data/local/app_database_test.dart`
Expected: PASS.

- [ ] **Step 5: Carry the column through model, entity and datasource**

- `medication_model.dart`: add `final String? ean;` to the fields and constructor; `fromJson`/`fromLocalMap` read `json['ean'] as String?`; `toJson` writes `'ean': ean`; `toDomain`/`fromDomain` pass it through.
- `medication.dart`: add `final String? ean;` to the entity, its constructor and `copyWith` (nullable named parameter, like every other field).
- `medication_local_datasource.dart`: add `'ean': m.ean` to `_toRow` and `ean: row['ean'] as String?` to `_fromRow`; change the lookup (`:129-138`) to

```dart
  /// The medication whose label code or EAN is [barcode] (a pack carries
  /// both; a scan may produce either).
  Future<MedicationModel?> getByBarcode(String barcode) async {
    final db = await AppDatabase.instance.database;
    final rows = await db.query(
      'medications',
      where: '(barcode = ? OR ean = ?) AND sync_status != ?',
      whereArgs: [barcode, barcode, SyncStatus.pendingDelete],
      limit: 1,
    );
    return rows.isEmpty ? null : _fromRow(rows.first);
  }
```

(keep the existing method name and signature so `MedicationRepositoryImpl` is unchanged).

- [ ] **Step 6: Add the Supabase column** — `supabase/migrations/20260916000000_medication_ean.sql`:

```sql
-- Medora: the EAN barcode of the pack, alongside the label code in `barcode`.
-- The medication remote datasource uploads `MedicationModel.toJson()` as a
-- whole, so this column must exist before a client on schema v14 syncs.
alter table if exists public.medications
  add column if not exists ean text;

create index if not exists idx_med_ean on public.medications (ean);
```

and add a line to the README's Supabase section listing the third migration file.

- [ ] **Step 7: Carry the EAN from the scan to the new medication**

- `scan_result.dart`: add the `ean` field (and include it in `==`/`hashCode`/`toString`).
- `barcode_scanner_screen.dart`: add `String? get _bestEan => _candidates.where((c) => c.kind == CodeKind.ean).map((c) => c.code).firstOrNull;` and use it in `_onCandidateSelected`: return-only mode pops `ScanResult(candidate.code, candidate.kind, alternatives: candidate.alternatives, ean: candidate.kind == CodeKind.ean ? null : _bestEan)`; the AIC and supplement paths pass `ean: _bestEan` into `addMedicationWithBarcode`.
- `supplement_routing.dart`: `addMedicationWithBarcode(String code, {String? ean})` appends `&ean=<encoded>` when `ean != null && ean != code`.
- `app_router.dart`: the `addMedication` builder passes `initialEan: state.uri.queryParameters['ean']`.
- `add_medication_screen.dart`: new `final String? initialEan;` constructor parameter, stored in `String? _ean` (also set from `ScanResult.ean` in `_openScanner`, and from the loaded medication in `_loadExistingMedication`), and written in `_saveMedication` as `ean: _ean`.

- [ ] **Step 8: Test the round trip**

- `test/services/backup_service_test.dart`: a medication with `ean: '8057737141836'` survives export → restore (the raw table dump carries it) and `schemaVersion` in the envelope is 14.
- `test/presentation/screens/add_medication_scan_test.dart`: a `ScanResult('107018', CodeKind.supplement, ean: '8057737141836')` returned by the fake scanner route fills the barcode field with `107018`, and the saved medication has `ean == '8057737141836'`; a plain EAN scan (`CodeKind.ean`) leaves `ean` null and puts the code in `barcode`.
- A datasource test: two medications, one with `barcode: 'A1'`, one with `ean: '8057737141836'`; `getMedicationByBarcode('8057737141836')` finds the second.

- [ ] **Step 9: Verify the gates and commit**

Run: `fvm dart format --set-exit-if-changed . && fvm flutter analyze --fatal-infos && fvm flutter test`
Expected: clean; the sync tests still pass (the remote fake accepts the extra key).

```bash
git add -A
git commit -m "$(cat <<'EOF'
feat(medications): remember the pack's EAN and match either code

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01BAjdzp9JhksW2XbhM6CPBS
EOF
)"
```

---

### Task 8: Low-stock and expiry reminders

Reuse the existing `ReminderPort` seam and the `ReminderScheduler` diffing pattern, with a second scheduler that owns stock and expiry notifications only.

**Files:**
- Create: `lib/services/stock_expiry_reminders.dart`, `lib/services/stock_reminder_scheduler.dart`, `test/services/stock_expiry_reminders_test.dart`, `test/services/stock_reminder_scheduler_test.dart`
- Modify: `lib/services/reminder_port.dart`, `lib/services/reminder_service.dart`, `lib/presentation/providers/settings_providers.dart`, `lib/presentation/providers/providers.dart`, `lib/presentation/screens/settings/settings_screen.dart`, `test/helpers/fake_reminder_port.dart`, ARB ×3

**Interfaces:**
- Consumes: `ReminderPort`, `MedicationRepository.getAllMedications`, `Medication.isLowStock/daysUntilExpiry/expiredAt`, `Now`, `AppConstants.expiryWarningDays` (= 30).
- Produces:
```dart
// lib/services/stock_expiry_reminders.dart
enum StockAlertKind { expiry, lowStock }

@immutable
class StockAlert {
  const StockAlert({required this.id, required this.medicationId, required this.medicationName,
    required this.kind, required this.when, required this.days, required this.quantity});
  final int id;
  final String medicationId;
  final String medicationName;
  final StockAlertKind kind;
  final DateTime when;   // local, always 09:00
  final int days;        // days until expiry (expiry alerts), else 0
  final int quantity;    // stock left (low-stock alerts), else 0
}

/// Notification id for one medication and kind. Shares
/// `ReminderService.notificationBaseId`'s hash space but uses offsets 8 and
/// 9, which dose reminders (offsets 0-3) never take.
int stockAlertId(String medicationId, StockAlertKind kind);

/// The alerts due for [medications] at [now]: an expiry alert for every
/// unarchived medication whose expiry is within [expiryLeadDays] and not yet
/// past, a low-stock alert for every unarchived medication with
/// `quantity <= minimumStockLevel` and a quantity below 1 excluded only when
/// the medication is archived. Each alert fires at 09:00 local — on the day
/// the expiry window opens, or the next 09:00 after [now], whichever is
/// later. Earliest first, at most [limit].
List<StockAlert> stockAlertsFor(
  List<Medication> medications,
  DateTime now, {
  int expiryLeadDays = 30,
  int limit = 30,
});

// lib/services/reminder_port.dart — two methods added
Future<void> scheduleStockAlert(StockAlert alert);
Future<void> cancelStockAlert(int id);

// lib/services/stock_reminder_scheduler.dart
class StockReminderScheduler {
  StockReminderScheduler({required ReminderPort port, required MedicationRepository medications,
    required bool Function() stockRemindersEnabled, Now? now});
  Future<int> reconcile();
  void reset();
}
```

- [ ] **Step 1: Write the failing planning tests** — `test/services/stock_expiry_reminders_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/domain/entities/medication.dart';
import 'package:medora/services/stock_expiry_reminders.dart';

Medication _med({
  required String id,
  String name = 'Aspirin',
  int quantity = 10,
  int minimumStockLevel = 2,
  DateTime? expiryDate,
  bool isArchived = false,
}) => Medication(
  id: id,
  name: name,
  quantity: quantity,
  minimumStockLevel: minimumStockLevel,
  expiryDate: expiryDate,
  isArchived: isArchived,
  createdAt: DateTime(2026, 1, 1),
  updatedAt: DateTime(2026, 1, 1),
);

void main() {
  final now = DateTime(2026, 9, 16, 10); // after 09:00

  test('an expiry inside the window fires at the next 09:00', () {
    final alerts = stockAlertsFor([
      _med(id: 'a', expiryDate: DateTime(2026, 10, 1)),
    ], now);
    expect(alerts, hasLength(1));
    expect(alerts.single.kind, StockAlertKind.expiry);
    expect(alerts.single.days, 15);
    expect(alerts.single.when, DateTime(2026, 9, 17, 9));
  });

  test('an expiry beyond the window fires when the window opens', () {
    final alerts = stockAlertsFor([
      _med(id: 'a', expiryDate: DateTime(2026, 12, 1)),
    ], now);
    expect(alerts.single.when, DateTime(2026, 11, 1, 9));
    expect(alerts.single.days, 76);
  });

  test('an expired medication gets no alert', () {
    expect(
      stockAlertsFor([_med(id: 'a', expiryDate: DateTime(2026, 9, 15))], now),
      isEmpty,
    );
  });

  test('expiring today still alerts (good for the whole day)', () {
    final alerts = stockAlertsFor([
      _med(id: 'a', expiryDate: DateTime(2026, 9, 16)),
    ], now);
    expect(alerts.single.days, 0);
  });

  test('quantity at or below the minimum is low stock', () {
    final alerts = stockAlertsFor([
      _med(id: 'a', quantity: 2, minimumStockLevel: 2),
      _med(id: 'b', quantity: 3, minimumStockLevel: 2),
    ], now);
    expect(alerts.map((a) => a.medicationId), ['a']);
    expect(alerts.single.kind, StockAlertKind.lowStock);
    expect(alerts.single.quantity, 2);
    expect(alerts.single.when, DateTime(2026, 9, 17, 9));
  });

  test('before 09:00 the alert is today', () {
    final alerts = stockAlertsFor(
      [_med(id: 'a', quantity: 0)],
      DateTime(2026, 9, 16, 7),
    );
    expect(alerts.single.when, DateTime(2026, 9, 16, 9));
  });

  test('archived medications are ignored', () {
    expect(
      stockAlertsFor([_med(id: 'a', quantity: 0, isArchived: true)], now),
      isEmpty,
    );
  });

  test('one medication can raise both alerts, with different ids', () {
    final alerts = stockAlertsFor([
      _med(id: 'a', quantity: 0, expiryDate: DateTime(2026, 9, 20)),
    ], now);
    expect(alerts.map((a) => a.kind), containsAll(StockAlertKind.values));
    expect(alerts.map((a) => a.id).toSet(), hasLength(2));
  });

  test('alerts come earliest first and honour the limit', () {
    final alerts = stockAlertsFor([
      _med(id: 'a', expiryDate: DateTime(2026, 12, 1)),
      _med(id: 'b', quantity: 0),
    ], now, limit: 1);
    expect(alerts, hasLength(1));
    expect(alerts.single.medicationId, 'b'); // 17 Sep beats 1 Nov
  });

  test('ids are stable, per kind, and clear of dose reminder offsets', () {
    final first = stockAlertId('a', StockAlertKind.expiry);
    expect(first, stockAlertId('a', StockAlertKind.expiry));
    expect(first, isNot(stockAlertId('a', StockAlertKind.lowStock)));
    expect(first & 0xF, 8);
    expect(stockAlertId('a', StockAlertKind.lowStock) & 0xF, 9);
    expect(first, lessThan(0x7FFFFFFF));
  });
}
```

- [ ] **Step 2: Run to verify failure**

Run: `fvm flutter test test/services/stock_expiry_reminders_test.dart`
Expected: FAIL — library not found.

- [ ] **Step 3: Implement the planning**

```dart
/// Medora - which stock and expiry notifications should exist
///
/// Pure planning, mirroring `ReminderScheduler`'s split: this decides *what*
/// should be scheduled and when, `StockReminderScheduler` diffs it against
/// what is scheduled already. Both take an injected clock, so the tests
/// state exact times.
library;

import 'package:flutter/foundation.dart';
import 'package:medora/core/clock.dart';
import 'package:medora/core/constants.dart';
import 'package:medora/domain/entities/medication.dart';

enum StockAlertKind { expiry, lowStock }

/// The hour of day stock and expiry notifications fire.
const int stockAlertHour = 9;

@immutable
class StockAlert {
  const StockAlert({
    required this.id,
    required this.medicationId,
    required this.medicationName,
    required this.kind,
    required this.when,
    required this.days,
    required this.quantity,
  });

  final int id;
  final String medicationId;
  final String medicationName;
  final StockAlertKind kind;
  final DateTime when;
  final int days;
  final int quantity;
}

int stockAlertId(String medicationId, StockAlertKind kind) {
  var hash = 0x811C9DC5;
  for (final unit in medicationId.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }
  // Dose reminders take offsets 0-3 of the same 16-slot block.
  return (hash & 0x7FFFFFF0) | (kind == StockAlertKind.expiry ? 0x8 : 0x9);
}

DateTime _nextAlertTime(DateTime from, DateTime now) {
  final day = DateTime(from.year, from.month, from.day, stockAlertHour);
  final today = DateTime(now.year, now.month, now.day, stockAlertHour);
  final earliest = now.isBefore(today)
      ? today
      : today.add(const Duration(days: 1));
  return day.isAfter(earliest) ? day : earliest;
}

List<StockAlert> stockAlertsFor(
  List<Medication> medications,
  DateTime now, {
  int expiryLeadDays = AppConstants.expiryWarningDays,
  int limit = 30,
}) {
  final alerts = <StockAlert>[];
  for (final m in medications) {
    if (m.isArchived) continue;
    final expiry = m.expiryDate;
    if (expiry != null && !m.expiredAt(now)) {
      final days = calendarDaysBetween(now, expiry);
      if (days <= expiryLeadDays) {
        alerts.add(
          StockAlert(
            id: stockAlertId(m.id, StockAlertKind.expiry),
            medicationId: m.id,
            medicationName: m.name,
            kind: StockAlertKind.expiry,
            when: _nextAlertTime(
              expiry.subtract(Duration(days: expiryLeadDays)),
              now,
            ),
            days: days,
            quantity: m.quantity,
          ),
        );
      }
    }
    if (m.isLowStock) {
      alerts.add(
        StockAlert(
          id: stockAlertId(m.id, StockAlertKind.lowStock),
          medicationId: m.id,
          medicationName: m.name,
          kind: StockAlertKind.lowStock,
          when: _nextAlertTime(now, now),
          days: 0,
          quantity: m.quantity,
        ),
      );
    }
  }
  alerts.sort((a, b) => a.when.compareTo(b.when));
  return alerts.length > limit ? alerts.sublist(0, limit) : alerts;
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `fvm flutter test test/services/stock_expiry_reminders_test.dart`
Expected: PASS (10 tests).

- [ ] **Step 5: Extend the port and its fake**

Add the two methods to `ReminderPort`; implement them in `ReminderService` by reusing `_scheduleNotification` with the same channel, titles from new ARB strings via `resolveLocalizations()` and the English fallbacks (mirroring `reminderTitle`), and payload `medication:<id>` so a tap can route to the medication later. Add to `test/helpers/fake_reminder_port.dart`: `final stockAlerts = <StockAlert>[]; final cancelledStockAlerts = <int>[];` and the two overrides.

- [ ] **Step 6: Write the failing scheduler tests** — `test/services/stock_reminder_scheduler_test.dart`, modelled on `reminder_scheduler_test.dart` (in-memory DB, real repository, `FakePort`, fixed clock `DateTime(2026, 9, 16, 10)`):

- Disabled → `reconcile()` returns 0, cancels everything it had scheduled, schedules nothing.
- Enabled with one low-stock and one expiring medication → two alerts scheduled, with the ids from `stockAlertId`.
- A second `reconcile()` with no data change schedules **nothing more** (no duplicates) and cancels nothing.
- A medication that is restocked above its minimum → its low-stock id is cancelled on the next reconcile.
- A medication whose expiry moves → the alert is re-scheduled (cancel + schedule) because the time changed.
- `reset()` forgets the snapshot, so the next reconcile schedules everything again.

- [ ] **Step 7: Implement `StockReminderScheduler`**

Same shape as `ReminderScheduler`: hold `final Map<int, DateTime> _scheduled = {}`, load medications via the repository, plan with `stockAlertsFor`, cancel every id in `_scheduled` that is absent or whose time changed, schedule every new or moved alert, replace the snapshot, return the number scheduled. When `stockRemindersEnabled()` is false, cancel everything in the snapshot, clear it and return 0. Guard every port call with try/catch and `debugPrint`, like the dose scheduler.

- [ ] **Step 8: Add the setting and wire startup**

- `settings_providers.dart`: `const _kStockRemindersEnabled = 'stock_reminders_enabled';` plus `stockRemindersEnabledProvider` as a `NotifierProvider<StockRemindersEnabledNotifier, bool>` defaulting to **false** (opt-in: existing installs must not start emitting notifications after an update) with `Future<void> set(bool)` mirroring `RemindersEnabledNotifier`.
- `providers.dart`: `stockReminderSchedulerProvider` built like `reminderSchedulerProvider` (including the `localeProvider` listener that calls `reset()` + `reconcile()`), and the startup `reminders:` closure becomes

```dart
    reminders: () async {
      await ref.read(reminderSchedulerProvider).reconcile();
      await ref.read(stockReminderSchedulerProvider).reconcile();
    },
```

- `settings_screen.dart`: a second `SwitchListTile` under the existing reminders switch (`:140`), title `l10n.stockAndExpiryReminders`, subtitle `l10n.stockAndExpiryRemindersHint`, `value: ref.watch(stockRemindersEnabledProvider)`, `onChanged` sets the notifier and then `unawaited(ref.read(stockReminderSchedulerProvider).reconcile())`; shown only when `caps.hasLocalNotifications`.

- [ ] **Step 9: Add the ARB strings** and `fvm flutter gen-l10n`:

- `stockAndExpiryReminders`: "Stock and expiry reminders" / "Bestands- und Ablauferinnerungen" / "Promemoria scorte e scadenza"
- `stockAndExpiryRemindersHint`: "Notify when a medication runs low or expires within 30 days" / "Benachrichtigen, wenn ein Medikament zur Neige geht oder in 30 Tagen abläuft" / "Avvisa quando un farmaco sta finendo o scade entro 30 giorni"
- `notificationExpiryTitle`: "Expiring soon" / "Läuft bald ab" / "In scadenza"
- `notificationExpiryBody` with `{name}` and `{days}` (`"type": "int"`): "{name} expires in {days} days" / "{name} läuft in {days} Tagen ab" / "{name} scade tra {days} giorni"
- `notificationLowStockTitle`: "Running low" / "Fast aufgebraucht" / "Scorte in esaurimento"
- `notificationLowStockBody` with `{name}` and `{quantity}` (`"type": "int"`): "{name}: {quantity} left" / "{name}: noch {quantity}" / "{name}: ne restano {quantity}"

- [ ] **Step 10: Run the scheduler tests and the suite**

Run: `fvm flutter test test/services/stock_reminder_scheduler_test.dart && fvm flutter test`
Expected: PASS; the existing reminder tests stay green (the port gained methods, and `FakePort` implements them).

- [ ] **Step 11: Commit**

```bash
git add -A
git commit -m "$(cat <<'EOF'
feat(reminders): notify about low stock and medications expiring soon

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01BAjdzp9JhksW2XbhM6CPBS
EOF
)"
```

---

### Task 9: Put the camera and ML Kit behind ports, and widget-test the scanner

`BarcodeScannerScreen` cannot be pumped today because `camera`, `image_picker` and both ML Kit plugins are constructed inside it. Three small ports behind Riverpod fix that, and then the review rendering, the confirm dialog, return-only mode, the crop timeout and the AIC alternatives all become testable.

**Files:**
- Create: `lib/services/scanner_ports.dart`, `lib/services/mlkit_scanner_ports.dart`, `test/helpers/fake_scanner_ports.dart`, `test/presentation/screens/barcode_scanner_screen_test.dart`
- Modify: `lib/presentation/screens/scanner/barcode_scanner_screen.dart`, `lib/presentation/providers/providers.dart`

**Interfaces:**
- Consumes: `OcrLine`, `CodeCandidate`, `ocrLinesFrom`, `barcodeCandidatesFrom`, `scanBarcodeFormats` (existing).
- Produces:
```dart
// lib/services/scanner_ports.dart
/// An image handed to a recogniser: a file on disk, or raw RGBA bytes.
sealed class ScanImage {
  const ScanImage();
}
final class ScanImageFile extends ScanImage {
  const ScanImageFile(this.path);
  final String path;
}
final class ScanImageBitmap extends ScanImage {
  const ScanImageBitmap({required this.rgba, required this.width, required this.height});
  final Uint8List rgba;
  final int width;
  final int height;
}

/// Text recognition over [ScanImage]; throws are the caller's to log.
abstract class TextRecognitionPort {
  Future<List<OcrLine>> linesIn(ScanImage image);
  Future<void> close();
}

/// Barcode decoding over [ScanImage], already mapped to candidates.
abstract class BarcodeScanPort {
  Future<List<CodeCandidate>> candidatesIn(ScanImage image);
  Future<void> close();
}

/// The still camera the capture stage drives.
abstract class CameraPort {
  Future<bool> initialize();
  bool get isReady;
  Size? get previewSize;
  Widget buildPreview(BuildContext context);
  Future<String?> takePicture();
  Future<void> setTorch(bool on);
  Future<void> setFocusPoint(Offset normalized);
  Future<void> pausePreview();
  Future<void> resumePreview();
  Future<void> dispose();
}

/// Picking a photo from the gallery; null when the user cancels.
abstract class GalleryPort {
  Future<String?> pickImage();
}

// lib/presentation/providers/providers.dart
final textRecognitionPortProvider = Provider<TextRecognitionPort>(...);
final barcodeScanPortProvider = Provider<BarcodeScanPort>(...);
final cameraPortProvider = Provider<CameraPort>(...);
final galleryPortProvider = Provider<GalleryPort>(...);
```

- [ ] **Step 1: Define the ports and their ML Kit implementations**

`lib/services/scanner_ports.dart` holds the abstractions above (no plugin imports, so tests can implement them). `lib/services/mlkit_scanner_ports.dart` holds `MlKitTextRecognitionPort` (wraps `TextRecognizer`, maps `ScanImageFile`/`ScanImageBitmap` to `InputImage.fromFilePath`/`InputImage.fromBitmap`, returns `ocrLinesFrom(...)`), `MlKitBarcodeScanPort` (wraps `BarcodeScanner(formats: scanBarcodeFormats)`, returns `barcodeCandidatesFrom(...)`, and keeps the existing `describeBarcodes` logging), `CameraControllerPort` (wraps `CameraController` with the current `availableCameras`/`ResolutionPreset.veryHigh`/`FocusMode.auto` behaviour and `CameraPreview` inside the existing `FittedBox` sizing) and `ImagePickerGalleryPort`.

- [ ] **Step 2: Register them as providers**

In `providers.dart`, four `Provider`s returning the ML Kit/camera implementations, each with `ref.onDispose(port.close)` (or `dispose`) so a disposed container closes the detectors — exactly what the screen does today in `dispose`.

- [ ] **Step 3: Rewrite the screen against the ports**

Replace `_textRecognizer`, `_barcodeScanner`, `_cameraController` and the direct `ImagePicker()` call with `ref.read(...)` of the four ports. `_recognizeText`/`_scanBarcodes` keep their signatures but take a `ScanImage`. The screen no longer closes the detectors (the providers do); it still disposes the camera port and deletes its photo. Behaviour is otherwise unchanged — this step must keep `test/presentation/screens/barcode_scanner_focus_test.dart` green (`focusPointFor` and `previewChildSize` stay static on the widget).

- [ ] **Step 4: Write the fakes** — `test/helpers/fake_scanner_ports.dart`:

```dart
class FakeTextRecognition implements TextRecognitionPort {
  FakeTextRecognition(this.linesByPass);
  /// Lines returned per call, in order; a null entry throws.
  final List<List<OcrLine>?> linesByPass;
  final calls = <ScanImage>[];
  var _index = 0;

  @override
  Future<List<OcrLine>> linesIn(ScanImage image) async {
    calls.add(image);
    final lines = linesByPass[_index.clamp(0, linesByPass.length - 1)];
    _index++;
    if (lines == null) throw StateError('text recognition failed');
    return lines;
  }

  @override
  Future<void> close() async {}
}
```

plus `FakeBarcodeScan` (same shape), `FakeCamera` (`isReady = true`, `previewSize = Size(1920, 1080)`, `buildPreview` returns a `ColoredBox`, `takePicture` returns a path written by the test) and `FakeGallery` (returns a fixed path or null). A helper `List<Override> scannerOverrides({...})` builds the four overrides.

- [ ] **Step 5: Write the screen tests** — `test/presentation/screens/barcode_scanner_screen_test.dart`. Each test writes a small real PNG into a temp dir (so `readImageSize` works), pumps `BarcodeScannerScreen` through `pumpMedoraApp` with the fakes plus `supplementRegistryServiceProvider`/`medicationRepositoryProvider` overrides, taps the shutter and settles:

1. **Review rendering** — OCR lines `COD MINSAN: 107018` and `8 057737 141836` → the review shows rows `107018` under `scanSupplementCodes` and `8057737141836` under `scanBarcodes`, numbered 1 and 2, with markers `scanMarker1`/`scanMarker2`.
2. **The alternative-code confirm dialog** — OCR line `COD MINSAN: T07018` with an **empty** register (`hasData()` false, so no review-time resolution) and a register lookup that matches only `107018` → tapping the row shows the confirm dialog naming both codes; confirming pushes `/medications/add?barcode=107018`; declining shows the `supplementNotFound` snackbar and stays on the review.
3. **Resolved chip, no dialog** — the same OCR line with a **cached** register that matches `107018` → the review row already reads `107018` and tapping it pushes straight to Add Medication with no dialog (this is Task 1's behaviour, tested at the screen level).
4. **Return-only mode** — `BarcodeScannerScreen(returnBarcodeOnly: true)` pops a `ScanResult` with the tapped code, its kind, its alternatives and the photo's EAN (Task 7).
5. **Crop timeout** — a fake text recogniser whose first pass returns lines that trigger `needsRegionPass` and an `image_size` crop that never completes (write the PNG to a path the test deletes, so `writeImageCrop` throws) → the review still renders the first pass's candidates and no exception escapes.
6. **AIC alternatives** — OCR line `AIC n. T34567891` with an AIFA fake that matches only `134567891` → the confirm dialog appears with the AIFA product name and confirming pushes Add Medication with `134567891`.
7. **EAN in the cabinet** — a seeded medication with that EAN → tapping the EAN row pushes `/medications/<id>` and shows `scanMedicationInCabinet` (this covers `_openEan`, which has no test today).

- [ ] **Step 6: Run them**

Run: `fvm flutter test test/presentation/screens/barcode_scanner_screen_test.dart`
Expected: PASS (7 tests).

- [ ] **Step 7: Verify the gates and commit**

Run: `fvm dart format --set-exit-if-changed . && fvm flutter analyze --fatal-infos && fvm flutter test`

```bash
git add -A
git commit -m "$(cat <<'EOF'
test(scanner): put camera and ML Kit behind ports and widget-test the screen

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01BAjdzp9JhksW2XbhM6CPBS
EOF
)"
```

---

### Task 10: Split the four largest screens — no behaviour change

Pure moves. Nothing is renamed except private classes that must lose their underscore to cross a file boundary, and no golden may move a pixel.

**Files:**
- Create: `lib/presentation/screens/settings/widgets/{settings_group.dart,aifa_database_tile.dart,supplement_register_tile.dart,settings_data_section.dart,settings_cloud_section.dart,settings_dialogs.dart}`
- Create: `lib/presentation/screens/scanner/{capture_view.dart,recognizing_view.dart}`
- Create: `lib/presentation/screens/medication/widgets/{medication_stock_section.dart,medication_details_section.dart,medication_photo_section.dart}`
- Create: `lib/presentation/screens/dose/widgets/{dose_card.dart,dose_summary_header.dart,date_strip.dart,time_groups.dart}`
- Modify: the four screens; imports in their tests only if a moved symbol is referenced there.

**Interfaces:**
- Consumes: everything as it stands after Task 9.
- Produces: the same widget tree from public classes — `SettingsGroup`, `SectionTitle`, `ColorDot`, `LanguageOption`, `AifaDatabaseTile`, `SupplementRegisterTile`, `CaptureView`, `RecognizingView`, `MedicationStockSection`, `MedicationDetailsSection`, `MedicationPhotoSection`, `DoseCard`, `DoseSummaryHeader`, `StatChip`, `DateStrip`, `DayChip`, `GroupHeader`, `TimeGroup`, `timeOfDayGroups`.

- [ ] **Step 1: Record the baseline**

Run: `fvm flutter test && git rev-parse HEAD`
Expected: green. Note the commit — every step below must keep the same test count and the same golden bytes.

- [ ] **Step 2: Split `settings_screen.dart` (1587 lines)**

Move, verbatim: `_SettingsGroup` (`:1572-1587`), `_SectionTitle` (`:1551-1570`), `_ColorDot` (`:1295-1311`), `_LanguageOption` (`:1545-1549`) → `widgets/settings_group.dart`; `_AifaDatabaseTile` (`:1313-1423`) → `widgets/aifa_database_tile.dart`; `_SupplementRegisterTile` (`:1427-1543`) → `widgets/supplement_register_tile.dart`; the dialog methods `_showLanguagePicker` (`:880`), `_showColorSchemePicker` (`:1176`), `_showForceSyncDialog` (`:740`), `_showDeleteAllDialog` (`:777`), `_showSyncFailures` (`:1077`) → top-level `Future<void> show…(BuildContext context, WidgetRef ref)` functions in `widgets/settings_dialogs.dart`; the Data group body (`:233`) → `SettingsDataSection`, the cloud group (`:274`) → `SettingsCloudSection`. Drop the leading underscore on each moved class and update every reference.

- [ ] **Step 3: Run the settings tests**

Run: `fvm flutter test test/presentation/screens/settings_screen_test.dart test/presentation/screens/settings_restore_test.dart test/presentation/screens/settings_sync_failures_test.dart test/presentation/screens/supplement_register_tile_test.dart`
Expected: PASS, unchanged counts.

- [ ] **Step 4: Commit the settings split**

```bash
git add -A
git commit -m "$(cat <<'EOF'
refactor(settings): split the settings screen into widget files

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01BAjdzp9JhksW2XbhM6CPBS
EOF
)"
```

- [ ] **Step 5: Split `barcode_scanner_screen.dart`**

Move `_buildCapture` into `CaptureView` (`capture_view.dart`) taking `{required CameraPort camera, required bool busy, required bool canShoot, required VoidCallback onShutter, required VoidCallback onGallery, required VoidCallback onManualEntry, required void Function(Offset, Size, Orientation) onFocus, required bool searching}`, `_buildRecognizing` into `RecognizingView` (`recognizing_view.dart`) taking `{required ImageProvider? photo}`, and `_ScrimLabel` alongside `CaptureView`. The state machine, the passes and the selection handlers stay in the screen.

- [ ] **Step 6: Run the scanner tests**

Run: `fvm flutter test test/presentation/screens/barcode_scanner_screen_test.dart test/presentation/screens/barcode_scanner_focus_test.dart test/presentation/screens/scan_review_view_test.dart`
Expected: PASS, unchanged counts. Commit as `refactor(scanner): split capture and recognizing into widget files`.

- [ ] **Step 7: Split `add_medication_screen.dart`**

Move `_buildPhotoSection` (`:806`) + `_photoPlaceholder` (`:867`) → `MedicationPhotoSection`, the stock fields → `MedicationStockSection`, the details fields → `MedicationDetailsSection`, each taking the controllers and callbacks it needs (pass `TextEditingController`s and `ValueChanged`s; do not move state).

- [ ] **Step 8: Run the medication tests and the golden**

Run: `fvm flutter test test/presentation/screens/add_medication_screen_test.dart test/presentation/screens/add_medication_scan_test.dart test/presentation/screens/add_medication_supplement_test.dart test/goldens/add_medication_golden_test.dart`
Expected: PASS; `git status` shows **no** change to `test/goldens/add_medication_*.png`. Commit as `refactor(medications): split the add medication form into sections`.

- [ ] **Step 9: Split `dose_schedule_screen.dart`**

Move `_DoseCard` (`:676-853`) → `dose_card.dart`, `_DoseSummaryHeader` (`:495`) + `_StatChip` (`:587`) → `dose_summary_header.dart`, `_DateStrip` (`:380`) + `_DayChip` (`:413`) → `date_strip.dart`, `_TimeGroup` (`:302`) + `_timeOfDayGroups` (`:313`) + `_GroupHeader` (`:344`) → `time_groups.dart`.

- [ ] **Step 10: Run the dose tests and both goldens**

Run: `fvm flutter test test/presentation/screens/dose_schedule_screen_test.dart test/goldens/doses_golden_test.dart test/goldens/doses_take_all_golden_test.dart`
Expected: PASS; `git status` shows **no** change to any `test/goldens/doses*.png`. Commit as `refactor(doses): split the dose schedule screen into widget files`.

- [ ] **Step 11: Confirm the whole suite and the goldens**

Run: `fvm flutter test && git status --porcelain test/goldens`
Expected: same pass count as Step 1; `git status` prints nothing for `test/goldens`.

---

### Task 11: A repeatable on-device scanner check

A documented script that drives one attached phone through Home → scanner → gallery → review → select, capturing screenshots and `[scan]` log lines. Never run in CI.

**Files:**
- Create: `tools/phone_check/run.sh`, `tools/phone_check/README.md`, `tools/phone_check/make_test_image.sh`

**Interfaces:**
- Consumes: `adb`, an installed debug build with `--dart-define=SCAN_DEBUG=true`, ImageMagick (`magick`) for the test image.
- Produces: `tools/phone_check/out/<UTC timestamp>/{01-home.png,02-scanner.png,03-review.png,04-selected.png,scan.log,run.log}`.

- [ ] **Step 1: Write `make_test_image.sh`**

Renders a supplement label PNG with `magick`: the lines `Integratore alimentare`, `COD MINSAN: 107018`, `Lotto 4R5T21`, `SCAD. 12/2027` and an EAN-13 `8057737141836` drawn as bars plus digits, at 1600×900 on white. Writes `tools/phone_check/out/test-label.png`. Exits non-zero when `magick` is missing.

- [ ] **Step 2: Write `run.sh`** — the serial is mandatory and an emulator is refused:

```bash
#!/usr/bin/env bash
# tools/phone_check/run.sh <adb-serial>
# Drives one attached phone through the scanner flow and captures
# screenshots plus [scan] log lines. See README.md. Never run in CI.
set -euo pipefail
SERIAL="${1:-}"
PKG="${MEDORA_PACKAGE:-com.example.medora}"
if [ -z "$SERIAL" ]; then
  echo "usage: tools/phone_check/run.sh <adb-serial>   (adb devices -l)" >&2
  exit 2
fi
case "$SERIAL" in
  emulator-*) echo "refusing to run against an emulator ($SERIAL): ML Kit and the camera need a real device" >&2; exit 1 ;;
esac
adb devices | awk '{print $1}' | grep -qx "$SERIAL" || {
  echo "device $SERIAL is not attached" >&2; exit 1; }
```

then: `OUT="$(cd "$(dirname "$0")" && pwd)/out/$(date -u +%Y%m%dT%H%M%SZ)"; mkdir -p "$OUT"`; generate the test image if absent; `adb -s "$SERIAL" push` it to `/sdcard/Pictures/medora-test-label.png` and trigger a media scan (`am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d file:///sdcard/Pictures/...`); clear and start capturing `adb -s "$SERIAL" logcat -v time | grep --line-buffered '\[scan\]' > "$OUT/scan.log" &`; `adb -s "$SERIAL" shell am force-stop "$PKG"` then `monkey -p "$PKG" -c android.intent.category.LAUNCHER 1`; screenshot helper `shot() { adb -s "$SERIAL" exec-out screencap -p > "$OUT/$1"; }`; taps driven by percentages of `wm size` (`tap_pct 50 92` etc.) with the defaults documented and overridable via `MEDORA_TAP_*` env vars; a `sleep 2` between steps; finally kill the logcat job, print the output directory and `grep -c '\[scan\] candidate' "$OUT/scan.log"`.

The script echoes each step into `run.log` and exits non-zero if any `adb` call fails (`set -e`) or if `scan.log` has no `[scan] candidate:` line at the end.

- [ ] **Step 3: Write the README**

`tools/phone_check/README.md` covers: what the check proves; the prerequisites (`adb`, ImageMagick, a real device with USB debugging, an app built with `fvm flutter build apk --debug --dart-define=SCAN_DEBUG=true` and installed); `adb devices -l` to find the serial and the warning that the serial is **mandatory** — the script refuses `emulator-*` because ML Kit's models and the camera behave differently there; the exact invocation `tools/phone_check/run.sh RZCXA1ZEXJE`; what lands in the output directory; how to override the tap coordinates for a different screen geometry; how to read `scan.log` (`[scan] line:`, `[scan] barcode:`, `[scan] candidate:`); and — in bold — that this script is **not** part of CI and must never be added to a workflow, because it needs a physical device.

- [ ] **Step 4: Check the script without a device**

Run: `bash -n tools/phone_check/run.sh tools/phone_check/make_test_image.sh && tools/phone_check/run.sh 2>&1 | head -2 && tools/phone_check/run.sh emulator-5554 2>&1 | head -2`
Expected: no syntax errors; the first prints the usage line and exits 2; the second refuses the emulator and exits 1.

- [ ] **Step 5: Add the output directory to `.gitignore` and commit**

Add `tools/phone_check/out/` to `.gitignore`.

```bash
git add -A
git commit -m "$(cat <<'EOF'
chore(tools): repeatable on-device scanner check over adb

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01BAjdzp9JhksW2XbhM6CPBS
EOF
)"
```

---

### Task 12: Whole-suite gates, on-device verification, release (controller-run)

- [ ] **Step 1: Documentation sweep**

Update `docs/architecture.md`: the Scanner section gains the stripe pass, the area rescan, the register resolution and the ports; a new sentence in "Reminders, doses and expiry" for the stock/expiry scheduler and its opt-in setting; the local-data section's `kSchemaVersion` **13 → 14** with the `ean` column; the testing section gains the scanner widget tests. Update the README feature bullets (EAN memory, stock/expiry reminders, register name search) and its Supabase migration list (third file).

- [ ] **Step 2: Full gates**

```bash
fvm dart format --set-exit-if-changed .
fvm flutter analyze --fatal-infos
fvm flutter gen-l10n && git diff --exit-code -- lib/l10n/generated
cat untranslated.txt   # must print {}
fvm flutter test
git status --porcelain test/goldens   # must print nothing
```

Expected: every command clean; the test count is at least the 609 baseline plus the roughly 60 tests these tasks add, 0 failures, 2 skipped.

- [ ] **Step 3: Build the artifact**

Run: `fvm flutter build apk --release --split-per-abi --dart-define-from-file=dart_defines.json --dart-define=SCAN_DEBUG=true`
Expected: `app-arm64-v8a-release.apk` builds; check the signer is not `CN=Android Debug`.

- [ ] **Step 4: On-device checklist** (`adb -s RZCXA1ZEXJE`, the real phone, never an emulator)

- [ ] `tools/phone_check/run.sh RZCXA1ZEXJE` completes and `scan.log` shows `[scan] candidate: supplement 107018` and `[scan] candidate: ean 8057737141836`.
- [ ] Photograph the real ZINCO-C pack from ~40 cm: the supplement chip reads **107018** directly (register cached), with no confirmation dialog.
- [ ] Photograph it so the EAN digits are readable but the bars are at an angle: the stripe pass decodes the EAN (`[scan] barcodes (stripe …)` in the log).
- [ ] On the review, tap **Select area**, drag a box around the MINSAN code, tap **Scan selection**: a new or corrected chip appears; the selection clears.
- [ ] Scan a pack whose EAN is already in the cabinet → the medication detail opens with the "in your cabinet" snackbar.
- [ ] Create a medication from a scan carrying both a MINSAN code and an EAN; re-scan the EAN afterwards → the same medication opens.
- [ ] Settings → Data: the register tile shows its "as of" date; with the device clock moved 60 days forward the staleness warning and **Update now** appear in the tile and on the scan review.
- [ ] Settings → Reminders: enable stock and expiry reminders; with a medication at or below its minimum and one expiring in 20 days, both notifications arrive at 09:00 (or set the clock to 08:59 to check).
- [ ] Update sheet: "What's new" shows the grouped changelog as plain text, collapsed, expanding on **Show more**.
- [ ] Kill the app during a scan, reopen it, and confirm no `scan_*` folder remains: `adb -s RZCXA1ZEXJE shell run-as <package> ls cache`.

- [ ] **Step 5: Install the timer (controller, after merge)**

```bash
mkdir -p ~/.config/systemd/user
ln -sf ~/repo/medora/tools/systemd/medora-supplements.service ~/.config/systemd/user/
ln -sf ~/repo/medora/tools/systemd/medora-supplements.timer   ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now medora-supplements.timer
systemctl --user list-timers medora-supplements.timer
```

- [ ] **Step 6: Merge and release**

```bash
git checkout main && git merge --no-ff improvements
tools/release.sh 0.2.4+16
gh run list --workflow Release
```

Confirm the release page carries the six assets, `SHA256SUMS.txt` and the grouped changelog body, and that the in-app update check on the phone offers `0.2.4`.

## Exit criteria

- [ ] A misread supplement code (`IT07O18`, `30 compresse 450`, re-read junk) no longer produces a wrong chip, and every pre-existing case in `test/services/code_candidates_test.dart` is still green.
- [ ] A cached register corrects the chip before the review renders; the confirmation dialog appears only when the register was not available then.
- [ ] A barcode that only OCR saw is decoded from its bars, in any of four rotations; a user can select an area and rescan it; orphaned crop folders are swept at startup.
- [ ] The register refresh script and its user units are committed and documented (installed by the controller, not by the plan), and the app warns at 45 days.
- [ ] "What's new" is readable, collapsible and capped, and release bodies carry a grouped changelog.
- [ ] Add Medication can search the register by name; a scan remembers the pack's EAN and finds the medication by either code.
- [ ] Low-stock and expiry reminders are scheduled from an injected clock, with no duplicates, behind an opt-in setting.
- [ ] The scanner screen has widget tests behind the camera/ML Kit ports, including `_openEan`, which had none.
- [ ] The four screens are split with no behaviour change and the 6 goldens byte-identical.
- [ ] `tools/phone_check/run.sh <serial>` is documented, refuses an emulator, and is referenced by no workflow.
- [ ] All gates green, on-device checklist done, `v0.2.4+16` released.
