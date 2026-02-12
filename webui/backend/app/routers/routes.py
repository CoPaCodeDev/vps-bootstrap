import os
import re

import yaml
from fastapi import APIRouter, Depends, HTTPException

from ..config import settings
from ..dependencies import get_current_user
from ..models.route import Route, RouteCreate
from ..services.ssh import run_ssh

router = APIRouter(prefix="/routes", tags=["Routen"])


def _parse_route_file(filepath: str) -> Route | None:
    """Parst eine Traefik-Route YAML-Datei."""
    try:
        with open(filepath, "r") as f:
            data = yaml.safe_load(f)
    except (OSError, yaml.YAMLError):
        return None

    if not data or "http" not in data:
        return None

    routers = data.get("http", {}).get("routers", {})
    services = data.get("http", {}).get("services", {})

    for name, router_cfg in routers.items():
        rule = router_cfg.get("rule", "")
        # Domain aus rule extrahieren: Host(`example.de`)
        domain_match = re.search(r"Host\(`([^`]+)`\)", rule)
        domain = domain_match.group(1) if domain_match else ""

        middlewares = router_cfg.get("middlewares", [])
        has_auth = "authelia" in middlewares

        has_tls = "tls" in router_cfg

        # Service-URL
        service_name = router_cfg.get("service", name)
        service_cfg = services.get(service_name, {})
        servers = service_cfg.get("loadBalancer", {}).get("servers", [])
        url = servers[0].get("url", "") if servers else ""

        # Host und Port aus URL extrahieren
        url_match = re.match(r"https?://([^:]+):(\d+)", url)
        host_ip = url_match.group(1) if url_match else ""
        port = int(url_match.group(2)) if url_match else 0

        return Route(
            domain=domain,
            host=host_ip,
            port=port,
            auth=has_auth,
            tls=has_tls,
        )

    return None


@router.get("/", response_model=list[Route])
async def list_routes(user: str = Depends(get_current_user)):
    """Alle Traefik-Routen auflisten."""
    conf_dir = settings.traefik_conf_dir
    routes = []

    if not os.path.exists(conf_dir):
        return routes

    for filename in sorted(os.listdir(conf_dir)):
        if not filename.endswith(".yml") and not filename.endswith(".yaml"):
            continue
        # Überspringe interne Configs
        if filename.startswith("_"):
            continue

        filepath = os.path.join(conf_dir, filename)
        route = _parse_route_file(filepath)
        if route:
            routes.append(route)

    return routes


@router.post("/", response_model=Route)
async def add_route(req: RouteCreate, user: str = Depends(get_current_user)):
    """Neue Route hinzufügen."""
    # Name aus Domain ableiten (Punkte durch Bindestriche ersetzen)
    name = req.domain.replace(".", "-")
    filename = f"{name}.yml"
    filepath = os.path.join(settings.traefik_conf_dir, filename)

    if os.path.exists(filepath):
        raise HTTPException(status_code=409, detail=f"Route für {req.domain} existiert bereits")

    # Template auswählen
    if req.auth:
        template = """http:
  routers:
    {name}:
      rule: "Host(`{domain}`)"
      entryPoints:
        - websecure
      service: {name}
      middlewares:
        - authelia
      tls:
        certResolver: letsencrypt

  services:
    {name}:
      loadBalancer:
        servers:
          - url: "http://{host}:{port}"
"""
    else:
        template = """http:
  routers:
    {name}:
      rule: "Host(`{domain}`)"
      entryPoints:
        - websecure
      service: {name}
      tls:
        certResolver: letsencrypt

  services:
    {name}:
      loadBalancer:
        servers:
          - url: "http://{host}:{port}"
"""

    content = template.format(
        name=name,
        domain=req.domain,
        host=req.host,
        port=req.port,
    )

    with open(filepath, "w") as f:
        f.write(content)

    return Route(
        domain=req.domain,
        host=req.host,
        port=req.port,
        auth=req.auth,
        tls=True,
    )


@router.delete("/{domain}")
async def remove_route(domain: str, user: str = Depends(get_current_user)):
    """Route entfernen."""
    name = domain.replace(".", "-")
    filename = f"{name}.yml"
    filepath = os.path.join(settings.traefik_conf_dir, filename)

    if not os.path.exists(filepath):
        raise HTTPException(status_code=404, detail=f"Route für {domain} nicht gefunden")

    os.remove(filepath)
    return {"message": f"Route für {domain} entfernt"}


@router.post("/{domain}/auth")
async def enable_auth(domain: str, user: str = Depends(get_current_user)):
    """Authelia-Schutz für Route aktivieren."""
    name = domain.replace(".", "-")
    filename = f"{name}.yml"
    filepath = os.path.join(settings.traefik_conf_dir, filename)

    if not os.path.exists(filepath):
        raise HTTPException(status_code=404, detail=f"Route für {domain} nicht gefunden")

    with open(filepath, "r") as f:
        data = yaml.safe_load(f)

    if not data or "http" not in data:
        raise HTTPException(status_code=500, detail="Ungültige Route-Konfiguration")

    routers = data.get("http", {}).get("routers", {})
    for router_name, cfg in routers.items():
        middlewares = cfg.get("middlewares", [])
        if "authelia" not in middlewares:
            middlewares.append("authelia")
            cfg["middlewares"] = middlewares

    with open(filepath, "w") as f:
        yaml.dump(data, f, default_flow_style=False, allow_unicode=True)

    return {"message": f"Authelia-Schutz für {domain} aktiviert"}


@router.post("/{domain}/noauth")
async def disable_auth(domain: str, user: str = Depends(get_current_user)):
    """Authelia-Schutz für Route deaktivieren."""
    name = domain.replace(".", "-")
    filename = f"{name}.yml"
    filepath = os.path.join(settings.traefik_conf_dir, filename)

    if not os.path.exists(filepath):
        raise HTTPException(status_code=404, detail=f"Route für {domain} nicht gefunden")

    with open(filepath, "r") as f:
        data = yaml.safe_load(f)

    if not data or "http" not in data:
        raise HTTPException(status_code=500, detail="Ungültige Route-Konfiguration")

    routers = data.get("http", {}).get("routers", {})
    for router_name, cfg in routers.items():
        middlewares = cfg.get("middlewares", [])
        if "authelia" in middlewares:
            middlewares.remove("authelia")
            if middlewares:
                cfg["middlewares"] = middlewares
            else:
                cfg.pop("middlewares", None)

    with open(filepath, "w") as f:
        yaml.dump(data, f, default_flow_style=False, allow_unicode=True)

    return {"message": f"Authelia-Schutz für {domain} deaktiviert"}
