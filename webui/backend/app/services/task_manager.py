import asyncio
import uuid
from datetime import datetime, timezone
from typing import Callable, Coroutine

from ..models.task import TaskInfo, TaskStatus


class TaskManager:
    """Verwaltet Background-Tasks mit Output-Buffering und WebSocket-Push."""

    def __init__(self):
        self._tasks: dict[str, TaskInfo] = {}
        self._output: dict[str, list[str]] = {}
        self._subscribers: dict[str, list[asyncio.Queue]] = {}
        self._asyncio_tasks: dict[str, asyncio.Task] = {}

    def create_task(
        self,
        task_type: str,
        description: str,
        host: str = "",
        coro_factory: Callable[[str], Coroutine] | None = None,
    ) -> str:
        """Erstellt einen neuen Background-Task und gibt die task_id zurück."""
        task_id = str(uuid.uuid4())[:8]
        self._tasks[task_id] = TaskInfo(
            task_id=task_id,
            type=task_type,
            description=description,
            status=TaskStatus.pending,
            host=host,
            started_at=datetime.now(timezone.utc).isoformat(),
        )
        self._output[task_id] = []
        self._subscribers[task_id] = []

        if coro_factory:
            self._asyncio_tasks[task_id] = asyncio.create_task(
                self._run_task(task_id, coro_factory)
            )

        return task_id

    async def _run_task(
        self,
        task_id: str,
        coro_factory: Callable[[str], Coroutine],
    ):
        """Führt einen Task aus und aktualisiert den Status."""
        self._tasks[task_id].status = TaskStatus.running
        try:
            await coro_factory(task_id)
            self._tasks[task_id].status = TaskStatus.completed
            self._tasks[task_id].exit_code = 0
        except Exception as e:
            self._tasks[task_id].status = TaskStatus.failed
            self._tasks[task_id].exit_code = 1
            await self.push_output(task_id, f"FEHLER: {e}")
        finally:
            self._tasks[task_id].finished_at = datetime.now(timezone.utc).isoformat()
            # Schließe alle Subscriber-Queues
            for queue in self._subscribers.get(task_id, []):
                await queue.put(None)

    async def push_output(self, task_id: str, line: str):
        """Fügt eine Zeile zum Output-Buffer hinzu und benachrichtigt Subscriber."""
        if task_id in self._output:
            self._output[task_id].append(line)
            self._tasks[task_id].output_lines = len(self._output[task_id])

        for queue in self._subscribers.get(task_id, []):
            await queue.put(line)

    def subscribe(self, task_id: str) -> asyncio.Queue:
        """Erstellt eine Queue für Live-Output eines Tasks."""
        queue: asyncio.Queue = asyncio.Queue()
        if task_id not in self._subscribers:
            self._subscribers[task_id] = []
        self._subscribers[task_id].append(queue)
        return queue

    def unsubscribe(self, task_id: str, queue: asyncio.Queue):
        """Entfernt eine Subscriber-Queue."""
        if task_id in self._subscribers:
            try:
                self._subscribers[task_id].remove(queue)
            except ValueError:
                pass

    def get_task(self, task_id: str) -> TaskInfo | None:
        return self._tasks.get(task_id)

    def get_output(self, task_id: str) -> list[str]:
        return self._output.get(task_id, [])

    def list_tasks(self) -> list[TaskInfo]:
        return list(self._tasks.values())

    def cleanup_old_tasks(self, max_age_hours: int = 24):
        """Entfernt abgeschlossene Tasks älter als max_age_hours."""
        now = datetime.now(timezone.utc)
        to_remove = []
        for task_id, task in self._tasks.items():
            if task.status in (TaskStatus.completed, TaskStatus.failed):
                if task.finished_at:
                    finished = datetime.fromisoformat(task.finished_at)
                    if (now - finished).total_seconds() > max_age_hours * 3600:
                        to_remove.append(task_id)
        for task_id in to_remove:
            self._tasks.pop(task_id, None)
            self._output.pop(task_id, None)
            self._subscribers.pop(task_id, None)


# Globale Instanz
task_manager = TaskManager()
