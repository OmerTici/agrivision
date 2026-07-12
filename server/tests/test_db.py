import numpy as np
import pytest

from app.db import INSERT_SQL, MATCH_SQL, vector_literal


def test_vector_literal_format():
    lit = vector_literal(np.array([0.5, -0.25, 1.0], dtype=np.float32))
    assert lit.startswith("[") and lit.endswith("]")
    parts = [float(p) for p in lit[1:-1].split(",")]
    assert parts == [0.5, -0.25, 1.0]


def test_vector_literal_roundtrip_precision():
    vec = np.random.default_rng(48).standard_normal(2152).astype(np.float32)
    vec /= np.linalg.norm(vec)
    parts = np.array([float(p) for p in vector_literal(vec)[1:-1].split(",")], dtype=np.float32)
    assert np.allclose(parts, vec, atol=1e-7)


def test_vector_literal_rejects_non_finite():
    with pytest.raises(ValueError):
        vector_literal(np.array([0.5, np.nan], dtype=np.float32))
    with pytest.raises(ValueError):
        vector_literal(np.array([np.inf, 0.5], dtype=np.float32))


def test_match_sql_is_owner_scoped_exact_scan():
    assert "e.owner = $2::uuid" in MATCH_SQL
    assert "e.model_name = $3" in MATCH_SQL
    assert "<=>" in MATCH_SQL          # pgvector cosine distance
    assert "limit 5" in MATCH_SQL


def test_match_sql_excludes_soft_deleted():
    # Archived animals (deleted_at set) must never be returned by identify.
    assert "a.deleted_at is null" in MATCH_SQL


def test_match_sql_mean_of_top_m():
    # Per-animal score = avg of the m closest embeddings (rn <= $4), plus the
    # raw best-single sim for telemetry.
    assert "row_number() over (partition by a.id" in MATCH_SQL
    assert "rn <= $4" in MATCH_SQL
    assert "avg(sim)" in MATCH_SQL
    assert "max(sim) as max_sim" in MATCH_SQL


def test_insert_sql_records_model_name():
    assert "model_name" in INSERT_SQL
    assert "$5" in INSERT_SQL
