import json

from fastapi import APIRouter, WebSocket, WebSocketDisconnect

from ..models.task import TaskInfo
from ..services.task_manager import task_manager

router = APIRouter(prefix="/tasks", tags=["Tasks"])


@router.get("/", response_model=list[TaskInfo])
async def list_tasks():
    """Alle Tasks auflisten."""
    return task_manager.list_tasks()


@router.get("/{task_id}", response_model=TaskInfo)
async def get_task(task_id: str):
    """Task-Status und Metadaten abrufen."""
    task = task_manager.get_task(task_id)
    if not task:
        return {"error": "Task nicht gefunden"}
    return task


@router.get("/{task_id}/output")
async def get_task_output(task_id: str):
    """Kompletter Output eines Tasks."""
    output = task_manager.get_output(task_id)
    task = task_manager.get_task(task_id)
    return {
        "task_id": task_id,
        "status": task.status if task else "unknown",
        "lines": output,
    }


@router.websocket("/ws/{task_id}")
async def task_websocket(websocket: WebSocket, task_id: str):
    """WebSocket für Live-Output eines Tasks."""
    await websocket.accept()

    task = task_manager.get_task(task_id)
    if not task:
        await websocket.send_json({"type": "error", "message": "Task nicht gefunden"})
        await websocket.close()
        return

    # Sende bisherigen Output
    existing_output = task_manager.get_output(task_id)
    for line in existing_output:
        await websocket.send_json({"type": "output", "data": line})

    # Wenn Task schon fertig, sende Status und schließe
    if task.status in ("completed", "failed"):
        await websocket.send_json({
            "type": "status",
            "status": task.status,
            "exit_code": task.exit_code,
        })
        await websocket.close()
        return

    # Subscriben für Live-Updates
    queue = task_manager.subscribe(task_id)
    try:
        while True:
            line = await queue.get()
            if line is None:
                # Task beendet
                task = task_manager.get_task(task_id)
                await websocket.send_json({
                    "type": "status",
                    "status": task.status if task else "unknown",
                    "exit_code": task.exit_code if task else -1,
                })
                break
            await websocket.send_json({"type": "output", "data": line})
    except WebSocketDisconnect:
        pass
    finally:
        task_manager.unsubscribe(task_id, queue)
