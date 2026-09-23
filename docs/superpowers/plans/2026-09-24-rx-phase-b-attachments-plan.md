# Prescription Attachments (Phase B) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Photos and PDFs attached to a prescription: taken with the camera, picked from the gallery or the file system, kept on the device, synced through a private Supabase Storage bucket, shown in the prescription detail, carried by backups.

**Architecture:** A fourth synced table `attachments` (sync v2, root table, soft reference `owner_kind`/`owner_id`) holds metadata; bytes live in `<app documents>/attachments/<id>.<ext>` and, once uploaded, in the private bucket `attachments` at `<auth.uid>/<id>.<ext>`. An `AttachmentTransfer` service runs beside the row sync: it uploads files whose row has no `remote_path`, removes storage objects queued for removal, downloads on demand, and sweeps local files whose row is gone. Photos are downscaled and stripped of EXIF in an isolate before they are stored.

**Tech Stack:** Flutter 3.44.6 (fvm), Dart 3.12.2, sqflite, supabase_flutter (PostgREST + Storage), `image` (pure-Dart JPEG decode/encode, new dependency), `image_picker`, `file_picker`, `open_filex`, `crypto`, Riverpod 3.

**Spec:** `docs/superpowers/specs/2026-09-23-prescription-rx-design.md` §4.5 and §7. Phase A (merged at ec2a94b) is the base; its patterns are the model for everything here.

## Global Constraints

- Always `fvm flutter …` / `fvm dart …`.
- CI gates after every task: `fvm flutter gen-l10n` no diff, `fvm dart format --output=none --set-exit-if-changed lib test`, `fvm flutter analyze --fatal-infos`, `fvm flutter test`.
- Every user-visible string in `lib/l10n/app_en.arb`, `app_de.arb`, `app_it.arb` (metadata `@key` only in the English file, as for existing keys).
- Every synced write: repository → local datasource (pending) → `requestSyncSoon`. Wire comparisons use `wireValueEquals`.
- Every repository `Result` from a user action surfaces failure (SnackBar `l10n.genericError` or a specific message); `context.mounted` after awaits.
- Local schema: migration **18** at the end of `kMigrations`, `kSchemaVersion = 18`.
- Supabase migration: `supabase/migrations/20260924000000_attachments.sql`; must be applied before devices update; errors name it (via `tableMigration`, as the rx tables do).
- Photos: long edge at most **2400 px**, JPEG quality **85**, EXIF removed (orientation baked into the pixels first). PDFs stored unchanged, at most **20 MB**. Any other file type is refused.
- Storage: private bucket `attachments`, object path `<auth.uid>/<attachment_id>.<ext>`; no public URLs, no signed URLs in logs; no tax code or file contents in `debugPrint`.
- Contents are immutable: a changed file is a new attachment.
- Disk on the dev machine is ~99% full: never copy the repo or create worktrees; scratch only in the session scratchpad; delete scratch files after use.
- Run every command in the foreground; exactly one full test suite per task, before committing (`test/services/year_of_doses_http_test.dart` alone takes ~5 min — normal).
- Commit messages end with `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`.
- Branch: `rx-phase-b`.

## File Map

Create:
- `lib/domain/entities/attachment.dart` — `Attachment`, `AttachmentKind`, `AttachmentOwnerKind`.
- `lib/data/models/attachment_model.dart`
- `lib/data/datasources/attachment_local_datasource.dart` — rows (SyncedLocalTable) + removal queue.
- `lib/services/attachment_files.dart` — `AttachmentFiles` (local bytes under `attachments/`).
- `lib/services/attachment_import.dart` — photo/PDF preparation (downscale, EXIF strip, limits, sha256).
- `lib/data/datasources/attachment_remote_datasource.dart` — row `SyncTable` + `AttachmentStore` port + Supabase implementation.
- `lib/domain/repositories/attachment_repository.dart`, `lib/data/repositories/attachment_repository_impl.dart`
- `lib/services/attachment_transfer.dart` — uploads, removals, downloads, orphan sweep.
- `lib/presentation/providers/attachment_providers.dart`
- `lib/presentation/screens/rx/rx_attachments_section.dart`, `lib/presentation/screens/rx/attachment_viewer.dart`
- `supabase/migrations/20260924000000_attachments.sql`
- Tests mirroring each; `test/integration/attachments_storage_test.dart`; `tools/sql/attachments_checks.sql`.

Modify: `lib/data/local/migrations.dart`, `lib/data/local/app_database.dart`, `lib/data/sync/sync_meta.dart`, `lib/data/sync/row_merge.dart`, `lib/data/sync/remote_wipe.dart`, `lib/services/sync_service.dart`, `lib/services/local_upload_marker.dart`, `lib/services/local_data_wiper.dart`, `lib/services/backup_service.dart`, `lib/data/datasources/account_data_remote_datasource.dart`, `lib/data/repositories/rx_repository_impl.dart`, `lib/presentation/providers/providers.dart`, `lib/presentation/screens/rx/rx_detail_screen.dart`, `lib/presentation/screens/rx/rx_list_view.dart`, `test/helpers/fake_server.dart`, `test/helpers/fake_remotes.dart`, `test/helpers/fake_postgrest.dart`, `tools/check_supabase_sql.sh`, `pubspec.yaml`, `docs/architecture.md`, `docs/release.md`.

---

### Task 1: Entity, local table, file store

**Files:**
- Create: `lib/domain/entities/attachment.dart`, `lib/data/models/attachment_model.dart`, `lib/data/datasources/attachment_local_datasource.dart`, `lib/services/attachment_files.dart`
- Modify: `lib/data/local/migrations.dart`, `lib/data/local/app_database.dart` (`clearAllData`)
- Test: `test/data/datasources/attachment_local_datasource_test.dart`, `test/services/attachment_files_test.dart`, extend `test/data/local/app_database_test.dart`

**Interfaces:**
- Produces:
  ```dart
  enum AttachmentKind { photo, pdf }            // wire: 'photo' | 'pdf'
  enum AttachmentOwnerKind { rx, treatment, person } // wire: 'rx' | 'treatment' | 'person'
  class Attachment {
    id, userId?, ownerKind, ownerId, kind, mime, sizeBytes, sha256,
    originalName?, remotePath?, createdAt?, updatedAt?;
    String get fileName; // '$id.jpg' for photo, '$id.pdf' for pdf
  }
  class AttachmentModel { same fields + deletedAt; fromJson/fromLocalMap/toJson/toDomain/fromDomain; copyWith({String? remotePath, DateTime? updatedAt, DateTime? deletedAt}) }
  class AttachmentLocalDatasource {
    upsert(AttachmentModel, {required String syncStatus}); markDeleted(String id);
    getById(String id); getForOwner(AttachmentOwnerKind, String ownerId);
    getAwaitingUpload(); // live rows with remote_path IS NULL
    getAllIds();         // every row id, tombstones included
    enqueueRemoval(String remotePath); pendingRemovals(); // List<String>
    completeRemoval(String remotePath);
    static rowOf(...); static wireOf(...);
  }
  class AttachmentFiles {
    AttachmentFiles({required Future<Directory> Function() rootDirectory});
    factory AttachmentFiles.appDocuments();
    static const folder = 'attachments';
    Future<File> fileFor(Attachment a);       // may not exist
    Future<bool> has(Attachment a);
    Future<File> write(String fileName, List<int> bytes);
    Future<void> delete(String fileName);
    Future<List<String>> listNames();
    Future<void> deleteAll();
  }
  ```

