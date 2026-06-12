"""Supabase Storage uploads via the REST API (service-role key).
Bucket is private; paths are owner-prefixed so per-owner Storage policies
line up with the DB's RLS model.

Object paths follow the layout:
  {owner}/{animal_id}/muzzle/{uuid}.jpg  — muzzle crops (embedded + in DB)
  {owner}/{animal_id}/full/{uuid}.jpg    — full pictures (stored only, not embedded)
"""
import uuid

import httpx

from .config import get_settings


def object_path(owner: str, animal_id: str, kind: str) -> str:
    if kind not in ("muzzle", "full"):
        raise ValueError(f"unknown image kind: {kind}")
    return f"{owner}/{animal_id}/{kind}/{uuid.uuid4().hex}.jpg"


async def upload_jpeg(path: str, data: bytes) -> str:
    s = get_settings()
    url = f"{s.supabase_url}/storage/v1/object/{s.storage_bucket}/{path}"
    async with httpx.AsyncClient(timeout=30) as client:
        resp = await client.post(
            url,
            content=data,
            headers={
                "Authorization": f"Bearer {s.supabase_service_role_key}",
                "Content-Type": "image/jpeg",
            },
        )
    resp.raise_for_status()
    return path
