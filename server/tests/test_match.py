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

        # Held-out 6th image of each enrolled animal → identified, correct.
        for name in enrolled:
            q = embedder.embed_batch([Image.open(data[name][5])])[0]
            d = decide(await db.match(q, owner), settings.sim_threshold, settings.sim_margin)
            assert d.decision == "identified", f"{name}: {d}"
            assert d.animal_id == animal_ids[name], f"{name} misidentified: {d}"

        # Never-enrolled animal → unknown.
        q = embedder.embed_batch([Image.open(data[holdout][0])])[0]
        d = decide(await db.match(q, owner), settings.sim_threshold, settings.sim_margin)
        assert d.decision == "unknown", f"open-set leak: {d}"
    finally:
        await pool.execute("delete from animals where owner = $1::uuid", owner)