- [ ] **Step 1: Write the failing tests**

`test/services/attachment_files_test.dart`:
```dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:medora/domain/entities/attachment.dart';
import 'package:medora/services/attachment_files.dart';

void main() {
  late Directory root;
  late AttachmentFiles files;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('att');
    files = AttachmentFiles(rootDirectory: () async => root);
  });
  tearDown(() => root.delete(recursive: true));

  const photo = Attachment(
    id: 'a1',
    ownerKind: AttachmentOwnerKind.rx,
    ownerId: 'r1',
    kind: AttachmentKind.photo,
    mime: 'image/jpeg',
    sizeBytes: 3,
    sha256: 'x',
  );

  test('bytes are stored under attachments/<id>.<ext>', () async {
    await files.write(photo.fileName, [1, 2, 3]);
    expect(await files.has(photo), isTrue);
    final f = await files.fileFor(photo);
    expect(f.path, endsWith('attachments/a1.jpg'));
    expect(await f.readAsBytes(), [1, 2, 3]);
    expect(await files.listNames(), ['a1.jpg']);
  });

  test('a name with a directory part is reduced to its basename', () async {
    await files.write('../../evil.jpg', [1]);
    expect(await files.listNames(), ['evil.jpg']);
  });

  test('delete and deleteAll remove files', () async {
    await files.write('a1.jpg', [1]);
    await files.write('a2.pdf', [2]);
    await files.delete('a1.jpg');
    expect(await files.listNames(), ['a2.pdf']);
    await files.deleteAll();
    expect(await files.listNames(), isEmpty);
  });
}
```

`test/data/datasources/attachment_local_datasource_test.dart`:
```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:medora/data/datasources/attachment_local_datasource.dart';
import 'package:medora/data/local/app_database.dart';
import 'package:medora/data/models/attachment_model.dart';
import 'package:medora/domain/entities/attachment.dart';

import '../../helpers/test_database.dart';

void main() {
  setUp(setUpTestDatabase);
  tearDown(tearDownTestDatabase);

  final at = DateTime(2026, 9, 24, 9);
  AttachmentModel model(String id, {String owner = 'r1', String? remote}) =>
      AttachmentModel(
        id: id,
        ownerKind: AttachmentOwnerKind.rx,
        ownerId: owner,
        kind: AttachmentKind.photo,
        mime: 'image/jpeg',
        sizeBytes: 1234,
        sha256: 'abc',
        originalName: 'IMG_1.jpg',
        remotePath: remote,
        createdAt: at,
        updatedAt: at,
      );

  test('a row round-trips and its wire copy equals the model', () async {
    final local = AttachmentLocalDatasource(now: () => at);
    await local.upsert(model('a1'), syncStatus: SyncStatus.pendingCreate);
    final back = (await local.getById('a1'))!;
    expect(back.ownerKind, AttachmentOwnerKind.rx);
    expect(back.kind, AttachmentKind.photo);
    expect(back.sizeBytes, 1234);
    final db = await AppDatabase.instance.database;
    final row = (await db.query('attachments')).single;
    expect(AttachmentLocalDatasource.wireOf(row), model('a1').toJson());
  });

  test('owner listing hides tombstones; awaiting upload = no remote path',
      () async {
    final local = AttachmentLocalDatasource(now: () => at);
    await local.upsert(model('a1'), syncStatus: SyncStatus.pendingCreate);
    await local.upsert(
      model('a2', remote: 'u/a2.jpg'),
      syncStatus: SyncStatus.synced,
    );
    await local.upsert(model('a3', owner: 'r2'), syncStatus: SyncStatus.synced);
    await local.markDeleted('a3');
    expect(
      (await local.getForOwner(AttachmentOwnerKind.rx, 'r1')).map((a) => a.id),
      unorderedEquals(['a1', 'a2']),
    );
    expect((await local.getAwaitingUpload()).map((a) => a.id), ['a1']);
    expect(await local.getAllIds(), unorderedEquals(['a1', 'a2', 'a3']));
  });

  test('the removal queue keeps each path once until completed', () async {
    final local = AttachmentLocalDatasource(now: () => at);
    await local.enqueueRemoval('u/a1.jpg');
    await local.enqueueRemoval('u/a1.jpg');
    await local.enqueueRemoval('u/a2.pdf');
    expect(await local.pendingRemovals(), ['u/a1.jpg', 'u/a2.pdf']);
    await local.completeRemoval('u/a1.jpg');
    expect(await local.pendingRemovals(), ['u/a2.pdf']);
  });
}
```

In `test/data/local/app_database_test.dart`, extend the migration test pattern of phase A: migration 18 creates `attachments` (all sync-v2 bookkeeping columns) and `attachment_removals`; `clearAllData` empties both.

- [ ] **Step 2: Run to verify failure**

Run: `fvm flutter test test/services/attachment_files_test.dart test/data/datasources/attachment_local_datasource_test.dart`
Expected: FAIL — missing files.

- [ ] **Step 3: Implement**

`lib/domain/entities/attachment.dart`:
```dart
/// Medora - A photo or PDF kept with a prescription (later also with a
/// treatment or a person).
///
/// The row is metadata; the bytes live in a file named after the id, and on
/// the server in the private storage bucket once uploaded. A changed file is
/// a new attachment: the bytes of an attachment never change.
library;

enum AttachmentKind {
  photo('photo', 'jpg'),
  pdf('pdf', 'pdf');

  const AttachmentKind(this.wire, this.extension);
  final String wire;
  final String extension;

  static AttachmentKind fromWire(String? raw) =>
      values.firstWhere((k) => k.wire == raw, orElse: () => photo);
}

enum AttachmentOwnerKind {
  rx('rx'),
  treatment('treatment'),
  person('person');

  const AttachmentOwnerKind(this.wire);
  final String wire;

  static AttachmentOwnerKind fromWire(String? raw) =>
      values.firstWhere((k) => k.wire == raw, orElse: () => rx);
}

class Attachment {
  const Attachment({
    required this.id,
    this.userId,
    required this.ownerKind,
    required this.ownerId,
    required this.kind,
    required this.mime,
    required this.sizeBytes,
    required this.sha256,
    this.originalName,
    this.remotePath,
    this.createdAt,
    this.updatedAt,
  });

  final String id;
  final String? userId;
  final AttachmentOwnerKind ownerKind;

  /// Soft reference: the owner may be gone.
  final String ownerId;
  final AttachmentKind kind;
  final String mime;
  final int sizeBytes;

  /// Hex sha256 of the stored bytes.
  final String sha256;
  final String? originalName;

  /// Object path in the storage bucket; null until uploaded.
  final String? remotePath;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  String get fileName => '$id.${kind.extension}';
}
```

