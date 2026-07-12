# Identify: mean-of-top-3 per-animal aggregation

**Date:** 2026-07-12
**Status:** Approved

## Problem

`MATCH_SQL` scores each animal by its single closest embedding (per-animal max
cosine). One outlier enrollment frame — blur, bad crop, mislabel — can flip a
match on its own. Vote-based KNN was considered and rejected: gallery-size bias
(enrollment counts vary per animal), and it returns a label rather than a
continuous score, breaking the open-set threshold + margin rule.

## Decision

Score each animal by the **mean of its m closest embeddings** (default m=3).
Robust to a single outlier, no gallery-size bias, keeps a continuous score so
`decide()` (threshold + margin) is unchanged.

## Changes

### 1. `server/app/db.py` — MATCH_SQL

Rank each animal's embeddings by cosine distance with
`row_number() over (partition by a.id order by e.vec <=> $1::vector)`, keep
`rn <= $4`, aggregate `avg(sim)` per animal. Animals with fewer than m
embeddings average over what they have. Still `order by sim desc limit 5`,
still an exact scan (no vector index; see existing rationale in db.py).

Additionally return each animal's max sim (`max(sim)` over the same window)
so telemetry can compare rules.

### 2. `server/app/config.py` — new setting

`sim_top_m: int = 3`, passed as `$4`. Tunable without redeploy.

### 3. Telemetry — dual-score logging

On every identify, log the top candidate's raw max-sim alongside the
mean-of-top-m score in `events.detail` JSON (e.g. `{"top_max_sim": ...,
"top_mean_sim": ...}`). No real calibration data exists; this collects it from
live traffic so threshold/margin can be re-fit to the new score later.

### 4. Threshold caveat (no code change)

`sim_threshold=0.60` / `sim_margin=0.05` were calibrated on max-cosine.
Mean-of-top-3 scores run systematically lower; expect more `"unknown"` results
until re-tuned from the telemetry above. Update the comment in config.py.

## Unchanged

- `decision.py` logic (docstring updated to say mean-of-top-m).
- Identify endpoint flow, schemas, storage, enrollment.

## Tests

- `test_db.py`: update SQL-shape assertions (partition/window, `$4`, avg).
- `test_match.py`:
  - Single close outlier embedding of animal B no longer beats animal A with
    3 moderately close embeddings.
  - Animal with fewer than 3 embeddings is scored over what it has.
- `test_config.py`: `sim_top_m` default.
