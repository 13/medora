# Sync v2 and the settings gear — design

**Date:** 2026-09-16. **Status:** proposed. **Branch:** `sync-v2-settings`, based on release v0.3.0+18 (`35bb1f5`).
Open questions for the user are in §14; everything else is decided.
**Revised 2026-09-17:** edit times are kept per column (`field_edited_at`, §4.4), not only per row; §4.1, §4.4, §4.5, §5, §6, §7, §9.2 and §12 follow.
**Revised 2026-09-17 (engine review):** the server never holds a live row under a deleted parent, and the app's own tombstones are told apart from a person's everywhere (§4.6); a column changed back to its old value counts as changed (§4.5); §5, §6, §7.2–§7.6, §9.2 and §12 follow.
**Revised 2026-09-17 (cycle review):** a child written while its parent is deleted ends deleted (§5 notes); a person's undo survives a later drop of the same dose (§4.6); rows that change by the hundred are read and written by the hundred (§4.6, §4.7, §7.3); the same value set again later is the latest edit (§4.4, §4.5); "delete all data" reaches every device (§7.9, a wipe marker in §5).

## 1. What the user asked for

> "plan fix whats still open and then add on every view on top right settings gear, do best practice."

This covers two pieces of work:

1. **Close what is still open** after v0.3.0. Most of it is sync behaviour that the last three review rounds deferred because it "needs a database change". There are also a few small visible defects.
2. **A settings gear at the top right.** The controller decided the scope: one shared widget in the app-bar actions of the four top-level tabs (Dashboard, Medikamente, Behandlungen, Dosen). It does not go on forms, detail screens, sheets, dialogs or the scanner, because leaving a half-filled form for Settings would lose the input, and those screens have their own actions. If a tab already has actions, the gear goes last.

The sync fixes ship as **one new Supabase migration**, `supabase/migrations/20260918000000_sync_v2.sql`, plus **one local schema migration** (v16).

## 2. What is still open

Sources: `.superpowers/sdd/progress.md`, `sick-branch-review.md`, `sync-hardening-2-report.md`, `sync-hardening-review.md`, `sync-followup-review.md`, `sync-paging-report.md`, `sync-cursor-reset-report.md` and `sick-prerelease-report.md`.

### 2.1 Sync items that need a server change

| # | Open item | Where it was recorded | What happens today | Why a client-only fix fails |
|---|---|---|---|---|
| S-1 | **Doses stored at a time-zone-shifted time keep it.** Rows an older build generated at 10:00 instead of 08:00 keep the slot's id at the wrong time, on every device. | hardening-2 concern 2; cursor-reset "Shifted dose rows" | Left alone on purpose. | The fix is a pushed time change. `update_updated_at` stamps every update with `now()`, so that change would beat a take made on another device and not yet pushed, and the take would be lost. |
| S-2 | **Stock is an absolute value under last-writer-wins.** Two devices changing stock at about the same time (online from a stale copy, or both offline) lose one change. | follow-up review I-1; ledger line 34 | Whole-row upsert of `quantity`. | A counter needs deltas. Deltas without an idempotent server step double-count on a retry after a lost answer (the reason the delta push was removed in `3df4516`). |
| S-3 | **A lost upsert answer can lose an edit.** The device sees its own write as a foreign, newer one: the stale check skips the next edit and the pull overwrites it. | follow-up review I-3; ledger line 27 | Open. | The device needs to recognise "this server copy is my own unconfirmed write". A version base alone cannot tell (follow-up review I-3, points 1–3). This needs a column. |
| S-4 | **I-1: a whole row is last-writer-wins.** End on device A and a sick-leave edit on device B: one of the two is lost. In S1b, End itself is undone: the episode is active again and reminders come back. | sick-branch review I-1 (S1a, S1b) | Documented in the v0.3.0 release notes as a known limitation. | Field-level merging needs a base and a conditional write, so that a merge never overwrites a newer server copy blind. |
| S-5 | **Generated doses stamped 1970 are invisible to delta pulls.** | hardening review C-A; hardening-2 §1 | Worked around: a pulled prescription regenerates the doses locally (`applyPulled`, `ensureScheduled`). | The pull cursor is `updated_at`, and a 1970 row sits before every cursor. |
| S-6 | **Doses dropped by a schedule change stay pending on the server.** A full pull brings them back as hidden rows. | hardening-2 OPEN; cursor-reset concern 4 | Regeneration hard-deletes them locally and never pushes a delete. | An unconditional tombstone would also delete a dose that another device took meanwhile. The delete must apply only while the server row is still pending. |
| S-7 | **The server keeps "pending" for doses the app marked missed on its own.** | hardening review Q2; hardening-2 concern 6 | Automatic "missed" is local-only. | Pushing it gets the `now()` stamp and beats a real take made elsewhere (the reason for the hardening deviation). |

These rows share the same root causes and are fixed together:

| Related item | Source | Fixed by |
|---|---|---|
| PR5: an explicit status wins by arrival order, not by the time of the action | hardening review I-B | §4.4 edit times |
| A whole-row upsert overwrites column-level updates (deactivate vs a dosage edit, status vs a note) | follow-up review m-2 | §4.5 changed-field patch and merge |
| I-C: a created row costs a second request just to get a server stamp | hardening-2 §4 | §4.2 cursor; §5 insert stamp |
| A timed-out insert that lands late brings back an undone intake | hardening review m-3 | §4.6 tombstone for an unconfirmed create |
| A refused prescription that became `pending_update` does not hold back its doses | sick-branch review m-3 | §7.3 |
| A cloud restore pushes generated (weak) dose rows as strong ones | sick-branch review m-2 | §4.4 and §6: restored rows keep their edit time |
| The backup merge compares mixed timestamp formats | sick-branch review m-13 | §6 |
| `updateTreatment` over a local pending delete undoes the delete | sync follow-up review m-6 | §6 |
| A force pull does not record the repair | cursor-reset concern 6 | §7.7 |
| The docs say "the edit that reaches the server last wins" | sick-branch review m-1 | Task 9 rewrites the sync docs |

### 2.2 Other open items (not sync)

**Included:** these are visible to the user and have a clear fix.

| Item | Source | Fix |
|---|---|---|
| Switching an as-needed prescription back to a schedule pre-fills "0" days, which the validator rejects | sick-branch review m-5 | Pre-fill 7 when the stored duration is 0 (§11). |
| "Laufend" / "In corso" is capitalised in the middle of a line in the shared text | sick-branch review m-6 (second part) | A lower-case `ongoingInline` key used by the episode text (§11). |
| A failed End shows nothing | sick task 5 review; ledger line 30 | A snackbar with a new `endTreatmentFailed` string (§11). |
| The Low Stock and Active Treatments cards drop rows after the third without saying so | dash branch review I2 | The "N more" row the expiry card already has (§11). |
| The dashboard gear has no tooltip, so a screen reader announces only "button" | found while designing §10 | The shared gear has one. |

**Deferred** (one line each):

- m-4: long one-word German names break mid-word at 360 dp and 1.6×. There is no clean fix: an ellipsis hides the name and scaling shrinks it to about 12 dp. It needs a design decision.
- m-8: privacy of the shared episode text (an employer variant). This is a product decision.
- m-10: duplicated rules (slot matching, "schedule changed", "pending and active"). Refactor only.
- m-11: two older data→services imports (`medication_model.dart` → `photo_storage`, `family_repository_impl.dart` → `connectivity_service`). New code keeps the rule.
- m-12 / hardening m-9: editing a schedule generates past slots. This changes dose history on every device and needs its own decision.
- Dash I3: a third copy of the 30-day expiry window.
- Dash I4: dose history overflows 10 px at 360 dp, German, 2.0× only. That row needs a redesign.
- The three router-pumping harnesses should become one `pumpMedoraRouterApp`. Test hygiene only.
- DetailRow squeeze and TagChip overflow in narrow boxes. Cosmetic, above 1.6×.
- The prescription count shrinks at large text. Cosmetic.
- The Italian End checkbox label wraps about 5 lines at 1.6×. The dialog scrolls.
- `createdAt` is dropped on an edit-mode save. Local only; `toJson` does not send `created_at`.
- The stock unit heuristic: half-tablet regimens never deduct. By design ("never more"); changing it needs a stored remainder.
- "y" in "x of y" depends on local rows. §4.2 makes every device hold every row, which removes most of the difference.
- No share on web. Platform follow-up.
- Skipped minors: the archived flag in the dose join, `autoDispose`, the tombstoned-prescription filter, a `durationDays > 0` guard test. Small.
- Every write starts a full, coalesced cycle; a 300–500 ms debounce would help. Performance only.
- The local `getPendingChanges` readers of the medication, treatment and dose-log datasources are unused (sick-branch m-9, local half). Dead code; a separate cleanup.
- Cloud reminders are set up 2 s or more after start. Cosmetic.
- A write made during a force pull is wiped by `clearAllData`. Force pull is an explicit "replace my data".
- Family members are pulled unpaged. Families are small.
- A slot whose id holds a server tombstone gets no dose (hardening m-8). The loop is bounded; rare.
- The list slide action ends a treatment with the list item's context, so End does nothing if a sync removes the row while the dialog is open. Rare.

## 3. How sync works today

These are the facts the design builds on, checked in the code at `35bb1f5`.

- **Server triggers** (`20260901000000_initial_schema.sql`, `20260914000000_tombstones_and_family.sql`):
  - `update_updated_at()` runs `BEFORE UPDATE` on the four data tables and sets `updated_at = now()`.
  - There is no insert trigger, so an insert keeps the client's `updated_at`.
  - The tombstone cascades run `AFTER UPDATE OF deleted_at` and tombstone the children.
- **Row-level security:**
  - `medications` and `treatments`: `user_id = auth.uid()`.
  - `prescriptions` and `dose_logs`: through treatment ownership.
  - Family members have **no** access to data rows (confirmed by the follow-up review).
- **Pull** (`lib/data/datasources/pull_page.dart`, `SyncService._pullTable`):
  - keyset pages ordered by `updated_at, id`, 1000 rows each, at most 50 pages;
  - the cursor is stored per page with a 1 s overlap and never below `1970-01-02`;
  - a one-time repair (`SyncCursorStore.pullRepairVersion = 1`) cleared the cursors once.
- **Push** (`SyncService._pushPendingChanges`):
  - `pending_update`: a stale check compares the device edit time with the server's `updated_at` (`_staleAgainstRemote`, `_skipStale`), then upserts the whole row.
  - `_upsertStamped` sends a created row a second time to get a server stamp.
  - `settlePushedRow` marks a row synced only while its local `updated_at` string is unchanged.
- **Doses:**
  - generated rows carry `updated_at = 1970-01-01`;
  - new doses go out as insert-if-absent batches of 100, followed by a read-back;
  - automatic "missed" is local-only and protected on pull by `isAutomaticallyMissedCopyOf`;
  - `applyPulled` and `ensureScheduled` regenerate doses for pulled prescriptions.
- **Stock:** `adjustQuantity` writes the new absolute quantity and marks the row `pending_update`.
- **Medora 0.3.0 against the server:**
  - upserts whole rows with no new keys, and reads `select('updated_at')` back;
  - pulls by `updated_at`;
  - skips an edit whose server `updated_at` is newer;
  - inserts new doses if absent;
  - sends a created row twice only when the answer carries exactly the stamp it sent.

## 4. Design

### 4.1 Overview

| Mechanism | Server side | Client side | Fixes |
|---|---|---|---|
| Transaction-horizon cursor | `sync_xid` set by trigger; `medora_sync_state()` returns the horizon | Pull `[key, horizon)` ordered by `sync_xid, id` | S-5, I-C, the 1970 floor, microsecond keys |
| Row versions | `row_version` +1 per update, set by trigger | Update only `row_version = base` | Blind overwrites; base for S-4 |
| Write ids | `write_id` kept as sent, cleared for a writer that does not send one | New id per attempt, stored before sending, compared on answer, fetch and pull | S-3 |
| Edit times | Per column: `field_edited_at`, merged key by key (capped at arrival, never going back, with an automatic flag). Per row: `edited_at`, the time the last write carried (1970 marks an automatic write, which leaves `updated_at` alone) | The same map, written by every local write for exactly the columns it changes; `edited_at` per row | PR5, S-1, S-7, the A/B/C case, compatibility with 0.3.0 |
| Field-level merge | — | Base snapshot per row; a patch sends only the changed columns and their times; a three-way merge per column group, each group judged by its own columns' times | S-4, follow-up m-2 |
| Guarded dose writes | Filters in the same statement | Time correction and delete only while pending and untouched | S-1, S-6, S-7 |
| Stock ledger | `stock_changes` table + `apply_stock_change()` | Local outbox of changes with ids | S-2 |
| Wipe marker | `sync_wipes` (generation, time) written by `medora_delete_all_data()`, read with the sync state | Removes what it holds from before a newer wipe, then pulls | "delete all data" left other devices' copies (§7.9) |

### 4.2 The pull cursor: a transaction horizon, not a sequence

The controller suggested a server-assigned, monotonically increasing counter, for example a `bigint` sequence set by trigger. **A sequence is not safe as a cursor:**

- a sequence number is taken when the statement runs, not when the transaction commits;
- request A takes number 100, request B takes 101, and B commits first;
- a pull that runs now sees 101, stores it as its cursor, and never asks for 100 again;
- so A's row is lost for good.

