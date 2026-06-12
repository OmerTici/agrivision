import numpy as np
import pytest

import app.main as main_mod
from app.decision import Candidate
from tests.conftest import TEST_UID

ANIMAL = "22222222-2222-2222-2222-222222222222"


def test_health(client):
    r = client.get("/health")
    assert r.status_code == 200
    assert r.json() == {"status": "ok", "model_loaded": True}


def test_identify_identified(client, jpeg_bytes, monkeypatch):
    async def fake_match(vec, owner):
        assert owner == TEST_UID
        return [Candidate(ANIMAL, "Bessie", 0.91), Candidate("other", None, 0.60)]

    monkeypatch.setattr(main_mod.db, "match", fake_match)
    r = client.post("/identify", files={"image": ("m.jpg", jpeg_bytes, "image/jpeg")})
    assert r.status_code == 200
    body = r.json()
    assert body["decision"] == "identified"
    assert body["animal_id"] == ANIMAL
    assert body["name"] == "Bessie"
    assert len(body["candidates"]) == 2


def test_identify_empty_gallery_is_unknown(client, jpeg_bytes, monkeypatch):
    async def fake_match(vec, owner):
        return []

    monkeypatch.setattr(main_mod.db, "match", fake_match)
    r = client.post("/identify", files={"image": ("m.jpg", jpeg_bytes, "image/jpeg")})
    assert r.status_code == 200
    assert r.json()["decision"] == "unknown"


def test_identify_invalid_image_is_422(client):
    r = client.post("/identify", files={"image": ("m.jpg", b"not a jpeg", "image/jpeg")})
    assert r.status_code == 422


def test_enroll_batches_and_inserts(client, jpeg_bytes, monkeypatch):
    inserted = {}

    async def fake_animal_owned(animal_id, owner):
        return True

    async def fake_upload(path, data):
        return path

    async def fake_insert(animal_id, owner, vecs, image_paths):
        inserted["vecs"] = vecs
        inserted["paths"] = image_paths
        return len(image_paths)

    monkeypatch.setattr(main_mod.db, "animal_owned", fake_animal_owned)
    monkeypatch.setattr(main_mod.storage, "upload_jpeg", fake_upload)
    monkeypatch.setattr(main_mod.db, "insert_embeddings", fake_insert)

    files = [("images", (f"m{i}.jpg", jpeg_bytes, "image/jpeg")) for i in range(3)]
    r = client.post("/enroll", data={"animal_id": ANIMAL}, files=files)
    assert r.status_code == 200
    assert r.json() == {"enrolled_count": 3, "full_images_stored": 0}
    assert np.asarray(inserted["vecs"]).shape == (3, 2152)  # one batched pass
    assert len(inserted["paths"]) == 3


def test_enroll_unowned_animal_is_404(client, jpeg_bytes, monkeypatch):
    async def fake_animal_owned(animal_id, owner):
        return False

    monkeypatch.setattr(main_mod.db, "animal_owned", fake_animal_owned)
    files = [("images", ("m.jpg", jpeg_bytes, "image/jpeg"))]
    r = client.post("/enroll", data={"animal_id": ANIMAL}, files=files)
    assert r.status_code == 404


def test_enroll_storage_failure_is_502(client, jpeg_bytes, monkeypatch):
    import httpx

    async def fake_animal_owned(animal_id, owner):
        return True

    async def fake_upload(path, data):
        raise httpx.HTTPStatusError(
            "boom", request=httpx.Request("POST", "http://x"), response=httpx.Response(500)
        )

    monkeypatch.setattr(main_mod.db, "animal_owned", fake_animal_owned)
    monkeypatch.setattr(main_mod.storage, "upload_jpeg", fake_upload)
    files = [("images", ("m.jpg", jpeg_bytes, "image/jpeg"))]
    r = client.post("/enroll", data={"animal_id": ANIMAL}, files=files)
    assert r.status_code == 502


def test_missing_auth_is_401(jpeg_bytes, monkeypatch):
    from fastapi.testclient import TestClient

    from app.main import app, state

    monkeypatch.setenv("SKIP_MODEL_LOAD", "1")  # keep lifespan from loading the real model
    state["embedder"] = None
    with TestClient(app, raise_server_exceptions=False) as c:
        r = c.post("/identify", files={"image": ("m.jpg", jpeg_bytes, "image/jpeg")})
    assert r.status_code == 401  # auth dependency fires before the 503 model check


