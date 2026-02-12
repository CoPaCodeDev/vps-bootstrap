import os
import re

import yaml
from fastapi import APIRouter, Depends, HTTPException

from ..config import settings
from ..dependencies import get_current_user
from ..models.authelia import (
    AutheliaUser,
    AutheliaUserCreate,
    AutheliaDomain,
    AutheliaDomainCreate,
    AutheliaStatus,
)
from ..services.ssh import run_ssh

router = APIRouter(prefix="/authelia", tags=["Authelia"])

USERS_DB_PATH = os.path.join(settings.authelia_config_dir, "users_database.yml")
CONFIG_PATH = os.path.join(settings.authelia_config_dir, "configuration.yml")


@router.get("/status", response_model=AutheliaStatus)
async def authelia_status(user: str = Depends(get_current_user)):
    """Authelia-Container-Status."""
    code, stdout, _ = await run_ssh(
        "proxy", "sudo docker ps --filter name=authelia --format json"
    )

    import json

    running = False
    version = ""
    if code == 0 and stdout.strip():
        try:
            data = json.loads(stdout.strip().split("\n")[0])
            running = data.get("State") == "running"
            version = data.get("Image", "").split(":")[-1] if ":" in data.get("Image", "") else ""
        except (json.JSONDecodeError, IndexError):
            pass

    users = _load_users()
    domains = _load_domains()

    return AutheliaStatus(
        running=running,
        version=version,
        users=len(users),
        domains=len(domains),
    )


@router.get("/users", response_model=list[AutheliaUser])
async def list_users(user: str = Depends(get_current_user)):
    """Authelia-Benutzer auflisten."""
    return _load_users()


@router.post("/users", response_model=AutheliaUser)
async def add_user(req: AutheliaUserCreate, user: str = Depends(get_current_user)):
    """Neuen Benutzer hinzufügen."""
    users_data = _load_users_raw()

    if req.username in users_data.get("users", {}):
        raise HTTPException(status_code=409, detail=f"Benutzer '{req.username}' existiert bereits")

    # Passwort-Hash generieren
    code, hash_out, stderr = await run_ssh(
        "proxy",
        f"sudo docker exec authelia authelia crypto hash generate argon2 --password '{req.password}'",
        timeout=15,
    )
    if code != 0:
        raise HTTPException(status_code=500, detail=f"Fehler beim Hash: {stderr}")

    # Hash extrahieren (Ausgabe: "Digest: $argon2id$...")
    password_hash = hash_out.strip()
    if "Digest:" in password_hash:
        password_hash = password_hash.split("Digest:")[-1].strip()

    if "users" not in users_data:
        users_data["users"] = {}

    users_data["users"][req.username] = {
        "displayname": req.displayname,
        "email": req.email,
        "password": password_hash,
        "groups": req.groups or [],
        "disabled": False,
    }

    _save_users_raw(users_data)

    return AutheliaUser(
        username=req.username,
        displayname=req.displayname,
        email=req.email,
        groups=req.groups or [],
    )


@router.delete("/users/{username}")
async def remove_user(username: str, user: str = Depends(get_current_user)):
    """Benutzer entfernen."""
    users_data = _load_users_raw()

    if username not in users_data.get("users", {}):
        raise HTTPException(status_code=404, detail=f"Benutzer '{username}' nicht gefunden")

    del users_data["users"][username]
    _save_users_raw(users_data)

    return {"message": f"Benutzer '{username}' entfernt"}


@router.get("/domains", response_model=list[AutheliaDomain])
async def list_domains(user: str = Depends(get_current_user)):
    """Cookie-Domains auflisten."""
    return _load_domains()


@router.post("/domains", response_model=AutheliaDomain)
async def add_domain(req: AutheliaDomainCreate, user: str = Depends(get_current_user)):
    """Cookie-Domain hinzufügen."""
    config = _load_config()
    if not config:
        raise HTTPException(status_code=500, detail="Authelia-Konfiguration nicht gefunden")

    # Cookie-Domains-Block finden
    session = config.get("session", {})
    cookies = session.get("cookies", [])

    # Prüfe ob Domain schon existiert
    for cookie in cookies:
        if cookie.get("domain") == req.domain:
            raise HTTPException(status_code=409, detail=f"Domain '{req.domain}' existiert bereits")

    cookies.append({
        "domain": req.domain,
        "authelia_url": f"https://auth.{req.domain}",
        "default_redirection_url": f"https://{req.domain}",
    })

    config["session"]["cookies"] = cookies
    _save_config(config)

    return AutheliaDomain(
        domain=req.domain,
        default_redirection_url=f"https://{req.domain}",
    )


@router.delete("/domains/{domain}")
async def remove_domain(domain: str, user: str = Depends(get_current_user)):
    """Cookie-Domain entfernen."""
    config = _load_config()
    if not config:
        raise HTTPException(status_code=500, detail="Authelia-Konfiguration nicht gefunden")

    session = config.get("session", {})
    cookies = session.get("cookies", [])

    new_cookies = [c for c in cookies if c.get("domain") != domain]
    if len(new_cookies) == len(cookies):
        raise HTTPException(status_code=404, detail=f"Domain '{domain}' nicht gefunden")

    config["session"]["cookies"] = new_cookies
    _save_config(config)

    return {"message": f"Domain '{domain}' entfernt"}


@router.post("/restart")
async def restart_authelia(user: str = Depends(get_current_user)):
    """Authelia neustarten."""
    code, _, stderr = await run_ssh("proxy", "sudo docker restart authelia")
    if code != 0:
        return {"success": False, "error": stderr}
    return {"success": True, "message": "Authelia neu gestartet"}


# --- Hilfsfunktionen ---

def _load_users_raw() -> dict:
    try:
        with open(USERS_DB_PATH, "r") as f:
            return yaml.safe_load(f) or {}
    except (OSError, yaml.YAMLError):
        return {"users": {}}


def _save_users_raw(data: dict):
    with open(USERS_DB_PATH, "w") as f:
        yaml.dump(data, f, default_flow_style=False, allow_unicode=True)


def _load_users() -> list[AutheliaUser]:
    data = _load_users_raw()
    users = []
    for username, info in data.get("users", {}).items():
        users.append(
            AutheliaUser(
                username=username,
                displayname=info.get("displayname", ""),
                email=info.get("email", ""),
                groups=info.get("groups", []),
                disabled=info.get("disabled", False),
            )
        )
    return users


def _load_config() -> dict | None:
    try:
        with open(CONFIG_PATH, "r") as f:
            return yaml.safe_load(f)
    except (OSError, yaml.YAMLError):
        return None


def _save_config(config: dict):
    with open(CONFIG_PATH, "w") as f:
        yaml.dump(config, f, default_flow_style=False, allow_unicode=True)


def _load_domains() -> list[AutheliaDomain]:
    config = _load_config()
    if not config:
        return []

    cookies = config.get("session", {}).get("cookies", [])
    return [
        AutheliaDomain(
            domain=c.get("domain", ""),
            default_redirection_url=c.get("default_redirection_url", ""),
        )
        for c in cookies
        if c.get("domain")
    ]
