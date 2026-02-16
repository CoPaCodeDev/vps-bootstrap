from fastapi import APIRouter, Depends, HTTPException

from ..dependencies import get_current_user
from ..models.netcup import DeviceCodeResponse, LoginStatus, Server, InstallRequest
from ..models.task import TaskCreate
from ..services.netcup_api import netcup_api
from ..services.task_manager import task_manager

router = APIRouter(prefix="/netcup", tags=["Netcup"])


@router.post("/login/device", response_model=DeviceCodeResponse)
async def start_device_login(user: str = Depends(get_current_user)):
    """Device Code Flow starten."""
    try:
        result = await netcup_api.start_device_login()
        return DeviceCodeResponse(**result)
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.get("/login/status/{sid}", response_model=LoginStatus)
async def check_login(sid: str, user: str = Depends(get_current_user)):
    """Login-Status prüfen."""
    result = await netcup_api.check_login_status(sid)
    return LoginStatus(**result)


@router.post("/logout")
async def logout(user: str = Depends(get_current_user)):
    """Von Netcup abmelden."""
    await netcup_api.logout()
    return {"message": "Abgemeldet"}


@router.get("/servers")
async def list_servers(user: str = Depends(get_current_user)):
    """Netcup-Server auflisten."""
    try:
        servers = await netcup_api.list_servers()
        return servers
    except Exception as e:
        raise HTTPException(status_code=401, detail=str(e))


@router.get("/servers/{server_id}")
async def get_server(server_id: str, user: str = Depends(get_current_user)):
    """Server-Details abrufen."""
    try:
        server = await netcup_api.get_server(server_id)
        return server
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.get("/servers/{server_id}/images")
async def get_images(server_id: str, user: str = Depends(get_current_user)):
    """Verfügbare Images für einen Server abrufen."""
    try:
        images = await netcup_api.get_images(server_id)
        return images
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.post("/servers/{server_id}/install", response_model=TaskCreate)
async def install_server(
    server_id: str,
    req: InstallRequest,
    user: str = Depends(get_current_user),
):
    """VPS installieren (Background-Task)."""

    async def do_install(task_id: str):
        await task_manager.push_output(task_id, f"Starte Installation von Server {server_id}...")
        await task_manager.push_output(task_id, f"Hostname: {req.hostname}")
        await task_manager.push_output(task_id, f"Image: {req.image}")

        try:
            # Images abrufen und gewünschtes finden
            images = await netcup_api.get_images(server_id)
            image_id = None
            for img in images:
                if req.image.lower() in str(img.get("name", "")).lower():
                    image_id = img.get("id") or img.get("imageFlavourId")
                    await task_manager.push_output(task_id, f"Image gefunden: {img.get('name')}")
                    break

            if not image_id:
                await task_manager.push_output(task_id, f"FEHLER: Image '{req.image}' nicht gefunden")
                raise Exception(f"Image '{req.image}' nicht gefunden")

            # Installation starten
            await task_manager.push_output(task_id, "Sende Installationsbefehl...")
            result = await netcup_api.install_server(server_id, str(image_id), req.hostname)
            await task_manager.push_output(task_id, f"Installation gestartet: {result}")
            await task_manager.push_output(
                task_id,
                "Die Installation läuft im Hintergrund bei Netcup. "
                "Dies kann einige Minuten dauern.",
            )
        except Exception as e:
            await task_manager.push_output(task_id, f"FEHLER: {e}")
            raise

    task_id = task_manager.create_task(
        "netcup_install",
        f"VPS-Installation Server {server_id}",
        coro_factory=do_install,
    )
    return TaskCreate(task_id=task_id)
