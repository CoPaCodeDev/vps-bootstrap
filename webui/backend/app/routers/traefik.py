from fastapi import APIRouter, Depends, Query

from ..dependencies import get_current_user
from ..services.ssh import run_ssh

router = APIRouter(prefix="/traefik", tags=["Traefik"])


@router.get("/status")
async def traefik_status(user: str = Depends(get_current_user)):
    """Traefik-Container-Status."""
    code, stdout, _ = await run_ssh(
        "proxy", "sudo docker ps --filter name=traefik --format json"
    )
    if code != 0 or not stdout.strip():
        return {"running": False}

    import json

    try:
        data = json.loads(stdout.strip().split("\n")[0])
        return {
            "running": data.get("State") == "running",
            "status": data.get("Status", ""),
            "image": data.get("Image", ""),
            "ports": data.get("Ports", ""),
        }
    except (json.JSONDecodeError, IndexError):
        return {"running": False}


@router.get("/logs")
async def traefik_logs(
    lines: int = Query(default=50, le=500),
    user: str = Depends(get_current_user),
):
    """Traefik-Logs abrufen."""
    code, stdout, _ = await run_ssh(
        "proxy", f"sudo docker logs --tail {lines} traefik 2>&1", timeout=15
    )
    return {"lines": stdout.split("\n") if stdout else []}


@router.post("/restart")
async def restart_traefik(user: str = Depends(get_current_user)):
    """Traefik neustarten."""
    code, _, stderr = await run_ssh("proxy", "cd /opt/traefik && sudo docker compose restart")
    if code != 0:
        return {"success": False, "error": stderr}
    return {"success": True, "message": "Traefik neu gestartet"}
