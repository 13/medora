-- Stand-in for the parts of Supabase's storage schema the migrations use.
-- Supabase's storage server creates them through its own migrations, so a
-- plain Postgres has none of it and the bare supabase/postgres image stops
-- short of the bucket settings. Every statement leaves what is already
-- there alone. Run as a superuser, after tools/sql/auth_shim.sql where that
-- one runs (the grants name its roles).
create schema if not exists storage;
create table if not exists storage.buckets (
  id         text primary key,
  name       text not null unique,
  owner      uuid,
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);
-- Added by the storage server's migrations, as the hosted projects have them.
alter table storage.buckets
  add column if not exists public boolean default false,
  add column if not exists file_size_limit bigint,
  add column if not exists allowed_mime_types text[];
create table if not exists storage.objects (
  id         uuid primary key default gen_random_uuid(),
  bucket_id  text references storage.buckets(id),
  name       text,
  owner      uuid,
  created_at timestamptz default now(),
  updated_at timestamptz default now(),
  metadata   jsonb,
  unique (bucket_id, name)
);
alter table storage.objects enable row level security;
do $$ begin
  if not exists (select 1 from pg_proc
                  where proname = 'foldername'
                    and pronamespace = 'storage'::regnamespace) then
    -- The folders of an object path: 'a/b/c.jpg' gives {a,b}.
    create function storage.foldername(name text) returns text[]
      language plpgsql immutable as $f$
      declare _parts text[];
      begin
        select string_to_array(name, '/') into _parts;
        return _parts[1:array_length(_parts, 1) - 1];
      end
      $f$;
  end if;
end $$;
grant usage on schema storage to anon, authenticated;
grant select, insert, delete on storage.objects to authenticated;
grant select on storage.buckets to authenticated;
grant execute on function storage.foldername(text) to anon, authenticated;
