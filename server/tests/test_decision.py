from app.decision import Candidate, decide

T, M = 0.7746, 0.05


def c(animal_id, sim, name=None):
    return Candidate(animal_id=animal_id, name=name, sim=sim)


def test_identified_when_above_threshold_and_margin():
    d = decide([c("a1", 0.90, "Bessie"), c("a2", 0.70)], T, M)
    assert d.decision == "identified"
    assert d.animal_id == "a1"
    assert d.name == "Bessie"
    assert d.score == 0.90
    assert abs(d.margin - 0.20) < 1e-9


def test_unknown_below_threshold():
    d = decide([c("a1", 0.60), c("a2", 0.40)], T, M)
    assert d.decision == "unknown"
    assert d.animal_id is None


def test_unknown_when_margin_too_thin():
    d = decide([c("a1", 0.90), c("a2", 0.88)], T, M)
    assert d.decision == "unknown"


def test_single_candidate_margin_trivially_satisfied():
    d = decide([c("a1", 0.85, "Solo")], T, M)
    assert d.decision == "identified"


def test_empty_gallery_is_unknown():
    d = decide([], T, M)
    assert d.decision == "unknown"
    assert d.score == 0.0
