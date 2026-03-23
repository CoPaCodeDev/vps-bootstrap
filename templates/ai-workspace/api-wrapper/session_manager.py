import asyncio
import logging
import os
import signal
from pathlib import Path

from models import SessionStatus

logger = logging.getLogger(__name__)

PROJECTS_DIR = Path(os.environ.get("PROJECTS_DIR", "/home/claude/projects"))
VIDEOS_DIR = Path(os.environ.get("VIDEOS_DIR", "/shared/videos"))


class ClaudeSession:
    def __init__(self, project: str, process: asyncio.subprocess.Process, telegram: bool = False):
        self.project = project
        self.process = process
        self.telegram = telegram
        self.output_buffer: list[str] = []

    @property
    def running(self) -> bool:
        return self.process.returncode is None

    @property
    def pid(self) -> int | None:
        return self.process.pid if self.running else None


class SessionManager:
    def __init__(self):
        self.sessions: dict[str, ClaudeSession] = {}

    async def create(self, project: str, telegram: bool = False) -> SessionStatus:
        if project in self.sessions and self.sessions[project].running:
            raise ValueError(f"Session '{project}' laeuft bereits")

        project_path = PROJECTS_DIR / project
        project_path.mkdir(parents=True, exist_ok=True)

        cmd = ["claude", "--dangerously-skip-permissions"]
        if telegram:
            cmd.extend(["--channels", "plugin:telegram@claude-plugins-official"])

        process = await asyncio.create_subprocess_exec(
            *cmd,
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.STDOUT,
            cwd=str(project_path),
        )

        session = ClaudeSession(project, process, telegram)
        self.sessions[project] = session

        # Output-Reader im Hintergrund starten
        asyncio.create_task(self._read_output(session))

        logger.info(f"Session gestartet: {project} (PID {process.pid})")
        return self._status(session)

    async def send_input(self, project: str, text: str) -> None:
        session = self._get_session(project)
        if not session.running:
            raise ValueError(f"Session '{project}' laeuft nicht")
        session.process.stdin.write(f"{text}\n".encode())
        await session.process.stdin.drain()

    async def get_output(self, project: str, since: int = 0) -> list[str]:
        session = self._get_session(project)
        return session.output_buffer[since:]

    async def stop(self, project: str) -> None:
        session = self._get_session(project)
        if session.running:
            session.process.send_signal(signal.SIGTERM)
            try:
                await asyncio.wait_for(session.process.wait(), timeout=10)
            except asyncio.TimeoutError:
                session.process.kill()
            logger.info(f"Session gestoppt: {project}")
        del self.sessions[project]

    async def list(self) -> list[SessionStatus]:
        return [self._status(s) for s in self.sessions.values()]

    def _get_session(self, project: str) -> ClaudeSession:
        if project not in self.sessions:
            raise KeyError(f"Session '{project}' nicht gefunden")
        return self.sessions[project]

    def _status(self, session: ClaudeSession) -> SessionStatus:
        return SessionStatus(
            project=session.project,
            pid=session.pid,
            running=session.running,
            telegram=session.telegram,
        )

    async def _read_output(self, session: ClaudeSession) -> None:
        try:
            while True:
                line = await session.process.stdout.readline()
                if not line:
                    break
                decoded = line.decode(errors="replace").rstrip()
                session.output_buffer.append(decoded)
        except Exception as e:
            logger.error(f"Output-Reader Fehler ({session.project}): {e}")
