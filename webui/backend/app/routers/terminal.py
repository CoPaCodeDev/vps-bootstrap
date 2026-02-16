import asyncio
import base64
import json
import logging

from fastapi import APIRouter, WebSocket, WebSocketDisconnect

from ..services.hosts import resolve_host
from ..services.ssh import resolve_ssh_target
from ..services.terminal import TerminalSession

logger = logging.getLogger(__name__)
router = APIRouter(tags=["terminal"])


@router.websocket("/terminal/ws/{host}")
async def terminal_ws(websocket: WebSocket, host: str):
    """WebSocket-Endpoint für interaktive Terminal-Sessions."""
    await websocket.accept()

    # Auth-Check: Remote-User Header (von Authelia via Traefik)
    remote_user = websocket.headers.get("remote-user", "")
    if not remote_user:
        # Im Dev-Modus ohne Authelia trotzdem erlauben
        logger.debug("Kein Remote-User Header — Dev-Modus")

    # Host auflösen
    ip = resolve_host(host)
    if not ip:
        await websocket.send_json({"type": "error", "message": f"Unbekannter Host: {host}"})
        await websocket.close()
        return

    # Terminal-Größe aus Query-Params (Fallback 80x24)
    cols = int(websocket.query_params.get("cols", "80"))
    rows = int(websocket.query_params.get("rows", "24"))

    session = TerminalSession(resolve_ssh_target(ip))
    try:
        await session.connect(cols=cols, rows=rows)
        await websocket.send_json({"type": "connected"})
    except Exception as e:
        logger.error("SSH-Verbindung fehlgeschlagen: %s — %s", host, e)
        await websocket.send_json({"type": "error", "message": f"SSH-Verbindung fehlgeschlagen: {e}"})
        await websocket.close()
        return

    async def pty_to_ws():
        """Liest vom PTY und sendet an WebSocket."""
        try:
            while True:
                data = await session.read()
                encoded = base64.b64encode(data).decode("ascii")
                await websocket.send_json({"type": "output", "data": encoded})
        except (EOFError, asyncio.CancelledError):
            pass
        except Exception as e:
            logger.debug("pty_to_ws beendet: %s", e)

    async def ws_to_pty():
        """Liest vom WebSocket und schreibt zum PTY."""
        try:
            while True:
                raw = await websocket.receive_text()
                msg = json.loads(raw)
                if msg["type"] == "input":
                    data = base64.b64decode(msg["data"])
                    session.write(data)
                elif msg["type"] == "resize":
                    session.resize(msg["cols"], msg["rows"])
        except (WebSocketDisconnect, asyncio.CancelledError):
            pass
        except Exception as e:
            logger.debug("ws_to_pty beendet: %s", e)

    task_pty = asyncio.create_task(pty_to_ws())
    task_ws = asyncio.create_task(ws_to_pty())

    try:
        done, pending = await asyncio.wait(
            [task_pty, task_ws],
            return_when=asyncio.FIRST_COMPLETED,
        )
        for t in pending:
            t.cancel()
        # Fehler aus abgeschlossenen Tasks loggen
        for t in done:
            if t.exception():
                logger.error("Terminal-Task Fehler: %s", t.exception())
    finally:
        await session.close()
        try:
            await websocket.send_json({"type": "closed", "reason": "Session beendet"})
        except Exception:
            pass
        try:
            await websocket.close()
        except Exception:
            pass
