from functools import lru_cache

from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    # Supabase project
    supabase_url: str = ""                # https://<ref>.supabase.co
    supabase_service_role_key: str = ""   # Storage uploads only
    # Supavisor TRANSACTION pooler DSN (port 6543), never direct 5432
    database_url: str = ""
    storage_bucket: str = "muzzles"

    # Open-set decision rule — tuned for 5-photo enrollment (2026-06-11 recalibration;
    # bakeoff suggested_threshold 0.7746 assumed ~15-image galleries).
    # CAUTION: threshold/margin were calibrated on per-animal MAX cosine; the
    # ranking score is now mean-of-top-m, which runs systematically lower.
    # Re-fit both from events.detail top_max_sim / top_mean_sim telemetry.
    sim_threshold: float = 0.60
    sim_margin: float = 0.05
    # Per-animal score = mean of the animal's sim_top_m closest embeddings
    # (robust to a single rogue enrollment frame; no gallery-size bias).
    sim_top_m: int = 3
    # Embedding-space identifier. Matching filters to this value because vectors
    # from different model versions are not comparable. Change this only when
    # deploying a new embedder and re-embedding enrolled animals.
    embedding_model_name: str = (
        "conservationxlabs/miewid-msv3@4f1d7f2b521149e5fe34bb85f377248ce9971a7d"
    )

    model_config = {"env_file": ".env", "extra": "ignore"}


@lru_cache
def get_settings() -> Settings:
    return Settings()
