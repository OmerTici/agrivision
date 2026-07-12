# Mean-of-Top-3 Per-Animal Aggregation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Score each animal in `/identify` by the mean of its 3 closest embeddings instead of its single closest, with dual-score telemetry for later threshold recalibration.

**Architecture:** The ranking rule lives entirely in `MATCH_SQL` (`server/app/db.py`) — a window function ranks each animal's embeddings by cosine distance, keeps the top `m`, and averages. The open-set decision rule (`decide()` in `decision.py`) is untouched: it still receives one continuous score per animal. Telemetry additions ride the existing `events.detail` JSON path in `main.py`.

**Tech Stack:** FastAPI, asyncpg (Supavisor transaction pooler, `statement_cache_size=0`), pgvector (`<=>` cosine distance, exact scan — no index), pydantic-settings, pytest.

**Spec:** `docs/superpowers/specs/2026-07-12-mean-top3-aggregation-design.md`

## Global Constraints

- Vectors are passed as pgvector text literals and cast in SQL (`$1::vector`) — no client-side codecs.
- `embeddings.vec` is `vector(2152)`; exact scan by design, do not add a vector index.
- API response schema is UNCHANGED — `CandidateOut` gets no new fields; `max_sim` is telemetry-only.
- `sim_threshold: float = 0.60`, `sim_margin: float = 0.05` keep their values; new setting is `sim_top_m: int = 3`.
- All commands run from `/Users/korkutkaanbalta/Developer/agrivision/server` with `.venv/bin/pytest`.
- Unit tests must never touch Postgres; DB-dependent tests go in `tests/test_match.py` behind the existing `INTEGRATION=1` module gate.

---

### Task 1: `sim_top_m` config setting

**Files:**
- Modify: `server/app/config.py:14-17`
- Test: `server/tests/test_config.py`

**Interfaces:**
- Produces: `Settings.sim_top_m: int = 3`, overridable via `SIM_TOP_M` env var. Task 2's `db.match()` reads it via `get_settings().sim_top_m`.

- [ ] **Step 1: Write the failing test**

In `server/tests/test_config.py`, add one assertion to the existing defaults test:

```python
def test_defaults_match_pilot_operating_point():
    s = Settings(_env_file=None)
    assert s.sim_threshold == 0.60
    assert s.sim_margin == 0.05
    assert s.sim_top_m == 3
    assert s.storage_bucket == "muzzles"
    assert s.embedding_model_name == (
        "conservationxlabs/miewid-msv3@4f1d7f2b521149e5fe34bb85f377248ce9971a7d"
    )
```

- [ ] **Step 2: Run test to verify it fails**

Run: `.venv/bin/pytest tests/test_config.py -v`
Expected: FAIL with `AttributeError: 'Settings' object has no attribute 'sim_top_m'`

- [ ] **Step 3: Write minimal implementation**

In `server/app/config.py`, replace lines 14-17 with:

```python
    # Open-set decision rule — tuned for 5-photo enrollment (2026-06-11 recalibration;
    # bakeoff suggested_threshold 0.7746 assumed ~15-image galleries).
    # CAUTION: threshold/margin were calibrated on per-animal MAX cosine; the
    # ranking score is now mean-of-top-m, which runs systematically lower.
    # Re-fit both from events.detail top_max_sim / top_mean_sim telemetry.
    sim_threshold: float = 0.60
    sim_margin: float = 0.05
    # Per-animal score = mean of the animal's sim_top_m closest embeddings
    # (robust to a single rogue enrollment frame; no gallery-size bias).
    sim_top_m: int = 3
```

- [ ] **Step 4: Run test to verify it passes**

Run: `.venv/bin/pytest tests/test_config.py -v`
Expected: 2 passed

- [ ] **Step 5: Commit**

```bash
git add app/config.py tests/test_config.py
git commit -m "feat(identify): add sim_top_m setting for mean-of-top-m aggregation"
```

---

### Task 2: Mean-of-top-m MATCH_SQL + `Candidate.max_sim`

