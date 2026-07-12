import numpy as np
import pytest

import app.main as main_mod
from app.decision import Candidate
from tests.conftest import TEST_UID

ANIMAL = "22222222-2222-2222-2222-222222222222"


def _capture_events(monkeypatch):
    """Stub db.insert_event, returning the list it appends (args, kwargs) to."""
    recorded = []

    async def fake_insert_event(owner, kind, animal_id, result, score, **kw):
        recorded.append({"owner": owner, "kind": kind, "animal_id": animal_id,
                         "result": result, "score": score, **kw})

    monkeypatch.setattr(main_mod.db, "insert_event", fake_insert_event)
    return recorded


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
    assert r.json() == {"enrolled_count": 3, "full_images_stored": 0, "frame_images_stored": 0}
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
    assert r.json() == {"enrolled_count": 1, "full_images_stored": 2, "frame_images_stored": 0}
    assert sum("/muzzle/" in p for p in uploads) == 1
    assert sum("/full/" in p for p in uploads) == 2


def test_enroll_with_frame_images(client, jpeg_bytes, monkeypatch):
    uploads = []

    async def fake_animal_owned(animal_id, owner):
        return True

    async def fake_upload(path, data):
        uploads.append(path)
        return path

    async def fake_insert(animal_id, owner, vecs, image_paths):
        assert all("/muzzle/" in p for p in image_paths)  # frames never embedded
        return len(image_paths)

    monkeypatch.setattr(main_mod.db, "animal_owned", fake_animal_owned)
    monkeypatch.setattr(main_mod.storage, "upload_jpeg", fake_upload)
    monkeypatch.setattr(main_mod.db, "insert_embeddings", fake_insert)

    files = (
        [("images", ("m.jpg", jpeg_bytes, "image/jpeg"))]
        + [("full_images", ("f.jpg", jpeg_bytes, "image/jpeg"))]
        + [("frame_images", (f"r{i}.jpg", jpeg_bytes, "image/jpeg")) for i in range(5)]
    )
    r = client.post("/enroll", data={"animal_id": ANIMAL}, files=files)
    assert r.status_code == 200
    assert r.json() == {"enrolled_count": 1, "full_images_stored": 1, "frame_images_stored": 5}
    assert sum("/frame/" in p for p in uploads) == 5


MODEL = "conservationxlabs/miewid-msv3@4f1d7f2b521149e5fe34bb85f377248ce9971a7d"


def test_enroll_writes_event(client, jpeg_bytes, monkeypatch):
    async def fake_animal_owned(animal_id, owner):
        return True

    async def fake_upload(path, data):
        return path

    async def fake_insert(animal_id, owner, vecs, image_paths):
        return len(image_paths)

    monkeypatch.setattr(main_mod.db, "animal_owned", fake_animal_owned)
    monkeypatch.setattr(main_mod.storage, "upload_jpeg", fake_upload)
    monkeypatch.setattr(main_mod.db, "insert_embeddings", fake_insert)
    recorded = _capture_events(monkeypatch)

    files = [("images", ("m.jpg", jpeg_bytes, "image/jpeg"))]
    r = client.post("/enroll", data={"animal_id": ANIMAL}, files=files)
    assert r.status_code == 200
    (e,) = recorded
    assert (e["owner"], e["kind"], e["animal_id"], e["result"], e["score"]) == (
        TEST_UID, "enroll", ANIMAL, "enrolled", None,
    )
    assert e["http_status"] == 200
    assert e["model_name"] == MODEL
    assert e["detail"]["muzzle_count"] == 1
    assert e["detail"]["enrolled_count"] == 1
    assert "upload_ms" in e["detail"] and "embed_ms" in e["detail"] and "insert_ms" in e["detail"]
    assert e["total_ms"] >= 0 and len(e["request_id"]) == 10


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


def test_identify_unknown_writes_event(client, jpeg_bytes, monkeypatch):
    async def fake_match(vec, owner):
        return []  # empty gallery -> unknown

    monkeypatch.setattr(main_mod.db, "match", fake_match)
    recorded = _capture_events(monkeypatch)

    r = client.post("/identify", files={"image": ("m.jpg", jpeg_bytes, "image/jpeg")})
    assert r.status_code == 200
    assert r.json()["decision"] == "unknown"
    (e,) = recorded
    assert (e["animal_id"], e["result"], e["http_status"]) == (None, "unknown", 200)


