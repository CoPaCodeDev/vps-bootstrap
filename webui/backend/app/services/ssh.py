import asyncio
import logging
import shlex
from typing import AsyncIterator

from ..config import settings

logger = logging.getLogger(__name__)


async def run_ssh(
    host: str,
    command: str,
    timeout: int | None = None,
) -> tuple[int, str, str]:
    """Führt einen SSH-Befehl auf einem Host aus.

    Gibt (exit_code, stdout, stderr) zurück.
    Alle Befehle werden per SSH ausgeführt (auch Proxy-Befehle),
    da das Backend in einem Container läuft.
    """
    effective_timeout = timeout or settings.ssh_timeout

    # "proxy" / "localhost" auf die echte Proxy-IP auflösen
    target = settings.proxy_host if host in ("proxy", "localhost") else host

    ssh_cmd = (
        f"ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "
        f"-o ConnectTimeout={effective_timeout} "
        f"-o BatchMode=yes -i {settings.ssh_key_path} "
        f"{settings.ssh_user}@{target} {shlex.quote(command)}"
    )
    proc = await asyncio.create_subprocess_shell(
        ssh_cmd,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )

    try:
        stdout, stderr = await asyncio.wait_for(
            proc.communicate(), timeout=effective_timeout + 5
        )
    except asyncio.TimeoutError:
        proc.kill()
        logger.warning("SSH timeout: %s", host)
        return -1, "", "Timeout"

    rc = proc.returncode or 0
    out = stdout.decode("utf-8", errors="replace").strip()
    err = stderr.decode("utf-8", errors="replace").strip()

    if rc != 0:
        logger.warning("SSH failed (host=%s, rc=%d): %s", host, rc, err)

    return rc, out, err


async def run_ssh_stream(
    host: str,
    command: str,
) -> AsyncIterator[str]:
    """Führt einen SSH-Befehl aus und streamt die Ausgabe zeilenweise."""
    target = settings.proxy_host if host in ("proxy", "localhost") else host

    ssh_cmd = (
        f"ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "
        f"-o ConnectTimeout={settings.ssh_timeout} "
        f"-o BatchMode=yes -i {settings.ssh_key_path} "
        f"{settings.ssh_user}@{target} {shlex.quote(command)}"
    )
    proc = await asyncio.create_subprocess_shell(
        ssh_cmd,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.STDOUT,
    )

    async for line in proc.stdout:
        yield line.decode("utf-8", errors="replace").rstrip("\n")

    await proc.wait()


async def scp_upload(
    host: str,
    local_path: str,
    remote_path: str,
    timeout: int | None = None,
) -> tuple[int, str]:
    """Lädt eine lokale Datei per SCP auf einen Host hoch.

    Gibt (exit_code, stderr) zurück.
    """
    effective_timeout = timeout or 120
    target = settings.proxy_host if host in ("proxy", "localhost") else host

    scp_cmd = (
        f"scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "
        f"-o ConnectTimeout={settings.ssh_timeout} "
        f"-o BatchMode=yes -i {settings.ssh_key_path} "
        f"{shlex.quote(local_path)} "
        f"{settings.ssh_user}@{target}:{shlex.quote(remote_path)}"
    )
    proc = await asyncio.create_subprocess_shell(
        scp_cmd,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )

    try:
        _, stderr = await asyncio.wait_for(
            proc.communicate(), timeout=effective_timeout
        )
    except asyncio.TimeoutError:
        proc.kill()
        logger.warning("SCP timeout: %s", host)
        return -1, "Timeout"

    rc = proc.returncode or 0
    err = stderr.decode("utf-8", errors="replace").strip()

    if rc != 0:
        logger.warning("SCP failed (host=%s, rc=%d): %s", host, rc, err)

    return rc, err


async def scp_download(
    host: str,
    remote_path: str,
    local_path: str,
    timeout: int | None = None,
) -> tuple[int, str]:
    """Lädt eine Datei per SCP von einem Host herunter.

    Gibt (exit_code, stderr) zurück.
    """
    effective_timeout = timeout or 120
    target = settings.proxy_host if host in ("proxy", "localhost") else host

    scp_cmd = (
        f"scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "
        f"-o ConnectTimeout={settings.ssh_timeout} "
        f"-o BatchMode=yes -i {settings.ssh_key_path} "
        f"{settings.ssh_user}@{target}:{shlex.quote(remote_path)} "
        f"{shlex.quote(local_path)}"
    )
    proc = await asyncio.create_subprocess_shell(
        scp_cmd,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )

    try:
        _, stderr = await asyncio.wait_for(
            proc.communicate(), timeout=effective_timeout
        )
    except asyncio.TimeoutError:
        proc.kill()
        logger.warning("SCP download timeout: %s", host)
        return -1, "Timeout"

    rc = proc.returncode or 0
    err = stderr.decode("utf-8", errors="replace").strip()

    if rc != 0:
        logger.warning("SCP download failed (host=%s, rc=%d): %s", host, rc, err)

    return rc, err


async def check_host_online(host: str) -> bool:
    """Prüft ob ein Host per SSH erreichbar ist."""
    code, _, _ = await run_ssh(host, "echo ok", timeout=5)
    return code == 0


async def run_local(command: str, timeout: int = 30) -> tuple[int, str, str]:
    """Führt einen lokalen Befehl auf dem Proxy aus."""
    return await run_ssh(settings.proxy_host, command, timeout=timeout)
