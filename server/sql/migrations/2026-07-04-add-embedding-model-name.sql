-- Track which model/version produced each embedding. Vectors from different
-- embedding spaces must never be compared directly.
alter table embeddings add column if not exists model_name text;

update embeddings
set model_name = 'conservationxlabs/miewid-msv3@4f1d7f2b521149e5fe34bb85f377248ce9971a7d'
where model_name is null;

alter table embeddings
  alter column model_name set default 'conservationxlabs/miewid-msv3@4f1d7f2b521149e5fe34bb85f377248ce9971a7d',
  alter column model_name set not null;

create index if not exists embeddings_owner_model_idx on embeddings (owner, model_name);
