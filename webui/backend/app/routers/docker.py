import asyncio
import json

from fastapi import APIRouter, Depends, HTTPException

from ..dependencies import get_current_user
from ..models.docker import Container, DockerOverview
from ..models.task import TaskCreate
from ..services.hosts import parse_hosts_file, resolve_host
from ..services.ssh import run_ssh, run_ssh_stream, check_host_online
from ..services.task_manager import task_manager

router = APIRouter(prefix="/docker", tags=["Docker"])


@router.get("/", response_model=list[DockerOverview])
async def docker_overview(user: str = Depends(get_current_user)):
    """Docker-Übersicht aller VPS."""
    hosts = parse_hosts_file()
    results = []

    async def check_docker(vps):
        online = await check_host_online(vps.ip)
        if not online:
            return DockerOverview(host=vps.name, online=False)

        code, _, _ = await run_ssh(vps.ip, "command -v docker", timeout=5)
        if code != 0:
            return DockerOverview(host=vps.name, online=True, docker_installed=False)

        code, stdout, _ = await run_ssh(
            vps.ip, "sudo docker ps -a --format json", timeout=10
        )
        containers = []
        running = 0
        stopped = 0
        if code == 0 and stdout:
            for line in stdout.strip().split("\n"):
                if not line.strip():
                    continue
                try:
                    c = json.loads(line)
                    state = c.get("State", "")
                    if state == "running":
                        running += 1
                    else:
                        stopped += 1
                    containers.append(
                        Container(
                            id=c.get("ID", ""),
                            name=c.get("Names", ""),
                            image=c.get("Image", ""),
                            status=c.get("Status", ""),
                            state=state,
                            ports=c.get("Ports", ""),
                            created=c.get("CreatedAt", ""),
                        )
                    )
                except json.JSONDecodeError:
                    continue

        return DockerOverview(
            host=vps.name,
            online=True,
            docker_installed=True,
            containers=containers,
            running=running,
            stopped=stopped,
        )

    tasks = [check_docker(vps) for vps in hosts]
    results = await asyncio.gather(*tasks, return_exceptions=True)

    return [r for r in results if isinstance(r, DockerOverview)]


@router.get("/{host}", response_model=list[Container])
async def list_containers(host: str, user: str = Depends(get_current_user)):
    """Container auf einem VPS auflisten."""
    ip = resolve_host(host)
    if not ip:
        raise HTTPException(status_code=404, detail=f"Host '{host}' nicht gefunden")

    code, stdout, _ = await run_ssh(ip, "sudo docker ps -a --format json", timeout=10)
    if code != 0:
        raise HTTPException(status_code=500, detail="Docker nicht verfügbar")

    containers = []
    if stdout:
        for line in stdout.strip().split("\n"):
            if not line.strip():
                continue
            try:
                c = json.loads(line)
                containers.append(
                    Container(
                        id=c.get("ID", ""),
                        name=c.get("Names", ""),
                        image=c.get("Image", ""),
                        status=c.get("Status", ""),
                        state=c.get("State", ""),
                        ports=c.get("Ports", ""),
                        created=c.get("CreatedAt", ""),
                    )
                )
            except json.JSONDecodeError:
                continue

    return containers


@router.post("/{host}/install", response_model=TaskCreate)
async def install_docker(host: str, user: str = Depends(get_current_user)):
    """Docker CE installieren (Background-Task)."""
    ip = resolve_host(host)
    if not ip:
        raise HTTPException(status_code=404, detail=f"Host '{host}' nicht gefunden")

    install_script = """
set -e
if command -v docker &>/dev/null; then
    echo "Docker ist bereits installiert:"
    docker --version
    exit 0
fi
echo "Installiere Docker CE..."
sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg lsb-release
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(. /etc/os-release && echo $VERSION_CODENAME) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo usermod -aG docker $USER
sudo systemctl enable docker
sudo systemctl start docker
echo "Docker installiert:"
docker --version
docker compose version
"""

    async def do_install(task_id: str):
        await task_manager.push_output(task_id, f"Installiere Docker auf {host} ({ip})...")
        async for line in run_ssh_stream(ip, install_script):
            await task_manager.push_output(task_id, line)
        await task_manager.push_output(task_id, "Docker-Installation abgeschlossen.")

    task_id = task_manager.create_task(
        "docker_install",
        f"Docker-Installation auf {host}",
        host=host,
        coro_factory=do_install,
    )
    return TaskCreate(task_id=task_id)


@router.post("/{host}/{container}/start")
async def start_container(
    host: str, container: str, user: str = Depends(get_current_user)
):
    """Container starten."""
    ip = resolve_host(host)
    if not ip:
        raise HTTPException(status_code=404, detail=f"Host '{host}' nicht gefunden")

    code, stdout, stderr = await run_ssh(ip, f"sudo docker start {container}")
    if code != 0:
        raise HTTPException(status_code=500, detail=stderr or "Fehler beim Starten")
    return {"message": f"Container '{container}' gestartet"}


@router.post("/{host}/{container}/stop")
async def stop_container(
    host: str, container: str, user: str = Depends(get_current_user)
):
    """Container stoppen."""
    ip = resolve_host(host)
    if not ip:
        raise HTTPException(status_code=404, detail=f"Host '{host}' nicht gefunden")

    code, stdout, stderr = await run_ssh(ip, f"sudo docker stop {container}")
    if code != 0:
        raise HTTPException(status_code=500, detail=stderr or "Fehler beim Stoppen")
    return {"message": f"Container '{container}' gestoppt"}
