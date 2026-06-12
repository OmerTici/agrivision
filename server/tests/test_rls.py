"""Integration: RLS isolation across owners (PostgREST + Storage).

Proves the design's decision #4: user B's JWT cannot read user A's animals,
events, or stored photos, while A can read their own.

Run from server/:
  INTEGRATION=1 \
  SUPABASE_URL=https://<ref>.supabase.co \
  SUPABASE_ANON_KEY=sb_publishable_... \
  SUPABASE_SERVICE_ROLE_KEY=sb_secret_... \
  DATABASE_URL=postgresql://...pooler.supabase.com:6543/postgres \
  .venv/bin/pytest tests/test_rls.py -v
"""
import io
import os

import asyncpg
import httpx
import pytest

pytestmark = pytest.mark.integration

if os.environ.get("INTEGRATION") != "1":
    pytest.skip("set INTEGRATION=1 to run", allow_module_level=True)

USER_A = ("pilot-test@carnivision.local", "pilot-test-only-3kX9")
USER_B = ("rls-test-b@carnivision.local", "rls-test-only-7pQ2")


def _url() -> str:
    return os.environ["SUPABASE_URL"]


def _service_headers() -> dict:
    key = os.environ["SUPABASE_SERVICE_ROLE_KEY"]
    return {"Authorization": f"Bearer {key}", "apikey": key}


def _ensure_user(email: str, password: str) -> None:
    # 200/201 = created; 422 = already exists — both fine, sign-in verifies.
    httpx.post(
        f"{_url()}/auth/v1/admin/users",
        headers=_service_headers(),
        json={"email": email, "password": password, "email_confirm": True},
    )


def _sign_in(email: str, password: str) -> tuple[str, str]:
    anon = os.environ["SUPABASE_ANON_KEY"]
    r = httpx.post(
        f"{_url()}/auth/v1/token?grant_type=password",
        headers={"apikey": anon},
        json={"email": email, "password": password},
    )
    r.raise_for_status()
    body = r.json()
    return body["access_token"], body["user"]["id"]


def _user_headers(token: str) -> dict:
    return {"Authorization": f"Bearer {token}", "apikey": os.environ["SUPABASE_ANON_KEY"]}


def _jpeg_bytes() -> bytes:
    from PIL import Image

    buf = io.BytesIO()
    Image.new("RGB", (32, 32), (90, 90, 90)).save(buf, format="JPEG")
    return buf.getvalue()


async def test_rls_blocks_cross_owner_reads():
    from app import storage

    _ensure_user(*USER_A)
    _ensure_user(*USER_B)
    token_a, uid_a = _sign_in(*USER_A)
    token_b, uid_b = _sign_in(*USER_B)
    assert uid_a != uid_b

    conn = await asyncpg.connect(os.environ["DATABASE_URL"], statement_cache_size=0)
    object_path = None
    try:
        animal_id = await conn.fetchval(
            "insert into animals (owner, name) values ($1::uuid, $2) returning id::text",
            uid_a, "rls-test-animal",
        )
        await conn.execute(
            "insert into events (owner, kind, animal_id, result, score) "
            "values ($1::uuid, 'identify', $2::uuid, 'identified', 0.91)",
            uid_a, animal_id,
        )
        object_path = storage.object_path(uid_a, animal_id, "muzzle")
        await storage.upload_jpeg(object_path, _jpeg_bytes())

        # --- B sees none of A's rows via PostgREST ---
        r = httpx.get(f"{_url()}/rest/v1/animals?select=id", headers=_user_headers(token_b))
        r.raise_for_status()
        assert animal_id not in [row["id"] for row in r.json()]

        r = httpx.get(f"{_url()}/rest/v1/events?select=id,owner", headers=_user_headers(token_b))
        r.raise_for_status()
        assert all(row["owner"] != uid_a for row in r.json())

        # --- B cannot read A's photo ---
        r = httpx.get(
            f"{_url()}/storage/v1/object/authenticated/muzzles/{object_path}",
            headers=_user_headers(token_b),
        )
        assert r.status_code != 200, f"cross-owner storage read allowed: {r.status_code}"

        # --- A CAN read their own photo (proves the read policy exists) ---
        r = httpx.get(
            f"{_url()}/storage/v1/object/authenticated/muzzles/{object_path}",
            headers=_user_headers(token_a),
        )
        assert r.status_code == 200, (
            f"owner storage read denied ({r.status_code}) — is the 'muzzles owner read' "
            "policy applied? (schema.sql DO block / Dashboard > Storage > Policies)"
        )

        # --- A sees their own rows via PostgREST ---
        r = httpx.get(f"{_url()}/rest/v1/animals?select=id", headers=_user_headers(token_a))
        r.raise_for_status()
        assert animal_id in [row["id"] for row in r.json()]

        r = httpx.get(
            f"{_url()}/rest/v1/events?select=animal_id,result,score",
            headers=_user_headers(token_a),
        )
        r.raise_for_status()
        assert any(row["animal_id"] == animal_id for row in r.json())
    finally:
        await conn.execute("delete from events where owner = $1::uuid", uid_a)
        await conn.execute(
            "delete from animals where owner = $1::uuid and name = 'rls-test-animal'", uid_a
        )
        await conn.close()
        if object_path:
            httpx.request(
                "DELETE",
                f"{_url()}/storage/v1/object/muzzles/{object_path}",
                headers=_service_headers(),
            )
