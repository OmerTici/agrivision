-- Soft-delete support for animals. Run once in the Supabase SQL editor.
-- deleted_at IS NULL = active; a timestamp = archived (hidden from herd list
-- and excluded from /identify matching). Embeddings/photos are retained.
alter table animals add column if not exists deleted_at timestamptz;
