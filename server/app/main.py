import asyncio
import io
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


# HTTPException status -> events.result for failure rows.
_FAILURE_RESULTS = {
    404: "unowned_animal",
    422: "invalid_image",
    502: "storage_failed",
    503: "model_not_loaded",
}


class _RequestLog:
    """One events row per request — the app feed and the demo/calibration
    telemetry in a single write. Field defaults assume the worst (error/500);
    the happy path overwrites them just before returning. flush() is
    best-effort: an insert failure must never fail the API response, and is
    capped at 5s so a degraded pool can't stall the response."""

    def __init__(self, kind: str, owner: str):
        self.kind = kind
        self.owner = owner
        self.request_id = uuid.uuid4().hex[:10]
        self.started = time.perf_counter()
        self.animal_id: str | None = None  # only set once the animal is known to exist (FK)
        self.result = "error"
        self.http_status = 500
        self.score: float | None = None
        self.margin: float | None = None
        self.model_name = get_settings().embedding_model_name
        self.detail: dict = {}

    def fail(self, exc: HTTPException) -> None:
        self.http_status = exc.status_code
        self.result = _FAILURE_RESULTS.get(exc.status_code, "error")
        self.detail["error"] = exc.detail

    async def flush(self) -> None:
        try:
            await asyncio.wait_for(
                db.insert_event(
                    self.owner, self.kind, self.animal_id, self.result, self.score,
                    model_name=self.model_name,
                    margin=self.margin,
                    http_status=self.http_status,
                    total_ms=_ms(self.started),
                    request_id=self.request_id,
                    detail=self.detail,
                ),
                timeout=5.0,
            )
        except Exception:
            logger.exception(
                "event insert failed (kind=%s, result=%s, request_id=%s)",
                self.kind, self.result, self.request_id,
            )


# NOT /healthz — Google Frontend reserves that path on *.run.app and swallows it.
@app.get("/health", response_model=HealthResponse)
async def health():
    return HealthResponse(
        status="ok" if state["embedder"] is not None else "loading",
        model_loaded=state["embedder"] is not None,
    )


async def _save_identify_images(owner: str, request_id: str, crop: bytes, frame: bytes | None) -> None:
    """Persist an identify capture for the embedder team — the cropped muzzle
    that was matched plus its raw uncropped frame. Best-effort: a storage
    failure must never break a live identify, so it's logged and swallowed."""
    try:
        await storage.upload_jpeg(storage.identify_object_path(owner, request_id, "muzzle"), crop)
        if frame is not None:
            await storage.upload_jpeg(storage.identify_object_path(owner, request_id, "frame"), frame)
    except Exception:
        logger.exception("identify image save failed (request_id=%s)", request_id)


@app.post("/identify", response_model=IdentifyResponse)
async def identify(
    image: UploadFile = File(...),
    frame_image: UploadFile | None = File(default=None),
    uid: str = Depends(current_uid),
):
    rlog = _RequestLog("identify", uid)
    try:
        raw = await image.read()
        rlog.detail["image_bytes"] = len(raw)
        # Raw uncropped frame behind the muzzle crop — stored for the embedder
        # team, never embedded. Optional so older clients keep working.
        frame_bytes = await frame_image.read() if frame_image is not None else None
        rlog.detail["frame_bytes"] = len(frame_bytes) if frame_bytes is not None else 0
        pil = _decode_jpegs([raw])
        rlog.detail["image_sizes"] = [{"width": pil[0].width, "height": pil[0].height}]
        embed_started = time.perf_counter()
        vec = _embed(pil)[0]
        rlog.detail["embed_ms"] = _ms(embed_started)
        match_started = time.perf_counter()
        candidates = await db.match(vec, uid)
        rlog.detail["match_ms"] = _ms(match_started)
        s = get_settings()
        d = decide(candidates, s.sim_threshold, s.sim_margin)
        rlog.animal_id = d.animal_id
        rlog.result = "identified" if d.decision == "identified" else "unknown"
        rlog.http_status = 200
        rlog.score = d.score
        rlog.margin = d.margin
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
        # Keep the capture (crop + raw frame) for the embedder team's dataset.
        await _save_identify_images(uid, rlog.request_id, raw, frame_bytes)
        return IdentifyResponse(
            decision=d.decision,
            animal_id=d.animal_id,
            name=d.name,
            score=d.score,
            margin=d.margin,
            candidates=[
                CandidateOut(animal_id=c.animal_id, name=c.name, sim=c.sim)
                for c in candidates
            ],
        )
    except HTTPException as e:
        rlog.fail(e)
        raise
    except Exception as e:
        rlog.detail["error"] = repr(e)  # result/http_status already default to error/500
        raise
    finally:
        await rlog.flush()


