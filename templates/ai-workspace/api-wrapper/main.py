import asyncio
import json
import logging
import os
from pathlib import Path

from fastapi import FastAPI, HTTPException, WebSocket, WebSocketDisconnect
from fastapi.responses import FileResponse

from models import SessionCreate, SessionStatus, VideoInfo
from session_manager import SessionManager

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

app = FastAPI(title="Claude Service API", version="1.0.0")
manager = SessionManager()

VIDEOS_DIR = Path(os.environ.get("VIDEOS_DIR", "/shared/videos"))


@app.get("/api/health")
async def health():
    return {"status": "ok"}


@app.get("/api/sessions", response_model=list[SessionStatus])
async def list_sessions():
    return await manager.list()


@app.post("/api/sessions", response_model=SessionStatus)
async def create_session(req: SessionCreate):
    try:
        return await manager.create(req.project, req.telegram)
    except ValueError as e:
        raise HTTPException(status_code=409, detail=str(e))


@app.get("/api/sessions/{project}", response_model=SessionStatus)
async def get_session(project: str):
    try:
        sessions = await manager.list()
        for s in sessions:
            if s.project == project:
                return s
        raise KeyError()
    except KeyError:
        raise HTTPException(status_code=404, detail=f"Session '{project}' nicht gefunden")


@app.delete("/api/sessions/{project}")
async def stop_session(project: str):
    try:
        await manager.stop(project)
        return {"message": f"Session '{project}' gestoppt"}
    except KeyError:
        raise HTTPException(status_code=404, detail=f"Session '{project}' nicht gefunden")


@app.get("/api/sessions/{project}/videos", response_model=list[VideoInfo])
async def list_videos(project: str):
    video_dir = VIDEOS_DIR / project
    if not video_dir.exists():
        return []

    videos = []
    for f in sorted(video_dir.iterdir()):
        if f.suffix in (".webm", ".mp4"):
            stat = f.stat()
            videos.append(VideoInfo(
                id=f.stem,
                filename=f.name,
                size=stat.st_size,
                created=str(stat.st_mtime),
            ))
    return videos


@app.get("/api/sessions/{project}/videos/{video_id}")
async def get_video(project: str, video_id: str):
    video_dir = VIDEOS_DIR / project
    for ext in (".mp4", ".webm"):
        path = video_dir / f"{video_id}{ext}"
        if path.exists():
            return FileResponse(path)
    raise HTTPException(status_code=404, detail="Video nicht gefunden")


@app.websocket("/ws/sessions/{project}")
async def session_websocket(websocket: WebSocket, project: str):
    await websocket.accept()

    try:
        output = await manager.get_output(project, since=0)
        cursor = len(output)
        for line in output:
            await websocket.send_text(line)
    except KeyError:
        await websocket.close(code=4004, reason="Session nicht gefunden")
        return

    try:
        async def send_output():
            nonlocal cursor
            while True:
                try:
                    lines = await manager.get_output(project, since=cursor)
                    for line in lines:
                        await websocket.send_text(line)
                    cursor += len(lines)
                except KeyError:
                    break
                await asyncio.sleep(0.2)

        output_task = asyncio.create_task(send_output())

        try:
            while True:
                data = await websocket.receive_text()
                try:
                    await manager.send_input(project, data)
                except (KeyError, ValueError):
                    await websocket.send_text("[Session beendet]")
                    break
        except WebSocketDisconnect:
            pass
        finally:
            output_task.cancel()

    except Exception as e:
        logger.error(f"WebSocket Fehler: {e}")
