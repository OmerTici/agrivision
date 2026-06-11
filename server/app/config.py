from functools import lru_cache

from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    # Supabase project
    supabase_url: str = ""                # https://<ref>.supabase.co
    supabase_jwt_secret: str = ""         # legacy HS256 secret (Dashboard > API)
    supabase_service_role_key: str = ""   # Storage uploads only
    # Supavisor TRANSACTION pooler DSN (port 6543), never direct 5432
    database_url: str = ""
    storage_bucket: str = "muzzles"

    # Open-set decision rule — bakeoff suggested_threshold (miewid-msv3.json)
    sim_threshold: float = 0.7746
    sim_margin: float = 0.05

    model_config = {"env_file": ".env", "extra": "ignore"}


@lru_cache
def get_settings() -> Settings:
    return Settings()
