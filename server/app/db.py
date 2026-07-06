"""Postgres access via the Supavisor TRANSACTION pooler (port 6543).
statement_cache_size=0 is REQUIRED behind transaction pooling: prepared
statements don't survive connection reassignment.

Vectors are passed as pgvector text literals and cast in SQL — no client-side
codec registration needed, which also keeps the pooler happy.

Matching is an exact scan by design (no vector index): pgvector caps HNSW at
2000 dims (MiewID is 2152) and exact scan is ~0.2 ms at 1k vectors anyway."""
import asyncio
import json

import asyncpg
import numpy as np

from .config import get_settings
from .decision import Candidate

_pool: asyncpg.Pool | None = None
_pool_lock = asyncio.Lock()


def vector_literal(vec: np.ndarray) -> str:
    if not np.isfinite(vec).all():
        raise ValueError("vector contains non-finite values")
    return "[" + ",".join(repr(float(x)) for x in vec) + "]"


async def get_pool() -> asyncpg.Pool:
    global _pool
    async with _pool_lock:
        if _pool is None:
            _pool = await asyncpg.create_pool(
                get_settings().database_url,
                min_size=0,
                max_size=4,
                statement_cache_size=0,
            )
    return _pool


MATCH_SQL = """
select a.id::text as animal_id, a.name, max(1 - (e.vec <=> $1::vector)) as sim
from embeddings e
join animals a on a.id = e.animal_id and a.deleted_at is null
where e.owner = $2::uuid
  and e.model_name = $3
group by a.id, a.name
order by sim desc
limit 5
"""

INSERT_SQL = """
insert into embeddings (animal_id, owner, vec, image_path, model_name)
values ($1::uuid, $2::uuid, $3::vector, $4, $5)
"""

ANIMAL_OWNED_SQL = "select 1 from animals where id = $1::uuid and owner = $2::uuid"


async def match(vec: np.ndarray, owner: str) -> list[Candidate]:
    pool = await get_pool()
    rows = await pool.fetch(MATCH_SQL, vector_literal(vec), owner, get_settings().embedding_model_name)
    return [Candidate(r["animal_id"], r["name"], float(r["sim"])) for r in rows]


async def animal_owned(animal_id: str, owner: str) -> bool:
    pool = await get_pool()
    return await pool.fetchval(ANIMAL_OWNED_SQL, animal_id, owner) is not None


async def insert_embeddings(
    animal_id: str, owner: str, vecs: np.ndarray, image_paths: list[str]
) -> int:
    pool = await get_pool()
    model_name = get_settings().embedding_model_name
    args = [
        (animal_id, owner, vector_literal(v), p, model_name)
        for v, p in zip(vecs, image_paths, strict=True)
    ]
    await pool.executemany(INSERT_SQL, args)
    return len(args)


INSERT_EVENT_SQL = """
insert into events (owner, kind, animal_id, result, score,
                    model_name, margin, http_status, total_ms, request_id, detail)
values ($1::uuid, $2, $3::uuid, $4, $5, $6, $7, $8, $9, $10, $11::jsonb)
"""


async def insert_event(
    owner: str,
    kind: str,
    animal_id: str | None,
    result: str,
    score: float | None,
    *,
    model_name: str | None = None,
    margin: float | None = None,
    http_status: int | None = None,
    total_ms: int | None = None,
    request_id: str | None = None,
    detail: dict | None = None,
) -> None:
    pool = await get_pool()
    await pool.execute(
        INSERT_EVENT_SQL,
        owner, kind, animal_id, result, score,
        model_name, margin, http_status, total_ms, request_id,
        json.dumps(detail or {}),
    )
