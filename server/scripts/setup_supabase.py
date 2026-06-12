"""One-time Supabase setup for the CarniVision embedder.

Run from server/:  .venv/bin/python scripts/setup_supabase.py

Reads .env. Idempotent — safe to re-run. Does three things:
1. Applies sql/schema.sql (tables, RLS, no vector index — by design).
2. Verifies the private `muzzles` Storage bucket exists (created in dashboard).
3. Creates (or finds) a pilot test user via the Auth admin API and prints its
   uid — use it as TEST_OWNER_UID for tests/test_match.py.
"""
import asyncio
import pathlib
import sys

import asyncpg
import httpx

ROOT = pathlib.Path(__file__).resolve().parent.parent
TEST_EMAIL = "pilot-test@carnivision.local"


def load_env() -> dict:
    env = {}
    for line in (ROOT / ".env").read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1)
            env[k] = v.strip()
    return env


async def apply_schema(dsn: str) -> None:
    conn = await asyncpg.connect(dsn, statement_cache_size=0)
    try:
        await conn.execute((ROOT / "sql" / "schema.sql").read_text())
        dim = await conn.fetchval(
            "select atttypmod from pg_attribute "
            "where attrelid='embeddings'::regclass and attname='vec'"
        )
        events_ok = await conn.fetchval("select to_regclass('public.events') is not null")
        storage_policy_ok = await conn.fetchval(
            "select exists (select 1 from pg_policies where schemaname = 'storage' "
            "and tablename = 'objects' and policyname = 'muzzles owner read')"
        )
        print(f"[1/3] schema applied (embeddings.vec dim = {dim}, "
              f"events table = {'ok' if events_ok else 'MISSING'}, "
              f"muzzles read policy = {'ok' if storage_policy_ok else 'MISSING - add in Dashboard > Storage > Policies'})")
    finally:
        await conn.close()


def check_bucket(url: str, service_key: str) -> None:
    r = httpx.get(
        f"{url}/storage/v1/bucket/muzzles",
        headers={"Authorization": f"Bearer {service_key}", "apikey": service_key},
    )
    if r.status_code == 200:
        public = r.json().get("public")
        note = "PRIVATE (correct)" if not public else "WARNING: bucket is PUBLIC — make it private!"
        print(f"[2/3] muzzles bucket exists — {note}")
    else:
        print("[2/3] muzzles bucket NOT FOUND — create a private bucket named "
              "'muzzles' in Dashboard > Storage")


def ensure_test_user(url: str, service_key: str) -> None:
    headers = {"Authorization": f"Bearer {service_key}", "apikey": service_key}
    r = httpx.post(
        f"{url}/auth/v1/admin/users",
        headers=headers,
        json={"email": TEST_EMAIL, "password": "pilot-test-only-3kX9", "email_confirm": True},
    )
    if r.status_code in (200, 201):
        uid = r.json()["id"]
    else:
        # Already exists (or other error) — look it up.
        q = httpx.get(f"{url}/auth/v1/admin/users", headers=headers, params={"page": 1, "per_page": 100})
        q.raise_for_status()
        users = q.json().get("users", q.json() if isinstance(q.json(), list) else [])
        match = [u for u in users if u.get("email") == TEST_EMAIL]
        if not match:
            print(f"[3/3] could not create or find test user: {r.status_code} {r.text}")
            sys.exit(1)
        uid = match[0]["id"]
    print(f"[3/3] test user ready: {TEST_EMAIL}")
    print(f"\nTEST_OWNER_UID={uid}")
    print("\nRun the integration test with:")
    print(f"  INTEGRATION=1 TEST_OWNER_UID={uid} .venv/bin/pytest tests/test_match.py -v")


def main() -> None:
    env = load_env()
    asyncio.run(apply_schema(env["DATABASE_URL"]))
    check_bucket(env["SUPABASE_URL"], env["SUPABASE_SERVICE_ROLE_KEY"])
    ensure_test_user(env["SUPABASE_URL"], env["SUPABASE_SERVICE_ROLE_KEY"])


if __name__ == "__main__":
    main()