`lib/data/models/attachment_model.dart`: follow `rx_dispensing_model.dart` exactly (use `parseStamp` from `lib/data/models/model_time.dart`). Wire keys: `id, user_id, owner_kind, owner_id, kind, mime, size_bytes, sha256, original_name, remote_path, updated_at` (+ `deleted_at` when set). `size_bytes` read as `(json['size_bytes'] as num).toInt()`.

`lib/data/local/migrations.dart` — migration 18 (bump `kSchemaVersion` to 18):
```dart
  // v18: attachments (spec 2026-09-23 §7). Metadata only; the bytes live in
  // `<documents>/attachments/<id>.<ext>`. `owner_id` is a soft reference:
  // an attachment outlives nothing and blocks nothing. Removals of uploaded
  // objects wait in their own queue until the storage API confirms them.
  Migration(18, (db) async {
    await db.execute('''
      CREATE TABLE attachments (
        id TEXT PRIMARY KEY,
        user_id TEXT,
        owner_kind TEXT NOT NULL,
        owner_id TEXT NOT NULL,
        kind TEXT NOT NULL,
        mime TEXT NOT NULL,
        size_bytes INTEGER NOT NULL,
        sha256 TEXT NOT NULL,
        original_name TEXT,
        remote_path TEXT,
        created_at TEXT,
        updated_at TEXT,
        deleted_at TEXT,
        sync_status TEXT NOT NULL DEFAULT 'synced',
        edited_at TEXT,
        field_edited_at TEXT,
        sync_version INTEGER,
        sync_base TEXT,
        sync_write_id TEXT
      )
    ''');
    await db.execute(
      'CREATE INDEX idx_local_att_owner ON attachments(owner_kind, owner_id)',
    );
    await db.execute('''
      CREATE TABLE attachment_removals (
        remote_path TEXT PRIMARY KEY,
        created_at TEXT NOT NULL
      )
    ''');
  }),
```
`clearAllData`: delete `attachment_removals` and `attachments` first (before the rx tables).

`lib/data/datasources/attachment_local_datasource.dart`: built on `SyncedLocalTable<AttachmentModel>` like `rx_dispensing_local_datasource.dart` (`rowOf` uses `SyncedLocalTable.rowStamps`). Extra methods:
```dart
  Future<List<AttachmentModel>> getForOwner(
    AttachmentOwnerKind kind,
    String ownerId,
  ) => _table.getAll(
    where: 'owner_kind = ? AND owner_id = ?',
    whereArgs: [kind.wire, ownerId],
    orderBy: 'created_at',
  );

  Future<List<AttachmentModel>> getAwaitingUpload() =>
      _table.getAll(where: 'remote_path IS NULL', orderBy: 'created_at');

  Future<List<String>> getAllIds() async => [
    for (final r in await (await _db).query('attachments', columns: ['id']))
      r['id']! as String,
  ];

  Future<void> enqueueRemoval(String remotePath) async =>
      (await _db).insert('attachment_removals', {
        'remote_path': remotePath,
        'created_at': _now().toIso8601String(),
      }, conflictAlgorithm: ConflictAlgorithm.ignore);

  Future<List<String>> pendingRemovals() async => [
    for (final r in await (await _db).query(
      'attachment_removals',
      orderBy: 'created_at, remote_path',
    ))
      r['remote_path']! as String,
  ];

  Future<void> completeRemoval(String remotePath) async => (await _db).delete(
    'attachment_removals',
    where: 'remote_path = ?',
    whereArgs: [remotePath],
  );
```
(`_db` = `AppDatabase.instance.database`; keep the clock as `_now`.)

`lib/services/attachment_files.dart`: mirror `lib/services/photo_storage.dart` (folder `attachments`, `p.basename` on every name, `write` flushes, `listNames` sorted, `deleteAll` removes the folder).

- [ ] **Step 4: Run tests**

Run: `fvm flutter test test/services/attachment_files_test.dart test/data/datasources/attachment_local_datasource_test.dart test/data/local/`
Expected: PASS. Update any test that pins `kSchemaVersion`/the migration list (phase A had one in `backup_service_test.dart`).

- [ ] **Step 5: Commit** — `feat(rx): attachment rows and local files`

---

### Task 2: Row sync for attachments

**Files:**
- Modify: `lib/data/sync/sync_meta.dart` (`syncedTables`, `canonicalWire`, `localWire` with `user_id`, `localRowOf`), `lib/data/sync/row_merge.dart` (`attachmentMerge = MergePolicy(groups: [])`, `mergePolicyOf`), `lib/data/sync/remote_wipe.dart` (tables list), `lib/services/local_upload_marker.dart` (both lists), `test/helpers/fake_server.dart` (schema entry `attachments` with all columns and defaults, delete-all order), `test/data/sync/sync_meta_test.dart` fixtures (it loops over `syncedTables`)
- Test: `test/data/sync/attachment_table_sync_test.dart`

**Interfaces:**
- Consumes: Task 1 model/datasource.
- Produces: `syncedTables` ends with `'attachments'`; `attachments` has no sync parent (`parentsOf` unchanged).

- [ ] **Step 1: Failing test** (model on `test/data/sync/rx_table_sync_test.dart`): (a) a new local attachment row is pushed, settles, server has `user_id` and `remote_path` null; (b) a pulled row with `remote_path` set is stored; (c) a local `remote_path` update on a pending row merges with a concurrent server change of nothing else (outcome merged/replaced, `remote_path` kept).
- [ ] **Step 2: Run** `fvm flutter test test/data/sync/attachment_table_sync_test.dart` — Expected: FAIL `not a merged table`.
- [ ] **Step 3: Implement** the wiring listed under Files, same shape as the phase-A `persons` entries.
- [ ] **Step 4: Run** `fvm flutter test test/data/sync/` — PASS.
- [ ] **Step 5: Commit** — `feat(rx): row sync merges attachments`

---

### Task 3: Server table, storage bucket, remote datasource, sync cycle

**Files:**
- Create: `supabase/migrations/20260924000000_attachments.sql`, `lib/data/datasources/attachment_remote_datasource.dart`, `tools/sql/attachments_checks.sql`
- Modify: `lib/services/sync_service.dart` (optional `attachmentRemote`, `_tables`, push after `rx_dispensings`, pull after the rx tables, `_childTables['attachments'] = []`, `discardFailedRow`, force-pull probe includes `attachments` the same way as the rx tables), `lib/presentation/providers/providers.dart` (`attachmentRemoteProvider`, pass to `SyncService`), `tools/check_supabase_sql.sh`, `test/helpers/fake_remotes.dart` (`FakeAttachmentRemote`, `FakeAttachmentStore`), `test/helpers/fake_postgrest.dart`, `test/services/sync_service_test.dart` Harness
- Test: `test/services/attachment_sync_test.dart`

