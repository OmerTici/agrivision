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
    sim_threshold: float = 0.60
    sim_margin: float = 0.05

    model_config = {"env_file": ".env", "extra": "ignore"}


@lru_cache
def get_settings() -> Settings:
    return Settings()
