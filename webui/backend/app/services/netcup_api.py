import asyncio
import base64
import json
import logging
import os
import time
import uuid
from typing import Callable, Awaitable

import httpx

from ..config import settings

logger = logging.getLogger(__name__)


class NetcupAPI:
    """Netcup SCP REST API Client mit Device Code OAuth Flow."""

    def __init__(self):
        self._pending_logins: dict[str, dict] = {}

    def _token_path(self) -> str:
        return settings.netcup_token_file

    def _load_tokens(self) -> dict | None:
        path = self._token_path()
        if not os.path.exists(path):
            return None
        try:
            with open(path, "r") as f:
                return json.load(f)
        except (json.JSONDecodeError, OSError):
            return None

    def _save_tokens(self, tokens: dict):
        path = self._token_path()
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            json.dump(tokens, f)

    def _is_token_valid(self, tokens: dict) -> bool:
        expires_at = tokens.get("expires_at", 0)
        return time.time() < expires_at - 10

    async def _refresh_token(self, tokens: dict) -> dict | None:
        refresh_token = tokens.get("refresh_token")
        if not refresh_token:
            return None

        token_url = f"{settings.netcup_keycloak_base}/realms/scp/protocol/openid-connect/token"
        async with httpx.AsyncClient() as client:
            resp = await client.post(
                token_url,
                data={
                    "grant_type": "refresh_token",
                    "client_id": settings.netcup_client_id,
                    "refresh_token": refresh_token,
                },
            )
            if resp.status_code != 200:
                return None

            data = resp.json()
            data["expires_at"] = time.time() + data.get("expires_in", 300)
            self._save_tokens(data)
            return data

    async def get_access_token(self) -> str | None:
        """Gibt ein gültiges Access Token zurück, refresht wenn nötig."""
        tokens = self._load_tokens()
        if not tokens:
            return None

        if not self._is_token_valid(tokens):
            tokens = await self._refresh_token(tokens)
            if not tokens:
                return None

        return tokens.get("access_token")

    async def start_device_login(self) -> dict:
        """Startet den Device Code Flow."""
        device_url = f"{settings.netcup_keycloak_base}/realms/scp/protocol/openid-connect/auth/device"

        async with httpx.AsyncClient() as client:
            resp = await client.post(
                device_url,
                data={
                    "client_id": settings.netcup_client_id,
                    "scope": "offline_access openid",
                },
            )
            resp.raise_for_status()
            data = resp.json()

        session_id = str(uuid.uuid4())[:8]
        self._pending_logins[session_id] = {
            "device_code": data["device_code"],
            "interval": data.get("interval", 5),
            "expires_at": time.time() + data.get("expires_in", 600),
        }

        return {
            "session_id": session_id,
            "verification_uri": data.get("verification_uri_complete", data.get("verification_uri", "")),
            "user_code": data.get("user_code", ""),
            "expires_in": data.get("expires_in", 600),
        }

    async def check_login_status(self, session_id: str) -> dict:
        """Prüft ob der Device Code Flow abgeschlossen ist."""
        login = self._pending_logins.get(session_id)
        if not login:
            return {"status": "error", "message": "Session nicht gefunden"}

        if time.time() > login["expires_at"]:
            self._pending_logins.pop(session_id, None)
            return {"status": "error", "message": "Session abgelaufen"}

        token_url = f"{settings.netcup_keycloak_base}/realms/scp/protocol/openid-connect/token"

        try:
            async with httpx.AsyncClient() as client:
                resp = await client.post(
                    token_url,
                    data={
                        "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                        "client_id": settings.netcup_client_id,
                        "device_code": login["device_code"],
                    },
                )
        except Exception:
            return {"status": "pending", "message": "Verbindungsfehler, versuche erneut..."}

        if resp.status_code == 200:
            tokens = resp.json()
            tokens["expires_at"] = time.time() + tokens.get("expires_in", 300)
            self._save_tokens(tokens)
            self._pending_logins.pop(session_id, None)
            return {"status": "success", "message": "Anmeldung erfolgreich"}

        data = resp.json()
        error = data.get("error", "")
        if error in ("authorization_pending", "slow_down"):
            return {"status": "pending", "message": "Warte auf Bestätigung..."}
        else:
            self._pending_logins.pop(session_id, None)
            return {"status": "error", "message": data.get("error_description", error)}

    async def logout(self):
        """Revoked das Token und löscht die Token-Datei."""
        tokens = self._load_tokens()
        if tokens and tokens.get("refresh_token"):
            revoke_url = f"{settings.netcup_keycloak_base}/realms/scp/protocol/openid-connect/revoke"
            try:
                async with httpx.AsyncClient() as client:
                    await client.post(
                        revoke_url,
                        data={
                            "client_id": settings.netcup_client_id,
                            "token": tokens["refresh_token"],
                            "token_type_hint": "refresh_token",
                        },
                    )
            except Exception:
                pass

        path = self._token_path()
        if os.path.exists(path):
            os.remove(path)

    async def _api_request(self, method: str, path: str, **kwargs) -> httpx.Response:
        """Führt einen authentifizierten API-Request aus."""
        token = await self.get_access_token()
        if not token:
            raise Exception("Nicht bei Netcup angemeldet")

        url = f"{settings.netcup_base_url}{path}"
        headers = {"Authorization": f"Bearer {token}"}
        if "headers_extra" in kwargs:
            headers.update(kwargs.pop("headers_extra"))
        req_timeout = kwargs.pop("timeout", 30)
        async with httpx.AsyncClient(timeout=req_timeout) as client:
            resp = await client.request(
                method,
                url,
                headers=headers,
                **kwargs,
            )
            resp.raise_for_status()
            return resp

    async def list_servers(self) -> list[dict]:
        resp = await self._api_request("GET", "/api/v1/servers")
        servers = resp.json()

        async def enrich(server: dict) -> dict:
            try:
                detail = await self.get_server(str(server["id"]))
                server["ipv4Addresses"] = detail.get("ipv4Addresses", [])
                server["ipv6Addresses"] = detail.get("ipv6Addresses", [])
                server["serverLiveInfo"] = detail.get("serverLiveInfo")
            except Exception:
                pass
            return server

        return await asyncio.gather(*[enrich(s) for s in servers])

    async def get_server(self, server_id: str) -> dict:
        resp = await self._api_request(
            "GET", f"/api/v1/servers/{server_id}", params={"loadServerLiveInfo": True}
        )
        return resp.json()

    async def set_server_state(self, server_id: str, state: str) -> dict:
        resp = await self._api_request(
            "PATCH",
            f"/api/v1/servers/{server_id}",
            json={"state": state},
            headers_extra={"Content-Type": "application/merge-patch+json"},
        )
        return resp.json()

    async def get_images(self, server_id: str) -> list[dict]:
        resp = await self._api_request("GET", f"/api/v1/servers/{server_id}/imageflavours")
        return resp.json()

    async def get_disks(self, server_id: str) -> list[dict]:
        """Disks eines Servers abrufen."""
        resp = await self._api_request("GET", f"/api/v1/servers/{server_id}/disks")
        return resp.json()

    async def install_image(self, server_id: str, body: dict) -> dict:
        """Image auf Server installieren (vollständiger Endpoint).

        Body enthält: imageFlavourId, diskName, hostname, password,
        sshKeyIds, customScript, locale, timezone etc.
        """
        resp = await self._api_request(
            "POST",
            f"/api/v1/servers/{server_id}/image",
            json=body,
            timeout=60,
        )
        return resp.json()

    async def get_tasks(self) -> list[dict]:
        """Alle Tasks des Users abrufen."""
        resp = await self._api_request("GET", "/api/v1/tasks")
        return resp.json()

    async def get_task(self, task_uuid: str) -> dict:
        """Einzelnen Task abrufen."""
        resp = await self._api_request("GET", f"/api/v1/tasks/{task_uuid}")
        return resp.json()

    async def get_ssh_keys(self, user_id: int) -> list[dict]:
        """SSH-Keys eines Users abrufen."""
        resp = await self._api_request("GET", f"/api/v1/users/{user_id}/ssh-keys")
        return resp.json()

    async def upload_ssh_key(self, user_id: int, name: str, key: str) -> dict:
        """SSH-Key für einen User hochladen."""
        resp = await self._api_request(
            "POST",
            f"/api/v1/users/{user_id}/ssh-keys",
            json={"name": name, "key": key},
        )
        return resp.json()

    async def create_vlan_interface(self, server_id: str, vlan_id: int) -> dict:
        """VLAN-Interface für einen Server anlegen."""
        resp = await self._api_request(
            "POST",
            f"/api/v1/servers/{server_id}/interfaces",
            json={"vlanId": vlan_id, "networkDriver": "VIRTIO"},
        )
        return resp.json()

    async def set_hostname(self, server_id: str, hostname: str) -> dict:
        """Hostname eines Servers setzen."""
        resp = await self._api_request(
            "PATCH",
            f"/api/v1/servers/{server_id}",
            json={"hostname": hostname},
            headers_extra={"Content-Type": "application/merge-patch+json"},
        )
        return resp.json()

    async def set_nickname(self, server_id: str, nickname: str) -> dict:
        """Nickname eines Servers setzen."""
        resp = await self._api_request(
            "PATCH",
            f"/api/v1/servers/{server_id}",
            json={"nickname": nickname},
            headers_extra={"Content-Type": "application/merge-patch+json"},
        )
        return resp.json()

    async def get_user_id(self) -> int:
        """User-ID aus Tasks-API oder JWT extrahieren."""
        # 1. Tasks-API: executingUser.id
        try:
            tasks = await self.get_tasks()
            for task in tasks:
                uid = (task.get("executingUser") or {}).get("id")
                if uid and isinstance(uid, int) and uid > 0:
                    return uid
        except Exception:
            pass

        # 2. JWT-Claims
        tokens = self._load_tokens()
        if tokens and tokens.get("access_token"):
            try:
                payload = tokens["access_token"].split(".")[1]
                # Base64-Padding
                payload += "=" * (4 - len(payload) % 4)
                decoded = json.loads(base64.b64decode(payload))
                for claim in ("userId", "user_id", "uid", "scp_user_id"):
                    val = decoded.get(claim)
                    if val and str(val).isdigit():
                        return int(val)
            except Exception:
                pass

        raise Exception("Konnte User-ID nicht ermitteln")

    async def get_vlan_id(self) -> int:
        """VLAN-ID aus bestehenden Server-Interfaces ermitteln."""
        servers = await self.list_servers()
        for server in servers:
            try:
                info = await self.get_server(str(server["id"]))
                interfaces = (info.get("serverLiveInfo") or {}).get("interfaces", [])
                for iface in interfaces:
                    if iface.get("vlanInterface"):
                        vlan_id = iface.get("vlanId")
                        if vlan_id and int(vlan_id) > 0:
                            return int(vlan_id)
            except Exception:
                continue
        raise Exception("Kein CloudVLAN gefunden. Kein bestehender Server hat ein VLAN-Interface.")

    async def poll_netcup_task(
        self,
        task_uuid: str,
        task_name: str,
        callback: Callable[[str], Awaitable[None]] | None = None,
        max_polls: int = 360,
    ) -> bool:
        """Pollt einen Netcup-Task bis fertig. Gibt True bei Erfolg zurück."""
        for poll in range(1, max_polls + 1):
            await asyncio.sleep(5)
            try:
                task = await self.get_task(task_uuid)
            except Exception as e:
                logger.warning("Task-Poll fehlgeschlagen: %s", e)
                continue

            state = task.get("state", "UNKNOWN")
            progress = task.get("taskProgress", {}).get("progressInPercent", 0)
            progress = int(float(progress))

            msg = f"  {task_name}... {progress}% ({state})"
            if callback:
                await callback(msg)

            if state == "FINISHED":
                if callback:
                    await callback(f"  {task_name}... 100% (FINISHED)")
                return True
            if state in ("ERROR", "CANCELED", "ROLLBACK"):
                error_msg = (
                    task.get("responseError", {}).get("message")
                    or task.get("message")
                    or "Unbekannter Fehler"
                )
                if callback:
                    await callback(f"FEHLER: {task_name} fehlgeschlagen: {error_msg}")
                return False

        if callback:
            await callback(f"FEHLER: {task_name}: Zeitüberschreitung nach 30 Minuten")
        return False


# Globale Instanz
netcup_api = NetcupAPI()
