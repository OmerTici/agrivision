import numpy as np
import pytest
from fastapi.testclient import TestClient

from app import db, storage
from app.auth import current_uid
from app.main import app, state

TEST_UID = "11111111-1111-1111-1111-111111111111"


class FakeEmbedder:
    """Deterministic unit vectors; index i lights up dimension i."""

    def embed_batch(self, pil_images):
        out = np.zeros((len(pil_images), 2152), dtype=np.float32)
        for i in range(len(pil_images)):
            out[i, i] = 1.0
        return out


@pytest.fixture
def client(monkeypatch):
    state["embedder"] = FakeEmbedder()
    app.dependency_overrides[current_uid] = lambda: TEST_UID

    async def _noop_insert_event(*args, **kwargs):
        return None

    async def _noop_upload(path, data):
        return path

    # Unit tests never touch Postgres or Storage; asserting tests re-stub these.
    monkeypatch.setattr(db, "insert_event", _noop_insert_event)
    monkeypatch.setattr(storage, "upload_jpeg", _noop_upload)
    with TestClient(app, raise_server_exceptions=False) as c:
        yield c
    app.dependency_overrides.clear()
    state["embedder"] = None


@pytest.fixture
def jpeg_bytes():
    import io

    from PIL import Image

    buf = io.BytesIO()
    Image.new("RGB", (64, 64), (128, 128, 128)).save(buf, format="JPEG")
    return buf.getvalue()
