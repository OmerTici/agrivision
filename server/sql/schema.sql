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

create policy "own animals" on animals
  for all using (owner = auth.uid()) with check (owner = auth.uid());
create policy "own embeddings" on embeddings
  for all using (owner = auth.uid()) with check (owner = auth.uid());