def test_event_insert_failure_does_not_fail_response(client, jpeg_bytes, monkeypatch):
    async def fake_match(vec, owner):
        return []

    async def exploding_insert_event(*args, **kwargs):
        raise RuntimeError("db down")

    monkeypatch.setattr(main_mod.db, "match", fake_match)
    monkeypatch.setattr(main_mod.db, "insert_event", exploding_insert_event)

    r = client.post("/identify", files={"image": ("m.jpg", jpeg_bytes, "image/jpeg")})
    assert r.status_code == 200
    assert r.json()["decision"] == "unknown"


def test_identify_invalid_image_writes_failure_row(client, monkeypatch):
    recorded = _capture_events(monkeypatch)
    r = client.post("/identify", files={"image": ("m.jpg", b"not a jpeg", "image/jpeg")})
    assert r.status_code == 422
    (e,) = recorded
    assert (e["kind"], e["result"], e["http_status"]) == ("identify", "invalid_image", 422)
    assert e["animal_id"] is None and e["score"] is None
    assert e["detail"]["error"] == "invalid image payload"
    assert e["detail"]["image_bytes"] == len(b"not a jpeg")


def test_identify_model_not_loaded_writes_failure_row(client, jpeg_bytes, monkeypatch):
    recorded = _capture_events(monkeypatch)
    main_mod.state["embedder"] = None  # client fixture restores this on teardown
    r = client.post("/identify", files={"image": ("m.jpg", jpeg_bytes, "image/jpeg")})
    assert r.status_code == 503
    (e,) = recorded
    assert (e["result"], e["http_status"]) == ("model_not_loaded", 503)


def test_identify_unexpected_error_writes_error_row(client, jpeg_bytes, monkeypatch):
    async def exploding_match(vec, owner):
        raise RuntimeError("pg down")

    monkeypatch.setattr(main_mod.db, "match", exploding_match)
    recorded = _capture_events(monkeypatch)
    r = client.post("/identify", files={"image": ("m.jpg", jpeg_bytes, "image/jpeg")})
    assert r.status_code == 500
    (e,) = recorded
    assert (e["result"], e["http_status"]) == ("error", 500)
    assert "RuntimeError" in e["detail"]["error"]


def test_enroll_unowned_writes_failure_row(client, jpeg_bytes, monkeypatch):
    async def fake_animal_owned(animal_id, owner):
        return False

    monkeypatch.setattr(main_mod.db, "animal_owned", fake_animal_owned)
    recorded = _capture_events(monkeypatch)
    files = [("images", ("m.jpg", jpeg_bytes, "image/jpeg"))]
    r = client.post("/enroll", data={"animal_id": ANIMAL}, files=files)
    assert r.status_code == 404
    (e,) = recorded
    assert (e["kind"], e["result"], e["http_status"]) == ("enroll", "unowned_animal", 404)
    # FK safety: the column stays NULL for an unverified id; it goes in detail.
    assert e["animal_id"] is None
    assert e["detail"]["animal_id_attempted"] == ANIMAL


def test_enroll_storage_failure_writes_failure_row(client, jpeg_bytes, monkeypatch):
    import httpx

    async def fake_animal_owned(animal_id, owner):
        return True

    async def fake_upload(path, data):
        raise httpx.HTTPStatusError(
            "boom", request=httpx.Request("POST", "http://x"), response=httpx.Response(500)
        )

    monkeypatch.setattr(main_mod.db, "animal_owned", fake_animal_owned)
    monkeypatch.setattr(main_mod.storage, "upload_jpeg", fake_upload)
    recorded = _capture_events(monkeypatch)
    files = [("images", ("m.jpg", jpeg_bytes, "image/jpeg"))]
    r = client.post("/enroll", data={"animal_id": ANIMAL}, files=files)
    assert r.status_code == 502
    (e,) = recorded
    assert (e["result"], e["http_status"]) == ("storage_failed", 502)
    assert e["animal_id"] == ANIMAL  # ownership was confirmed before the failure
