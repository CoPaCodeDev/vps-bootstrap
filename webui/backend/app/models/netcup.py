from pydantic import BaseModel


class DeviceCodeResponse(BaseModel):
    session_id: str
    verification_uri: str
    user_code: str
    expires_in: int


class LoginStatus(BaseModel):
    status: str  # pending, success, error
    message: str = ""


class Server(BaseModel):
    id: str
    name: str
    status: str = ""
    ip: str = ""
    ipv6: str = ""
    os: str = ""
    cpu: int = 0
    ram_mb: int = 0
    disk_gb: int = 0


class InstallRequest(BaseModel):
    hostname: str
    image: str
    password: str
    setup_vlan: bool = True
