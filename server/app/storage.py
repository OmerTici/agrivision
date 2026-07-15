"""Supabase Storage uploads via the REST API (service-role key).
Bucket is private; paths are owner-prefixed so per-owner Storage policies
line up with the DB's RLS model.

Object paths follow the layout:
  {owner}/{animal_id}/muzzle/{uuid}.jpg  — muzzle crops (embedded + in DB)
  {owner}/{animal_id}/full/{uuid}.jpg    — full pictures (stored only, not embedded)
  {owner}/{animal_id}/frame/{uuid}.jpg   — raw uncropped enrollment frames (dataset
                                           material for embedder training; never
                                           listed by the app's gallery)
  {owner}/_identify/muzzle/{req}.jpg     — the cropped muzzle sent to /identify
  {owner}/_identify/frame/{req}.jpg      — its raw uncropped frame (dataset material;
                                           `_identify` is a reserved segment — never a
                                           real UUID — so it can't collide with an
                                           animal folder)
"""
import uuid

import httpx

from .config import get_settings


def object_path(owner: str, animal_id: str, kind: str) -> str:
    if kind not in ("muzzle", "full", "frame"):
        raise ValueError(f"unknown image kind: {kind}")
    return f"{owner}/{animal_id}/{kind}/{uuid.uuid4().hex}.jpg"


def identify_object_path(owner: str, request_id: str, kind: str) -> str:
    """Path for an identify-time capture. Identify has no confirmed animal, so
    these live under the reserved `_identify` segment. The crop and its raw
    frame share the request_id stem so the embedder team can pair them."""
    if kind not in ("muzzle", "frame"):
        raise ValueError(f"unknown identify image kind: {kind}")
    return f"{owner}/_identify/{kind}/{request_id}.jpg"


async def upload_jpeg(path: str, data: bytes) -> str:
    s = get_settings()
    url = f"{s.supabase_url}/storage/v1/object/{s.storage_bucket}/{path}"
    async with httpx.AsyncClient(timeout=30) as client:
        resp = await client.post(
            url,
            content=data,
            # New-style sb_secret_ keys need BOTH headers; Bearer alone is rejected ("Invalid Compact JWS").
            headers={
                "Authorization": f"Bearer {s.supabase_service_role_key}",
                "apikey": s.supabase_service_role_key,
                "Content-Type": "image/jpeg",
            },
        )
    resp.raise_for_status()
    return path
