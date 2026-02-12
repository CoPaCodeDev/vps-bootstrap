from pydantic import BaseModel


class TemplateVariable(BaseModel):
    name: str
    type: str  # required, secret, generate, default
    default: str = ""
    description: str = ""
    condition: str = ""  # z.B. "ENABLE_AI=j"


class Template(BaseModel):
    name: str
    description: str = ""
    variables: list[TemplateVariable] = []
    has_authelia: bool = False
    profiles: list[str] = []


class DeployRequest(BaseModel):
    template: str
    host: str
    vars: dict[str, str] = {}
    auth: bool = False


class Deployment(BaseModel):
    app: str
    host: str
    template: str = ""
    status: str = ""
    containers: int = 0
