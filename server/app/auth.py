"""Supabase JWT verification — asymmetric signing keys (ES256) via the
project's JWKS endpoint (the project uses Supabase's new JWT signing keys;
there is no legacy HS256 secret). ALL verify logic lives here.

PyJWKClient caches fetched keys and refreshes on unknown kid, so key
rotation is handled without restarts."""
import jwt
from fastapi import Header, HTTPException

from .config import get_settings

_jwks_client: jwt.PyJWKClient | None = None


def _jwks() -> jwt.PyJWKClient:
    global _jwks_client
    if _jwks_client is None:
        url = f"{get_settings().supabase_url}/auth/v1/.well-known/jwks.json"
        _jwks_client = jwt.PyJWKClient(url, cache_keys=True, lifespan=3600)
    return _jwks_client


def verify_jwt(token: str) -> str:
    """Return the authenticated user's uid (the `sub` claim) or raise 401."""
    try:
        key = _jwks().get_signing_key_from_jwt(token).key
        payload = jwt.decode(
            token, key, algorithms=["ES256", "RS256"], audience="authenticated"
        )
    except (jwt.InvalidTokenError, jwt.PyJWKClientError):
        raise HTTPException(status_code=401, detail="invalid token")
    sub = payload.get("sub")
    if not sub:
        raise HTTPException(status_code=401, detail="invalid token")
    return sub


def current_uid(authorization: str = Header(default="")) -> str:
    """FastAPI dependency: extract and verify the bearer token."""
    if not authorization.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="missing bearer token")
    return verify_jwt(authorization[len("Bearer "):])