PostgREST runs every request in its own transaction, so two phones pushing at the same moment are exactly this case.

**Use the transaction id and a horizon instead.**

- `sync_xid` holds `pg_current_xact_id()` of the transaction that last wrote the row.
- `medora_sync_state()` returns `horizon = pg_snapshot_xmin(pg_current_snapshot())`. Every transaction with an id below the horizon has finished, so every row with `sync_xid < horizon` that will ever be visible is visible now.
- A pull reads rows with `sync_xid` in `[stored key, horizon)`, ordered by `sync_xid, id`, in keyset pages.
- When it reads to the end, it stores the horizon itself as the next start (`sync_xid >= horizon`).

**Probe** (throwaway `postgres:15-alpine`, this migration applied; `scratchpad/sync-v2-design/`):

1. A transaction took xid 849 and slept for 6 s before committing.
2. Meanwhile another request inserted `fast` with xid 850.
3. **While 849 was open:** horizon = 849, so `fast` (850) was **held back** (`sync_xid < 849` is false).
4. **After the commit:** horizon = 851, and both rows (849 and 850) were returned.

A sequence would have handed out `fast` and moved past `slow`. `tools/check_supabase_sql.sh` repeats this check.

**Consequences:**

- **The cursor is two values, stored per table:** `xid` (int) and `id` (string, or null for "from the start of `xid`").
- **Paging filter:**
  - `or=(sync_xid.gt.X,and(sync_xid.eq.X,id.gt."ID"))` when `id` is set;
  - `sync_xid=gte.X` when `id` is null;
  - always `sync_xid=lt.H`, ordered by `sync_xid.asc,id.asc`, with `limit=1000`.
- **What disappears:** the 1 s overlap, the 1970 floor and the microsecond problem on web (xids are integers).
- **Generated doses and offline-created rows are pulled like any other row** (S-5, I-C). `applyPulled` and `ensureScheduled` stay as a safety net, and their inserts are no-ops for rows the pull already brought.
- **A long-running transaction on the server holds the horizon back** until it ends. Pulls then return fewer rows, never wrong ones.
- **`pg_snapshot_xmin` never decreases on one primary.** If a stored key is ever above the horizon (a restored database), the pull logs it and restarts that table from the beginning.
- **Numbers on web:** `sync_xid` travels as a JSON number. Dart on Android and iOS holds 64 bits. Web holds 53 bits, which a real xid does not reach.

### 4.3 Row versions and write ids

- **Row versions.**
  - `row_version` is 1 on insert and `old + 1` on every update, set by the trigger whatever the client sends.
  - A 0.4.0 client updates with `PATCH …?id=eq.X&row_version=eq.V` and `Prefer: return=representation`.
  - An empty answer means the row moved on, or is gone.
- **Write ids.**
  - A 0.4.0 client sends a fresh `write_id` (uuid v4) with every write attempt, and stores it in the local row's `sync_write_id` **before** sending.
  - The trigger keeps a sent `write_id`.
  - An update that sends none, or repeats the stored one, gets `write_id = NULL`. This covers 0.3.0, the tombstone cascade and a replay. The repeat rule stops a 0.3.0 write from inheriting the last 0.4.0 id, which would otherwise look like that device's own write.
- **A lost answer is recognised in three places:**
  - **on the next attempt:** a row with `sync_write_id` set is fetched first (§7.3);
  - **in the pull:** an incoming row whose `write_id` equals the local `sync_write_id` (§7.2);
  - **after a failed conditional update:** the fetched row carries the device's own id.

  In all three cases the server row becomes the new base, and the local row is marked synced when nothing changed locally since, or stays pending with only the newer changes.
- **Survives an app kill.** `sync_write_id` is a column, so a kill between the request and its answer changes nothing.

### 4.4 Edit times and automatic changes

**Why per column.** One edit time per row is applied against the wrong time:

1. Device A changes the notes at 10:00 and syncs.
2. Device B, offline, changed the sick leave at 09:00. It syncs next, and the row's edit time becomes 09:00.
3. Device C, offline, changed the notes at 09:30. It syncs last, compares 09:30 with the row's 09:00, and overwrites A's later notes.

So every synced row keeps an edit time per column, and the merge compares the times of the columns it decides on.

**The map.** `field_edited_at` maps a column name to that column's last applied change:

```json
{"notes":  {"at": "2026-03-05T10:00:00+00:00", "auto": false},
 "status": {"at": "1970-01-01T00:00:00+00:00", "auto": true}}
```

- `at` is when the change was made (UTC); `auto` says the app made it on its own.
- The server keeps it as `jsonb`, the device as JSON text. Both mean the same.
- **Columns that never get an entry:** the bookkeeping (`id`, `user_id`, `created_at`, `updated_at`, `deleted_at` and the sync columns), and `quantity`, which only `apply_stock_change` writes (§4.8).
- **An empty map** means no column changed since the row was written: every column was last changed at the row's own time, `edited_at` (or `updated_at` when that is empty). This covers rows from before the migration, rows not updated since their insert, and local rows not changed since they were made or restored.
- **A column missing from a filled map** (for example one a later migration adds) has an unknown time.

**Client side.** Every local write stamps exactly the columns it changes (`fieldTimesAfterWrite` in `lib/data/local/field_times.dart`):

- it compares the wire copies of the row before and after the write, so a value written in another format is no change;
- a person's change gets the device time of the change, never later than the device clock;
- a change the app made on its own gets `1970-01-01` and `auto`;
- a write to a row whose map is empty first fills the map from the row's old time, because the write moves the row's own `edited_at`;
- a new row stores no map.

The automatic changes are:

- an overdue dose marked missed;
- a dose time corrected;
- a dose dropped from a changed schedule;
- a generated dose.

`edited_at` is still written per row: the time of the row's last local change (1970 for a generated row). It stands for every column while the map is empty.

**The trigger, per row (unchanged):**

- keeps a sent `edited_at`, capped at `now()`;
- turns every value before `1970-01-02` into exactly `1970-01-01`;
- uses `now()` for a writer that sends no write id (0.3.0, the tombstone cascade);
- keeps the stored `edited_at` when a 0.4.0 update sends a write id but no `edited_at`, and falls back to the old `updated_at` only when the stored one is empty. A 0.4.0 client therefore always sends `edited_at` with a write id.

**The trigger, per column:**

- **An update** reads the entries a 0.4.0 client sent for the columns whose value it really changes. A changed column without an entry takes the row's normalised `edited_at`. For a column whose value it does not change, a sent entry counts only when it is a person's time later than the one held (capped at arrival): the same value set again later is the latest edit of that column (review Minor 1). An older or automatic entry for an unchanged column is ignored.
- **Normalising:** an entry before `1970-01-02`, or one sent with `auto`, is automatic and counts as `1970-01-01`. Any other time is capped at `now()`.
- **Never back:** the stored time is the later of the time already held and the new one. The flag is the new change's.
- **A writer without a new write id** (0.3.0, the cascade) is never read: its changed columns are stamped on arrival, as a person's change.
- **The fill:** the first update of a row with an empty map gives every column the write does not change the row's old time (`edited_at`, else `updated_at`, capped at `now()`).
- **An insert** keeps the entries it sent, normalised the same way, for the columns it names. A 0.3.0 insert has an empty map.

**The row's `edited_at` is the last write's time, not the latest entry.** The controller allowed keeping it as the maximum of the map "if the design needs it". The design needs something else from it:

- `update_updated_at()` recognises an automatic write by `edited_at = 1970`, so that 0.3.0 does not see it;
- a pulled tombstone is automatic by the same mark (§4.6).

The maximum of the map would turn an automatic write on a row a person once changed into a real one. Nothing shows the row's edit time, and the pull cursor is `sync_xid` (§4.2).

**`updated_at` stays what 0.3.0 relies on:**

- **Real updates** keep getting `now()`.
- **Automatic updates** (a write id plus the 1970 edit time) keep the old `updated_at`. A 0.3.0 device then neither pulls them nor counts them as newer than its own pending edit, and its edit wins, as it should.
  - A 0.4.0 client sends the 1970 row time only when every column it writes is automatic. A write that also carries a person's change moves `updated_at`.
- **Real inserts** are stamped `now()` on arrival. A 0.3.0 device whose cursor passed the creation time while the creator was offline still pulls the row (I-C, server-side).
- **Generated inserts** keep 1970.

**Merging with edit times** (`mergeRows`, §4.5), for a column group both sides changed to different values:

- each side's change is the **strongest** time among the group's columns *that side changed*; an older person's time on a column that side left alone does not count;
- a person's change beats an unknown time, which beats an automatic change;
- two people's changes go by time, compared as instants, and the later wins;
- a tie, and two automatic changes, keep the server's value.

The server's times are already capped at arrival. A local change has not arrived yet, so its cap would be a later moment than any server copy's; comparing it uncapped gives the same answer.

**What this settles:**

- **PR5:** A marks a dose missed at 10:00 while offline, B takes it at 11:00, and A syncs first. B's take wins on every device.
- **The A/B/C case above:** C's 09:30 notes meet the notes' own 10:00, and lose, in either sync order.
- **Automatic changes can be pushed** (S-7, §4.7), even together with a person's change to another column of the same row: each column keeps its own kind.

### 4.5 Field-level merge (I-1)

**Choice: merge per column group, then write conditionally.**

- Every synced local row keeps `sync_base`: the canonical wire copy of the server row it was last in step with, plus `sync_version`.
- A `pending_update` push sends **only the columns that differ from the base**, conditional on `sync_version`.
- On a version conflict, the client fetches the server row and merges three ways (base, local, server). It stores the result with the server row as the new base, and sends the remaining difference once more in the same cycle (at most two attempts per row per cycle, then the next cycle).
- The pull applies the same merge to a pending local row (§7.2).

**Why not the alternative.** The alternative was to turn a conflict into a pending re-merge without field groups. Its whole-row rule is exactly what loses the certificate number today.

**The merge rule** (`lib/data/sync/row_merge.dart`, pure, unit-tested; the probe run is in the scratchpad):

