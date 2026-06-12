from app.config import Settings


def test_defaults_match_pilot_operating_point():
    s = Settings(_env_file=None)
    assert s.sim_threshold == 0.60
    assert s.sim_margin == 0.05
    assert s.storage_bucket == "muzzles"


def test_env_override(monkeypatch):
    monkeypatch.setenv("SIM_THRESHOLD", "0.9")
    s = Settings(_env_file=None)
    assert s.sim_threshold == 0.9