**Interfaces:**
- Produces:
  ```dart
  const attachmentsMigration = 'supabase/migrations/20260924000000_attachments.sql';
  abstract interface class AttachmentStore {
    /// Uploads [bytes] to [path]; an object already there with the same
    /// path counts as done (the write was retried).
    Future<void> upload(String path, Uint8List bytes, {required String mime});
    Future<Uint8List> download(String path);   // throws AttachmentNotFound
    Future<void> remove(List<String> paths);   // missing objects are fine
    Future<List<String>> listFolder(String folder); // object paths
  }
  class AttachmentNotFound implements Exception { const AttachmentNotFound(this.path); final String path; }
  class SupabaseAttachmentStore implements AttachmentStore { SupabaseAttachmentStore(SupabaseClient client); static const bucket = 'attachments'; }
  class AttachmentRemoteDatasource { AttachmentRemoteDatasource(SupabaseClient c); final SyncTable rows; final AttachmentStore store; }
  ```

- [ ] **Step 1: Server migration**

```sql
-- ============================================================
-- Medora - Attachments (spec 2026-09-23 §7): metadata rows synced like
-- every other table, bytes in a private storage bucket, one folder per
-- user. Apply after 20260923000000_rx.sql and before any device runs the
-- release that adds attachments. Every statement can be run again.
-- ============================================================

set local lock_timeout = '5s';

create table if not exists public.attachments (
  id              text primary key,
  user_id         uuid not null references auth.users(id) on delete cascade,
  owner_kind      text not null check (owner_kind in ('rx', 'treatment', 'person')),
  owner_id        text not null,
  kind            text not null check (kind in ('photo', 'pdf')),
  mime            text not null check (mime in ('image/jpeg', 'application/pdf')),
  size_bytes      integer not null check (size_bytes > 0 and size_bytes <= 20971520),
  sha256          text not null,
  original_name   text,
  remote_path     text,
  created_at      timestamptz default now(),
  updated_at      timestamptz default now(),
  deleted_at      timestamptz,
  sync_xid        bigint not null default 0,
  row_version     bigint not null default 1,
  write_id        uuid,
  edited_at       timestamptz,
  field_edited_at jsonb not null default '{}'::jsonb,
  -- A path always sits in the owner's folder and names this attachment.
  constraint attachments_remote_path check (
    remote_path is null
    or remote_path = user_id::text || '/' || id || '.' ||
       case kind when 'photo' then 'jpg' else 'pdf' end
  )
);

create index if not exists idx_att_sync on public.attachments (user_id, sync_xid, id);

alter table public.attachments enable row level security;

drop policy if exists "attachments_select" on public.attachments;
create policy "attachments_select" on public.attachments
  for select using (user_id = auth.uid());
drop policy if exists "attachments_insert" on public.attachments;
create policy "attachments_insert" on public.attachments
  for insert with check (user_id = auth.uid());
drop policy if exists "attachments_update" on public.attachments;
create policy "attachments_update" on public.attachments
  for update using (user_id = auth.uid()) with check (user_id = auth.uid());
drop policy if exists "attachments_delete" on public.attachments;
create policy "attachments_delete" on public.attachments
  for delete using (user_id = auth.uid());

revoke truncate, trigger, references on public.attachments from anon, authenticated;

drop trigger if exists attachments_sync_stamp on public.attachments;
create trigger attachments_sync_stamp
  before insert or update on public.attachments
  for each row execute function public.medora_sync_stamp();
drop trigger if exists attachments_updated_at on public.attachments;
create trigger attachments_updated_at
  before update on public.attachments
  for each row execute function public.update_updated_at();

-- The bucket: private, 20 MB per object, JPEG and PDF only.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('attachments', 'attachments', false, 20971520,
        array['image/jpeg', 'application/pdf'])
on conflict (id) do update
  set public = false,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

-- Objects: a user reads, adds and removes only inside their own folder.
-- No update policy: contents never change.
drop policy if exists "attachments_objects_select" on storage.objects;
create policy "attachments_objects_select" on storage.objects
  for select to authenticated
  using (bucket_id = 'attachments'
         and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists "attachments_objects_insert" on storage.objects;
create policy "attachments_objects_insert" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'attachments'
              and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists "attachments_objects_delete" on storage.objects;
create policy "attachments_objects_delete" on storage.objects
  for delete to authenticated
  using (bucket_id = 'attachments'
         and (storage.foldername(name))[1] = auth.uid()::text);

-- "Delete all data" also removes the attachment rows. Storage objects cannot
-- be deleted from SQL (Supabase blocks direct deletes on storage tables); the
-- app removes the user's folder through the storage API right after the call.
-- Same function as in 20260923000000_rx.sql, with the attachments delete added.
```
Then append `create or replace function public.medora_delete_all_data()` copied from `20260923000000_rx.sql` with `delete from public.attachments where user_id = v_uid;` added before the rx deletes, plus its revoke/grant lines. Diff the body against the rx migration: only that line may differ.

Apply locally: move `supabase/.temp/postgres-version` aside to the scratchpad (the local volume is PG15, the pin says PG17), `supabase start && supabase db reset`, restore the pin afterwards even on failure, `supabase stop`. Never stop other projects' containers; never pull new images (disk) — report NEEDS_CONTEXT if a pull would be needed.

- [ ] **Step 2: SQL check** `tools/sql/attachments_checks.sql`, in the style of `tools/sql/rx_checks.sql` (`\set ON_ERROR_STOP on`, `assert` in `do $$` blocks, fresh user ids): RLS isolation on `public.attachments`; the `remote_path` check refuses another user's folder and a wrong id; `medora_delete_all_data` removes the caller's attachment rows only; the bucket exists, is private, has the size limit and MIME list; the three `storage.objects` policies exist with the folder condition (query `pg_policies`). Wire it into `tools/check_supabase_sql.sh` after `rx_checks.sql`. If the plain `postgres:15-alpine` CI image has no `storage` schema, create a minimal `storage.buckets`/`storage.objects`/`storage.foldername` shim in `tools/sql/auth_shim.sql` (read how that shim fakes `auth`) — only what the migration needs.

- [ ] **Step 3: Remote datasource**

