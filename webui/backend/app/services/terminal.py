import asyncio
import logging

import asyncssh

from ..config import settings

logger = logging.getLogger(__name__)


class TerminalSession:
    """SSH-Verbindung mit PTY für interaktive Terminal-Sessions."""

    def __init__(self, host: str):
        self.host = host
        self._conn: asyncssh.SSHClientConnection | None = None
        self._process: asyncssh.SSHClientProcess | None = None

    async def connect(self, cols: int = 80, rows: int = 24) -> None:
        """Stellt SSH-Verbindung her und öffnet PTY."""
        self._conn = await asyncssh.connect(
            self.host,
            username=settings.ssh_user,
            client_keys=[settings.ssh_key_path],
            known_hosts=None,
            connect_timeout=settings.ssh_timeout,
        )
        self._process = await self._conn.create_process(
            term_type="xterm-256color",
            term_size=(cols, rows),
            encoding=None,
        )
        logger.info("Terminal-Session geöffnet: %s", self.host)

    async def read(self) -> bytes:
        """Liest Bytes vom PTY-stdout."""
        assert self._process is not None
        data = await self._process.stdout.read(4096)
        if not data:
            raise EOFError("PTY geschlossen")
        return data

    def write(self, data: bytes) -> None:
        """Schreibt Eingabe zum PTY-stdin."""
        assert self._process is not None
        self._process.stdin.write(data)

    def resize(self, cols: int, rows: int) -> None:
        """Ändert die Terminal-Größe."""
        assert self._process is not None
        self._process.change_terminal_size(cols, rows)

    async def close(self) -> None:
        """Beendet die Session und räumt auf."""
        if self._process is not None:
            self._process.close()
            try:
                await asyncio.wait_for(self._process.wait(), timeout=3)
            except (asyncio.TimeoutError, Exception):
                pass
            self._process = None
        if self._conn is not None:
            self._conn.close()
            self._conn = None
        logger.info("Terminal-Session geschlossen: %s", self.host)
