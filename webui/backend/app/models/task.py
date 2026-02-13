from pydantic import BaseModel
from enum import Enum


class TaskStatus(str, Enum):
    pending = "pending"
    running = "running"
    completed = "completed"
    failed = "failed"


class TaskInfo(BaseModel):
    task_id: str
    type: str
    description: str
    status: TaskStatus = TaskStatus.pending
    host: str = ""
    started_at: str = ""
    finished_at: str = ""
    exit_code: int | None = None
    output_lines: int = 0


class TaskCreate(BaseModel):
    task_id: str