```dart
/// Medora - The server side of attachments: the metadata rows and the
/// private storage bucket holding the bytes.
library;

import 'dart:typed_data';

import 'package:medora/data/datasources/sync_table.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const attachmentsMigration =
    'supabase/migrations/20260924000000_attachments.sql';

class AttachmentNotFound implements Exception {
  const AttachmentNotFound(this.path);
  final String path;

  @override
  String toString() => 'Attachment not in storage';
}

abstract interface class AttachmentStore {
  Future<void> upload(String path, Uint8List bytes, {required String mime});
  Future<Uint8List> download(String path);
  Future<void> remove(List<String> paths);
  Future<List<String>> listFolder(String folder);
}

class SupabaseAttachmentStore implements AttachmentStore {
  SupabaseAttachmentStore(this._client);

  static const bucket = 'attachments';
  final SupabaseClient _client;

  StorageFileApi get _files => _client.storage.from(bucket);

  @override
  Future<void> upload(
    String path,
    Uint8List bytes, {
    required String mime,
  }) async {
    try {
      await _files.uploadBinary(
        path,
        bytes,
        fileOptions: FileOptions(contentType: mime, upsert: false),
      );
    } on StorageException catch (e) {
      // Already there: an earlier attempt landed but its answer was lost.
      if (e.statusCode == '409' || e.statusCode == '400' &&
          e.message.toLowerCase().contains('exists')) {
        return;
      }
      rethrow;
    }
  }

  @override
  Future<Uint8List> download(String path) async {
    try {
      return await _files.download(path);
    } on StorageException catch (e) {
      if (e.statusCode == '404' || e.statusCode == '400') {
        throw AttachmentNotFound(path);
      }
      rethrow;
    }
  }

  @override
  Future<void> remove(List<String> paths) async {
    if (paths.isEmpty) return;
    await _files.remove(paths);
  }

  @override
  Future<List<String>> listFolder(String folder) async => [
    for (final o in await _files.list(path: folder)) '$folder/${o.name}',
  ];
}

class AttachmentRemoteDatasource {
  AttachmentRemoteDatasource(SupabaseClient client)
    : rows = PostgrestSyncTable(
        client,
        'attachments',
        migration: attachmentsMigration,
        tableMigration: attachmentsMigration,
      ),
      store = SupabaseAttachmentStore(client);

  final SyncTable rows;
  final AttachmentStore store;
}
```
Check the storage client's exact exception fields/status codes for supabase_flutter ^2.9 (`storage_client` package source in `~/.pub-cache`) and adjust the duplicate / not-found detection to what it really returns; cover both with tests against a small fake.

- [ ] **Step 4: Sync cycle** — `SyncService({…, AttachmentRemoteDatasource? attachmentRemote})`, wired exactly like `rxRemote` (push after `rx_dispensings`, pull after the rx tables, `_childTables`, `discardFailedRow`, force-pull probe). Test `test/services/attachment_sync_test.dart` with the Harness: a local attachment row reaches the fake server; a server row arrives locally; a force pull against a server without the attachments table keeps local attachment rows.

- [ ] **Step 5: Fakes** — `FakeAttachmentStore implements AttachmentStore` in `test/helpers/fake_remotes.dart`: an in-memory `Map<String, Uint8List>` keyed by path, with `ownerOf(path)` checks mimicking the folder policy (the fake is constructed with a current user id and refuses paths outside `<uid>/` with a `StorageException`-like error), counters for calls, and switches to fail the next N calls.

- [ ] **Step 6: Run** `fvm flutter test test/services/ test/data/` + the SQL check script as CI runs it — PASS. **Commit** — `feat(rx): attachments table, private bucket and sync`.

---

### Task 4: Preparing a photo or PDF

**Files:**
- Modify: `pubspec.yaml` (add `image: ^4.5.4` — check the newest 4.x that resolves with the current SDK via `fvm flutter pub add image`), 
- Create: `lib/services/attachment_import.dart`
- Test: `test/services/attachment_import_test.dart`, fixtures under `test/fixtures/` (reuse `exif_orientation_6.jpg`; generate any larger test image in the test itself with the `image` package, never commit big binaries)

**Interfaces:**
- Produces:
  ```dart
  sealed class ImportResult {}
  final class Imported extends ImportResult { final AttachmentKind kind; final String mime; final Uint8List bytes; final String sha256; final String? originalName; }
  final class ImportRefused extends ImportResult { final ImportRefusal reason; }
  enum ImportRefusal { tooLarge, unsupported, unreadable }
  abstract final class AttachmentImport {
    static const maxLongEdge = 2400;
    static const jpegQuality = 85;
    static const maxPdfBytes = 20 * 1024 * 1024;
    static Future<ImportResult> fromPath(String path, {String? originalName});
    static ImportResult prepare(Uint8List raw, {required String nameOrPath}); // pure, for tests and the isolate
  }
  ```

- [ ] **Step 1: Failing tests**

```dart
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:medora/domain/entities/attachment.dart';
import 'package:medora/services/attachment_import.dart';

Uint8List _jpeg(int w, int h, {img.ExifData? exif}) {
  final image = img.Image(width: w, height: h);
  img.fill(image, color: img.ColorRgb8(200, 100, 50));
  if (exif != null) image.exif = exif;
  return Uint8List.fromList(img.encodeJpg(image));
}

void main() {
  test('a large photo is scaled to a 2400 px long edge', () {
    final result = AttachmentImport.prepare(
      _jpeg(4000, 3000),
      nameOrPath: 'IMG_1.jpg',
    ) as Imported;
    final decoded = img.decodeJpg(result.bytes)!;
    expect(decoded.width, 2400);
    expect(decoded.height, 1800);
    expect(result.kind, AttachmentKind.photo);
    expect(result.mime, 'image/jpeg');
    expect(result.sha256, sha256.convert(result.bytes).toString());
  });

  test('a small photo keeps its size', () {
    final result = AttachmentImport.prepare(
      _jpeg(800, 600),
      nameOrPath: 'a.jpg',
    ) as Imported;
    expect(img.decodeJpg(result.bytes)!.width, 800);
  });

  test('EXIF, including GPS, is removed; orientation is baked in', () {
    final exif = img.ExifData();
    exif.gpsIfd['GPSLatitude'] = img.IfdValueRational(46, 1);
    exif.imageIfd['Orientation'] = img.IfdValueShort(6);
    final result = AttachmentImport.prepare(
      _jpeg(400, 200, exif: exif),
      nameOrPath: 'a.jpg',
    ) as Imported;
    final decoded = img.decodeJpg(result.bytes)!;
    expect(decoded.exif.gpsIfd.isEmpty, isTrue);
    expect(decoded.exif.imageIfd['Orientation'], isNull);
    // Orientation 6 = rotate 90° clockwise: 400x200 becomes 200x400.
    expect(decoded.width, 200);
    expect(decoded.height, 400);
  });

  test('a PDF is kept byte for byte', () {
    final pdf = Uint8List.fromList('%PDF-1.4\n%fake\n'.codeUnits);
    final result = AttachmentImport.prepare(pdf, nameOrPath: 'rezept.pdf')
        as Imported;
    expect(result.bytes, pdf);
    expect(result.kind, AttachmentKind.pdf);
    expect(result.mime, 'application/pdf');
    expect(result.originalName, 'rezept.pdf');
  });

  test('a PDF over 20 MB is refused', () {
    final big = Uint8List(AttachmentImport.maxPdfBytes + 1)
      ..setAll(0, '%PDF-'.codeUnits);
    expect(
      (AttachmentImport.prepare(big, nameOrPath: 'x.pdf') as ImportRefused)
          .reason,
      ImportRefusal.tooLarge,
    );
  });

  test('other files are refused; broken images are unreadable', () {
    expect(
      (AttachmentImport.prepare(Uint8List.fromList([1, 2, 3]),
              nameOrPath: 'x.docx') as ImportRefused)
          .reason,
      ImportRefusal.unsupported,
    );
    expect(
      (AttachmentImport.prepare(Uint8List.fromList([0xFF, 0xD8, 0, 0]),
              nameOrPath: 'x.jpg') as ImportRefused)
          .reason,
      ImportRefusal.unreadable,
    );
  });
}
```
Also a test using `test/fixtures/exif_orientation_6.jpg` asserting the result has no EXIF orientation and is rotated.

