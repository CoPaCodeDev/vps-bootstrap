from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from .config import settings
from .routers import vps, docker, traefik, routes, deploy, netcup, backup, authelia, tasks, terminal

app = FastAPI(
    title="VPS Dashboard API",
    description="Web-API für die VPS-Verwaltung",
    version="1.0.0",
    docs_url="/docs",
    redoc_url="/redoc",
)

# CORS für Entwicklung (Frontend auf anderem Port)
app.add_middleware(
    CORSMiddleware,
    allow_origins=["http://localhost:5173", "http://127.0.0.1:5173"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Router einbinden
app.include_router(vps.router, prefix=settings.api_prefix)
app.include_router(docker.router, prefix=settings.api_prefix)
app.include_router(traefik.router, prefix=settings.api_prefix)
app.include_router(routes.router, prefix=settings.api_prefix)
app.include_router(deploy.router, prefix=settings.api_prefix)
app.include_router(netcup.router, prefix=settings.api_prefix)
app.include_router(backup.router, prefix=settings.api_prefix)
app.include_router(authelia.router, prefix=settings.api_prefix)
app.include_router(tasks.router, prefix=settings.api_prefix)
app.include_router(terminal.router, prefix=settings.api_prefix)


@app.get("/api/health")
async def health():
    return {"status": "ok"}
