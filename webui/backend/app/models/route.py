from pydantic import BaseModel


class Route(BaseModel):
    domain: str
    host: str
    port: int
    auth: bool = False
    tls: bool = True


class RouteCreate(BaseModel):
    domain: str
    host: str
    port: int
    auth: bool = False
