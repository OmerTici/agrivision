from app.config import Settings


def test_defaults_match_pilot_operating_point():
    s = Settings(_env_file=None)
    assert s.sim_threshold == 0.60
    assert s.sim_margin == 0.05
    assert s.storage_bucket == "muzzles"
    assert s.embedding_model_name == (
        "conservationxlabs/miewid-msv3@4f1d7f2b521149e5fe34bb85f377248ce9971a7d"
    )


def test_env_override(monkeypatch):
    monkeypatch.setenv("SIM_THRESHOLD", "0.9")
    s = Settings(_env_file=None)
    assert s.sim_threshold == 0.9
