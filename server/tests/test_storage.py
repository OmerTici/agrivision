from app.storage import object_path


def test_object_path_is_owner_prefixed():
    p = object_path("owner-uid", "animal-uid")
    assert p.startswith("owner-uid/animal-uid/")
    assert p.endswith(".jpg")


def test_object_paths_unique():
    a = object_path("o", "a")
    b = object_path("o", "a")
    assert a != b
