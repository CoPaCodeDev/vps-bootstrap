from pydantic import BaseModel


class Container(BaseModel):
    id: str
    name: str
    image: str
    status: str
    state: str
    ports: str = ""
    created: str = ""


class DockerOverview(BaseModel):
    host: str
    online: bool
    docker_installed: bool = False
    containers: list[Container] = []
    running: int = 0
    stopped: int = 0