**Files:**
- Modify: `server/app/db.py:42-64` (MATCH_SQL, `match()`)
- Modify: `server/app/decision.py:1-11` (docstring, `Candidate`)
- Test: `server/tests/test_db.py`

**Interfaces:**
- Consumes: `get_settings().sim_top_m` (Task 1).
- Produces: `Candidate(animal_id: str, name: str | None, sim: float, max_sim: float | None = None)` — `sim` is now the mean of the animal's top-m cosine sims (the ranking/decision score); `max_sim` is the best single-embedding sim, telemetry-only. `db.match(vec, owner)` signature unchanged. Task 3 reads `candidate.max_sim`.

- [ ] **Step 1: Write the failing tests**

In `server/tests/test_db.py`, add after `test_match_sql_excludes_soft_deleted`:

```python
def test_match_sql_mean_of_top_m():
    # Per-animal score = avg of the m closest embeddings (rn <= $4), plus the
    # raw best-single sim for telemetry.
    assert "row_number() over (partition by a.id" in MATCH_SQL
    assert "rn <= $4" in MATCH_SQL
    assert "avg(sim)" in MATCH_SQL
    assert "max(sim) as max_sim" in MATCH_SQL
```

- [ ] **Step 2: Run tests to verify the new one fails**

Run: `.venv/bin/pytest tests/test_db.py -v`
Expected: `test_match_sql_mean_of_top_m` FAILS on the `row_number()` assertion; all others pass.

- [ ] **Step 3: Implement**

In `server/app/decision.py`, replace lines 1-11 with:

```python
"""Open-set decision rule from the bakeoff: accept the top animal only if its
similarity clears the threshold AND beats the runner-up animal by the margin.
Candidates are per-animal mean-of-top-m cosine scores, ordered best-first."""
from dataclasses import dataclass


@dataclass
class Candidate:
    animal_id: str
    name: str | None
    sim: float  # mean of the animal's top-m cosine sims (ranking/decision score)
    max_sim: float | None = None  # best single-embedding sim, telemetry only
```

In `server/app/db.py`, replace `MATCH_SQL` (lines 42-51) with:

```python
MATCH_SQL = """
select animal_id, name, avg(sim) as sim, max(sim) as max_sim
from (
    select a.id::text as animal_id, a.name,
           1 - (e.vec <=> $1::vector) as sim,
           row_number() over (partition by a.id order by e.vec <=> $1::vector) as rn
    from embeddings e
    join animals a on a.id = e.animal_id and a.deleted_at is null
    where e.owner = $2::uuid
      and e.model_name = $3
) ranked
where rn <= $4
group by animal_id, name
order by sim desc
limit 5
"""
```

Replace `match()` (lines 61-64) with:

```python
async def match(vec: np.ndarray, owner: str) -> list[Candidate]:
    pool = await get_pool()
    s = get_settings()
    rows = await pool.fetch(
        MATCH_SQL, vector_literal(vec), owner, s.embedding_model_name, s.sim_top_m
    )
    return [
        Candidate(r["animal_id"], r["name"], float(r["sim"]), float(r["max_sim"]))
        for r in rows
    ]
```

Also update the db.py module docstring line 8 sentence "Matching is an exact scan by design" paragraph — replace the final paragraph of the docstring with:

