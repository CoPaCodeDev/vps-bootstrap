from pydantic import BaseModel


class SessionCreate(BaseModel):
    project: str
    telegram: bool = False


class SessionStatus(BaseModel):
    project: str
    pid: int | None = None
    running: bool = False
    telegram: bool = False


class VideoInfo(BaseModel):
    id: str
    filename: str
    size: int
    created: str
