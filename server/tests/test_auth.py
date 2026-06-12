import time

import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric import ec
from fastapi import HTTPException

import app.auth as auth_mod
from app.auth import verify_jwt

PRIVATE_KEY = ec.generate_private_key(ec.SECP256R1())
PUBLIC_KEY = PRIVATE_KEY.public_key()
OTHER_KEY = ec.generate_private_key(ec.SECP256R1())


class FakeSigningKey:
    key = PUBLIC_KEY


class FakeJWKS:
    def get_signing_key_from_jwt(self, token):
        return FakeSigningKey()


@pytest.fixture(autouse=True)
def fake_jwks(monkeypatch):
    monkeypatch.setattr(auth_mod, "_jwks", lambda: FakeJWKS())


def make_token(key=PRIVATE_KEY, sub="user-123", aud="authenticated", exp_delta=3600):
    return jwt.encode(
        {"sub": sub, "aud": aud, "exp": int(time.time()) + exp_delta},
        key,
        algorithm="ES256",
        headers={"kid": "test-kid"},
    )


def test_valid_token_returns_uid():
    assert verify_jwt(make_token()) == "user-123"


def test_wrong_key_rejected():
    with pytest.raises(HTTPException) as e:
        verify_jwt(make_token(key=OTHER_KEY))
    assert e.value.status_code == 401


def test_expired_token_rejected():
    with pytest.raises(HTTPException) as e:
        verify_jwt(make_token(exp_delta=-10))
    assert e.value.status_code == 401


def test_wrong_audience_rejected():
    with pytest.raises(HTTPException) as e:
        verify_jwt(make_token(aud="anon"))
    assert e.value.status_code == 401


def test_hs256_token_rejected():
    tok = jwt.encode(
        {"sub": "user-123", "aud": "authenticated", "exp": int(time.time()) + 60},
        "some-shared-secret-0123456789abcdef0123456789",
        algorithm="HS256",
    )
    with pytest.raises(HTTPException) as e:
        verify_jwt(tok)
    assert e.value.status_code == 401


def test_missing_sub_rejected():
    tok = jwt.encode(
        {"aud": "authenticated", "exp": int(time.time()) + 60},
        PRIVATE_KEY,
        algorithm="ES256",
    )
    with pytest.raises(HTTPException) as e:
        verify_jwt(tok)
    assert e.value.status_code == 401
