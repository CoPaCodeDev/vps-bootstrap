from .ssh import run_ssh


async def run_on_proxy(cmd: str, timeout: int = 30) -> str:
    """Führt einen Befehl auf dem Proxy aus und gibt stdout zurück."""
    rc, stdout, stderr = await run_ssh("proxy", cmd, timeout=timeout)
    if rc != 0:
        raise Exception(f"Proxy-Befehl fehlgeschlagen (rc={rc}): {stderr}")
    return stdout