def test_enroll_with_full_images(client, jpeg_bytes, monkeypatch):
    uploads = []

    async def fake_animal_owned(animal_id, owner):
        return True

    async def fake_upload(path, data):
        uploads.append(path)
        return path

    async def fake_insert(animal_id, owner, vecs, image_paths):
        assert all("/muzzle/" in p for p in image_paths)
        return len(image_paths)

    monkeypatch.setattr(main_mod.db, "animal_owned", fake_animal_owned)
    monkeypatch.setattr(main_mod.storage, "upload_jpeg", fake_upload)
    monkeypatch.setattr(main_mod.db, "insert_embeddings", fake_insert)

    files = [("images", ("m.jpg", jpeg_bytes, "image/jpeg"))] + [
        ("full_images", (f"f{i}.jpg", jpeg_bytes, "image/jpeg")) for i in range(2)
    ]
    r = client.post("/enroll", data={"animal_id": ANIMAL}, files=files)
    assert r.status_code == 200
    assert r.json() == {"enrolled_count": 1, "full_images_stored": 2}
    assert sum("/muzzle/" in p for p in uploads) == 1
    assert sum("/full/" in p for p in uploads) == 2


def test_enroll_writes_event(client, jpeg_bytes, monkeypatch):
    recorded = []

    async def fake_animal_owned(animal_id, owner):
        return True

    async def fake_upload(path, data):
        return path

    async def fake_insert(animal_id, owner, vecs, image_paths):
        return len(image_paths)

    async def fake_insert_event(owner, kind, animal_id, result, score):
        recorded.append((owner, kind, animal_id, result, score))

    monkeypatch.setattr(main_mod.db, "animal_owned", fake_animal_owned)
    monkeypatch.setattr(main_mod.storage, "upload_jpeg", fake_upload)
    monkeypatch.setattr(main_mod.db, "insert_embeddings", fake_insert)
    monkeypatch.setattr(main_mod.db, "insert_event", fake_insert_event)

    files = [("images", ("m.jpg", jpeg_bytes, "image/jpeg"))]
    r = client.post("/enroll", data={"animal_id": ANIMAL}, files=files)
    assert r.status_code == 200
    assert recorded == [(TEST_UID, "enroll", ANIMAL, "enrolled", None)]


def test_identify_identified_writes_event(client, jpeg_bytes, monkeypatch):
    recorded = []

    async def fake_match(vec, owner):
        return [Candidate(ANIMAL, "Bessie", 0.91), Candidate("other", None, 0.60)]

    async def fake_insert_event(owner, kind, animal_id, result, score):
        recorded.append((owner, kind, animal_id, result, score))

    monkeypatch.setattr(main_mod.db, "match", fake_match)
    monkeypatch.setattr(main_mod.db, "insert_event", fake_insert_event)

    r = client.post("/identify", files={"image": ("m.jpg", jpeg_bytes, "image/jpeg")})
    assert r.status_code == 200
    assert recorded == [(TEST_UID, "identify", ANIMAL, "identified", pytest.approx(0.91))]


def test_identify_unknown_writes_event(client, jpeg_bytes, monkeypatch):
    recorded = []

    async def fake_match(vec, owner):
        return []  # empty gallery -> unknown

    async def fake_insert_event(owner, kind, animal_id, result, score):
        recorded.append((owner, kind, animal_id, result, score))

    monkeypatch.setattr(main_mod.db, "match", fake_match)
    monkeypatch.setattr(main_mod.db, "insert_event", fake_insert_event)

    r = client.post("/identify", files={"image": ("m.jpg", jpeg_bytes, "image/jpeg")})
    assert r.status_code == 200
    assert r.json()["decision"] == "unknown"
    assert recorded == [(TEST_UID, "identify", None, "unknown", pytest.approx(0.0))]


def test_event_insert_failure_does_not_fail_response(client, jpeg_bytes, monkeypatch):
    async def fake_match(vec, owner):
        return []

    async def exploding_insert_event(owner, kind, animal_id, result, score):
        raise RuntimeError("db down")

    monkeypatch.setattr(main_mod.db, "match", fake_match)
    monkeypatch.setattr(main_mod.db, "insert_event", exploding_insert_event)

    r = client.post("/identify", files={"image": ("m.jpg", jpeg_bytes, "image/jpeg")})
    assert r.status_code == 200
    assert r.json()["decision"] == "unknown"
