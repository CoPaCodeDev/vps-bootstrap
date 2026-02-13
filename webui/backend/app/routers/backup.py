import json

from fastapi import APIRouter, Depends, HTTPException, Query

from ..dependencies import get_current_user
from ..models.backup import BackupStatus, Snapshot, RestoreRequest, ForgetRequest
from ..models.task import TaskCreate
from ..services.hosts import resolve_host
from ..services.ssh import run_ssh, run_ssh_stream
from ..services.task_manager import task_manager

router = APIRouter(prefix="/backup", tags=["Backup"])

# Restic-Befehle brauchen die Env-Variablen aus /etc/restic/env
RESTIC_PREFIX = "sudo bash -c 'source /etc/restic/env && export RESTIC_REPOSITORY RESTIC_PASSWORD_FILE && "
RESTIC_SUFFIX = "'"


def _restic_cmd(cmd: str) -> str:
    """Wraps einen Restic-Befehl mit source /etc/restic/env."""
    return f"{RESTIC_PREFIX}{cmd}{RESTIC_SUFFIX}"


@router.get("/status", response_model=list[BackupStatus])
async def backup_status(user: str = Depends(get_current_user)):
    """Backup-Status aller Hosts."""
    from ..services.hosts import parse_hosts_file
    import asyncio

    hosts = parse_hosts_file()

    async def check_backup(vps):
        # Prüfe ob Restic-Env existiert
        code, stdout, _ = await run_ssh(
            vps.ip,
            _restic_cmd("restic snapshots --json --latest 1 2>/dev/null"),
            timeout=30,
        )

        if code != 0:
            return BackupStatus(host=vps.name, healthy=False)

        try:
            snapshots = json.loads(stdout) if stdout else []
            last_time = snapshots[0].get("time", "") if snapshots else ""

            # Repo-Größe
            code2, stats_out, _ = await run_ssh(
                vps.ip,
                _restic_cmd("restic stats --json 2>/dev/null"),
                timeout=30,
            )
            repo_size = ""
            if code2 == 0 and stats_out:
                stats = json.loads(stats_out)
                size_bytes = stats.get("total_size", 0)
                repo_size = _format_size(size_bytes)

            # Snapshot-Anzahl
            code3, all_out, _ = await run_ssh(
                vps.ip,
                _restic_cmd("restic snapshots --json 2>/dev/null"),
                timeout=30,
            )
            snapshot_count = 0
            if code3 == 0 and all_out:
                all_snapshots = json.loads(all_out)
                snapshot_count = len(all_snapshots)

            return BackupStatus(
                host=vps.name,
                last_backup=last_time,
                snapshots=snapshot_count,
                repo_size=repo_size,
                healthy=True,
            )
        except (json.JSONDecodeError, IndexError):
            return BackupStatus(host=vps.name, healthy=False)

    tasks = [check_backup(vps) for vps in hosts]
    results = await asyncio.gather(*tasks, return_exceptions=True)
    return [r for r in results if isinstance(r, BackupStatus)]


@router.get("/{host}/snapshots", response_model=list[Snapshot])
async def list_snapshots(host: str, user: str = Depends(get_current_user)):
    """Snapshots eines Hosts auflisten."""
    ip = resolve_host(host)
    if not ip:
        raise HTTPException(status_code=404, detail=f"Host '{host}' nicht gefunden")

    code, stdout, _ = await run_ssh(
        ip,
        _restic_cmd("restic snapshots --json 2>/dev/null"),
        timeout=30,
    )

    if code != 0:
        return []

    try:
        data = json.loads(stdout) if stdout else []
        return [
            Snapshot(
                id=s.get("id", ""),
                short_id=s.get("short_id", s.get("id", "")[:8]),
                time=s.get("time", ""),
                hostname=s.get("hostname", ""),
                tags=s.get("tags") or [],
                paths=s.get("paths") or [],
            )
            for s in data
        ]
    except json.JSONDecodeError:
        return []


