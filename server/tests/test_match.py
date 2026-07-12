"""Integration: real MiewID + real Supabase Postgres.

Run:
  INTEGRATION=1 TEST_OWNER_UID=<auth user uuid> \
  DATABASE_URL=postgresql://...pooler...:6543/postgres \
  .venv/bin/pytest tests/test_match.py -v

Enrolls the first 5 images of 3 animals, identifies a held-out 6th image of
each (expect: identified, correct animal), and one image of a never-enrolled
animal (expect: unknown). Cleans up its rows afterwards."""
import os
from pathlib import Path

import numpy as np
import pytest
from PIL import Image

pytestmark = pytest.mark.integration

DATASET = Path(
    os.environ.get(
        "MUZZLE_DATASET",
        "/Volumes/Extreme SSD/Animal_Biometrics_System/BeefCattle_Muzzle_Individualized",
    )
)

if os.environ.get("INTEGRATION") != "1":
    pytest.skip("set INTEGRATION=1 to run", allow_module_level=True)


def animal_images(n_animals: int, n_images: int):
    dirs = sorted(d for d in DATASET.iterdir() if d.is_dir())[: n_animals]
    out = {}
    for d in dirs:
        imgs = sorted(d.glob("*.*"))[: n_images]
        assert len(imgs) >= n_images, f"{d.name} has fewer than {n_images} images"
        out[d.name] = imgs
    return out


@pytest.fixture(scope="module")
def embedder():
    from app.miewid import MiewIDEmbedder

    return MiewIDEmbedder(device="cpu")


async def test_enroll_then_identify_rank1(embedder):
    from app import db
    from app.config import get_settings
    from app.decision import decide

    owner = os.environ["TEST_OWNER_UID"]
    pool = await db.get_pool()
    data = animal_images(n_animals=4, n_images=6)
    names = list(data)
    enrolled, holdout = names[:3], names[3]
    settings = get_settings()
    animal_ids = {}

    try:
        for name in enrolled:
            animal_ids[name] = await pool.fetchval(
                "insert into animals (owner, name) values ($1::uuid, $2) returning id::text",
                owner, name,
            )
            train = [Image.open(p) for p in data[name][:5]]
            vecs = embedder.embed_batch(train)
            await db.insert_embeddings(
                animal_ids[name], owner, vecs, [f"test/{name}/{i}.jpg" for i in range(5)]
            )

        # Held-out 6th image of each enrolled animal → rank-1 correct, identified.
        for name in enrolled:
            q = embedder.embed_batch([Image.open(data[name][5])])[0]
            candidates = await db.match(q, owner)
            assert candidates and candidates[0].animal_id == animal_ids[name], (
                f"{name} rank-1 wrong: {candidates[:2]}"
            )
            d = decide(candidates, settings.sim_threshold, settings.sim_margin)
            assert d.decision == "identified", f"{name} false-rejected: {d}"
            assert d.animal_id == animal_ids[name]

        # Never-enrolled animal → unknown.
        q = embedder.embed_batch([Image.open(data[holdout][0])])[0]
        d = decide(await db.match(q, owner), settings.sim_threshold, settings.sim_margin)
        assert d.decision == "unknown", f"open-set leak: {d}"
    finally:
        await pool.execute("delete from animals where owner = $1::uuid", owner)


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