```
Matching is an exact scan by design (no vector index): pgvector caps HNSW at
2000 dims (MiewID is 2152) and exact scan is ~0.2 ms at 1k vectors anyway.
Each animal is scored by the mean of its sim_top_m closest embeddings (robust
to a single rogue enrollment frame); its single best sim rides along for
telemetry."""
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `.venv/bin/pytest tests/ -v -m "not integration"`
Expected: all pass (existing `test_api.py` fake Candidates still construct with 3 positional args — `max_sim` defaults to `None`).

- [ ] **Step 5: Commit**

```bash
git add app/db.py app/decision.py tests/test_db.py
git commit -m "feat(identify): rank animals by mean of top-m embedding sims, not single max"
```

---

### Task 3: Dual-score telemetry in identify events

**Files:**
- Modify: `server/app/main.py:154-162`
- Test: `server/tests/test_api.py:215-234`

**Interfaces:**
- Consumes: `Candidate.max_sim` (Task 2).
- Produces: `events.detail` JSON gains `top_mean_sim`, `top_max_sim` (top candidate only, present only when candidates exist) and a `max_sim` key per entry in the existing `candidates` list. No API response change.

- [ ] **Step 1: Write the failing test**

In `server/tests/test_api.py`, replace `test_identify_identified_writes_event` (lines 215-234) with:

```python
def test_identify_identified_writes_event(client, jpeg_bytes, monkeypatch):
    async def fake_match(vec, owner):
        return [Candidate(ANIMAL, "Bessie", 0.91, 0.95), Candidate("other", None, 0.60, 0.70)]

    monkeypatch.setattr(main_mod.db, "match", fake_match)
    recorded = _capture_events(monkeypatch)

    r = client.post("/identify", files={"image": ("m.jpg", jpeg_bytes, "image/jpeg")})
    assert r.status_code == 200
    (e,) = recorded
    assert (e["owner"], e["kind"], e["animal_id"], e["result"]) == (
        TEST_UID, "identify", ANIMAL, "identified",
    )
    assert e["score"] == pytest.approx(0.91)
    assert e["margin"] == pytest.approx(0.31)
    assert e["http_status"] == 200
    assert e["model_name"] == MODEL
    assert e["detail"]["candidate_count"] == 2
    assert e["detail"]["candidates"][0]["sim"] == pytest.approx(0.91)
    # Dual-score telemetry: raw max-sim logged next to the mean-of-top-m score
    # so threshold/margin can be re-fit from live traffic.
    assert e["detail"]["candidates"][0]["max_sim"] == pytest.approx(0.95)
    assert e["detail"]["top_mean_sim"] == pytest.approx(0.91)
    assert e["detail"]["top_max_sim"] == pytest.approx(0.95)
    assert "embed_ms" in e["detail"] and "match_ms" in e["detail"]
```

- [ ] **Step 2: Run test to verify it fails**

Run: `.venv/bin/pytest tests/test_api.py::test_identify_identified_writes_event -v`
Expected: FAIL with `KeyError: 'max_sim'`

- [ ] **Step 3: Implement**

In `server/app/main.py`, replace the `rlog.detail.update(...)` call (lines 154-162) with:

```python
        rlog.detail.update(
            decision_threshold=s.sim_threshold,
            margin_threshold=s.sim_margin,
            candidates=[
                {
                    "animal_id": _id_tail(c.animal_id),
                    "sim": round(c.sim, 4),
                    "max_sim": round(c.max_sim, 4) if c.max_sim is not None else None,
                }
                for c in candidates[:3]
            ],
            candidate_count=len(candidates),
        )
        if candidates:
            # Dual-score telemetry: mean-of-top-m is the live rule; max-sim is
            # what the old rule would have scored. Collected for recalibration.
            rlog.detail["top_mean_sim"] = round(candidates[0].sim, 4)
            if candidates[0].max_sim is not None:
                rlog.detail["top_max_sim"] = round(candidates[0].max_sim, 4)
```

- [ ] **Step 4: Run the full unit suite**

Run: `.venv/bin/pytest tests/ -v -m "not integration"`
Expected: all pass (`test_identify_unknown_writes_event` covers the empty-candidates path — no `top_mean_sim` key, no crash).

- [ ] **Step 5: Commit**

```bash
git add app/main.py tests/test_api.py
git commit -m "feat(telemetry): log max-sim alongside mean-of-top-m on identify"
```

---

### Task 4: Integration test — outlier robustness with synthetic vectors

**Files:**
- Modify: `server/tests/test_match.py`

**Interfaces:**
- Consumes: `db.match()` / `db.insert_embeddings()` (Task 2), real Postgres. No embedder needed — vectors are hand-built at exact cosine sims to the query.

- [ ] **Step 1: Add the test**

In `server/tests/test_match.py`, add `import numpy as np` after `from pathlib import Path` (line 12), then append at end of file:

```python
def _unit_vec(axis: int, dim: int = 2152) -> np.ndarray:
    v = np.zeros(dim, dtype=np.float32)
    v[axis] = 1.0
    return v


