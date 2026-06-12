import pytest

from app.storage import object_path


def test_object_path_is_owner_prefixed_with_kind():
    p = object_path("owner-uid", "animal-uid", "muzzle")
    assert p.startswith("owner-uid/animal-uid/muzzle/")
    assert p.endswith(".jpg")
    f = object_path("owner-uid", "animal-uid", "full")
    assert f.startswith("owner-uid/animal-uid/full/")


def test_object_paths_unique():
    a = object_path("o", "a", "muzzle")
    b = object_path("o", "a", "muzzle")
    assert a != b


def test_object_path_rejects_unknown_kind():
    with pytest.raises(ValueError):
        object_path("o", "a", "thumbnail")
