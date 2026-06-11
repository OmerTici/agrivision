import time

import jwt
import pytest
from fastapi import HTTPException

from app.auth import verify_jwt

SECRET = "test-secret-0123456789abcdef0123456789abcdef"


def make_token(secret=SECRET, sub="user-123", aud="authenticated", exp_delta=3600):
    return jwt.encode(
        {"sub": sub, "aud": aud, "exp": int(time.time()) + exp_delta},
        secret,
        algorithm="HS256",
    )


def test_valid_token_returns_uid():
    assert verify_jwt(make_token(), SECRET) == "user-123"


def test_wrong_secret_rejected():
    with pytest.raises(HTTPException) as e:
        verify_jwt(make_token(secret="other-secret-0123456789abcdef0123456789"), SECRET)
    assert e.value.status_code == 401


def test_expired_token_rejected():
    with pytest.raises(HTTPException) as e:
        verify_jwt(make_token(exp_delta=-10), SECRET)
    assert e.value.status_code == 401


def test_wrong_audience_rejected():
    with pytest.raises(HTTPException) as e:
        verify_jwt(make_token(aud="anon"), SECRET)
    assert e.value.status_code == 401


def test_missing_sub_rejected():
    tok = jwt.encode({"aud": "authenticated", "exp": int(time.time()) + 60}, SECRET, algorithm="HS256")
    with pytest.raises(HTTPException) as e:
        verify_jwt(tok, SECRET)
    assert e.value.status_code == 401
