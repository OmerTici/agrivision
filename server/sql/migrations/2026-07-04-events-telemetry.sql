-- Events becomes the single per-request record: app feed (success rows) +
-- demo/calibration telemetry (all rows, including failures). Written only by
-- the embedder service role; the iOS app filters result to success values.
-- Applied to mvp_agrivision as migration `events_telemetry` on 2026-07-04.
alter table events add column if not exists model_name  text;
alter table events add column if not exists margin      real;
alter table events add column if not exists http_status int;
alter table events add column if not exists total_ms    int;
alter table events add column if not exists request_id  text;
alter table events add column if not exists detail      jsonb not null default '{}';

alter table events drop constraint if exists events_result_check;
alter table events add constraint events_result_check check (result in (
  'enrolled', 'identified', 'unknown',
  'invalid_image', 'unowned_animal', 'storage_failed',
  'model_not_loaded', 'error'
));

-- Rows written before this migration were produced by the launch model.
update events set model_name = 'conservationxlabs/miewid-msv3@4f1d7f2b521149e5fe34bb85f377248ce9971a7d'
  where model_name is null;
