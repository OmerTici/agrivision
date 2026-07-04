import asyncio
import io
import json
import logging
import os
import time
import uuid
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


app = FastAPI(title="AgriVision Embedder", lifespan=lifespan)


def _ms(start: float) -> int:
    return round((time.perf_counter() - start) * 1000)


def _id_tail(value: str | None) -> str | None:
    if not value:
        return None
    return value[-8:]


def _log_demo(event: str, **fields) -> None:
    """Single-line JSON logs for first-demo calibration.

    Keep them compact and non-secret: user/animal ids are shortened, tokens and
    storage paths are never emitted.
    """
    logger.info(json.dumps({"event": event, **fields}, separators=(",", ":"), sort_keys=True))


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
    request_id = uuid.uuid4().hex[:10]
    started = time.perf_counter()
    raw = await image.read()
    try:
        pil = _decode_jpegs([raw])
    except HTTPException:
        _log_demo(
            "identify_invalid_image",
            request_id=request_id,
            owner=_id_tail(uid),
            image_bytes=len(raw),
            total_ms=_ms(started),
        )
        raise
    image_size = pil[0].size
    embed_started = time.perf_counter()
    vec = _embed(pil)[0]
    embed_ms = _ms(embed_started)
    match_started = time.perf_counter()
    candidates = await db.match(vec, uid)
    match_ms = _ms(match_started)
    s = get_settings()
    d = decide(candidates, s.sim_threshold, s.sim_margin)
    await _record_event(
        uid,
        "identify",
        d.animal_id,
        "identified" if d.decision == "identified" else "unknown",
        d.score,
    )
    _log_demo(
        "identify",
        request_id=request_id,
        owner=_id_tail(uid),
        decision=d.decision,
        animal_id=_id_tail(d.animal_id),
        score=round(d.score, 4),
        margin=round(d.margin, 4),
        model_name=s.embedding_model_name,
        threshold=s.sim_threshold,
        margin_threshold=s.sim_margin,
        candidates=[
            {"animal_id": _id_tail(c.animal_id), "sim": round(c.sim, 4)}
            for c in candidates[:3]
        ],
        candidate_count=len(candidates),
        image_bytes=len(raw),
        image_width=image_size[0],
        image_height=image_size[1],
        embed_ms=embed_ms,
        match_ms=match_ms,
        total_ms=_ms(started),
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
    request_id = uuid.uuid4().hex[:10]
    started = time.perf_counter()
    if not await db.animal_owned(animal_id, uid):
        _log_demo(
            "enroll_unowned_animal",
            request_id=request_id,
            owner=_id_tail(uid),
            animal_id=_id_tail(animal_id),
            total_ms=_ms(started),
        )
        raise HTTPException(status_code=404, detail="animal not found for this user")
    raw = [await f.read() for f in images]
    try:
        pil = _decode_jpegs(raw)
    except HTTPException:
        _log_demo(
            "enroll_invalid_muzzle_image",
            request_id=request_id,
            owner=_id_tail(uid),
            animal_id=_id_tail(animal_id),
            muzzle_count=len(raw),
            muzzle_bytes=sum(len(data) for data in raw),
            total_ms=_ms(started),
        )
        raise
    raw_full = [await f.read() for f in full_images]
    try:
        _decode_jpegs(raw_full)  # validate only; full pictures are stored, never embedded
    except HTTPException:
        _log_demo(
            "enroll_invalid_full_image",
            request_id=request_id,
            owner=_id_tail(uid),
            animal_id=_id_tail(animal_id),
            full_image_count=len(raw_full),
            full_image_bytes=sum(len(data) for data in raw_full),
            total_ms=_ms(started),
        )
        raise
    embed_started = time.perf_counter()
    vecs = _embed(pil)  # ONE batched forward pass for all muzzle crops
    embed_ms = _ms(embed_started)
    paths = []
    # On partial upload failure we return 502 and skip the DB insert; already-
    # uploaded objects are left as storage orphans (DB stays the source of
    # truth). Acceptable for MVP; a cleanup pass can reap them later.
    try:
        upload_started = time.perf_counter()
        for data in raw:
            path = storage.object_path(uid, animal_id, "muzzle")
            await storage.upload_jpeg(path, data)
            paths.append(path)
        for data in raw_full:
            await storage.upload_jpeg(storage.object_path(uid, animal_id, "full"), data)
        upload_ms = _ms(upload_started)
    except httpx.HTTPError:
        _log_demo(
            "enroll_storage_failed",
            request_id=request_id,
            owner=_id_tail(uid),
            animal_id=_id_tail(animal_id),
            muzzle_count=len(raw),
            full_image_count=len(raw_full),
            total_ms=_ms(started),
        )
        raise HTTPException(status_code=502, detail="image storage upload failed")
    insert_started = time.perf_counter()
    count = await db.insert_embeddings(animal_id, uid, vecs, paths)
    insert_ms = _ms(insert_started)
    await _record_event(uid, "enroll", animal_id, "enrolled", None)
    _log_demo(
        "enroll",
        request_id=request_id,
        owner=_id_tail(uid),
        animal_id=_id_tail(animal_id),
        model_name=get_settings().embedding_model_name,
        muzzle_count=len(raw),
        full_image_count=len(raw_full),
        enrolled_count=count,
        muzzle_bytes=sum(len(data) for data in raw),
        full_image_bytes=sum(len(data) for data in raw_full),
        image_sizes=[{"width": im.size[0], "height": im.size[1]} for im in pil],
        embed_ms=embed_ms,
        upload_ms=upload_ms,
        insert_ms=insert_ms,
        total_ms=_ms(started),
    )
    return EnrollResponse(enrolled_count=count, full_images_stored=len(raw_full))
