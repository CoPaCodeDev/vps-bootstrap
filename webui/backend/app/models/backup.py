from pydantic import BaseModel


class Snapshot(BaseModel):
    id: str
    short_id: str
    time: str
    hostname: str
    tags: list[str] = []
    paths: list[str] = []
    size: str = ""


class BackupStatus(BaseModel):
    host: str
    last_backup: str = ""
    next_backup: str = ""
    snapshots: int = 0
    repo_size: str = ""
    healthy: bool = True


class RestoreRequest(BaseModel):
    snapshot_id: str
    target: str = ""
    paths: list[str] = []


class ForgetRequest(BaseModel):
    keep_last: int = 7
    keep_daily: int = 7
    keep_weekly: int = 4
    keep_monthly: int = 6
