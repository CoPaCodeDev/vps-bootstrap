import asyncio
import os
import shlex
import uuid

from fastapi import APIRouter, Depends, HTTPException, UploadFile, File, Form
from fastapi.responses import FileResponse

from ..dependencies import get_current_user
from ..models.vps import VPS, VPSStatus, ExecRequest
from ..models.task import TaskCreate
from ..services.hosts import parse_hosts_file, resolve_host
from ..services.ssh import run_ssh, run_ssh_stream, check_host_online, scp_upload, scp_download
from ..services.task_manager import task_manager

router = APIRouter(prefix="/vps", tags=["VPS"])


@router.get("/", response_model=list[VPS])
async def list_vps(user: str = Depends(get_current_user)):
    """Liste aller VPS aus /etc/vps-hosts."""
    return parse_hosts_file()


@router.post("/scan", response_model=TaskCreate)
async def scan_network(user: str = Depends(get_current_user)):
    """Startet einen Netzwerk-Scan (Background-Task)."""

    async def do_scan(task_id: str):
        await task_manager.push_output(task_id, "Scanne Netzwerk 10.10.0.2-254...")
        found = []
        tasks = []

        async def check_ip(ip: str):
            online = await check_host_online(ip)
            if online:
                code, hostname, _ = await run_ssh(ip, "hostname", timeout=5)
                if code == 0 and hostname:
                    found.append((ip, hostname))
                    await task_manager.push_output(task_id, f"  Gefunden: {ip} → {hostname}")

        for i in range(2, 255):
            ip = f"10.10.0.{i}"
            tasks.append(check_ip(ip))

        # Batchweise ausführen (max 50 parallel)
        batch_size = 50
        for i in range(0, len(tasks), batch_size):
            batch = tasks[i : i + batch_size]
            await asyncio.gather(*batch, return_exceptions=True)

        # Sortieren und speichern
        found.sort(key=lambda x: int(x[0].split(".")[-1]))
        lines = [
            f"# VPS Hosts - generiert vom Dashboard",
            "# IP          Hostname",
        ]
        for ip, hostname in found:
            lines.append(f"{ip} {hostname}")

        content = "\n".join(lines) + "\n"
        code, _, err = await run_ssh(
            "proxy",
            f"echo {repr(content)} | sudo tee /etc/vps-hosts > /dev/null",
        )
        await task_manager.push_output(
            task_id, f"Scan abgeschlossen. {len(found)} VPS gefunden."
        )

    task_id = task_manager.create_task(
        "scan", "Netzwerk-Scan", coro_factory=do_scan
    )
    return TaskCreate(task_id=task_id)


@router.get("/{host}/status", response_model=VPSStatus)
async def get_vps_status(host: str, user: str = Depends(get_current_user)):
    """Status eines einzelnen VPS."""
    ip = resolve_host(host)
    if not ip:
        raise HTTPException(status_code=404, detail=f"Host '{host}' nicht gefunden")

    online = await check_host_online(ip)
    if not online:
        return VPSStatus(host=host, online=False)

    # Parallel Status-Informationen sammeln
    cmds = {
        "updates": "LC_ALL=C apt list --upgradable 2>/dev/null | grep -c upgradable; true",
        "reboot": "[ -f /var/run/reboot-required ] && echo ja || echo nein",
        "load": "uptime | awk -F'load average:' '{print $2}' | awk -F, '{print $1}' | tr -d ' '",
        "uptime": "awk '{d=int($1/86400);h=int($1%86400/3600);m=int($1%3600/60);printf \"%dd:%dh:%dm\",d,h,m}' /proc/uptime",
        "kernel": "uname -r",
        "memory": "LC_ALL=C free -h | awk '/^Mem:/{print $3\"|\"$2}'",
        "disk": "LC_ALL=C df -h / | awk 'NR==2{print $3\"|\"$2}'",
    }

    results = {}
    async_tasks = []
    for key, cmd in cmds.items():

        async def _run(k=key, c=cmd):
            code, stdout, _ = await run_ssh(ip, c, timeout=10)
            results[k] = stdout if code == 0 else ""

        async_tasks.append(_run())

    await asyncio.gather(*async_tasks, return_exceptions=True)

    # Memory/Disk parsen (Fallback bei leerem Ergebnis)
    memory_raw = results.get("memory", "")
    memory_parts = memory_raw.split("|") if "|" in memory_raw else []
    disk_raw = results.get("disk", "")
    disk_parts = disk_raw.split("|") if "|" in disk_raw else []

    updates_str = results.get("updates", "0").strip()
    try:
        updates_count = int(updates_str)
    except ValueError:
        updates_count = 0

    return VPSStatus(
        host=host,
        online=True,
        load=results.get("load", "").strip(),
        uptime=results.get("uptime", "").strip(),
        updates_available=updates_count,
        reboot_required=results.get("reboot", "nein").strip() == "ja",
        kernel=results.get("kernel", "").strip(),
        memory_used=memory_parts[0].strip() if len(memory_parts) >= 2 else "",
        memory_total=memory_parts[1].strip() if len(memory_parts) >= 2 else "",
        disk_used=disk_parts[0].strip() if len(disk_parts) >= 2 else "",
        disk_total=disk_parts[1].strip() if len(disk_parts) >= 2 else "",
    )