@router.get("/{host}/files")
async def list_files(
    host: str,
    snapshot: str = Query(default="latest"),
    path: str = Query(default="/"),
    user: str = Depends(get_current_user),
):
    """Dateien in einem Snapshot auflisten."""
    ip = resolve_host(host)
    if not ip:
        raise HTTPException(status_code=404, detail=f"Host '{host}' nicht gefunden")

    code, stdout, _ = await run_ssh(
        ip,
        _restic_cmd(f"restic ls {snapshot} {path} --json 2>/dev/null"),
        timeout=30,
    )

    if code != 0:
        return {"files": []}

    files = []
    for line in stdout.strip().split("\n"):
        if not line.strip():
            continue
        try:
            entry = json.loads(line)
            files.append(entry)
        except json.JSONDecodeError:
            continue

    return {"files": files}


@router.post("/{host}/run", response_model=TaskCreate)
async def run_backup(host: str, user: str = Depends(get_current_user)):
    """Backup ausführen (Background-Task)."""
    ip = resolve_host(host)
    if not ip:
        raise HTTPException(status_code=404, detail=f"Host '{host}' nicht gefunden")

    async def do_backup(task_id: str):
        await task_manager.push_output(task_id, f"Starte Backup für {host} ({ip})...")
        async for line in run_ssh_stream(
            ip,
            _restic_cmd("restic backup /opt --verbose 2>&1"),
        ):
            await task_manager.push_output(task_id, line)
        await task_manager.push_output(task_id, "Backup abgeschlossen.")

    task_id = task_manager.create_task(
        "backup", f"Backup von {host}", host=host, coro_factory=do_backup
    )
    return TaskCreate(task_id=task_id)


@router.post("/{host}/restore", response_model=TaskCreate)
async def restore_backup(
    host: str,
    req: RestoreRequest,
    user: str = Depends(get_current_user),
):
    """Backup wiederherstellen (Background-Task)."""
    ip = resolve_host(host)
    if not ip:
        raise HTTPException(status_code=404, detail=f"Host '{host}' nicht gefunden")

    async def do_restore(task_id: str):
        target = req.target or "/"
        await task_manager.push_output(
            task_id, f"Stelle Snapshot {req.snapshot_id} auf {host} wieder her..."
        )
        paths_arg = " ".join(f"--include {p}" for p in req.paths) if req.paths else ""
        cmd = _restic_cmd(
            f"restic restore {req.snapshot_id} "
            f"--target {target} {paths_arg} --verbose 2>&1"
        )
        async for line in run_ssh_stream(ip, cmd):
            await task_manager.push_output(task_id, line)
        await task_manager.push_output(task_id, "Wiederherstellung abgeschlossen.")

    task_id = task_manager.create_task(
        "restore",
        f"Restore auf {host} (Snapshot {req.snapshot_id})",
        host=host,
        coro_factory=do_restore,
    )
    return TaskCreate(task_id=task_id)


@router.post("/{host}/forget", response_model=TaskCreate)
async def forget_snapshots(
    host: str,
    req: ForgetRequest,
    user: str = Depends(get_current_user),
):
    """Alte Snapshots entfernen (Background-Task)."""
    ip = resolve_host(host)
    if not ip:
        raise HTTPException(status_code=404, detail=f"Host '{host}' nicht gefunden")

    async def do_forget(task_id: str):
        await task_manager.push_output(task_id, f"Bereinige Snapshots für {host}...")
        cmd = _restic_cmd(
            f"restic forget "
            f"--keep-last {req.keep_last} "
            f"--keep-daily {req.keep_daily} "
            f"--keep-weekly {req.keep_weekly} "
            f"--keep-monthly {req.keep_monthly} "
            f"--prune --verbose 2>&1"
        )
        async for line in run_ssh_stream(ip, cmd):
            await task_manager.push_output(task_id, line)
        await task_manager.push_output(task_id, "Bereinigung abgeschlossen.")

    task_id = task_manager.create_task(
        "forget",
        f"Snapshot-Bereinigung für {host}",
        host=host,
        coro_factory=do_forget,
    )
    return TaskCreate(task_id=task_id)


def _format_size(size_bytes: int) -> str:
    """Formatiert Bytes in menschenlesbares Format."""
    for unit in ["B", "KB", "MB", "GB", "TB"]:
        if size_bytes < 1024:
            return f"{size_bytes:.1f} {unit}"
        size_bytes /= 1024
    return f"{size_bytes:.1f} PB"
