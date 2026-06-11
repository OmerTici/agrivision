"""Supabase JWT verification — legacy HS256 secret (decided 2026-06-11).
ALL verify logic lives here so the future swap to JWKS (asymmetric keys)
is a one-file change."""
import jwt
from fastapi import Header, HTTPException

from .config import get_settings


def verify_jwt(token: str, secret: str) -> str:
    """Return the authenticated user's uid (the `sub` claim) or raise 401."""
    try:
        payload = jwt.decode(
            token, secret, algorithms=["HS256"], audience="authenticated"
        )
    except jwt.InvalidTokenError:
        raise HTTPException(status_code=401, detail="invalid token")
    sub = payload.get("sub")
    if not sub:
        raise HTTPException(status_code=401, detail="token missing sub claim")
    return sub


def current_uid(authorization: str = Header(default="")) -> str:
    """FastAPI dependency: extract and verify the bearer token."""
    if not authorization.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="missing bearer token")
    return verify_jwt(authorization[len("Bearer "):], get_settings().supabase_jwt_secret)
