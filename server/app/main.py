import asyncio
import io
import logging
import os
from contextlib import asynccontextmanager

import httpx
from fastapi import Depends, FastAPI, File, Form, HTTPException, UploadFile
from PIL import Image

from . import db, storage
from .auth import current_uid
from .config import get_settings
from .decision import decide
from .schemas import CandidateOut, EnrollResponse, HealthResponse, IdentifyResponse

logger = logging.getLogger("carnivision.embedder")

# Module-global model slot. Tests pre-populate it with a fake; production
# leaves it None and the lifespan loads the real model once per container.
state: dict = {"embedder": None}


@asynccontextmanager
async def lifespan(app: FastAPI):
    if state["embedder"] is None and os.environ.get("SKIP_MODEL_LOAD") != "1":
        from .miewid import MiewIDEmbedder

        state["embedder"] = MiewIDEmbedder(device="cpu")
    yield


app = FastAPI(title="CarniVision Embedder", lifespan=lifespan)


def _decode_jpegs(uploads: list[bytes]) -> list[Image.Image]:
    images = []
    for raw in uploads:
        try:
            images.append(Image.open(io.BytesIO(raw)).convert("RGB"))
        except Exception:
            raise HTTPException(status_code=422, detail="invalid image payload")
    return images


def _embed(images: list[Image.Image]):
    embedder = state["embedder"]
    if embedder is None:
        raise HTTPException(status_code=503, detail="model not loaded yet")
    try:
        return embedder.embed_batch(images)
    except Exception:
        logger.exception("embedding failed")
        raise HTTPException(status_code=500, detail="embedding failed")


async def _record_event(
    owner: str, kind: str, animal_id: str | None, result: str, score: float | None
) -> None:
    """Best-effort event-feed write: an insert failure must never fail the
    API response — log and continue. Capped at 5s so a degraded pool can't
    stall the response while the insert waits on a connection."""
    try:
        await asyncio.wait_for(
            db.insert_event(owner, kind, animal_id, result, score), timeout=5.0
        )
    except Exception:
        logger.exception("event insert failed (kind=%s, result=%s)", kind, result)


# NOT /healthz — Google Frontend reserves that path on *.run.app and swallows it.
@app.get("/health", response_model=HealthResponse)
async def health():
    return HealthResponse(
        status="ok" if state["embedder"] is not None else "loading",
        model_loaded=state["embedder"] is not None,
    )


@app.post("/identify", response_model=IdentifyResponse)
async def identify(image: UploadFile = File(...), uid: str = Depends(current_uid)):
    pil = _decode_jpegs([await image.read()])
    vec = _embed(pil)[0]
    candidates = await db.match(vec, uid)
    s = get_settings()
    d = decide(candidates, s.sim_threshold, s.sim_margin)
    await _record_event(
        uid,
        "identify",
        d.animal_id,
        "identified" if d.decision == "identified" else "unknown",
        d.score,
    )
    return IdentifyResponse(
        decision=d.decision,
        animal_id=d.animal_id,
        name=d.name,
        score=d.score,
        margin=d.margin,
        candidates=[CandidateOut(animal_id=c.animal_id, name=c.name, sim=c.sim) for c in candidates],
    )


@app.post("/enroll", response_model=EnrollResponse)
async def enroll(
    animal_id: str = Form(...),
    images: list[UploadFile] = File(...),
    full_images: list[UploadFile] = File(default=[]),
    uid: str = Depends(current_uid),
):
    if not await db.animal_owned(animal_id, uid):
        raise HTTPException(status_code=404, detail="animal not found for this user")
    raw = [await f.read() for f in images]
    pil = _decode_jpegs(raw)
    raw_full = [await f.read() for f in full_images]
    _decode_jpegs(raw_full)  # validate only; full pictures are stored, never embedded
    vecs = _embed(pil)  # ONE batched forward pass for all muzzle crops
    paths = []
    # On partial upload failure we return 502 and skip the DB insert; already-
    # uploaded objects are left as storage orphans (DB stays the source of
    # truth). Acceptable for MVP; a cleanup pass can reap them later.
    try:
        for data in raw:
            path = storage.object_path(uid, animal_id, "muzzle")
            await storage.upload_jpeg(path, data)
            paths.append(path)
        for data in raw_full:
            await storage.upload_jpeg(storage.object_path(uid, animal_id, "full"), data)
    except httpx.HTTPError:
        raise HTTPException(status_code=502, detail="image storage upload failed")
    count = await db.insert_embeddings(animal_id, uid, vecs, paths)
    await _record_event(uid, "enroll", animal_id, "enrolled", None)
    return EnrollResponse(enrolled_count=count, full_images_stored=len(raw_full))
