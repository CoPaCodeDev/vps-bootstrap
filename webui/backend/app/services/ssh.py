import asyncio
import shlex
from typing import AsyncIterator

from ..config import settings


async def run_ssh(
    host: str,
    command: str,
    timeout: int | None = None,
) -> tuple[int, str, str]:
    """Führt einen SSH-Befehl auf einem Host aus.

    Gibt (exit_code, stdout, stderr) zurück.
    Wenn host == proxy_host oder 'proxy', wird lokal ausgeführt.
    """
    effective_timeout = timeout or settings.ssh_timeout

    if host in (settings.proxy_host, "proxy", "localhost"):
        proc = await asyncio.create_subprocess_shell(
            command,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
    else:
        ssh_cmd = (
            f"ssh -o StrictHostKeyChecking=no -o ConnectTimeout={effective_timeout} "
            f"-o BatchMode=yes -i {settings.ssh_key_path} "
            f"{settings.ssh_user}@{host} {shlex.quote(command)}"
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
        return -1, "", "Timeout"

    return (
        proc.returncode or 0,
        stdout.decode("utf-8", errors="replace").strip(),
        stderr.decode("utf-8", errors="replace").strip(),
    )


async def run_ssh_stream(
    host: str,
    command: str,
) -> AsyncIterator[str]:
    """Führt einen SSH-Befehl aus und streamt die Ausgabe zeilenweise."""
    if host in (settings.proxy_host, "proxy", "localhost"):
        proc = await asyncio.create_subprocess_shell(
            command,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.STDOUT,
        )
    else:
        ssh_cmd = (
            f"ssh -o StrictHostKeyChecking=no -o ConnectTimeout={settings.ssh_timeout} "
            f"-o BatchMode=yes -i {settings.ssh_key_path} "
            f"{settings.ssh_user}@{host} {shlex.quote(command)}"
        )
        proc = await asyncio.create_subprocess_shell(
            ssh_cmd,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.STDOUT,
        )

    async for line in proc.stdout:
        yield line.decode("utf-8", errors="replace").rstrip("\n")

    await proc.wait()


async def check_host_online(host: str) -> bool:
    """Prüft ob ein Host per SSH erreichbar ist."""
    code, _, _ = await run_ssh(host, "echo ok", timeout=5)
    return code == 0


async def run_local(command: str, timeout: int = 30) -> tuple[int, str, str]:
    """Führt einen lokalen Befehl auf dem Proxy aus."""
    return await run_ssh(settings.proxy_host, command, timeout=timeout)
