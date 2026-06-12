-- CarniVision embedder schema. Apply once in the Supabase SQL editor.
create extension if not exists vector;

create table if not exists animals (
  id uuid primary key default gen_random_uuid(),
  owner uuid references auth.users not null,
  name text, tag text, breed text, sex text,
  birth_date date, status text,
  created_at timestamptz default now()
);

create table if not exists embeddings (
  id uuid primary key default gen_random_uuid(),
  animal_id uuid references animals(id) on delete cascade,
  owner uuid references auth.users not null,
  vec vector(2152) not null,
  image_path text,
  created_at timestamptz default now()
);

-- NO vector index, intentionally. pgvector caps HNSW/IVFFlat at 2000 dims
-- (MiewID is 2152); exact scan is ~0.2 ms at 1k vectors and 100% recall.
-- Upgrade path if an owner exceeds ~50k vectors:
--   create index on embeddings using hnsw ((vec::halfvec(2152)) halfvec_cosine_ops);

create index if not exists embeddings_owner_idx on embeddings (owner);
create index if not exists animals_owner_idx on animals (owner);

-- RLS: defense-in-depth. The service filters by owner explicitly in SQL;
-- these policies protect direct PostgREST access from the iOS app.
alter table animals enable row level security;
alter table embeddings enable row level security;

drop policy if exists "own animals" on animals;
create policy "own animals" on animals
  for all using (owner = auth.uid()) with check (owner = auth.uid());
drop policy if exists "own embeddings" on embeddings;
create policy "own embeddings" on embeddings
  for all using (owner = auth.uid()) with check (owner = auth.uid());

-- Action feed: one row per enroll/identify, written ONLY by the embedder
-- (service role). Owners read their own feed from the iOS app via PostgREST.
create table if not exists events (
  id          uuid primary key default gen_random_uuid(),
  owner       uuid references auth.users not null,
  kind        text not null check (kind in ('enroll', 'identify')),
  animal_id   uuid references animals(id) on delete set null,  -- null for unknown identify
  result      text not null check (result in ('enrolled', 'identified', 'unknown')),
  score       real,                                 -- top-1 similarity for identify, null for enroll
  created_at  timestamptz not null default now()
);
create index if not exists events_owner_created_idx on events (owner, created_at desc);

alter table events enable row level security;

-- Owners read their own events; there is deliberately NO insert/update/delete
-- policy — only the service role (which bypasses RLS) writes.
drop policy if exists "own events" on events;
create policy "own events" on events
  for select using (owner = auth.uid());

-- Storage: owners read their own photos. Object paths are
-- {owner_uid}/{animal_id}/{muzzle|full}/{uuid}.jpg, so the first path segment
-- is the owner uid. Wrapped in a DO block: on some Supabase projects the
-- postgres role cannot create policies on storage.objects; in that case the
-- NOTICE below says to add it in Dashboard > Storage > Policies instead.
do $$
begin
  drop policy if exists "muzzles owner read" on storage.objects;
  create policy "muzzles owner read" on storage.objects for select
    using (bucket_id = 'muzzles' and auth.uid()::text = (storage.foldername(name))[1]);
exception when insufficient_privilege then
  raise notice 'insufficient privilege for storage.objects policies — create "muzzles owner read" (SELECT, bucket muzzles, auth.uid()::text = (storage.foldername(name))[1]) in Dashboard > Storage > Policies';
end $$;