- [ ] **Step 2: Run** — FAIL (missing file / package).
- [ ] **Step 3: Implement**

```dart
/// Medora - Turning a picked photo or PDF into what is stored.
///
/// Photos: decoded, orientation baked into the pixels, scaled to at most
/// [maxLongEdge] px, re-encoded as JPEG [jpegQuality] with no metadata —
/// a phone photo carries GPS and device data that has no business next to
/// a prescription. PDFs: kept as they are, up to [maxPdfBytes]. Anything
/// else is refused. Runs in an isolate: a 12 MP decode takes seconds.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:medora/domain/entities/attachment.dart';
import 'package:path/path.dart' as p;

sealed class ImportResult {
  const ImportResult();
}

final class Imported extends ImportResult {
  const Imported({
    required this.kind,
    required this.mime,
    required this.bytes,
    required this.sha256,
    this.originalName,
  });
  final AttachmentKind kind;
  final String mime;
  final Uint8List bytes;
  final String sha256;
  final String? originalName;
}

enum ImportRefusal { tooLarge, unsupported, unreadable }

final class ImportRefused extends ImportResult {
  const ImportRefused(this.reason);
  final ImportRefusal reason;
}

abstract final class AttachmentImport {
  static const maxLongEdge = 2400;
  static const jpegQuality = 85;
  static const maxPdfBytes = 20 * 1024 * 1024;

  static const _imageExtensions = {'.jpg', '.jpeg', '.png', '.heic', '.webp'};

  static Future<ImportResult> fromPath(
    String path, {
    String? originalName,
  }) async {
    final raw = await File(path).readAsBytes();
    final name = originalName ?? p.basename(path);
    return compute(_prepareArgs, (raw, name));
  }

  static ImportResult _prepareArgs((Uint8List, String) args) =>
      prepare(args.$1, nameOrPath: args.$2);

  static ImportResult prepare(Uint8List raw, {required String nameOrPath}) {
    final name = p.basename(nameOrPath);
    final ext = p.extension(name).toLowerCase();
    if (_isPdf(raw)) {
      if (raw.length > maxPdfBytes) {
        return const ImportRefused(ImportRefusal.tooLarge);
      }
      return Imported(
        kind: AttachmentKind.pdf,
        mime: 'application/pdf',
        bytes: raw,
        sha256: sha256.convert(raw).toString(),
        originalName: name,
      );
    }
    if (!_imageExtensions.contains(ext) && img.findDecoderForData(raw) == null) {
      return const ImportRefused(ImportRefusal.unsupported);
    }
    final decoded = img.decodeImage(raw);
    if (decoded == null) return const ImportRefused(ImportRefusal.unreadable);
    var image = img.bakeOrientation(decoded);
    final longEdge = image.width > image.height ? image.width : image.height;
    if (longEdge > maxLongEdge) {
      image = image.width >= image.height
          ? img.copyResize(image, width: maxLongEdge)
          : img.copyResize(image, height: maxLongEdge);
    }
    image.exif = img.ExifData();
    final bytes = Uint8List.fromList(img.encodeJpg(image, quality: jpegQuality));
    return Imported(
      kind: AttachmentKind.photo,
      mime: 'image/jpeg',
      bytes: bytes,
      sha256: sha256.convert(bytes).toString(),
      originalName: name,
    );
  }

  static bool _isPdf(Uint8List raw) =>
      raw.length >= 5 &&
      raw[0] == 0x25 && raw[1] == 0x50 && raw[2] == 0x44 &&
      raw[3] == 0x46 && raw[4] == 0x2D; // %PDF-
}
```
HEIC: the `image` package cannot decode it; a HEIC file yields `unreadable` (image_picker hands back JPEG on iOS by default, so this only affects files picked through the file picker). Check `img.bakeOrientation` handles a missing orientation, and that `encodeJpg` writes no EXIF when `image.exif` is empty (assert it in the test as above).

- [ ] **Step 4: Run** — PASS. **Commit** — `feat(rx): prepare photos and PDFs for attaching`.

---

### Task 5: Repository and deletes that follow the prescription

**Files:**
- Create: `lib/domain/repositories/attachment_repository.dart`, `lib/data/repositories/attachment_repository_impl.dart`, `lib/presentation/providers/attachment_providers.dart`
- Modify: `lib/presentation/providers/providers.dart` (datasource, files and repository providers next to the rx ones), `lib/data/repositories/rx_repository_impl.dart` (deleting an rx also deletes its attachments), `lib/presentation/providers/rx_providers.dart` (`invalidateRxData` also invalidates attachment providers)
- Test: `test/data/repositories/attachment_repository_test.dart`, extend `test/data/repositories/rx_repository_test.dart`

**Interfaces:**
- Produces:
  ```dart
  abstract class AttachmentRepository {
    Future<Result<List<Attachment>>> forOwner(AttachmentOwnerKind kind, String ownerId);
    /// Stores [imported] as a new attachment of the owner; the file is
    /// written before the row, so a row never points at nothing here.
    Future<Result<Attachment>> add(AttachmentOwnerKind kind, String ownerId, Imported imported);
    /// Tombstones the row, deletes the local file, and queues the storage
    /// object for removal when it was uploaded.
    Future<Result<void>> delete(String id);
    Future<Result<void>> deleteForOwner(AttachmentOwnerKind kind, String ownerId);
    /// Records a finished upload; refused (and the object queued for
    /// removal) when the attachment was deleted meanwhile.
    Future<Result<bool>> markUploaded(String id, String remotePath);
  }
  // attachment_providers.dart
  final attachmentsForOwnerProvider = FutureProvider.family<List<Attachment>, (AttachmentOwnerKind, String)>(...);
  ```
  `RxRepositoryImpl` gets an optional `AttachmentRepository? attachments` and calls `deleteForOwner(AttachmentOwnerKind.rx, id)` inside `deleteRx` (a failure there fails the delete with its message — nothing is swallowed).

