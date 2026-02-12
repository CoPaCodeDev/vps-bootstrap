import os
import json

from fastapi import APIRouter, Depends, HTTPException

from ..config import settings
from ..dependencies import get_current_user
from ..models.deploy import Template, DeployRequest, Deployment
from ..models.task import TaskCreate
from ..services.hosts import resolve_host
from ..services.ssh import run_ssh, run_ssh_stream
from ..services.task_manager import task_manager
from ..services.template_parser import list_templates, parse_template_conf

router = APIRouter(prefix="/deploy", tags=["Deploy"])


@router.get("/templates", response_model=list[Template])
async def get_templates(user: str = Depends(get_current_user)):
    """Verfügbare Templates auflisten."""
    return list_templates()


@router.get("/templates/{name}", response_model=Template)
async def get_template(name: str, user: str = Depends(get_current_user)):
    """Template-Details abrufen."""
    template_dir = os.path.join(settings.templates_dir, name)
    template = parse_template_conf(template_dir)
    if not template:
        raise HTTPException(status_code=404, detail=f"Template '{name}' nicht gefunden")
    return template


@router.get("/{host}", response_model=list[Deployment])
async def list_deployments(host: str, user: str = Depends(get_current_user)):
    """Deployments auf einem Host auflisten."""
    ip = resolve_host(host)
    if not ip:
        raise HTTPException(status_code=404, detail=f"Host '{host}' nicht gefunden")

    # Suche nach Docker-Compose-Projekten in /opt/
    code, stdout, _ = await run_ssh(
        ip,
        "for d in /opt/*/docker-compose.yml; do [ -f \"$d\" ] && dirname \"$d\"; done 2>/dev/null",
        timeout=10,
    )

    deployments = []
    if code == 0 and stdout:
        for deploy_dir in stdout.strip().split("\n"):
            if not deploy_dir.strip():
                continue
            app_name = os.path.basename(deploy_dir)

            # Container-Anzahl prüfen
            rc, count_str, _ = await run_ssh(
                ip,
                f"cd {deploy_dir} && sudo docker compose ps -q 2>/dev/null | wc -l",
                timeout=10,
            )
            try:
                container_count = int(count_str.strip()) if rc == 0 else 0
            except ValueError:
                container_count = 0

            deployments.append(
                Deployment(
                    app=app_name,
                    host=host,
                    status="running" if container_count > 0 else "stopped",
                    containers=container_count,
                )
            )

    return deployments


@router.post("/", response_model=TaskCreate)
async def deploy_template(req: DeployRequest, user: str = Depends(get_current_user)):
    """Template deployen (Background-Task)."""
    ip = resolve_host(req.host)
    if not ip:
        raise HTTPException(status_code=404, detail=f"Host '{req.host}' nicht gefunden")

    template_dir = os.path.join(settings.templates_dir, req.template)
    template = parse_template_conf(template_dir)
    if not template:
        raise HTTPException(status_code=404, detail=f"Template '{req.template}' nicht gefunden")

    async def do_deploy(task_id: str):
        await task_manager.push_output(
            task_id, f"Deploye {req.template} auf {req.host} ({ip})..."
        )

        # Deploy-Verzeichnis aus template.conf lesen
        conf_path = os.path.join(template_dir, "template.conf")
        deploy_dir = f"/opt/{req.template}"
        with open(conf_path, "r") as f:
            for line in f:
                if line.startswith("TEMPLATE_DEPLOY_DIR="):
                    deploy_dir = line.split("=", 1)[1].strip().strip('"')
                    break

        # Verzeichnis erstellen
        await task_manager.push_output(task_id, f"Erstelle Verzeichnis {deploy_dir}...")
        await run_ssh(ip, f"sudo mkdir -p {deploy_dir} && sudo chown master:master {deploy_dir}")

        # docker-compose.yml übertragen
        compose_src = os.path.join(template_dir, "docker-compose.yml")
        if os.path.exists(compose_src):
            with open(compose_src, "r") as f:
                compose_content = f.read()

            # Variablen ersetzen
            for key, value in req.vars.items():
                compose_content = compose_content.replace(f"{{{{{key}}}}}", value)

            await task_manager.push_output(task_id, "Übertrage docker-compose.yml...")
            # .env-Datei mit Variablen erstellen
            env_lines = [f"{k}={v}" for k, v in req.vars.items()]
            env_content = "\n".join(env_lines) + "\n"

            await run_ssh(ip, f"cat > {deploy_dir}/.env << 'ENVEOF'\n{env_content}ENVEOF")
            await run_ssh(ip, f"cat > {deploy_dir}/docker-compose.yml << 'COMPEOF'\n{compose_content}COMPEOF")

        # Docker Compose starten
        await task_manager.push_output(task_id, "Starte Container...")
        async for line in run_ssh_stream(ip, f"cd {deploy_dir} && sudo docker compose up -d"):
            await task_manager.push_output(task_id, line)

        # Route erstellen wenn benötigt
        domain = req.vars.get("DOMAIN", "")
        if domain:
            await task_manager.push_output(task_id, f"Erstelle Route für {domain}...")
            route_name = domain.replace(".", "-")
            route_template = "route-auth.yml.template" if req.auth else "route.yml.template"
            route_src = os.path.join(settings.templates_dir, "..", "templates", "traefik", route_template)

            # Einfache Route direkt erstellen
            port = "8000"
            with open(conf_path, "r") as f:
                for line in f:
                    if line.startswith("TEMPLATE_ROUTE_PORT="):
                        port = line.split("=", 1)[1].strip().strip('"')
                        break

            if req.auth:
                route_content = f"""http:
  routers:
    {route_name}:
      rule: "Host(`{domain}`)"
      entryPoints:
        - websecure
      service: {route_name}
      middlewares:
        - authelia
      tls:
        certResolver: letsencrypt

  services:
    {route_name}:
      loadBalancer:
        servers:
          - url: "http://{ip}:{port}"
"""
            else:
                route_content = f"""http:
  routers:
    {route_name}:
      rule: "Host(`{domain}`)"
      entryPoints:
        - websecure
      service: {route_name}
      tls:
        certResolver: letsencrypt

  services:
    {route_name}:
      loadBalancer:
        servers:
          - url: "http://{ip}:{port}"
"""

            route_file = os.path.join(settings.traefik_conf_dir, f"{route_name}.yml")
            with open(route_file, "w") as f:
                f.write(route_content)
            await task_manager.push_output(task_id, f"Route {domain} erstellt.")

        await task_manager.push_output(task_id, "Deployment abgeschlossen.")

    task_id = task_manager.create_task(
        "deploy",
        f"{req.template} auf {req.host}",
        host=req.host,
        coro_factory=do_deploy,
    )
    return TaskCreate(task_id=task_id)


@router.delete("/{host}/{app}")
async def remove_deployment(
    host: str, app: str, user: str = Depends(get_current_user)
):
    """Deployment entfernen."""
    ip = resolve_host(host)
    if not ip:
        raise HTTPException(status_code=404, detail=f"Host '{host}' nicht gefunden")

    deploy_dir = f"/opt/{app}"
    # Container stoppen und entfernen
    code, _, stderr = await run_ssh(
        ip, f"cd {deploy_dir} && sudo docker compose down -v 2>&1", timeout=60
    )

    # Verzeichnis entfernen
    await run_ssh(ip, f"sudo rm -rf {deploy_dir}")

    return {"message": f"Deployment {app} auf {host} entfernt"}
