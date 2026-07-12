"""Open-set decision rule from the bakeoff: accept the top animal only if its
similarity clears the threshold AND beats the runner-up animal by the margin.
Candidates are per-animal mean-of-top-m cosine scores, ordered best-first."""
from dataclasses import dataclass


@dataclass
class Candidate:
    animal_id: str
    name: str | None
    sim: float  # mean of the animal's top-m cosine sims (ranking/decision score)
    max_sim: float | None = None  # best single-embedding sim, telemetry only


@dataclass
class Decision:
    decision: str  # "identified" | "unknown"
    animal_id: str | None
    name: str | None
    score: float
    margin: float


def decide(candidates: list[Candidate], threshold: float, margin: float) -> Decision:
    if not candidates:
        return Decision("unknown", None, None, 0.0, 0.0)
    top = candidates[0]
    # With one enrolled animal there is no runner-up; the margin criterion
    # is trivially satisfied (mirrors the bakeoff's top2-distinct semantics).
    gap = top.sim - candidates[1].sim if len(candidates) > 1 else 1.0
    if top.sim >= threshold and gap >= margin:
        return Decision("identified", top.animal_id, top.name, top.sim, gap)
    return Decision("unknown", None, None, top.sim, gap)
