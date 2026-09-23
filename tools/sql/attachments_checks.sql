-- Checks for supabase/migrations/20260924000000_attachments.sql (the
-- attachments table and the private storage bucket). Run by
-- tools/check_supabase_sql.sh after rx_checks.sql, with every migration
-- applied. Any failed ASSERT stops the script with a non-zero exit.
--
-- Users F and G of their own: "delete all data" below must not touch the
-- rows the later checks in tools/check_supabase_sql.sh expect of user A.
\set ON_ERROR_STOP on

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000000f1'),
  ('00000000-0000-0000-0000-0000000000f2');

-- Clients never truncate, add triggers or add foreign keys.
do $$
declare r text; p text;
begin
  foreach r in array array['anon', 'authenticated'] loop
    foreach p in array array['TRUNCATE', 'TRIGGER', 'REFERENCES'] loop
      assert not has_table_privilege(r, 'public.attachments', p),
        format('grants: %s must not hold %s on attachments', r, p);
    end loop;
  end loop;
end $$;

-- The bucket: private, 20 MB per object, JPEG and PDF only.
do $$ begin
  assert (select count(*) from storage.buckets where id = 'attachments'
             and name = 'attachments'
             and public = false
             and file_size_limit = 20971520
             and allowed_mime_types = array['image/jpeg', 'application/pdf']) = 1,
    'bucket: attachments is private, 20 MB, JPEG and PDF only';
end $$;

-- Objects: read, add and remove in one's own folder; no update policy.
do $$
declare cmds text[];
begin
  select array_agg(cmd::text order by cmd) into cmds
    from pg_policies
   where schemaname = 'storage' and tablename = 'objects'
     and policyname like 'attachments_objects_%';
  assert cmds = array['DELETE', 'INSERT', 'SELECT'],
    'storage policies: select, insert and delete only, got ' || coalesce(cmds::text, 'none');
  assert (select bool_and(roles = '{authenticated}'
                          and coalesce(qual, with_check) like '%bucket_id = ''attachments''::text%'
                          and coalesce(qual, with_check) like '%foldername(name)%[1] = (auth.uid())::text%')
            from pg_policies
           where schemaname = 'storage' and tablename = 'objects'
             and policyname like 'attachments_objects_%'),
    'storage policies: authenticated only, in the bucket, in the caller''s folder';
end $$;

set role authenticated;
set request.jwt.claim.sub = '00000000-0000-0000-0000-0000000000f1';

insert into attachments (id, user_id, owner_kind, owner_id, kind, mime, size_bytes, sha256,
                         remote_path, write_id, edited_at)
  values ('att-1', auth.uid(), 'rx', 'rx-1', 'photo', 'image/jpeg', 1000, 'abc',
          auth.uid()::text || '/att-1.jpg', gen_random_uuid(), now()),
         ('att-2', auth.uid(), 'person', 'p-1', 'pdf', 'application/pdf', 2000, 'def',
          null, gen_random_uuid(), now());
do $$ begin
  assert (select count(*) from attachments where row_version = 1 and sync_xid > 0) = 2,
    'insert: attachment rows land stamped';
end $$;

