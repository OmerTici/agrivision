from pydantic import BaseModel


class HealthResponse(BaseModel):
    status: str
    model_loaded: bool


class CandidateOut(BaseModel):
    animal_id: str
    name: str | None
    sim: float


class IdentifyResponse(BaseModel):
    decision: str  # "identified" | "unknown"
    animal_id: str | None = None
    name: str | None = None
    score: float
    margin: float
    candidates: list[CandidateOut]


class EnrollResponse(BaseModel):
    enrolled_count: int
    full_images_stored: int = 0