@router.post("/{host}/update", response_model=TaskCreate)
async def update_vps(host: str, user: str = Depends(get_current_user)):
    """Startet ein System-Update (Background-Task)."""
    ip = resolve_host(host)
    if not ip:
        raise HTTPException(status_code=404, detail=f"Host '{host}' nicht gefunden")

    async def do_update(task_id: str):
        await task_manager.push_output(task_id, f"Starte Update auf {host} ({ip})...")
        async for line in run_ssh_stream(ip, "sudo apt update && sudo apt upgrade -y"):
            await task_manager.push_output(task_id, line)
        await task_manager.push_output(task_id, "Update abgeschlossen.")

    task_id = task_manager.create_task(
        "update", f"System-Update auf {host}", host=host, coro_factory=do_update
    )
    return TaskCreate(task_id=task_id)


@router.post("/{host}/reboot")
async def reboot_vps(host: str, user: str = Depends(get_current_user)):
    """VPS neustarten."""
    ip = resolve_host(host)
    if not ip:
        raise HTTPException(status_code=404, detail=f"Host '{host}' nicht gefunden")

    await run_ssh(ip, "sudo reboot", timeout=5)
    return {"message": f"Reboot-Befehl an {host} gesendet"}


@router.post("/{host}/exec")
async def exec_command(
    host: str, req: ExecRequest, user: str = Depends(get_current_user)
):
    """Führt einen Befehl auf dem VPS aus."""
    ip = resolve_host(host)
    if not ip:
        raise HTTPException(status_code=404, detail=f"Host '{host}' nicht gefunden")

    code, stdout, stderr = await run_ssh(ip, req.command, timeout=30)
    return {"exit_code": code, "stdout": stdout, "stderr": stderr}


def _validate_remote_path(path: str) -> str:
    """Validiert einen Remote-Pfad gegen Directory Traversal."""
    if not path.startswith("/"):
        raise HTTPException(status_code=400, detail="Pfad muss mit / beginnen")
    if ".." in path.split("/"):
        raise HTTPException(status_code=400, detail="Pfad darf kein .. enthalten")
    return path


@router.get("/{host}/files")
async def list_files(
    host: str, path: str = "/home/master", user: str = Depends(get_current_user)
):
    """Listet Verzeichnisinhalt eines VPS auf."""
    ip = resolve_host(host)
    if not ip:
        raise HTTPException(status_code=404, detail=f"Host '{host}' nicht gefunden")

    path = _validate_remote_path(path)

    code, stdout, stderr = await run_ssh(
        ip,
        f"LC_ALL=C ls -lAp --time-style=long-iso {shlex.quote(path)}",
        timeout=10,
    )
    if code != 0:
        raise HTTPException(status_code=400, detail=stderr or "Verzeichnis nicht lesbar")

    entries = []
    for line in stdout.splitlines():
        # Überspringe "total"-Zeile und leere Zeilen
        if not line or line.startswith("total"):
            continue
        # Format: drwxr-xr-x 2 user group 4096 2024-01-15 10:30 dirname/
        parts = line.split(None, 7)
        if len(parts) < 8:
            continue
        name = parts[7]
        is_dir = name.endswith("/")
        if is_dir:
            name = name.rstrip("/")
        entries.append({
            "name": name,
            "type": "dir" if is_dir else "file",
            "size": parts[4],
            "modified": f"{parts[5]} {parts[6]}",
            "permissions": parts[0],
        })

    return {"path": path, "entries": entries}


@router.post("/{host}/upload", response_model=TaskCreate)
async def upload_file(
    host: str,
    destination: str = Form(...),
    file: UploadFile = File(...),
    user: str = Depends(get_current_user),
):
    """Lädt eine Datei per SCP auf einen VPS hoch."""
    ip = resolve_host(host)
    if not ip:
        raise HTTPException(status_code=404, detail=f"Host '{host}' nicht gefunden")

    destination = _validate_remote_path(destination)
    filename = os.path.basename(file.filename or "upload")

    # Temp-Datei speichern
    tmp_path = f"/tmp/vps-upload-{uuid.uuid4()}"
    with open(tmp_path, "wb") as f:
        content = await file.read()
        f.write(content)

    remote_path = f"{destination.rstrip('/')}/{filename}"

    async def do_upload(task_id: str):
        try:
            await task_manager.push_output(
                task_id, f"Lade {filename} hoch nach {remote_path}..."
            )
            rc, err = await scp_upload(ip, tmp_path, remote_path)
            if rc == 0:
                await task_manager.push_output(
                    task_id, f"Upload erfolgreich: {remote_path}"
                )
            else:
                raise RuntimeError(f"SCP fehlgeschlagen: {err}")
        finally:
            if os.path.exists(tmp_path):
                os.remove(tmp_path)

    task_id = task_manager.create_task(
        "upload",
        f"Upload {filename} → {host}:{remote_path}",
        host=host,
        coro_factory=do_upload,
    )
    return TaskCreate(task_id=task_id)


@router.get("/{host}/download")
async def download_file(
    host: str, path: str, user: str = Depends(get_current_user)
):
    """Lädt eine Datei per SCP von einem VPS herunter."""
    ip = resolve_host(host)
    if not ip:
        raise HTTPException(status_code=404, detail=f"Host '{host}' nicht gefunden")

    path = _validate_remote_path(path)
    filename = os.path.basename(path)
    tmp_path = f"/tmp/vps-download-{uuid.uuid4()}"

    rc, err = await scp_download(ip, path, tmp_path)
    if rc != 0:
        if os.path.exists(tmp_path):
            os.remove(tmp_path)
        raise HTTPException(status_code=400, detail=f"Download fehlgeschlagen: {err}")

    return FileResponse(
        tmp_path,
        filename=filename,
        media_type="application/octet-stream",
    )