@app.post("/enroll", response_model=EnrollResponse)
async def enroll(
    animal_id: str = Form(...),
    # Muzzle scans are optional at creation: a photos-only enroll uploads
    # gallery media without touching the embedding index, and the muzzle
    # burst can be added later from the animal's page.
    images: list[UploadFile] = File(default=[]),
    full_images: list[UploadFile] = File(default=[]),
    frame_images: list[UploadFile] = File(default=[]),
    uid: str = Depends(current_uid),
):
    rlog = _RequestLog("enroll", uid)
    try:
        if not await db.animal_owned(animal_id, uid):
            # Unverified id: keep it out of the FK column, log it in detail.
            rlog.detail["animal_id_attempted"] = animal_id
            raise HTTPException(status_code=404, detail="animal not found for this user")
        rlog.animal_id = animal_id
        raw = [await f.read() for f in images]
        rlog.detail["muzzle_count"] = len(raw)
        rlog.detail["muzzle_bytes"] = sum(len(data) for data in raw)
        pil = _decode_jpegs(raw)
        rlog.detail["image_sizes"] = [{"width": im.width, "height": im.height} for im in pil]
        raw_full = [await f.read() for f in full_images]
        rlog.detail["full_image_count"] = len(raw_full)
        rlog.detail["full_image_bytes"] = sum(len(data) for data in raw_full)
        _decode_jpegs(raw_full)  # validate only; full pictures are stored, never embedded
        # Raw uncropped frames behind the muzzle scans: stored under frame/ as
        # embedder-training material, invisible to the app's gallery.
        raw_frames = [await f.read() for f in frame_images]
        rlog.detail["frame_image_count"] = len(raw_frames)
        rlog.detail["frame_image_bytes"] = sum(len(data) for data in raw_frames)
        _decode_jpegs(raw_frames)
        embed_started = time.perf_counter()
        # ONE batched forward pass for all muzzle crops; skipped entirely for
        # a photos-only enroll (also keeps it off the 503 model-loading path).
        vecs = _embed(pil) if pil else []
        rlog.detail["embed_ms"] = _ms(embed_started)
        paths = []
        # On partial upload failure we return 502 and skip the DB insert; already-
        # uploaded objects are left as storage orphans (DB stays the source of
        # truth). Acceptable for MVP; a cleanup pass can reap them later.
        upload_started = time.perf_counter()
        try:
            for data in raw:
                path = storage.object_path(uid, animal_id, "muzzle")
                await storage.upload_jpeg(path, data)
                paths.append(path)
            for data in raw_full:
                await storage.upload_jpeg(storage.object_path(uid, animal_id, "full"), data)
            for data in raw_frames:
                await storage.upload_jpeg(storage.object_path(uid, animal_id, "frame"), data)
        except httpx.HTTPError:
            raise HTTPException(status_code=502, detail="image storage upload failed")
        rlog.detail["upload_ms"] = _ms(upload_started)
        insert_started = time.perf_counter()
        count = await db.insert_embeddings(animal_id, uid, vecs, paths) if paths else 0
        rlog.detail["insert_ms"] = _ms(insert_started)
        rlog.detail["enrolled_count"] = count
        rlog.result = "enrolled"
        rlog.http_status = 200
        return EnrollResponse(
            enrolled_count=count,
            full_images_stored=len(raw_full),
            frame_images_stored=len(raw_frames),
        )
    except HTTPException as e:
        rlog.fail(e)
        raise
    except Exception as e:
        rlog.detail["error"] = repr(e)
        raise
    finally:
        await rlog.flush()