- [ ] **Step 1: Failing tests** — `attachment_repository_test.dart` with a temp-dir `AttachmentFiles` and the test database:
  - `add` writes `<id>.jpg` with the bytes, stores the row `pending_create` with `remote_path` null, asks for a sync;
  - `delete` of an uploaded attachment tombstones the row, removes the file, and `pendingRemovals()` holds its path; of a never-uploaded one queues nothing;
  - `markUploaded` on a live row sets `remote_path` (pending update, sync requested) and returns `true`; on a deleted row returns `false` and queues the path;
  - `deleteForOwner` handles every live attachment of the owner.
  - `rx_repository_test.dart`: `deleteRx` tombstones the rx's attachments.
- [ ] **Step 2: Run** — FAIL.
- [ ] **Step 3: Implement** following `RxRepositoryImpl` (clock `now`, `requestSyncSoon(_requestSync, 'attachment')`, `Result` everywhere, `nextUpdatedAt`). The new id is a uuid v4. `add` sets `userId: null` (the sync stamps it), `sizeBytes: imported.bytes.length`.
- [ ] **Step 4: Run** `fvm flutter test test/data/repositories/` — PASS. **Commit** — `feat(rx): attachment repository; deleting a prescription deletes its attachments`.

---

### Task 6: Transfer service (upload, removal, download, sweep)

