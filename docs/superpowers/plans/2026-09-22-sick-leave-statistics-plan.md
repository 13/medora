# Sick-leave statistics and the year view — Implementation Plan

**Date:** 2026-09-22. **Branch:** `main`, from v0.4.3+22.

Two asks, one data source:

1. **How many days off work, and so on** — the numbers a person wants at the
   end of a year: total days, how many separate episodes, the longest one,
   the average, which months were bad, which illnesses cost the most, and
   whether it was worse than last year.
2. **A year view** — twelve mini-months with the sick days coloured in, the
   shape `~/repo/dontdrink` uses (`lib/ui/yearly/widgets/year_months_grid.dart`:
   a 3×4 grid of `_MiniMonth`, each a Monday-first 7-column grid of `_MiniCell`
   sized from `LayoutBuilder`, with the day number inside a rounded square).

## What the data actually is

Sick leave lives on `Treatment`: `sickLeaveFrom` and `sickLeaveTo`, both
date-only, with `sickLeaveTo == null` meaning the leave is still running
(`treatment.dart:64-107`). There is no per-day record anywhere — a range is
all there is, so every day-level answer has to be derived.

**Counting is calendar days**, both ends inclusive, as `sickLeaveDaysAt`
already does: a note "from Monday to Friday" is five days, and that is what
an Italian sick note and INPS count. Weekends are not subtracted.

### The trap this plan exists to avoid

Two treatments can carry **overlapping** leave — a flu and a back injury in
the same week. Summing `sickLeaveDaysAt` across treatments double-counts
those days and reports more days off than the year contains. Every number
below therefore comes from one **deduplicated set of dates**, not from a sum
of per-treatment lengths.

A second, quieter trap: an **open** leave counts to today, so the same
treatment yields a different number tomorrow. Every function takes `now`
rather than reading the clock, and the screen reads `nowProvider`, like the
rest of the app.

Third: a leave can **span the year boundary** (20 December to 8 January).
Days are attributed to the year they fall in, not to the year the leave
started, so that leave contributes to both.

## Steps

- [ ] **Step 1 — the pure layer, tests first**
  (`test/domain/sick_leave_stats_test.dart`, then
  `lib/domain/sick_leave_stats.dart`)

  `sickDaysIn(int year, List<Treatment>, {required DateTime now})` →
  `Set<DateTime>` of date-only days, and `SickLeaveStats.of(...)` over it.
  Cases to pin before writing it:
  - two overlapping leaves count each shared day **once**
  - back-to-back leaves (one ends the day the next starts) count that day once
  - an open leave counts to `now` and no further, and nothing when it starts
    in the future
  - a leave crossing New Year contributes to both years, split at the boundary
  - an inverted range (`to` before `from`, reachable from a synced or restored
    row the form never validated — `sickLeaveDaysAt` already returns null for
    it) contributes nothing rather than throwing
  - a treatment with no leave contributes nothing
  - `episodes` counts leaves, not days, and merges nothing: two overlapping
    leaves are two episodes even though they share days
  - `longest` and `average` are over episodes, in calendar days
  - `byMonth` sums to `total`, and `byTreatment` sums to **at least** `total`
    (overlap means a day appears under two names — the list is "days
    attributable to", and the plan says so in the UI rather than pretending)

- [ ] **Step 2 — the year grid**
  (`test/presentation/widgets/year_months_grid_test.dart`, then
  `lib/presentation/widgets/year_months_grid.dart`)

  Ported from dontdrink, not copied wholesale: same 3×4 shape,
  `LayoutBuilder` cell sizing and Monday-first rotation of
  `DateFormat.EEEE(locale).dateSymbols.NARROWWEEKDAYS`, but coloured from the
  sick-day set instead of a `DayEntry.level`, and using
  `context.medora`/`context.colors` rather than that project's palette.
  Tests: a known sick day is filled and a well day is not; today has its
  border; a future day is dimmed; the leading blanks land on the right
  weekday for a month starting on a Sunday; it survives 1.6x text scale at
  360 dp without overflow (the sweep every other screen here answers to).

- [ ] **Step 3 — the screen** (`lib/presentation/screens/stats/stats_screen.dart`,
  route `/stats`)

  Year stepper at the top (bounded by the first year with any leave and the
  current year), the headline total, then episodes / longest / average, the
  per-month row, the per-illness list, and last year's total beside this
  year's with the direction of travel. Empty state when the year holds no
  leave at all — which is the common case for a new user and must not read
  as an error.

- [ ] **Step 4 — getting there.** An action on the Treatments tab app bar,
  and a Home card when the current year has any sick leave. No new bottom-bar
  tab: the four-tab layout was just settled across three locales at 1.6x and
  a fifth would reopen it.

- [ ] **Step 5 — strings.** `app_en/de/it.arb` for every label above,
  including the plural forms (`days`, `episodes`), then `gen-l10n`. German
  and Italian are the long ones — the stat tiles are the place layout breaks.

- [ ] **Step 6 — gates.** `analyze --fatal-infos`, `dart format`, the full
  suite in UTC and `TZ=Europe/Rome` (this feature is all calendar arithmetic,
  so the zone pass is the one that matters), and through
  `MEDORA_FAKE_TRANSPORT=http`. Goldens only if the Home card changes an
  existing one.

## Deliberately not in this plan

- **Working days.** "Days off work" is counted as calendar days; a
  working-day number needs a working week, public holidays, shift patterns
  and part-time, none of which the app knows.
- **Sharing the year as an image.** dontdrink has it
  (`ShareImageButton` over a `RepaintBoundary`); Medora's export already
  shares an episode as text. Worth doing, worth doing separately.
- **A per-day record.** Everything here derives from ranges. Per-day notes
  ("worse today") would be a schema change and a sync surface.

## What is true when this is done

Opening Statistics for a year answers, without arithmetic: how many days I
was signed off, in how many episodes, which was the longest, which months
they fell in, what made me ill, and whether it was worse than last year —
and the grid shows the shape of it, with overlapping illnesses counted as
the days they actually were.
