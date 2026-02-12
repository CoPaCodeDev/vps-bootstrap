from pydantic import BaseModel


class AutheliaUser(BaseModel):
    username: str
    displayname: str = ""
    email: str = ""
    groups: list[str] = []
    disabled: bool = False


class AutheliaUserCreate(BaseModel):
    username: str
    displayname: str
    email: str
    password: str
    groups: list[str] = []


class AutheliaDomain(BaseModel):
    domain: str
    default_redirection_url: str = ""


class AutheliaDomainCreate(BaseModel):
    domain: str


class AutheliaStatus(BaseModel):
    running: bool
    version: str = ""
    users: int = 0
    domains: int = 0