**Files:**
- Create: `lib/services/attachment_transfer.dart`
- Modify: `lib/presentation/providers/providers.dart` (provider; run after each successful sync cycle next to `invalidateRxData`, and after an attachment is added), `lib/data/datasources/account_data_remote_datasource.dart` (after `medora_delete_all_data`, remove the user's storage folder), `lib/services/local_data_wiper.dart` (delete the attachments folder and `attachment_removals`)
- Test: `test/services/attachment_transfer_test.dart`, extend `test/services/local_data_wiper_test.dart`

**Interfaces:**
- Consumes: `AttachmentStore` (Task 3), repository/datasource/files (Tasks 1, 5).
- Produces:
  ```dart
  class AttachmentTransfer {
    AttachmentTransfer({required AttachmentLocalDatasource local, required AttachmentRepository repository,
      required AttachmentFiles files, required AttachmentStore? store, required String? Function() currentUserId,
      required bool Function() isOnline, Now now = systemNow});
    /// One pass: removals first, then uploads, then the local sweep. Never
    /// throws; failures back off per item and are retried on the next pass.
    Future<TransferReport> run();
    /// The file of [a], downloading it when it is not here yet.
    Future<File?> open(Attachment a); // null: not uploaded yet or gone
  }
  class TransferReport { int uploaded; int removed; int swept; int failed; }
  ```

- [ ] **Step 1: Failing tests** (fake store from Task 3, temp files, test database; clock injected):
  1. An attachment added locally is uploaded to `<uid>/<id>.jpg` with its bytes and MIME, and its row gets `remote_path` (pending update).
  2. No user signed in, offline, or `store == null` (local-only): `run()` does nothing and returns zeros.
  3. Upload fails twice (fake switch) → row keeps `remote_path` null, report counts failures; a pass before the backoff expires skips it; after it, it succeeds. Backoff: 1 min, 5 min, 30 min, 2 h cap, per attachment id, kept in memory (a restart retries at once — acceptable).
  4. Deleted during upload (delete between upload and `markUploaded`) → object queued and removed on the next pass; row not revived.
  5. Removal queue: paths removed through the store, completed on success, kept on failure.
  6. Sweep: a file whose id has no row (tombstone pulled and hard-deleted, or a wipe) is deleted; files of live rows are kept.
  7. `open` of a synced attachment with no local file downloads it once, writes it, returns the file; a second `open` reads locally (store download count stays 1); `AttachmentNotFound` → null, no throw.
  8. `run()` while a run is in progress coalesces (use `RerunGuard` from `lib/services/rerun_guard.dart`).
  9. Delete-all: `AccountDataRemoteDatasource.deleteAllData` (with an injected store) lists `<uid>/` and removes every object after the RPC; a store failure is reported (rethrown after the RPC succeeded, so the caller shows an error) — check how its caller handles errors today and keep it consistent.
- [ ] **Step 2: Run** — FAIL.
- [ ] **Step 3: Implement.** Order in `run()`: removals → uploads → sweep. Upload reads the local file; if it is missing, skip (it may still be written) and log without the path. Log lines must not contain file names or paths of other users — ids only.
- [ ] **Step 4: Wire** the provider: construct with `ref.watch(attachmentRemoteProvider)?.store`, `SupabaseConfig.currentUserId`, `ConnectivityService.instance.isOnline`. Trigger `unawaited(transfer.run())` after a successful sync cycle (same listener that calls `invalidateRxData`) and after `AttachmentRepository.add` succeeds in the UI (Task 8).
- [ ] **Step 5: Run** focused, then the full suite — PASS. **Commit** — `feat(rx): upload, remove and fetch attachment files`.

---

### Task 7: Strings

**Files:** `lib/l10n/app_en.arb`, `app_de.arb`, `app_it.arb`, generated.

- [ ] **Step 1: Add** (metadata only in EN, as usual):

| Key | EN | DE | IT |
|---|---|---|---|
| `rxAttachments` | Attachments | Anhänge | Allegati |
| `rxAttachmentAdd` | Add attachment | Anhang hinzufügen | Aggiungi allegato |
| `rxAttachmentCamera` | Take photo | Foto aufnehmen | Scatta foto |
| `rxAttachmentGallery` | Choose photo | Foto auswählen | Scegli foto |
| `rxAttachmentFile` | Choose PDF or image file | PDF oder Bilddatei auswählen | Scegli PDF o immagine |
| `rxAttachmentDelete` | Delete attachment | Anhang löschen | Elimina allegato |
| `rxAttachmentDeleteConfirm` | Delete this attachment on all devices? | Diesen Anhang auf allen Geräten löschen? | Eliminare questo allegato su tutti i dispositivi? |
| `rxAttachmentTooLarge` | The file is larger than 20 MB | Die Datei ist größer als 20 MB | Il file supera i 20 MB |
| `rxAttachmentUnsupported` | Only photos and PDF files can be attached | Nur Fotos und PDF-Dateien können angehängt werden | Si possono allegare solo foto e PDF |
| `rxAttachmentUnreadable` | This image could not be read | Dieses Bild konnte nicht gelesen werden | Impossibile leggere questa immagine |
| `rxAttachmentNotAvailable` | Not on this device yet — it arrives with the next sync | Noch nicht auf diesem Gerät – kommt mit der nächsten Synchronisierung | Non ancora su questo dispositivo: arriva con la prossima sincronizzazione |
| `rxAttachmentPreparing` | Preparing… | Wird vorbereitet … | Preparazione… |
| `rxAttachmentCount` | `{count, plural, =1{1 attachment} other{{count} attachments}}` | `{count, plural, =1{1 Anhang} other{{count} Anhänge}}` | `{count, plural, =1{1 allegato} other{{count} allegati}}` |

Also update the backup photo option texts (search the ARB files for the key used by `backup_photos_dialog.dart` / the export checkbox) so they say "photos and attachments" in all three languages.

- [ ] **Step 2:** `fvm flutter gen-l10n`, analyze, `test/presentation/l10n_sweep_test.dart`. **Commit** — `feat(rx): attachment strings (en, de, it)`.

---

### Task 8: Attachments on the prescription screen

**Files:**
- Create: `lib/presentation/screens/rx/rx_attachments_section.dart`, `lib/presentation/screens/rx/attachment_viewer.dart`
- Modify: `lib/presentation/screens/rx/rx_detail_screen.dart` (section below the items), `lib/presentation/screens/rx/rx_list_view.dart` (attachment icon on tiles with ≥ 1 attachment — read counts with one query per list build, e.g. a `attachmentCountsProvider` returning `Map<String, int>` for rx owners)
- Test: `test/presentation/screens/rx/rx_attachments_section_test.dart`

**Interfaces:**
- Consumes: `attachmentsForOwnerProvider`, `AttachmentRepository`, `AttachmentImport`, `AttachmentTransfer.open`, `AttachmentFiles`.
- Produces: `RxAttachmentsSection({required String rxId})`, `AttachmentViewer({required File file})`, and a picker port so widget tests don't touch platform channels:
  ```dart
  abstract interface class AttachmentPicker {
    Future<({String path, String? name})?> camera();
    Future<({String path, String? name})?> gallery();
    Future<({String path, String? name})?> file(); // pdf, jpg, jpeg, png
  }
  final attachmentPickerProvider = Provider<AttachmentPicker>((_) => const PlatformAttachmentPicker());
  ```
  `PlatformAttachmentPicker` uses `ImagePicker().pickImage(source: camera|gallery)` (no `maxWidth` — the import scales) and `FilePicker.pickFile(type: FileType.custom, allowedExtensions: ['pdf','jpg','jpeg','png'])`, copying a content-URI result to the cache like `lib/services/backup_file_picker.dart`.

Behaviour:
- Header row: `l10n.rxAttachments` + add button (tooltip `rxAttachmentAdd`) opening a bottom sheet with the three sources (camera only when `platformCapabilitiesProvider` says the device has one).
- After a pick: a small progress indicator with `rxAttachmentPreparing`; run `AttachmentImport.fromPath`; `ImportRefused` → SnackBar with the matching string; `Imported` → `repository.add(...)`; failure → `genericError`; success → invalidate the owner's provider and `unawaited(transfer.run())`.
- Thumbnails in a `Wrap`: photos as 72×72 `Image.file` of the local file when present (`cacheWidth: 216`), else a cloud icon; PDFs as a document icon with the original name under it (ellipsized).
- Tap: `transfer.open(a)`; null → SnackBar `rxAttachmentNotAvailable`; photo → push `AttachmentViewer` (black background, `InteractiveViewer` with `minScale: 1, maxScale: 5`, close button); PDF → `OpenFilex.open(file.path)` (non-`done` result → `genericError`).
- Long-press or a delete icon in the viewer: confirm with `rxAttachmentDeleteConfirm`, then `repository.delete`, invalidate, SnackBar on failure.
- Every repository `Result` surfaced; `context.mounted` after awaits; no hardcoded strings.

- [ ] **Step 1: Failing widget tests** with a fake picker, a fake repository and a fake transfer:
  1. Choosing "file" with a PDF path adds an attachment (repository `add` called with kind pdf) and triggers `transfer.run()`.
  2. A refused import (too large) shows `The file is larger than 20 MB`; nothing is added.
  3. Tapping an attachment whose `open` returns null shows the not-available message.
  4. Deleting asks first; confirming calls `repository.delete`; a failing delete shows `Something went wrong`.
  5. The list tile of an rx with attachments shows the attachment icon.
- [ ] **Step 2–4:** implement until green; one full suite.
- [ ] **Step 5: Commit** — `feat(rx): attach photos and PDFs to a prescription`.

---

### Task 9: Backups, wipes, docs, integration test

**Files:**
- Modify: `lib/services/backup_service.dart` (`attachments` table in `tables`/`_insertOrder`/`_versioned`; attachment files under a new envelope key `attachmentFiles` when photos are included; size estimate and count include them; restore writes them via `AttachmentFiles.write`), `lib/data/sync/remote_wipe.dart` + the `onRemoteWipe` hook in `providers.dart` (after a remote wipe, run the transfer sweep so orphaned files go), `docs/architecture.md`, `docs/release.md`
- Create: `test/integration/attachments_storage_test.dart`
- Test: extend `test/services/backup_service_test.dart`

- [ ] **Step 1: Backup tests**: an attachment row and its file survive export→clear→restore with photos included; with photos excluded the row is restored and the file is not (it will be downloaded again); an old backup without `attachments`/`attachmentFiles` restores.
- [ ] **Step 2: Integration test** (skips without the local Supabase dart-defines, like `test/integration/rx_rls_test.dart`): user A uploads `<A>/<id>.jpg` and reads it back; user B cannot download, list, remove or upload into A's folder; a PDF over 20 MB and a `text/plain` upload are refused by the bucket; `medora_delete_all_data` + the client folder removal leave A's folder empty. Run it against local Supabase with the pin moved aside (as in Task 3); stop the stack afterwards.
- [ ] **Step 3: Docs**: `docs/architecture.md` — an "Attachments" subsection under Prescriptions (row vs bytes, path scheme, transfer order, sweep, EXIF stripping, limits, delete-all removes objects client-side because SQL cannot). `docs/release.md` — apply `20260924000000_attachments.sql` after the rx migration and before the release; re-running older migrations requires re-running this one (it redefines `medora_delete_all_data`).
- [ ] **Step 4:** full gates. **Commit** — `feat(rx): attachments in backups and wipes; storage integration test; docs`.

---

## Self-review notes

- Spec §7.1 (local, downscale, EXIF, PDF limit) → Tasks 1, 4. §7.2 (bucket, path, policies, no public/signed URLs) → Task 3. §7.3 (transfer: upload queue with backoff, lazy download, delete queue, 404 message) → Tasks 5, 6, 8. §7.4 (backup, wipes, gallery, InteractiveViewer, open_filex, migration note) → Tasks 6, 8, 9. §6.2 attachment icon on the list → Task 8.
- Out of scope, as in the spec: attachments on treatments and persons in the UI (the model allows them), thumbnails prefetch on Wi-Fi (downloads are on demand only; no Wi-Fi detection in this phase), page counts for PDFs.
- Decision recorded here: uploads run whenever online (the connectivity service does not tell Wi-Fi from mobile reliably); files are small after downscaling.
