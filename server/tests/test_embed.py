import numpy as np
import pytest
from PIL import Image

pytestmark = pytest.mark.slow


@pytest.fixture(scope="module")
def embedder():
    from app.miewid import MiewIDEmbedder
    return MiewIDEmbedder(device="cpu")


def _img(color):
    return Image.new("RGB", (300, 300), color)


def test_embedding_is_2152d_and_l2_normalized(embedder):
    out = embedder.embed_batch([_img((255, 255, 255))])
    assert out.shape == (1, 2152)
    assert out.dtype == np.float32
    assert abs(np.linalg.norm(out[0]) - 1.0) < 1e-3


def test_batched_forward_pass(embedder):
    out = embedder.embed_batch([_img((255, 0, 0)), _img((0, 255, 0)), _img((0, 0, 255))])
    assert out.shape == (3, 2152)
    norms = np.linalg.norm(out, axis=1)
    assert np.all(np.abs(norms - 1.0) < 1e-3)