- **What changed since the base:** a column whose value differs from the base, or whose time on that side is a person's change later than the base's own time for it. The second case is a change back to the old value (A sets Y, B sets Z, A sets the old value again: A's is the latest edit). `sync_base` keeps the server's column times of the base for this (§6). A base stored without them counts values only.
- **Per group, by what changed since the base:**
  - a group only the local side changed takes the local values;
  - a group only the server changed, or neither, takes the server values;
  - a group both sides changed to different values takes the side whose change to that group wins, by that group's own column times (§4.4);
  - a group this side changed to the values the server already holds takes the server's values, and keeps this side's times when a person here made that change later than the server's times for the group. The row then still has those times to send (`MergeResult.sendsTimes`): it stays `pending_update`, and the push sends the column with its unchanged value and its later time (review Minor 1, found by the three-device random run: A sets 6 at 19:00, B offline sets 4 at 19:18, C, which had not seen A's change, sets 6 at 21:20; without this, the server kept 19:00 and B's 4 won).
- **With no base** (rows from before v16, or a restore), every group counts as changed on both sides, so each group goes to the side whose column times win.
  - A restored row without a map meets the server's times column by column, with its one row time.
  - A row from before the migration has an empty map, so its `updated_at` stands for every column. A device's 0.3.0 change still waiting then loses to a newer server row, as it did under 0.3.0.
- **The stored times:** a merged row keeps the server's times, with this device's for the columns taken from here (and none for a column whose time here is unknown).
- **Always the server's:** bookkeeping keys (`id`, `user_id`, `updated_at`, `deleted_at`) and server-owned columns.

**Column groups** are columns that only make sense together:

| Table | Groups (any other column is a group of its own) | Server-owned |
|---|---|---|
| `treatments` | `{end_date, is_active}`, `{sick_leave_from, sick_leave_to}` | — |
| `prescriptions` | `{schedule_type, interval_hours, duration_days, start_time, schedule_times}`, `{dosage, dosage_amount, dosage_unit}` | — |
| `dose_logs` | `{status, taken_time}` | — |
| `medications` | `{barcode, ean}` | `quantity` (§4.8) |

**What the user sees:**

- **Different fields changed on two devices:** after both have synced, both devices show both changes. No message.
  - **S1a / S1b** (B adds the certificate number, A ends the illness and closes the leave, in either order): both devices end with the treatment ended on A's date, the leave closed on A's date, and certificate number `CERT-B`. End is never undone.
  - **A deactivated prescription while its dosage is edited elsewhere:** both changes are kept.
  - **A dose note while the dose is taken elsewhere:** both are kept.
- **The same field, or the same group, changed on both devices:**
  - the value from the edit made later (by device clock, never later than the server received it) is kept on both devices;
  - the other is dropped **without a dialog**;
  - the cycle counts it in `SyncReport.overwritten` (table, id, group, which side was kept) and logs it.

  **Example:** the certificate number is typed as `A` on one phone at 10:05 and as `B` on the other at 10:07, and the first phone syncs last: both show `B`.
- **Delete against edit:** a person's delete wins over any edit, as today. An automatic dose delete loses to a real dose change (§4.7).

The merge runs on the canonical wire form (`Model.fromJson(row).toJson()`), so a server timestamp written as `+00:00` and a local one written as `Z` compare equal.

### 4.6 Deletes

**Two kinds of tombstone.** A tombstone whose row `edited_at` is `1970` is the **app's own delete**. Every other tombstone is a **person's delete**, and it always wins.

The app's own deletes are:
- a dose dropped from a changed schedule (below);
- a child deleted with its parent: the tombstone cascade (a prescription with its treatment or medication, a dose with its prescription);
- a child written live under a deleted parent (below).

- **A person's delete.** An unconditional `PATCH {deleted_at, write_id, edited_at}`; the local row is then hard-deleted.
  - If the server has no such row and the row still carries an unresolved `sync_write_id` (its create may land late), the client inserts a **tombstone row** (the full row with `deleted_at`, insert-if-absent). A late insert then does nothing, which fixes hardening m-3.
- **An automatic dose delete** (a dose dropped by a schedule change, S-6):
  - It sends `PATCH …?id=eq.X&status=eq.pending&deleted_at=is.null` with `deleted_at`, `edited_at = 1970`, and a write id. The cycle sends these in bulk, 100 ids per request (`id=in.(…)`) with one write id; the doses a request did not delete are read in one request and handled as below, or left to the one-by-one push (still live and pending, or carrying an undo).
  - If a row matched, the local row is hard-deleted.
  - If none matched, the client fetches the row:
    - gone or already deleted: the local row is hard-deleted;
    - no longer pending (taken or skipped elsewhere): the server copy replaces the local row, stored as `synced`. It is a historical fact and is shown;
    - no longer pending, but a person here made the dose pending again later than that take or skip (an undo made offline before the schedule changed; cycle review I-2): the undo is sent first (its status group, with its own times, at the fetched version), then the guarded delete again. The undo is a person's change, so `updated_at` moves and 0.3.0 sees it; the delete stays the app's own. If the copy moved meanwhile, the push fails and is tried again after its backoff. "Later" is the three-way merge of §4.5 on the status group, with the base the device last held: the drop only fills the column times, so the undo's time is still the row's;
    - still live and pending (the row changed and changed back meanwhile): the push fails, the row stays `pending_delete` and is tried again after its backoff.
  - A dropped dose that never reached a server, and whose create got no answer, sends nothing in its place.
  - Locally this is `sync_status = pending_delete` with `delete_guard = 'if_pending'`. A dose with a change still waiting (`pending_update`, such as that undo) is dropped the same way: it disappears here at once, with its reminder, and keeps its base and column times for the push. (The review's alternative, leaving `pending_update` doses out of the drop, kept the undo but left the dose shown and reminded at the old time until the next regeneration, and `DoseScheduleService` does not regenerate the same doses twice in one process, so it stayed until the app was restarted.)
- **A pulled tombstone:**
  - it deletes the local row;
  - **exception:** the app's own tombstone of a **dose** loses to a change still waiting here, which is then pushed with `deleted_at: null`:
    - a person's change to a column (a changed value, not a change back);
    - the schedule generating the same slot again here (`pending_create`) after the delete: its `created_at` is later than the tombstone's `deleted_at`, or unknown. Two changes the app made: the newer wins. A slot generated before the drop stays dropped;
  - the exception never applies under a prescription that is deleted or missing here, nor when the tombstone carries this device's own write id (the server deleted what this device sent), nor to any table but doses (a dose has no children).

**Rows under a deleted parent (review C-1).** A live dose under a deleted prescription, or a live prescription under a deleted treatment or medication, would fail every device's local foreign key for good. So neither side keeps one:

- **Server** (`medora_sync_stamp`, §5):
  - a prescription or dose written live under a deleted parent is stored deleted, with the parent's `deleted_at`, as the app's own delete. The write still lands (its columns, its write id), so the sending device learns the row is gone. This covers a late insert, a 0.3.0 upsert, and a row brought back by a take or a force push;
  - the tombstone cascade deletes live children as the app's own change; it still moves `updated_at`, so 0.3.0 sees it as before;
  - the migration deletes, once, the live children it finds under deleted parents (as the app's own change).
  - With these, the server never holds a live row under a deleted parent. A parent that is not there at all is refused by the foreign key (23503), as before.
- **Device, pull:** a live row under a parent that is `pending_delete` here goes with that parent (deleted here, or not stored). A live row whose parent this device does not hold is reported as `orphaned`, never thrown: the cycle fetches the parent, stores it and then the row when the server has it live, and otherwise passes the row over. Either way the pull key moves on.
- **Device, push:** a row under a parent that is `pending_delete` here (its delete could not be sent yet) is deleted here and never sent, in the batch of new doses as well. A row the server answers deleted is deleted here when it settles. A force push that the server answers deleted fails and keeps the row, since the parent's own force push failed.
- **Decision:** a person's take of a dose whose prescription a person deleted on another device loses. The take reaches the server, stored deleted; the delete wins on every device, because the user deleted the prescription on purpose.

**A 0.3.0 take of a dose 0.4.0 dropped (review I-2).** 0.3.0 never sees the drop (it keeps `updated_at`) and sends its take as a whole-row upsert without `deleted_at`. The trigger brings the dose back when such a legacy write sets the status of a row the app deleted to `taken` or `skipped`: a person's take beats the app's delete. Any other legacy write to that row (a note, the same values again, 0.3.0's own `missed`) leaves it deleted, still as the app's own delete. A 0.4.0 write decides for itself by sending `deleted_at: null`.

### 4.7 Doses: automatic "missed", shifted times, dropped slots

- **Automatic "missed" is pushed** (S-7).
  - `markOverduePendingAsMissed` sets `status = missed` and `edited_at = 1970` on `synced` rows and makes them `pending_update`.
    - Rows already `pending_update` are still skipped (I-B).
    - `pending_create` rows keep their status.
  - The push is conditional on `sync_version`. It goes out in bulk (cycle review I-5): one `PATCH …?id=in.(…)&row_version=eq.V&status=eq.pending&deleted_at=is.null` per version and 100 doses, with `status = missed`, one write id for the request, `edited_at = 1970` and `status` marked automatic. A dose is sent this way only when its sole change since its base is that automatic status, from pending, at a known version, with no unanswered write. The doses the request did not write are read in one request and merged (below); what is still pending then goes out one by one. The request is conditional per dose exactly as the one-by-one push is, so a change made elsewhere is never overwritten.
  - **A "missed" the server already has is not written again:** the status filter leaves it out, its version stays, and the read-back settles the local copy as the same value. A second device that swept the same doses offline costs two requests per 100 doses, not two per dose.
  - **If the server row moved** (someone took the dose), the merge keeps the take (real beats automatic) and the local row settles as `taken`.
  - **If it did not**, the server stores "missed" and keeps `updated_at`, so 0.3.0 devices do not see it and compute the same result themselves.
  - `isAutomaticallyMissedCopyOf` and its pull guard are removed, because the merge covers them.
- **Shifted dose times are corrected** (S-1).
  - `DoseScheduleService.ensureScheduled` already finds a dose stored under a slot's own id at another time.
  - It now calls `DoseLogRepository.correctDoseTimes(slotTimes)` (dose id → the slot's time). For each such row that is `synced`, `status = pending` and has `edited_at` null or 1970, that call sets `scheduled_time` to the slot's time and `edited_at = 1970`, and marks the row `pending_update`.
  - The push is conditional on the version, so the correction lands only on the copy it was computed from.
  - **If B took the dose meanwhile,** the merge keeps both, since `scheduled_time` and `{status, taken_time}` are different groups: the dose is taken, at the right time.
  - A dose a person has touched (a real `edited_at`), taken, skipped or marked missed by a person is never corrected.
- **Dropped slots are deleted on the server** (S-6).
  - `regenerateDoseLogsForPrescription` marks pending doses the schedule no longer has as `pending_delete` + `delete_guard = 'if_pending'` + `edited_at = 1970`, instead of hard-deleting them.
  - A row with no `sync_version` and no `sync_write_id` has never reached a server (a generated dose not sent yet, or any dose in local-only mode) and is still hard-deleted.
  - Generation treats `pending_delete` rows as present, so it never re-creates a dose that is being deleted (follow-up m-6).
  - A schedule changed back generates the same slot ids again. They meet their own automatic tombstones on the server and bring them back (§4.6), on the create path and in the batch of new doses. A slot a person deleted stays deleted; `DoseScheduleService` then stops generating it for the life of the process.

### 4.8 Stock as idempotent changes (S-2)

- **The local outbox.** A new local table `stock_outbox(op_id, medication_id, delta, set_to, created_at)` receives one row per stock change. It is written in the same transaction as the local quantity.
  - A dose that uses stock, a stock button and an undo each write `delta`.
  - A quantity typed in the medication form writes `set_to`.
  - A stock change is not a row edit: the row keeps its status and stamps, so a change made while the row's push is in flight never makes that push look stale.
  - Local-only mode writes an outbox row only for a medication the server has seen (a known `sync_version`): a device that left cloud mode and kept its data sends those changes when it signs back in to the same account (`markAllForUpload` keeps the outbox; another account drops it). A medication that never synced gets none. A change that is not queued stamps `updated_at` and `edited_at` and fills the column times, as every local write does.
  - A quantity typed into the form is a count only when the person changed the field: a field left as it was loaded takes the stock as it is when the form is saved, so an old number never undoes a dose taken meanwhile.
  - A medication that is still `pending_create` writes its changes too. Its insert carries its quantity, which already holds them, so they leave the outbox in the transaction that prepares the insert and stores its write id (§7.3). A change made after that waits and goes out once the insert settles. (An earlier draft queued nothing and turned an in-flight difference into a `delta` when the create settled; that lost the difference when the insert's answer was lost and the write was found again, and counted waiting changes twice then.)
- **Draining.** Each cycle drains the outbox after the medication rows are pushed, in the order the changes were made (`seq`), by calling `apply_stock_change(op_id, medication_id, delta, set_to)`. The function:
  - takes a transaction-level advisory lock on the op id;
  - returns `duplicate` if the ledger already has the id;
  - brings the change into range first (`set_to` to 0…999999, `delta` to −999999…999999; `stockChangeInRange` in `stock_remote.dart`, which the client also applies before sending);
  - otherwise applies `quantity = clamp(quantity + delta)` or `set_to` (0…999999) to a live medication (`stockAfter`);
  - records the id and the values in range in `stock_changes`;
  - returns `applied` with the new quantity and version, or `gone`: no live medication with that id (deleted, removed from the server, never created, or not the caller's). `gone` is final: drop the change.
- **Reading stock.**
  - `quantity` is server-owned in the merge and never part of a row patch.
  - The local quantity is always `the server's quantity + the pending outbox changes, in order` (`applyStockOps`), applied on every pull, settle and drain (`localStock`). One exception: `apply_stock_change` stamps its op id as the medication's `write_id`, so when a pulled copy's write id is the op id of the oldest change still waiting, that change has landed (only its answer was lost) and is left out of the sum. It stays in the outbox until the function answers `duplicate`; nothing else is read as proof that a change applied.
  - When the answer's `row_version` is exactly one more than the local `sync_version`, the client moves the base forward, so its own stock change does not turn the next row edit into a conflict.
- **Result:** two devices each taking one tablet from 10 end at 8 on both, in any order and with any lost answer. A retry is never counted twice.
- **Force push** sends each local quantity as `set_to`. So does a cloud restore.

### 4.9 What is removed from the client

- the stale check (`_staleAgainstRemote`, `_skipStale`, `getUpdatedAt` on the four remote datasources) and `SyncReport.skippedStale`;
- the create re-send (`_upsertStamped`, `_stampRecordedDose`);
- the `updated_at` pull key, the 1 s overlap and the 1970 floor (`_storePullCursor`);
- the whole-row `upsert*` methods;
- `isAutomaticallyMissedCopyOf`;
- the remaining unpaged remote readers (sick-branch m-9: `getDoseLogs`, `getTodaysDoseLogs`, `getPrescriptions`, `getActivePrescriptions`, `getPrescriptionsByTreatment`), which go with the v1 remote datasources.

## 5. The migration — exact SQL

File: `supabase/migrations/20260918000000_sync_v2.sql`. Apply it after `20260917000000_treatment_sick_leave.sql`.

**Checked** against a throwaway `postgres:15-alpine` with a stand-in `auth` schema, using `tools/check_supabase_sql.sh` and `tools/sql/sync_v2_checks.sql` (committed by Task 3):

- all assertions pass;
- the file is re-runnable (applied twice);
- three deliberate mutations are each caught: an automatic change that stamps `updated_at`, a replayed write id that is not cleared, and a created row that is not stamped on arrival;
- all five migrations also apply on a local `supabase start` (CLI 2.117.0), where the 0.4.0 integration scenarios pass and the unchanged v0.3.0 integration suite still passes;
- after the Task 3 review (fix round) the checks also cover: no TRUNCATE, TRIGGER or REFERENCES for clients on any synced or family table, every kind of update moving `sync_xid`, stock values out of range, a medication removed from the server, a retry racing its original, and the app's family and "delete all data" flows. They pass on the real `supabase/postgres:15.8.1.085` image as well.
- after the per-column revision (2026-09-17), the checks also fail when a column time goes back, when the cap at arrival is missing, when an older time overwrites an entry, when an unchanged column is stamped, when a legacy write's map is read, when a sent map is ignored or replaces the stored one, when the fill is missing or uses the arrival time, and when the stock or `deleted_at` gets an entry (14 mutants, all caught). The revision was checked on `postgres:15-alpine` only.
- after the engine review (2026-09-17), the checks also cover: children stored deleted under a deleted treatment, medication or prescription (inserts, 0.4.0 updates that bring a row back, 0.3.0 upserts); the cascade as the app's own change; the one-time repair of live children; a 0.3.0 take bringing a dropped dose back, and every legacy write that must not; the fill capped at arrival, a write id without an edit time, and the automatic fill. 15 mutants of these rules, all caught, on `postgres:15-alpine`.
- after the cycle review (2026-09-17), the checks also cover: the same value set again by a person later moves its entry, an older or automatic entry for an unchanged column does not (review Minor 1, in `sync_v2_checks.sql` and in the parity script); a bulk "missed" and a bulk drop (cycle review I-5). `tools/check_supabase_sql.sh` also runs two sessions against each other under row-level security: a dose insert left open while its prescription is deleted, the delete left open while the insert runs, and a prescription insert left open while its medication is deleted. Each child must end deleted, as the app's own delete. Without the parents read `FOR SHARE` every case fails.
- `tools/sql/fake_server_parity.sql`, which `test/helpers/fake_server_parity_test.dart` writes, runs the fake server's script of writes against the migration and fails on any row where Postgres answers differently (§12).

```sql
-- ============================================================
-- Medora - Sync v2: a change cursor the server assigns, row versions,
-- write ids, edit times per column and idempotent stock changes.
--
-- Apply after 20260917000000_treatment_sick_leave.sql and BEFORE any
-- device runs Medora 0.4.0. Medora 0.3.0 keeps working against it:
-- every new column has a default or is set by a trigger, no existing
-- column changes meaning for a client that does not send the new ones,
-- and `updated_at` still moves on every change such a client can see.
--
-- No backfill UPDATE: every new column is added with a constant default
-- (no table rewrite, no trigger fires), so no row changes `updated_at`
-- and no 0.3.0 device sees its pending edit turn stale. The one UPDATE
-- (section 7) deletes the live rows it finds under a deleted parent, as
-- the app's own change. Section 8 adds "delete all data", which records a
-- wipe marker (section 2b) every device follows.
--
-- Run it in one transaction (`supabase db push` and the SQL editor do).
-- Every statement can be run again, so a failed run can simply be
-- retried.
--
-- After this migration:
-- - never run 20260901000000_initial_schema.sql again: it would put back
--   the old update_updated_at() and break the rule in section 4;
-- - do not enable read replicas for this project: a pull reads its pages
--   below a horizon taken on the primary, and a lagging replica would
--   answer without rows that are already below it.
-- ============================================================

-- The ALTER TABLEs wait for every open transaction on these tables, and
-- every API request on them would queue behind that wait. Give up instead.
set local lock_timeout = '5s';

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
--              corrected, a dose dropped from a changed schedule). It is the
--              time the last write carried; the merge reads the times per
--              column below.
-- field_edited_at
--              per column, when that column's last applied change was made:
--              {"<column>": {"at": <timestamptz>, "auto": <bool>}}. "auto"
--              marks a change the app made on its own. A time is never
--              later than the server received the change, and never earlier
--              than the time the map already held for that column. The
--              stock (quantity) and the bookkeeping columns have no entry.
--              An empty map (every row from before this migration, every
--              row not updated since it was inserted): each column was last
--              changed at the row's edited_at, or its updated_at when that
--              is empty. The first update of such a row fills the map.

alter table public.medications
  add column if not exists sync_xid        bigint not null default 0,
  add column if not exists row_version     bigint not null default 1,
  add column if not exists write_id        uuid,
  add column if not exists edited_at       timestamptz,
  add column if not exists field_edited_at jsonb not null default '{}'::jsonb;

alter table public.treatments
  add column if not exists sync_xid        bigint not null default 0,
  add column if not exists row_version     bigint not null default 1,
  add column if not exists write_id        uuid,
  add column if not exists edited_at       timestamptz,
  add column if not exists field_edited_at jsonb not null default '{}'::jsonb;

alter table public.prescriptions
  add column if not exists sync_xid        bigint not null default 0,
  add column if not exists row_version     bigint not null default 1,
  add column if not exists write_id        uuid,
  add column if not exists edited_at       timestamptz,
  add column if not exists field_edited_at jsonb not null default '{}'::jsonb;

alter table public.dose_logs
  add column if not exists sync_xid        bigint not null default 0,
  add column if not exists row_version     bigint not null default 1,
  add column if not exists write_id        uuid,
  add column if not exists edited_at       timestamptz,
  add column if not exists field_edited_at jsonb not null default '{}'::jsonb;

-- 2. Pull indexes (keyset: sync_xid, then id) -----------------------------

create index if not exists idx_med_sync   on public.medications   (user_id, sync_xid, id);
create index if not exists idx_treat_sync on public.treatments    (user_id, sync_xid, id);
create index if not exists idx_presc_sync on public.prescriptions (sync_xid, id);
create index if not exists idx_dose_sync  on public.dose_logs     (sync_xid, id);

-- 2b. The wipe marker ------------------------------------------------------
--
-- One row per user who used "delete all data" (medora_delete_all_data,
-- section 8): how many times, and when the last one ran. Every device reads
-- it with the sync state; one that sees a newer generation than it last
-- saw removes what it holds from before `wiped_at` and pulls again. Only
-- that function writes it; a user reads only their own row.

create table if not exists public.sync_wipes (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  generation bigint not null,
  wiped_at   timestamptz not null
);

alter table public.sync_wipes enable row level security;

drop policy if exists "sync_wipes_select" on public.sync_wipes;
create policy "sync_wipes_select" on public.sync_wipes
  for select using (user_id = auth.uid());

revoke all on public.sync_wipes from anon, authenticated;
grant select on public.sync_wipes to authenticated;

-- 3. The stamp trigger ------------------------------------------------------
--
-- Runs BEFORE the `<table>_updated_at` trigger: Postgres fires BEFORE
-- triggers of one event in name order, and `_sync_stamp` sorts before
-- `_updated_at`. update_updated_at() below relies on that order.
--
-- Deletes. A tombstone whose edited_at is 1970 is the app's own delete:
-- a dose dropped from a changed schedule, a child deleted with its
-- parent. On a dose, a 0.4.0 device lets a person's change still waiting
-- beat it, and lets the schedule generate the dose again, but only under
-- a live prescription. Every other tombstone is a person's delete and
-- always wins. Around that:
-- - a child written live under a deleted parent (prescriptions under a
--   treatment or medication, doses under a prescription) is stored
--   deleted, with the parent's deleted_at, as the app's own delete. The
--   write still lands (its columns, its write id), so the device that
--   sent it learns the row is gone. With the tombstone cascade below, the
--   server never holds a live row under a deleted parent;
-- - the cascade (a write made by another trigger) deletes as the app's own
--   change, but still moves updated_at, so 0.3.0 sees it as before;
-- - a 0.3.0 write that sets a dose the app deleted to taken or skipped
--   brings it back (a person's take beats the app's delete). Any other
--   0.3.0 write to such a row leaves it deleted, still as the app's own.

create or replace function public.medora_sync_stamp()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
declare
  c_ceiling constant timestamptz := timestamptz '1970-01-02 00:00:00+00';
  c_epoch   constant timestamptz := timestamptz '1970-01-01 00:00:00+00';
  -- Columns with no edit time of their own: the bookkeeping, and the stock,
  -- which only apply_stock_change writes.
  c_untimed constant text[] := array['id', 'user_id', 'created_at', 'updated_at',
    'deleted_at', 'sync_xid', 'row_version', 'write_id', 'edited_at',
    'field_edited_at', 'quantity'];
  v_now    timestamptz := now();
  v_legacy boolean := false;
  -- A write made by another trigger: the tombstone cascade.
  v_cascade boolean := pg_trigger_depth() > 1;
  -- The row stays or becomes the app's own tombstone.
  v_app_delete boolean := false;
  v_parent_deleted timestamptz;
  v_other_deleted  timestamptz;
  -- "Delete all data" (section 8): the caller's last wipe, and the wipe
  -- generation a 0.4.0 insert says its device has seen.
  v_wiped_at   timestamptz;
  v_generation bigint;
  v_wipe_delete boolean := false;
  v_new    jsonb;
  v_old    jsonb;
  v_sent   jsonb;
  v_map    jsonb := '{}';
  v_key    text;
  v_entry  jsonb;
  v_at     timestamptz;
  v_auto   boolean;
begin
  new.sync_xid := pg_current_xact_id()::text::bigint;
  if tg_op = 'INSERT' then
    new.row_version := 1;
    new.edited_at := coalesce(new.edited_at, new.updated_at, v_now);
  else
    new.row_version := old.row_version + 1;
    if new.write_id is null or new.write_id is not distinct from old.write_id then
      -- A writer that sends no write id: Medora 0.3.0 and older, the
      -- tombstone cascade. Its change counts as made when it arrived.
      v_legacy := true;
      new.write_id := null;
      new.edited_at := v_now;
    elsif new.edited_at is null then
      new.edited_at := coalesce(old.updated_at, v_now);
    end if;
  end if;
  if new.edited_at < c_ceiling then
    new.edited_at := c_epoch;
  else
    new.edited_at := least(new.edited_at, v_now);
    if tg_op = 'INSERT' then
      -- A row a person created is stamped on arrival, so a device whose
      -- updated_at cursor passed its creation time while it was offline
      -- still pulls it (Medora 0.3.0 pulls by updated_at). A generated
      -- row keeps its 1970 stamp and stays invisible to those cursors.
      new.updated_at := v_now;
    end if;
  end if;

  -- A 0.4.0 insert from a device that has not seen the caller's last
  -- "delete all data" (the wipe generation it sends under "@wipe" is
  -- older), of a row a person last changed before that wipe, is stored
  -- deleted, as that person's delete: the device read the sync state just
  -- before the wipe, and its next cycle removes the row there too. A row
  -- changed after the wipe is new data, and so is every insert from a
  -- writer that sends no "@wipe" (Medora 0.3.0). The shared lock makes
  -- inserts and the wipe (which takes it exclusively) run one after the
  -- other, so this reads the wipe that is committed when the row lands.
  if tg_op = 'INSERT' and auth.uid() is not null then
    perform pg_advisory_xact_lock_shared(
      hashtextextended('medora-wipe:' || auth.uid()::text, 0));
    if new.deleted_at is null and new.write_id is not null
       and jsonb_typeof(new.field_edited_at) = 'object'
       and new.field_edited_at ? '@wipe'
       and new.edited_at >= c_ceiling then
      select w.wiped_at, w.generation into v_wiped_at, v_generation
        from public.sync_wipes w where w.user_id = auth.uid();
      if v_generation > (new.field_edited_at ->> '@wipe')::bigint
         and new.edited_at <= v_wiped_at then
        new.deleted_at := v_wiped_at;
        v_wipe_delete := true;
      end if;
    end if;
  end if;

  v_new := to_jsonb(new);
  if tg_op = 'UPDATE' then
    v_old := to_jsonb(old);
    -- A legacy write to a row the app deleted, that does not delete it
    -- itself.
    if v_legacy and not v_cascade and old.deleted_at is not null
       and old.edited_at < c_ceiling
       and new.deleted_at is not distinct from old.deleted_at then
      if tg_table_name = 'dose_logs'
         and v_new->>'status' in ('taken', 'skipped')
         and (v_new->'status') is distinct from (v_old->'status') then
        new.deleted_at := null;
      else
        v_app_delete := true;
      end if;
    end if;
  end if;

  -- Edit times per column. A 0.4.0 client sends an entry for each column
  -- it writes; the entries are read for the columns the write really
  -- changes (an insert: the columns it names), and for an unchanged column
  -- only as a later person's time (below); never for a legacy write.
  if tg_op = 'INSERT' then
    v_sent := new.field_edited_at;
  else
    v_map := old.field_edited_at;
    if not v_legacy and new.field_edited_at is distinct from old.field_edited_at then
      v_sent := new.field_edited_at;
    end if;
    if v_map = '{}' then
      -- The first update since the row was written: every column was last
      -- changed at the row's own time.
      v_map := '{}';
      v_at := least(coalesce(old.edited_at, old.updated_at, v_now), v_now);
      v_auto := v_at < c_ceiling;
      for v_key in select jsonb_object_keys(v_old) loop
        continue when v_key = any(c_untimed);
        v_map := v_map || jsonb_build_object(v_key, jsonb_build_object(
          'at', case when v_auto then c_epoch else v_at end, 'auto', v_auto));
      end loop;
    end if;
  end if;
  for v_key in select jsonb_object_keys(v_new) loop
    continue when v_key = any(c_untimed);
    v_entry := v_sent -> v_key;
    if tg_op = 'INSERT' then
      continue when v_entry is null;
    elsif (v_new -> v_key) is not distinct from (v_old -> v_key) then
      -- An unchanged value moves its entry only when the write sent a
      -- person's time for it that is later than the one held: the same
      -- value set again, later, is the latest edit of that column. Any
      -- other entry for an unchanged column is ignored (a legacy write
      -- sends none).
      v_at := (v_entry ->> 'at')::timestamptz;
      continue when v_at is null
        or coalesce((v_entry ->> 'auto')::boolean, false)
        or v_at < c_ceiling
        or least(v_at, v_now)
           <= coalesce((v_map -> v_key ->> 'at')::timestamptz, '-infinity');
    end if;
    -- A changed column with no entry takes the time the write carried
    -- (a legacy write: its arrival).
    v_at := coalesce((v_entry ->> 'at')::timestamptz, new.edited_at);
    v_auto := coalesce((v_entry ->> 'auto')::boolean, false) or v_at < c_ceiling;
    v_at := case when v_auto then c_epoch else least(v_at, v_now) end;
    -- Never earlier than the time already held (greatest skips a NULL).
    v_at := greatest((v_map -> v_key ->> 'at')::timestamptz, v_at);
    v_map := v_map || jsonb_build_object(v_key, jsonb_build_object('at', v_at, 'auto', v_auto));
  end loop;
  new.field_edited_at := v_map;

  -- A live child under a deleted parent is stored deleted.
  --
  -- The parents are read FOR SHARE and held until this write commits. A
  -- parent's delete (FOR NO KEY UPDATE) then waits for this write, and its
  -- cascade, which runs after that wait, sees this row and deletes it; a
  -- delete that came first makes this read wait, and it then sees the
  -- parent deleted. Without the lock the two pass each other (the foreign
  -- key's FOR KEY SHARE does not conflict with a delete) and a live child
  -- stays under a deleted parent. Reading FOR SHARE needs the UPDATE right
  -- and policy on the parent, which its owner has.
  if new.deleted_at is null then
    if tg_table_name = 'prescriptions' then
      select t.deleted_at into v_parent_deleted
        from public.treatments t where t.id = v_new->>'treatment_id' for share;
      select m.deleted_at into v_other_deleted
        from public.medications m where m.id = v_new->>'medication_id' for share;
      v_parent_deleted := coalesce(v_parent_deleted, v_other_deleted);
    elsif tg_table_name = 'dose_logs' then
      select p.deleted_at into v_parent_deleted
        from public.prescriptions p where p.id = v_new->>'prescription_id' for share;
    end if;
    if v_parent_deleted is not null then
      new.deleted_at := v_parent_deleted;
      v_app_delete := true;
    end if;
  end if;
  if v_cascade or v_app_delete then
    -- After the column times: the columns a write changes keep its time.
    new.edited_at := c_epoch;
  elsif v_wipe_delete then
    new.edited_at := v_wiped_at;
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
-- counts it as newer). Every other update is stamped now(), as before,
-- including the tombstone cascade and a 0.3.0 write (they send no write
-- id).

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

-- Trigger functions run as triggers only (a trigger does not need EXECUTE).
revoke all on function public.medora_sync_stamp() from public, anon, authenticated;
revoke all on function public.update_updated_at() from public, anon, authenticated;
revoke all on function public.cascade_tombstone_treatment() from public, anon, authenticated;
revoke all on function public.cascade_tombstone_medication() from public, anon, authenticated;
revoke all on function public.cascade_tombstone_prescription() from public, anon, authenticated;

-- Clients never truncate, add triggers or add foreign keys. Row-level
-- security does not cover TRUNCATE, and Supabase grants all three by
-- default, so one signed-in user could otherwise empty every user's rows
-- through any SQL surface. Hard DELETE stays, under the tables' policies
-- ("delete all data" uses medora_delete_all_data, section 8, which also
-- tells the user's other devices).
revoke truncate, trigger, references
  on public.medications, public.treatments, public.prescriptions,
     public.dose_logs, public.families, public.family_members
  from anon, authenticated;

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
    'horizon', pg_snapshot_xmin(pg_current_snapshot())::text::bigint,
    'wipe', (select jsonb_build_object('generation', w.generation, 'wiped_at', w.wiped_at)
               from public.sync_wipes w where w.user_id = auth.uid())
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
  constraint stock_changes_set_to_range check (set_to is null or set_to between 0 and 999999),
  constraint stock_changes_quantity_range check (quantity_after between 0 and 999999)
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

-- Supabase grants every right on a new table to anon and authenticated.
-- Row-level security does not cover TRUNCATE, so take the rights away and
-- give back only reading and appending.
revoke all on public.stock_changes from anon, authenticated;
grant select, insert on public.stock_changes to authenticated;

-- Applies one stock change once. Returns
--   {"status":"applied",   "quantity":q, "row_version":v}
--   {"status":"duplicate", "quantity":q}   (this op_id was applied before)
--   {"status":"gone"}      (no live medication with this id for the caller:
--                           deleted, removed from the server, or never
--                           there. The change can never apply: drop it.)
-- A client sends a change only for a medication whose create has reached
-- the server, so "never there" means removed. The ledger rows of a removed
-- medication go with it, so a retry after the removal is gone as well.
--
-- Values out of range are brought into range before anything else, so a
-- change is never refused for good: set_to to 0..999999, delta to
-- -999999..999999; the new quantity is set_to, or quantity + delta
-- (computed without overflow) capped to 0..999999. The ledger records the
-- values in range. lib/data/datasources/stock_remote.dart (stockAfter) and
-- test/helpers/fake_server.dart follow the same rule.
--
-- The medication keeps its edit time (a stock change is not a field edit
-- that the merge compares). Medications never carry the 1970 edit time of
-- an automatic change, so updated_at moves and 0.3.0 pulls the change.
--
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
  v_delta   integer;
  v_set_to  integer;
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
  -- (greatest and least skip NULLs, so keep a NULL as it is.)
  v_delta := case when p_delta is not null then greatest(-999999, least(999999, p_delta)) end;
  v_set_to := case when p_set_to is not null then greatest(0, least(999999, p_set_to)) end;

  -- Two attempts with one op id (a retry racing the original) run one
  -- after the other.
  perform pg_advisory_xact_lock(hashtextextended(p_op_id::text, 0));

  select quantity_after into v_after
    from public.stock_changes where op_id = p_op_id;
  if found then
    return jsonb_build_object('status', 'duplicate', 'quantity', v_after);
  end if;

  update public.medications m
     set quantity = coalesce(
           v_set_to,
           greatest(0, least(999999, m.quantity::bigint + v_delta))::integer
         ),
         write_id = p_op_id
   where m.id = p_medication_id
     and m.deleted_at is null
  returning m.quantity, m.row_version into v_qty, v_version;

  if not found then
    return jsonb_build_object('status', 'gone');
  end if;

  insert into public.stock_changes (op_id, medication_id, delta, set_to, quantity_after)
    values (p_op_id, p_medication_id, v_delta, v_set_to, v_qty);

  return jsonb_build_object(
    'status', 'applied', 'quantity', v_qty, 'row_version', v_version
  );
end;
$$;

revoke all on function public.apply_stock_change(uuid, text, integer, integer) from public, anon;
grant execute on function public.apply_stock_change(uuid, text, integer, integer) to authenticated;

-- 7. Live rows under deleted parents ---------------------------------------
--
-- Before this migration a device could leave a live child under a parent
-- deleted elsewhere (a dose generated offline, pushed after the
-- prescription was deleted). Every device would fail to store such a row.
-- They are deleted here as the app's own change (the trigger above keeps
-- it so from now on): prescriptions first, whose own tombstones cascade
-- to their doses, then the doses left. The rows updated here keep their
-- updated_at, like any other change the app makes; 0.3.0 devices already
-- dropped them with their parent. The doses the cascade reaches from a
-- prescription repaired here are a cascade write, which moves updated_at
-- (0.3.0 then pulls a tombstone for a row it no longer holds, which does
-- nothing). Running this again finds nothing.

update public.prescriptions c
   set deleted_at = coalesce(t.deleted_at, m.deleted_at),
       write_id = gen_random_uuid(),
       edited_at = timestamptz '1970-01-01 00:00:00+00'
  from public.treatments t, public.medications m
 where t.id = c.treatment_id
   and m.id = c.medication_id
   and c.deleted_at is null
   and (t.deleted_at is not null or m.deleted_at is not null);

update public.dose_logs c
   set deleted_at = p.deleted_at,
       write_id = gen_random_uuid(),
       edited_at = timestamptz '1970-01-01 00:00:00+00'
  from public.prescriptions p
 where p.id = c.prescription_id
   and c.deleted_at is null
   and p.deleted_at is not null;

-- 8. "Delete all data" -----------------------------------------------------
--
-- Removes every medication, treatment, prescription and dose of the caller,
-- and records the wipe (section 2b) in the same transaction, so every other
-- device of the account removes its copies on its next sync instead of
-- keeping them (and writing them back with a later edit). Returns
-- {"generation": g, "wiped_at": t}.
--
-- Runs with the owner's rights, so it can write the marker, which clients
-- cannot; every delete names the caller's rows exactly as the tables'
-- delete policies do (prescriptions and doses through the caller's
-- treatments). The stock ledger goes with the medications (foreign key).
-- The exclusive lock makes the caller's inserts wait for the wipe, or the
-- wipe for them (medora_sync_stamp takes the shared side), so a row
-- inserted meanwhile is either deleted here or sees this wipe.
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
  delete from public.medications where user_id = v_uid;
  return jsonb_build_object('generation', v_generation, 'wiped_at', v_at);
end;
$$;

revoke all on function public.medora_delete_all_data() from public, anon;
grant execute on function public.medora_delete_all_data() to authenticated;
```

**Notes on the SQL:**

- **Backfill: none, deliberately.**
  - Constant defaults make each `ADD COLUMN` metadata-only in Postgres 11+. No row is rewritten and no trigger fires, so no `updated_at` moves and no 0.3.0 device finds its pending edit stale.
  - Rows from before the migration carry `sync_xid = 0`, `row_version = 1`, `edited_at = NULL` and `field_edited_at = '{}'`. The client reads a missing `edited_at` as `updated_at`, and an empty map as that time for every column.
  - The map is filled lazily: the first update of such a row writes an entry for every column (the old time for the columns it does not change). That costs one small `jsonb` per row touched, and nothing for rows never touched again.
  - The first 0.4.0 pull of each table starts from the beginning (§7.7), so `sync_xid = 0` rows arrive.
- **Row-level security.**
  - The four data tables keep their policies; a column is not a row.
  - `stock_changes` follows the medication: the policy subquery runs under the caller's own `medications` policies. Today that means the owner. If family access to medications is ever added, the ledger follows with no change.
  - There is no update or delete policy, so the ledger is append-only for clients.
  - Supabase's default privileges grant `anon` EXECUTE on new functions, so both functions revoke it explicitly. The check script verifies this.
  - Supabase also grants `anon` and `authenticated` TRUNCATE, TRIGGER and REFERENCES on every table, and RLS does not cover TRUNCATE. The migration takes these away on the four data tables, the two family tables and the ledger. SELECT, INSERT, UPDATE and DELETE stay under the policies, so 0.3.0 and "delete all data" keep working. The trigger functions are not executable by clients (a trigger does not need EXECUTE).
- **Stock values out of range** are brought into range before anything else (`set_to` to 0…999999, `delta` to −999999…999999, the sum computed as `bigint`), and the ledger records those values. A change is never refused for good.
- **A medication that is gone.** `apply_stock_change` answers `gone` whenever the caller has no live medication with that id: deleted, removed from the server (its ledger rows cascade with it), never created, or another user's. There is no `missing`: a client sends a change only after the medication's create reached the server (§7.5), so "not there" always means "removed".
- **Locks.** `set local lock_timeout = '5s'` makes the migration give up instead of queueing every API request behind an `ALTER TABLE` that waits for a long transaction. Retry it.
- **After this migration** never run `20260901000000_initial_schema.sql` again (it would restore the old `update_updated_at()`), and do not enable read replicas (a page could come from a replica that has not yet replayed rows below the primary's horizon).
- **Locks.** `CREATE INDEX` without `CONCURRENTLY` blocks writes to that table while it builds. That takes milliseconds at household sizes, and `CONCURRENTLY` cannot run inside the CLI's migration transaction.
- **Edit times per column.** The trigger compares `to_jsonb(new)` with `to_jsonb(old)`, so it needs no list of each table's columns; a column a later migration adds gets entries from its first change on. A malformed `at` in a sent map fails the write (SQLSTATE 22007); only the app writes the map.
- **Rows under a deleted parent** (§4.6). The trigger looks the parents up with the caller's rights: the insert and update policies already require the caller to see them. It reads them `FOR SHARE`, held until the write commits (review I-3): a parent's delete takes `FOR NO KEY UPDATE`, so it waits for a child being written and its cascade then sees that child, and a child written while the delete is open waits and then sees the parent deleted. The foreign key's own `FOR KEY SHARE` does not conflict with a delete, so without this the two passed each other and left a live child. `FOR SHARE` needs the UPDATE right and policy on the parent, which its owner has. A batch that writes children of two parents while another request deletes both can deadlock; Postgres aborts one of them (40P01) and the device retries it after its backoff. It tells the tombstone cascade from every other writer by `pg_trigger_depth() > 1` (the cascade's update runs inside another trigger; `apply_stock_change` is a function, not a trigger). The app's own delete is marked by setting `edited_at` to 1970 after the column times are stamped, so the columns a write changes keep that write's time. The one-time repair (section 7) is the only UPDATE in the migration: it touches only live rows under deleted parents, which no device can store anyway, and keeps their `updated_at` (0.3.0 dropped them with their parent). The doses its cascade reaches from a repaired prescription are a cascade write and get a new `updated_at`; 0.3.0 then pulls a tombstone for a row it no longer holds, which does nothing (review Minor 2).
- **A 0.3.0 take of a dropped dose** (§4.6). Only a legacy write (no new write id) that does not set `deleted_at` itself, on a row whose tombstone is the app's own, and that changes `status` to `taken` or `skipped`, clears `deleted_at`. The trigger reads `status` through `to_jsonb`, so the one function serves every table.
- **Trigger order.** Postgres runs `BEFORE` triggers of one event in name order. `<table>_sync_stamp` sorts before `<table>_updated_at`, and `update_updated_at()` reads the `write_id` and `edited_at` the stamp trigger has just settled.
- **The wipe marker** (sections 2b and 8, §7.9). `sync_wipes` is readable by its owner only and written only by `medora_delete_all_data()`, which runs with the owner's rights and names the caller's rows exactly as the delete policies do. The stamp trigger reads the marker with the caller's rights, for inserts only, under the shared side of the caller's wipe lock (`hashtextextended('medora-wipe:' || uid)`, an advisory lock, which needs no table rights). A trigger function is volatile, so its read after the lock wait sees a wipe that committed meanwhile.
- **No down migration.** Every change is additive, and 0.3.0 runs against it (§9.2). Rolling the app back does not need the schema rolled back.

## 6. Local schema v16

`lib/data/local/migrations.dart`, appended as `Migration(16, …)`; `kSchemaVersion = 16`.

```sql
-- for each of medications, treatments, prescriptions, dose_logs:
ALTER TABLE <t> ADD COLUMN edited_at TEXT;       -- when the row's last change was made here (UTC ISO); 1970 = automatic
ALTER TABLE <t> ADD COLUMN field_edited_at TEXT; -- JSON: column -> {at, auto} (§4.4); NULL = edited_at for every column
ALTER TABLE <t> ADD COLUMN sync_version INTEGER; -- server row_version the base belongs to; NULL = unknown
ALTER TABLE <t> ADD COLUMN sync_base TEXT;       -- JSON: canonical wire copy of that server row, with its column times under "@field_edited_at"
ALTER TABLE <t> ADD COLUMN sync_write_id TEXT;   -- write attempt whose outcome is unknown
-- then, in Dart, for rows that are not synced: edited_at = updated_at read
-- as an instant in this zone, capped at now (lib/data/local/migrations.dart)

ALTER TABLE dose_logs ADD COLUMN delete_guard TEXT;  -- 'if_pending' for an automatic delete

CREATE TABLE stock_outbox (
  seq INTEGER PRIMARY KEY AUTOINCREMENT,  -- the order the changes were made in
  op_id TEXT NOT NULL UNIQUE,
  medication_id TEXT NOT NULL REFERENCES medications(id) ON DELETE CASCADE,
  delta INTEGER,
  set_to INTEGER,
  created_at TEXT NOT NULL,
  CHECK ((delta IS NULL) <> (set_to IS NULL))
);
CREATE INDEX idx_local_stock_outbox_med ON stock_outbox(medication_id, seq);
```

**Every local write path stamps `edited_at`:**

- a pending upsert writes `edited_at = updated_at` of the model it stores, never later than the clock;
- `_editRow`, `_setActive`, `updateStatus` and `markDeleted` stamp the same instant they write to `updated_at` (`markDeleted` uses now);
- generated inserts use 1970;
- the automatic changes of §4.7 use 1970;
- every time is UTC text.

**Every local write path stamps `field_edited_at`** for exactly the columns it changes (§4.4):

- a pending upsert compares the stored row with the new one; a new row stores none;
- `_editRow` (archive, stock), `_setActive` and `updateStatus` stamp their own columns; the stock never gets an entry;
- the overdue sweep stamps `status` as automatic, and leaves `edited_at` alone;
- a synced write (a pull) stores the server's map;
- `markDeleted` changes no column that has a time, so it leaves the map alone. A row waiting for its delete never merges (§7.2).

**Pull writes.** A pull stores the server's `edited_at`, `field_edited_at`, `row_version` and canonical wire copy. The base keeps the server's column times (and the row time that stands for them while the map is empty) under the key `@field_edited_at`, which no column has; `LocalSyncMeta` reads them as `baseTimes`. A base stored without them counts changed values only.

**Backups.**

- **Export** leaves out `sync_status`, `sync_version`, `sync_base`, `sync_write_id` and `delete_guard`, and keeps `edited_at` and `field_edited_at`.
- **Restore** writes the meta columns as NULL, and the backup's `edited_at` and `field_edited_at` (NULL for a 0.3.0 backup, whose `updated_at` then stands for every column). In cloud mode it marks rows `pending_update` as before; with no base, the merge goes by edit time. A restored generated or auto-missed row therefore keeps its 1970 edit time and loses to real changes elsewhere (sick-branch m-2).
- **Merge restore** compares parsed instants, not strings (m-13).
- **Cloud restore** also queues a `set_to` for each restored medication.
- **A v15 backup** restores into v16 (the missing columns are NULL).
- **A v16 backup** is refused by 0.3.0 as "newer schema", as before.

**Other touch points:**

- `LocalUploadMarker.markAllForUpload` also clears `sync_version`, `sync_base` and `sync_write_id`, because the rows belong to a new account. The next cycle reads their server copies in bulk (§7.3).
- `AppDatabase.clearAllData` and `LocalDataWiper` also clear `stock_outbox`. `LocalDataWiper` also removes the recorded wipe generation (§7.9).
- `TreatmentRepositoryImpl.updateTreatment` refuses a row that is `pending_delete`, as the medication repository already does.

## 7. The client algorithm

### 7.1 One cycle (`SyncService._syncAll`)

1. `state = await syncStateRemote.read()` → `(schema, horizon, wipe)`.
   - A missing function or `schema < 2` throws `MissingMigrationException` (§8).
   - The cycle ends before any write.
   - A newer "delete all data" than this device applied removes what it holds from before it (§7.9), before anything is sent.
2. `repairing = await cursors.startPullRepair()` (version 2, §7.7).
3. **Push**, in foreign-key order:
   - families (unchanged);
   - medication rows;
   - the stock outbox;
   - treatments;
   - prescriptions;
   - new dose logs (batched);
   - the app's own dose changes (in bulk: dropped doses, then overdue doses marked missed);
   - the other dose logs.

   Before a table's rows go out, the rows that need a server copy first are read in bulk (§7.3).
4. **Pull** every table with `horizon` (§7.2).
5. If `repairing` and every table was fetched, `finishPullRepair()`.

`SyncService` gains two constructor parameters:

- `syncState` (`SyncStateRemoteDatasource?`, part of `isAvailable`);
- `stockOutbox` (`StockOutboxLocalDatasource`).

It also gains `newWriteId`, which defaults to `const Uuid().v4()`; tests inject a counter.

### 7.2 Pull and merge (`lib/data/sync/table_sync.dart`, `applyPulledRow`)

**Paging.** For each table, pages come from `after = cursors.pullKey(table)` up to `horizon`.

- The key is stored after every fully applied page, as the last row's `(sync_xid, id)`.
- Only an **empty** page ends the table, and the key `(horizon, null)` is stored (`afterPullPage` in `sync_page.dart`). A short page is not the end: the project's "Max rows" setting may be below 1000, and PostgREST does not say it cut an answer short. This costs one request per table per cycle.
- A row that fails to apply holds the key where it was for the rest of the cycle, as today.
- A live row whose parent this device does not hold is not a failure (`orphaned`, §4.6): the cycle fetches each missing parent; a live one is stored first (up to the treatment and medication above a dose), then the row again. A parent the server lacks or holds deleted means the row can never be stored: it is passed over, and the key moves on.
- A stored key above the horizon resets that table to a full pull.

**Per incoming row R** (canonical wire `W`, meta `M`), inside one local transaction:

| Local row L | Action |
|---|---|
| R live, and a parent it names is `pending_delete` here | delete L if there is one (the parent's delete wins) |
| R live, and a parent it names is not here | nothing; `orphaned` (see above) |
| none, and R is a tombstone | nothing |
| none | insert R as `synced`, base = W (with R's column times), version = M.rowVersion, `edited_at` = M.editedAt, `field_edited_at` = R's map |
| any, and R is a tombstone that does not lose (below) | hard-delete L (its outbox rows and its children cascade) |
| `pending_delete` with `delete_guard = if_pending`, and R is not pending | replace with R as `synced`, unless L carries a person's undo that beats R's status (§4.6): then keep L, and the push sends the undo and the drop |
| `pending_delete` otherwise | keep L (a delete wins) |
| `synced` | if M.rowVersion > L.version (or L.version is null): replace with R as `synced`, base = W; otherwise keep L |
| pending, and M.writeId = L.sync_write_id | own write: base = W, version = M.rowVersion, write id cleared; `synced` if L equals W in content, else stays `pending_update`, with R's column times for the columns L shares with W |
| pending, and M.rowVersion ≤ L.version | ignore (already merged) |
| pending, otherwise (including a dose tombstone that loses, below) | `mergeRows(base, L, W)` with both sides' column times and the base's → store as `pending_update` with base = W, version = M.rowVersion and the merged times, or as `synced` (with R's map) if the result equals W; count conflicts in `report.overwritten` |

A tombstone **loses** only when all of these hold (§4.6): the table is `dose_logs`; R's `edited_at` is 1970; L is pending; R does not carry L's `sync_write_id`; L has a person's changed value, or L is `pending_create` with a `created_at` after R's `deleted_at` (or none); and L's prescription is here and not `pending_delete`.

- **Synced rows** (replaced) store R's map, as they store R's `edited_at`.
- **Medications:** the stored quantity is `localStock(W.quantity, W.write_id, outbox ops)` (§4.8).
- **Prescriptions:** the new/changed tracking for `onPrescriptionsPulled` is unchanged.

### 7.3 Push (`TableSync.pushRow`)

Skipped: rows in backoff, doses of a refused prescription (`pending_create` **or** `pending_update` with a failure record; sick-branch m-3), and the stock ops of a medication with no known server version (§7.5).

Dropped: a prescription or dose whose parent is `pending_delete` here (its delete failed or waits for its backoff) is deleted here and never sent, before any other check, in the batch of new doses too (§4.6).

**First, resolve an unknown outcome.** If L has `sync_write_id`, fetch R.

- If R's write id equals it: adopt R as the base, then continue with whatever still differs, or settle as `synced`.
- Otherwise: clear the id and continue.

**Read in bulk first (cycle review I-4).** Before a table's pending rows go out, the cycle reads, 100 ids per request (`fetchMany`), every `pending_create` or `pending_update` row that has a `sync_write_id`, and every `pending_update` row with no known version (a sign-in marks every row so, and an upgrade leaves 0.3.0's pending rows so). Each copy is applied as the steps below would one by one: its own write is adopted, a write id the copy does not carry is cleared, a copy is merged into a row with no base. An update the server lacks becomes `pending_create` (meta cleared), so a dose joins the batch of new doses and any other row is inserted without a second read. Doses are read before the batch of new doses. A row whose read failed is backed off for this cycle. Signing in again with a year of doses (730 per prescription) costs one read per 100 rows and one pull, not one read per row.

**Then, by status:**

- **`pending_create`** (non-dose tables): insert-if-absent the full wire row plus `user_id`, `write_id`, `edited_at` and the local `field_edited_at` (empty when no column changed since the row was made), then fetch it.
  - Our write id: settle (§7.4). A copy the server stored deleted (its parent is deleted there) is deleted here.
  - Another copy: merge with no base, store it as `pending_update` with base = R, and retry once. When that copy is the app's own tombstone of a dose and the local row is a slot generated after it, the merge brings it back and the retry sends `deleted_at: null` with the automatic edit time (§4.6).
  - No row: failure with backoff.
- **`pending_create` doses:** the existing batch path (100 per request, row-by-row fallback, read-back), now with a write id and `edited_at` per row, adopted through §7.4. The rows are read once, before the first batch goes out, so each batch is stamped in one transaction that stores the write id only where the row is still `pending_create` and reads the row again: a row deleted since (a schedule changed while an earlier batch was on its way drops the doses no server has seen at once) is left out, and every other row is sent as it is now (cycle review I-1).
- **`pending_update`:**
  1. If base is null: fetch R. If there is no row, go through the create path. Otherwise merge with no base and take R as the base.
  2. `changes = changedColumns(base, L)`, with the local and the base's column times (a change back to the base's value is sent). If empty, settle as `synced`.
  3. `PATCH changes + {write_id, edited_at, field_edited_at}` if `row_version = version`.
     - `field_edited_at` holds the local time of each sent column that has one.
     - `edited_at` is the latest person's time among them; `1970` when all of them are automatic and every one has a known time; otherwise `L.edited_at ?? L.updated_at` (a column of unknown time is never sent as the app's own change).
  4. If a row came back, settle.
  5. If none came back: fetch R. Our write id: settle with R. No row: create path. Otherwise merge, store, and repeat from step 2 once. After the second failure, leave the row pending and request a re-run.
- **`pending_delete`:** §4.6.

**Force push:** every row is sent as `PATCH` of every column with no version condition, a fresh write id and `edited_at = now`. A row the server lacks is inserted. Every medication quantity is queued as `set_to` before the rows go out (settling a row shows the server's stock plus the waiting changes, so the count must be read first); the counts drain after the medication rows, behind any change already waiting. A force patch never names `quantity`. Parents go first, so their children are brought back under live parents; a child the server still stores deleted (its parent's own force push failed) fails and stays as it is here.

### 7.4 Settle (`lib/data/sync/row_settle.dart`, which replaces `push_settle.dart`)

`settlePushedRow(db, table, pushed: row, server: json, newOpId: …)` runs in one transaction and returns whether the row still has changes to push:

- **Local `updated_at` still equals the value the push read:**
  - `sync_status = synced`;
  - base = canonical(server), version = server.rowVersion, `sync_write_id = NULL`;
  - `updated_at`, `edited_at` and `field_edited_at` = the server's (its times are the capped ones, and a backup carries them into a later restore).
- **The server stored it deleted** (a parent is deleted there, §4.6): the local row is deleted.
- **It changed** (an edit landed in flight):
  - base, version and write id as above;
  - status stays `pending_update`, and the next push sends only the newer difference;
  - the columns it shares with the server copy take the server's (capped) times, so a clock ahead does not make them look changed since the base.
  - A medication keeps its own quantity: a change made in flight waits in the outbox. (No difference is queued here; see §4.8.)
- **Row gone, or `pending_delete`:** left alone. A `pending_delete` still returns "still pending".

### 7.5 Draining the stock outbox

For each op, oldest first:

- **Skip** (counted as waiting) when the medication has no known server version yet (its create has not settled), when the op is in its backoff window, or when an earlier op of the same medication failed this cycle.
- Otherwise call `apply_stock_change`.
- **`applied` or `duplicate`:** delete the op. For `applied`, set the local quantity to `applyStockOps(result.quantity, remaining ops)`, and move the base forward when `result.rowVersion == version + 1`.
- **`gone`:** delete the op. It is final: the medication is deleted or was removed from the server, and its ledger went with it, so a retry would never apply either.
- **An error:** keep the op, record a failure with backoff (table `stock_outbox`, id = op id), and stop draining that medication for this cycle, so the order is kept.
- **A medication the create path inserts** (a new one, one restored or re-marked with no server copy, or one re-created after it was removed from the server): its insert carries the local quantity, which already includes the waiting ops, so they leave the outbox in the transaction that stores the insert's write id. Dropping them only once the insert settles would count them twice when the answer is lost and the write is found again on the next cycle. If the insert still never lands, the next attempt carries the same quantity. If the server turns out to hold another copy (the insert was ignored), the ops go back to the outbox with their old `seq` and apply to that copy.
- **`discardFailedRow('stock_outbox', opId)`** fetches the medication, drops the op, and shows the server's quantity with the other waiting ops on top (the local quantity held the dropped change). A fetch that fails keeps the op.

### 7.6 Force pull and discard

- **Force pull:** clears the cursors (both key families), the failure store, local data and the outbox, then pulls everything with meta and records the repair as done.
- **`discardFailedRow`:** fetches the server row and stores it with meta (base, version, `edited_at`), clearing `sync_write_id`, or deletes the local row. Deleting the local row takes its children with it, and a pull may have passed over children of a parent that was being deleted here, so discarding a medication, treatment or prescription also resets the pull keys of the tables below it: the next cycle pulls them again from the start.

### 7.7 The one-time repair, version 2

- `SyncCursorStore.pullRepairVersion = 2`.
- **Upgraded device:** the repair clears the old `sync.last_pull_at.*` keys and the new `sync.pull_key.*` keys, so the first 0.4.0 cycle pulls every table from the start. That stores base, version and `edited_at` for every row, and brings every generated dose and every row an old cursor skipped.
- **Fresh install:** no cursor, so it is marked done at once, as in version 1.
- **Force pull:** records the repair as done (cursor-reset concern 6).

### 7.8 Report

`SyncReport` changes:

- **Added:** `int merged` (rows merged on pull or push), `List<SyncOverwrite> overwritten` (`table`, `id`, `columns`, `keptLocal`), `String? missingMigration`, and `int wiped` (rows removed because of a "delete all data" made elsewhere, §7.9).
- **Removed:** `skippedStale`.
- **Log line:** `merged` and `overwritten` are added to the debug line.

### 7.9 "Delete all data" reaches every device

**Before:** the settings dialog hard-deleted the server rows. Another phone kept its synced copies (a removed row leaves nothing to pull), and a later edit there sent them back as new rows (controller decision: the data must be gone everywhere).

**Server** (§5, sections 2b and 8):
- `sync_wipes(user_id, generation, wiped_at)`: one row per user who used "delete all data". Row-level security lets a user read their own row; no client may write it.
- `medora_delete_all_data()` (security definer, callable by `authenticated`): in one transaction, takes the user's wipe lock, moves the marker (`generation + 1`, `wiped_at = now()`), and deletes the user's doses, prescriptions (through the user's treatments, as the delete policies name them), treatments and medications; the ledger goes with the medications. It answers `{generation, wiped_at}`.
- `medora_sync_state()` also answers `wipe: {generation, wiped_at}` (or `null`), so reading it costs no extra request.
- **The moment around the wipe.** A device may read the sync state just before the wipe and push just after it. So every 0.4.0 insert carries, under the key `@wipe` in its `field_edited_at` (a key no column has; the trigger keeps no entry for it), the wipe generation its device has applied. An insert whose `@wipe` is older than the user's generation, of a row a person last changed at or before `wiped_at` (`edited_at`; the app's own 1970 rows are left to their parents), is stored deleted, as that person's delete (`deleted_at = edited_at = wiped_at`). The device settles it as deleted, and its next cycle removes the rest. Every insert takes the shared side of the user's wipe lock (`pg_advisory_xact_lock_shared`), and the wipe the exclusive side, so an insert either lands before the wipe (and is deleted by it) or sees it. `tools/check_supabase_sql.sh` runs both orders in two sessions.

**Device** (`SyncService._followRemoteWipe`, `lib/data/sync/remote_wipe.dart`), at the start of every cycle, before anything is sent:
- `SyncCursorStore.wipeSeen(userId)` holds the generation this device applied for the signed-in account (`sync.wipe_seen` = `<user id>|<generation>`; `clear()` keeps it, `LocalDataWiper` removes it).
- **A newer generation:** `removeDataFromBefore(wiped_at)` deletes every medication, treatment, prescription and dose whose `created_at` is not after `wiped_at`, in any sync state: synced copies, and changes still waiting, which belong to rows the person deleted everywhere ("nothing pending from before the wipe"). Children go with their parents and stock changes with their medication (local foreign keys). A row created after the wipe stays with its sync state: it is new data (a medication added offline after the wipe is uploaded). Families stay: "delete all data" never touched them. Then every pull key and backoff record is dropped, the generation is recorded, and the cycle goes on (a full pull brings whatever the server holds). `onRemoteWipe` gets the photo names no remaining medication uses; the app deletes those files. The lists and reminders refresh when the cycle ends, as after every sync (`_afterSync` reconciles the reminders, so a removed dose's reminder is cancelled).
- **No generation recorded for this account** (a fresh install, a sign-in, a device wiped itself, another account): the generation is recorded and nothing is removed: the data here is the person's to upload, and its inserts then carry the current generation, so an old wipe never deletes it. **Exception:** a device that still holds a Medora 0.3.0 pull cursor (`sync.last_pull_at.*`) synced before this build and may hold rows from before the wipe; it follows the wipe like any other.
- **A lower generation than recorded** (a restored project): recorded, nothing removed.
- **Force pull** records the generation after it cleared the device. **Force push** records it without removing anything and sends its rows as data written now: "my copy is the truth" holds against a wipe too, and restores the device's rows everywhere (a way back from a wipe made by mistake).
- "After the wipe" is judged by the device's `created_at` against the server's `wiped_at`, so a row made within the device clock's error of the wipe can land on the wrong side.
- The wiping device calls the function, then wipes itself (`LocalDataWiper`), which removes its recorded generation; its next cycle records the new one. A project without sync v2 has no function: the dialog then deletes the tables as before (`AccountDataRemoteDatasource`).

**Medora 0.3.0 against a wipe.** A 0.3.0 device cannot read the marker:
- it keeps its local copies; its pulls by `updated_at` see nothing of the purge;
- an edit it makes to one of those rows is a whole-row upsert, which inserts the row again (with the columns 0.3.0 sends, `created_at` set on arrival); a dose it takes or generates under a purged prescription fails the foreign key and stays pending there;
- **decision: the server treats a 0.3.0 write after a wipe as new data** and stores it live. 0.4.0 devices pull it like any other new row, and never remove it again: they remove rows only when the generation moves, before they pull. Refusing such writes (or storing them deleted) was rejected: the server cannot tell a stale re-upload from a deliberate edit, or from old local data a person merges when signing in on 0.3.0 (0.3.0 sends no write id and no creation time, and its `updated_at` is the local edit time, which can be months old for legitimate data), so a refusal would block or delete data the person wants. It is the same limit 0.3.0 has with every change it has not seen (§9.2); pinned in `multi_device_wipe_sync_test`;
- when that device updates to 0.4.0, its first cycle finds the 0.3.0 cursor and the newer generation, removes its rows from before the wipe, and pulls what the server holds (including anything a 0.3.0 device wrote back).

## 8. A project without the migration

- **How the client knows.** `SyncStateRemoteDatasource.read()` calls `rpc('medora_sync_state')`. PostgREST answers `PGRST202` when the function is not in its schema cache, and Postgres answers `42883` when it does not exist. Both, and a `schema` below 2, become a `MissingMigrationException(migration: 'supabase/migrations/20260918000000_sync_v2.sql', cause)`, which sits next to `MissingColumnException` in `lib/data/datasources/schema_errors.dart`. Its `toString()` follows the existing format: *"The Supabase project is missing the sync v2 migration. Apply supabase/migrations/20260918000000_sync_v2.sql to the project, then sync again (server: …)."*
- **What the cycle does.**
  - Nothing is pushed or pulled; pending rows stay pending.
  - `report.fatal` holds the text and `report.missingMigration` the file.
  - The state is `error`, so the chip shows "Sync error".
- **What Settings shows.** Settings → Cloud sync shows, under the last-sync line, one line in the error colour: `syncNeedsMigration(file)`.
  - en: *"The cloud project needs an update: apply {file}"*
  - de: *"Das Cloud-Projekt braucht ein Update: {file} anwenden"*
  - it: *"Il progetto cloud va aggiornato: applica {file}"*
- **When it recovers.** The next cycle, on any trigger, checks again, and syncing resumes once the file is applied.

## 9. Rollout and older builds

### 9.1 Order

1. **Apply the migration** to the Supabase project: in the SQL editor, or with `supabase db push`. Devices on 0.3.0 keep syncing during and after it, with no downtime and no rewrite.
2. **Update the devices**, in any order. Each 0.4.0 device's first cycle is the repair pull: one full download, which the release note mentions.
3. **Until the last device is updated**, 0.3.0 writes are accepted with the limits in §9.2. The release note says to update every device.
4. **Nothing to clean up afterwards.** A later release can drop 0.3.0 compatibility (the `updated_at` rules) only by a new migration.

### 9.2 Medora 0.3.0 against the migrated server (it keeps working)

| 0.3.0 does | Against the migrated server |
|---|---|
| Upserts whole rows (`toJson` keys only) | Accepted; there are no new required keys. The row gets `row_version + 1` (so `sync_xid` moves and 0.4.0 pulls it), `write_id = NULL` and `edited_at = now()`. **In `field_edited_at`, only the columns whose value it really changes are stamped**, with its arrival time, as a person's change. The columns it sends unchanged keep their entries; on its first update of a row with an empty map they get the row's old time. A 0.4.0 device merges it column by column, as edits made on arrival. |
| `select('updated_at')` after the upsert | Unchanged. A real update gets `now()`. An insert now also gets `now()`, so its create re-send simply does not fire. |
| Pulls by `updated_at` | Sees every real change a 0.4.0 device makes. Does **not** see automatic changes (missed, time corrections, dropped slots): it computes "missed" itself and drops off-schedule pending doses locally, so its view matches. |
| Skips an edit when the server `updated_at` is newer | Unchanged for real edits. Automatic changes keep `updated_at`, so they never make a 0.3.0 edit look stale. |
| Pushes stock as an absolute `quantity` | A 0.3.0 stock change (and any 0.3.0 row write, a rename included) is a whole-row upsert carrying the quantity it computed from the copy it last pulled. Its stale check skips it only when the server's `updated_at` is newer than its own edit; otherwise the server stores that number as it is (no ledger row, no edit time for `quantity`, `write_id` NULL), replacing whatever the ledger applied since that 0.3.0 device last pulled. A 0.4.0 change that reaches the server after it applies on top of it (arrival order). 0.4.0 devices pull the row (its `row_version` moved) and show the server's quantity plus their own waiting changes, so every 0.4.0 device converges on the server's number. **Known limitation until every device is updated:** doses logged on 0.4.0 devices between the 0.3.0 device's last pull and its write are lost (pinned in `multi_device_stock_sync_test`). |
| Inserts new doses if absent, then reads them back | Unchanged. Generated rows keep 1970 and get `edited_at = 1970`. |
| Takes a dose whose time a 0.4.0 device corrected | Its whole-row upsert sends the shifted time back. The take wins as a real edit. The correction is not retried, because the row is no longer pending. |
| Takes (or skips) a dose a 0.4.0 device dropped from its schedule | 0.3.0 never saw the drop. Its upsert brings the dose back as a person's change, so the take reaches every device (§4.6). A 0.3.0 write that leaves the status alone, or sets its own "missed", leaves the dose deleted, still as the app's own delete. |
| Writes a dose or prescription under a parent deleted elsewhere | Accepted, and stored deleted (§4.6); `updated_at` moves, so 0.3.0 pulls the tombstone and drops its copy. |
| Sends a whole row it last pulled before a 0.4.0 device changed a column | Its stale value for that column is a real change on the server: it overwrites the newer 0.4.0 edit and is stamped with its arrival time, as the newest person's change. v1 behaved the same; the server cannot tell a stale value from a new one. |
| Restores a backup whose `updated_at` falls in the repeated autumn hour | The wall-clock stamp is read as the first of the two instants. The row can lose or win against a change made in that hour by up to one hour of difference. |
| Tombstone cascade | Children are deleted as the app's own change (`edited_at` 1970, no write id), and `updated_at` still moves, so 0.3.0 pulls them as before. `deleted_at` has no edit time, so the cascade adds no entry (it only fills an empty map). |
| Holds data another device deleted with "delete all data" | It cannot see the wipe marker and keeps its copies. An edit of such a row inserts it again, and the server keeps it as new data; 0.4.0 devices show it (§7.9). Its takes under a removed prescription fail the foreign key. On update to 0.4.0 it removes its rows from before the wipe. |

**Medora 0.2.5 and older** are outside this table. The v0.3.0 notes already said to update every device.

### 9.3 Medora 0.4.0 against a project without the migration

It stops syncing with the message in §8. It loses nothing and writes nothing.

### 9.4 Release note (hand-written part)

> **Before you update (cloud sync only):** apply `supabase/migrations/20260918000000_sync_v2.sql` to your Supabase project. Devices still on 0.3.0 keep syncing with it. Without it, 0.4.0 stops syncing and Settings names the file.
>
> **New: a settings button on every main screen.** Dashboard, Medicines, Treatments and Doses now have the gear at the top right.
>
> **Sync keeps both changes.**
> - Changes to different fields of the same entry on two devices are both kept. For example, ending an illness on one phone and adding the certificate number on the other.
> - If the same field was changed on both, the change made later wins.
> - A dose taken on one device is never undone by another device marking it missed.
> - Stock changes from several devices all count, and a lost connection never counts one twice.
> - Doses saved at a shifted time by older versions move back to the right time, and doses removed from a changed schedule disappear everywhere.
>
> **Update every device you sync.** Until the last one is on 0.4.0, stock changed on an older device can still replace a change from a newer one.
>
> **The first sync after this update downloads all your data once more.** Your unsynced changes are kept.
>
> **"Delete all data" now deletes on every device** that syncs with 0.4.0: each removes its copies on its next sync. A device still on 0.3.0 keeps them, and an edit there brings that entry back.
>
> **Deleting a prescription removes its dose history on every device**, including doses taken on another phone that had not synced yet.

## 10. Settings gear

- **Widget.** `SettingsAction` in `lib/presentation/widgets/settings_action.dart`. It is a `StatefulWidget` that builds one `IconButton` with:
  - `key: SettingsAction.buttonKey`;
  - `icon: Icon(Icons.settings)`, the icon the dashboard uses today, so the Home goldens stay byte-identical;
  - `tooltip: l10n.settings` ("Settings" / "Einstellungen" / "Impostazioni"; the key already exists). The tooltip is also the screen-reader label.

  It pushes `AppRoutes.settings`, and ignores taps while its own push is open, so a double tap opens Settings once.
- **Placement.** It is the **last** entry of `AppBar.actions` on the four tab screens:
  - Home: scanner (on mobile), sync chip (in cloud mode), gear. The existing inline gear is replaced.
  - Medications: search/close, gear.
  - Treatments: search/close, gear.
  - Doses: history, gear.
- **Search mode.** The gear stays visible while a list is searching. The search is a filter, not a form, and the tab's state survives the push.
- **Where it does not appear:**
  - add and edit medication, add and edit treatment;
  - medication and treatment detail;
  - dose history, expiring medications, export, family, settings, auth, the unavailable screen;
  - the prescription, AIFA, supplement, onboarding and update sheets;
  - every dialog;
  - the scanner.
- **Layout.**
  - `IconButton` keeps the 48 × 48 dp touch target, and the icon does not grow with the text scale.
  - App-bar titles are single-line and ellipsised by `AppBar`, so a long title never pushes the gear off screen.
  - Tests check 360 dp at a 2.0 text scale in German (the longest labels) on all four tabs: no overflow, the gear fully on screen, and the gear right of every other action.
- **Goldens.**
  - `doses_light.png`, `doses_dark.png`, `doses_take_all_light.png` and `doses_take_all_dark.png` are re-recorded in Task 1, because the Doses app bar gains the gear.
  - `home_light.png` and `home_dark.png` must stay byte-identical.

## 11. Other included fixes

- **As-needed back to a schedule.** `prescription_sheet.dart` pre-fills `_durationController` with 7 when `existing.durationDays` is 0 or less.
- **Ongoing, lower case.** `EpisodeLabels.ongoing` reads `l10n.ongoingInline`: "ongoing" / "laufend" / "in corso". The status chip and the detail screen keep `ongoing`.
- **Failed End.** `confirmAndEndTreatment` catches the provider's exception, shows `SnackBar(content: Text(l10n.endTreatmentFailed))` and returns false.
  - en: *"Could not end the treatment"*
  - de: *"Die Behandlung konnte nicht beendet werden"*
  - it: *"Impossibile terminare il trattamento"*
- **Hidden rows on the dashboard.** `_LowStockCard` and `_ActiveTreatmentsCard` add the `moreCount(hidden)` row (icon `more_horiz`, chevron) when more than three rows exist. It opens the same tab as the section's "See all" (index 1 and 2). The golden fixture has fewer than four of each, so the Home PNGs do not change.

## 12. Testing

- **SQL.** `tools/check_supabase_sql.sh` runs every migration and `tools/sql/sync_v2_checks.sql` in a throwaway Postgres 15, plus the horizon race. A new CI job, `supabase-sql`, runs it with a `postgres:15` service container (`USE_DOCKER=0`).
- **Fake against SQL.** `test/helpers/fake_server_parity_test.dart` runs a script of 0.3.0 and 0.4.0 writes (inserts, updates, whole-row upserts, drops, cascades, children under deleted parents, a 0.3.0 take of a dropped dose) through the fake and writes the same writes, with the fake's answers, to `tools/sql/fake_server_parity.sql`. The SQL check runs that file against the migration: every step asserts `row_version`, the write id, `edited_at`, `updated_at`, the tombstone and the whole column map. A changed fake or script fails the Dart test until the file is written again (`MEDORA_WRITE_PARITY_SQL=1`); a changed migration fails the SQL check.
- **Fake server.** `test/helpers/fake_server.dart` holds one `FakeServerCore` that models the migration exactly:
  - every column of each synced table, with its default, on every row (the fill reads them all, as the trigger does); a write naming another column is refused (PGRST204); foreign keys are not checked;
  - children of deleted parents stored deleted, the cascade as the app's own change, and a 0.3.0 take bringing a dropped dose back;
  - a global xid counter;
  - open transactions that hold the horizon back;
  - `row_version`, the write-id rule, `edited_at` normalisation and capping;
  - the per-column map: sent entries for the changed columns only, the cap, the automatic flag, never going back, the fill, and legacy writes stamped on arrival;
  - the `updated_at` rules (automatic updates keep it, real inserts get `now()`);
  - guarded filters, bulk updates (`patchMany`, one transaction) and bulk reads (`fetchMany`, one request), hard deletes with their cascade, and the ledger with duplicate and gone;
  - `max_rows` = 1000 by default (`rowCap`); a test sets it to 250 to prove a pull ends only on an empty page.

  The Dart-level fakes (`FakeRemoteTable`, `Fake*Remote`, `FakeSyncState`) are thin views of it. They keep today's knobs (`failIds`, `throwOnFetch`, `beforeCall`, `rowCap`, `pageCalls`, `seed`, `upsert` as a 0.3.0 write).
- **Fake PostgREST.** `test/helpers/fake_postgrest.dart` serves the same core over HTTP (`MockClient`). It parses the requests the real datasources send:
  - `select`, `eq`, `gt`, `gte`, `lt`, `is`, `in`, `or` and `and`;
  - `order` and `limit`;
  - `Prefer: return=representation` and `resolution=ignore-duplicates`;
  - `/rpc/…`.

  Every Dart-level fake table, stock remote and sync-state fake can reach the core through the app's **real** remote datasources and this fake instead of by method call. The knobs keep working. `--dart-define=MEDORA_FAKE_TRANSPORT=http` makes that the default, so the whole suite runs a second time through the real request code (a third CI run). The two-device suites run over both transports in every run.
- **Two-device scenarios.** They start from realistic state:
  - both devices warmed up with history (a treatment made three days ago, a taken dose, pulled by both);
  - cursors past it;
  - stock already changed once.

  The plan lists them with exact expected values: S1a, S1b, PR5, stock from two devices, lost answers, time correction against a take, a dropped slot against a take, automatic missed against a take, and a 0.3.0 device in the fleet.

  `test/data/sync/edit_time_merge_test.dart` adds a third device for the per-column cases:
  - A/B/C in both sync orders, and a later note from C that still wins;
  - A/B/C across both daylight-saving changes;
  - a clock a day ahead and a clock two hours behind;
  - the app's missed against a person's take, and against a person's note;
  - a 0.3.0 write in between;
  - a row restored without a map;
  - an edit back to the old value, and an undone take;
  - deletes and the rows under them: a slot dropped and generated again (on either device, before or after the drop, and after a person's delete), a take and a generated dose under a prescription deleted elsewhere, a dose pulled under a prescription deleted here, a live orphan on the server, and a 0.3.0 take of a dropped dose. Each ends with a round that changes nothing on the server.

  `test/services/multi_device_stock_sync_test.dart` runs the stock through two phones with real repositories and cycles, each case ending with rounds that change nothing: a dose on each phone (both orders), a restock against a dose, a count against a dose (both arrival orders), a lost answer, a medication deleted or removed from the server ("delete all data") while a dose waits, a medication added and restocked offline (also with its insert answer lost), an undone dose, a phone that left cloud mode, a cloud restore, and a 0.3.0 phone's absolute quantity.

  `test/services/multi_device_wipe_sync_test.dart` runs "delete all data" on one phone against another with changes waiting (and one made after the wipe), a push in the moment after the wipe, a 0.3.0 phone writing an old row back, a phone upgraded from 0.3.0, a phone signing in after an old wipe, a force push after a wipe, a restored project, and the wiping phone itself; each ends with a quiet round.

  `test/services/sync_request_count_test.dart` counts the requests of a year of doses on two phones: signing in again (with a change made while signed out and a newer one from the other phone), a first sign-in with a year of local doses, the overdue sweep on both phones (a take made first on the other phone wins; the second phone writes nothing), an undo on the other phone against a sweep from an older copy, a schedule change that drops half a year, and upgrade day on two phones. Each ends with a quiet round that writes nothing.

  `test/services/multi_device_schedule_sync_test.dart` runs the same through the whole cycle: a schedule changed and changed back (doses and reminders on both devices), and a prescription deleted while the other device, offline, takes a dose or generates more.
- **Existing suites.** `multi_device_*`, `treatment_sync_test` and `sync_service_test` keep their behavioural expectations. Tests that pin removed v1 mechanics (the stale skip, the create re-send, the 1970 floor, the `updated_at` cursor) are replaced by their v2 equivalents, listed per task.
- **Whole suite.** It runs under `TZ=UTC` and `TZ=Europe/Rome`.
- **Integration.** `test/integration/sync_convergence_test.dart` gains the S1 and stock scenarios against a local `supabase start`. It runs in the manual `integration` CI job and is never pointed at a real project.

## 13. Out of scope

- Family access to data rows. The ledger policy is written so that it follows the medication policies if family access is ever added.
- A server-side purge of old tombstones and old ledger rows.
- A UI that lists overwritten same-field changes. They are counted and logged only; see Q1.
- Dropping 0.3.0 compatibility.
- The deferred minors in §2.2.

## 14. Open questions for the user

1. **Two devices change the same field: which change wins?**
   - (a) The change **made later on the device**. The device clock is trusted, but never beyond the moment the server received the change.
   - (b) The change that **reached the server later**, which is today's rule. Under it, a dose marked "missed" offline at 10:00 beats a take at 11:00 if the taking phone syncs first.

   **Recommendation: (a).** It matches what people expect, and a phone with a wrong clock can only win until the server receives the change. Choosing (b) changes one line of the trigger (`edited_at := now()` always) and nothing else.

2. **A cloud project where the migration has not been applied yet: what should 0.4.0 do?**
   - (a) **Stop syncing** and name the file in Settings. Nothing is lost; changes wait on the device.
   - (b) **Keep syncing the old way** until the file is applied.

   **Recommendation: (a).** Option (b) keeps every known data loss this release fixes, and doubles the sync code and its tests. The migration is one file, and older phones keep working with it.

3. **A counted quantity typed in the medicine form while another phone logs a dose at about the same time: what is the result?**
   - (a) **Apply the changes in the order the server receives them.** Typing 20 and then receiving the other phone's −1 gives 19, even if that dose was taken before the pills were counted.
   - (b) **The count wins over every dose logged before it was typed**, judged by device clocks.

   **Recommendation: (a).** It is predictable, it needs no clock, and the difference is at most the doses logged in the minute around the count.
