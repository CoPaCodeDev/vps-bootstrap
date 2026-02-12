from pydantic import BaseModel


class VPS(BaseModel):
    name: str
    host: str
    ip: str
    description: str = ""


class VPSStatus(BaseModel):
    host: str
    online: bool
    load: str = ""
    uptime: str = ""
    updates_available: int = 0
    reboot_required: bool = False
    kernel: str = ""
    memory_used: str = ""
    memory_total: str = ""
    disk_used: str = ""
    disk_total: str = ""


class ExecRequest(BaseModel):
    command: str