-- The path always sits in the owner's folder and names this attachment,
-- with the extension of its kind.
do $$ begin
  begin
    update attachments set remote_path = '00000000-0000-0000-0000-0000000000f2/att-2.pdf'
     where id = 'att-2';
    assert false, 'remote_path: another user''s folder must be refused';
  exception when check_violation then null;
  end;
  begin
    update attachments set remote_path = auth.uid()::text || '/att-1.pdf' where id = 'att-2';
    assert false, 'remote_path: another attachment''s id must be refused';
  exception when check_violation then null;
  end;
  begin
    update attachments set remote_path = auth.uid()::text || '/att-2.jpg' where id = 'att-2';
    assert false, 'remote_path: the wrong extension must be refused';
  exception when check_violation then null;
  end;
  begin
    insert into attachments (id, user_id, owner_kind, owner_id, kind, mime, size_bytes, sha256)
      values ('att-big', auth.uid(), 'rx', 'rx-1', 'pdf', 'application/pdf', 20971521, 'x');
    assert false, 'size: over 20 MB must be refused';
  exception when check_violation then null;
  end;
  begin
    insert into attachments (id, user_id, owner_kind, owner_id, kind, mime, size_bytes, sha256)
      values ('att-png', auth.uid(), 'rx', 'rx-1', 'photo', 'image/png', 10, 'x');
    assert false, 'mime: only JPEG and PDF';
  exception when check_violation then null;
  end;
  update attachments set remote_path = auth.uid()::text || '/att-2.pdf',
         write_id = gen_random_uuid(), edited_at = now()
   where id = 'att-2';
  assert found, 'remote_path: its own path is accepted';
end $$;

-- Storage objects: F adds and reads inside its own folder only.
insert into storage.objects (bucket_id, name, owner)
  values ('attachments', '00000000-0000-0000-0000-0000000000f1/att-1.jpg', auth.uid());
do $$ begin
  begin
    insert into storage.objects (bucket_id, name, owner)
      values ('attachments', '00000000-0000-0000-0000-0000000000f2/att-9.jpg', auth.uid());
    assert false, 'storage: F must not add an object to G''s folder';
  exception when insufficient_privilege then null;
  end;
  begin
    insert into storage.objects (bucket_id, name, owner)
      values ('attachments', 'att-9.jpg', auth.uid());
    assert false, 'storage: F must not add an object outside any folder';
  exception when insufficient_privilege then null;
  end;
end $$;

-- Row-level security: G sees none of F's rows or objects and cannot write
-- as F.
set request.jwt.claim.sub = '00000000-0000-0000-0000-0000000000f2';
insert into attachments (id, user_id, owner_kind, owner_id, kind, mime, size_bytes, sha256,
                         write_id, edited_at)
  values ('att-g', auth.uid(), 'treatment', 't-1', 'photo', 'image/jpeg', 10, 'g',
          gen_random_uuid(), now());
do $$ begin
  assert (select count(*) from attachments) = 1, 'rls: G sees only its own attachment';
  assert (select count(*) from storage.objects where bucket_id = 'attachments') = 0,
    'storage: G sees none of F''s objects';
  begin
    insert into attachments (id, user_id, owner_kind, owner_id, kind, mime, size_bytes, sha256)
      values ('att-g2', '00000000-0000-0000-0000-0000000000f1', 'rx', 'rx-1', 'photo',
              'image/jpeg', 10, 'g');
    assert false, 'rls: G must not write an attachment as F';
  exception when insufficient_privilege then null;
  end;
  update attachments set original_name = 'x' where id = 'att-1';
  assert not found, 'rls: G must not change F''s attachment';
  delete from attachments where id = 'att-1';
  assert not found, 'rls: G must not delete F''s attachment';
  delete from storage.objects where bucket_id = 'attachments';
  assert not found, 'storage: G must not delete F''s objects';
end $$;

-- "Delete all data" removes the caller's attachment rows, and only those.
set request.jwt.claim.sub = '00000000-0000-0000-0000-0000000000f1';
do $$ begin
  assert (select count(*) from storage.objects where bucket_id = 'attachments') = 1,
    'storage: F reads its own object';
end $$;
select medora_delete_all_data() \g /dev/null
do $$ begin
  assert (select count(*) from attachments) = 0, 'delete all: F''s attachments are gone';
end $$;
reset role;
do $$ begin
  assert (select count(*) from attachments
           where user_id = '00000000-0000-0000-0000-0000000000f1') = 0,
    'delete all: none of F''s attachments left, seen without row-level security';
  assert (select count(*) from attachments
           where user_id = '00000000-0000-0000-0000-0000000000f2') = 1,
    'delete all: G''s attachment untouched';
end $$;
select 'attachments checks passed' as result;