def _vec_with_sim(sim: float, ortho_axis: int) -> np.ndarray:
    """Unit vector at exact cosine `sim` to the query axis e0, tilted along e_ortho."""
    v = sim * _unit_vec(0) + np.sqrt(1.0 - sim**2) * _unit_vec(ortho_axis)
    return v.astype(np.float32)


async def test_mean_of_top3_resists_single_outlier():
    """A single rogue 0.95 embedding must not beat an animal whose 3 embeddings
    all sit at 0.80 (the old max rule would pick the rogue). Also proves an
    animal with fewer than sim_top_m embeddings is averaged over what it has."""
    from app import db

    owner = os.environ["TEST_OWNER_UID"]
    pool = await db.get_pool()
    q = _unit_vec(0)
    names = ("steady", "outlier", "two-shot")
    try:
        ids = {}
        for name in names:
            ids[name] = await pool.fetchval(
                "insert into animals (owner, name) values ($1::uuid, $2) returning id::text",
                owner, name,
            )
        await db.insert_embeddings(
            ids["steady"], owner,
            np.stack([_vec_with_sim(0.80, i) for i in (1, 2, 3)]),
            [f"t/steady/{i}.jpg" for i in range(3)],
        )
        await db.insert_embeddings(
            ids["outlier"], owner,
            np.stack([_vec_with_sim(0.95, 4), _vec_with_sim(0.10, 5), _vec_with_sim(0.10, 6)]),
            [f"t/outlier/{i}.jpg" for i in range(3)],
        )
        await db.insert_embeddings(
            ids["two-shot"], owner,
            np.stack([_vec_with_sim(0.70, 7), _vec_with_sim(0.70, 8)]),
            [f"t/two-shot/{i}.jpg" for i in range(2)],
        )

        cands = await db.match(q, owner)
        by_id = {c.animal_id: c for c in cands}
        assert cands[0].animal_id == ids["steady"], cands
        assert by_id[ids["steady"]].sim == pytest.approx(0.80, abs=1e-3)
        assert by_id[ids["outlier"]].sim == pytest.approx((0.95 + 0.10 + 0.10) / 3, abs=1e-3)
        assert by_id[ids["outlier"]].max_sim == pytest.approx(0.95, abs=1e-3)
        assert by_id[ids["two-shot"]].sim == pytest.approx(0.70, abs=1e-3)
        assert by_id[ids["two-shot"]].max_sim == pytest.approx(0.70, abs=1e-3)
    finally:
        await pool.execute(
            "delete from animals where owner = $1::uuid and name = any($2::text[])",
            owner, list(names),
        )
```

- [ ] **Step 2: Run it against the real database (if credentials available)**

`DATABASE_URL` is read from `server/.env` by pydantic-settings; only the gate
and owner uid must be exported (same values as the existing integration test):

Run: `INTEGRATION=1 TEST_OWNER_UID=<auth user uuid> .venv/bin/pytest tests/test_match.py::test_mean_of_top3_resists_single_outlier -v`
Expected: PASS. (Does NOT need the muzzle dataset or the embedder — synthetic vectors only.)

If no credentials are available in this environment: run `.venv/bin/pytest tests/test_match.py -v` and confirm the module skips cleanly (`set INTEGRATION=1 to run`); flag the unrun integration test in the task report.

- [ ] **Step 3: Commit**

```bash
git add tests/test_match.py
git commit -m "test(identify): integration proof that mean-of-top-3 resists a single outlier"
```

---

### Task 5: Final verification

- [ ] **Step 1: Full unit suite**

Run: `.venv/bin/pytest tests/ -v -m "not integration"`
Expected: all pass, integration module skipped.

- [ ] **Step 2: Confirm no API contract drift**

Run: `git diff main -- app/schemas.py`
Expected: empty output (response models untouched).
