import numpy as np

from app.db import MATCH_SQL, vector_literal


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


def test_match_sql_is_owner_scoped_exact_scan():
    assert "e.owner = $2::uuid" in MATCH_SQL
    assert "<=>" in MATCH_SQL          # pgvector cosine distance
    assert "limit 5" in MATCH_SQL
