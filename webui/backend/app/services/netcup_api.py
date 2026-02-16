import json
import os
import time
import uuid

import httpx

from ..config import settings


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
        async with httpx.AsyncClient() as client:
            resp = await client.request(
                method,
                url,
                headers={"Authorization": f"Bearer {token}"},
                **kwargs,
            )
            resp.raise_for_status()
            return resp

    async def list_servers(self) -> list[dict]:
        resp = await self._api_request("GET", "/api/v1/servers")
        return resp.json()

    async def get_server(self, server_id: str) -> dict:
        resp = await self._api_request(
            "GET", f"/api/v1/servers/{server_id}", params={"loadServerLiveInfo": True}
        )
        return resp.json()

    async def get_images(self, server_id: str) -> list[dict]:
        resp = await self._api_request("GET", f"/api/v1/servers/{server_id}/imageflavours")
        return resp.json()

    async def install_server(self, server_id: str, image_id: str, hostname: str, ssh_keys: list[int] | None = None) -> dict:
        body = {
            "imageFlavourId": image_id,
            "hostname": hostname,
        }
        if ssh_keys:
            body["sshKeyIds"] = ssh_keys

        resp = await self._api_request("POST", f"/api/v1/servers/{server_id}/install", json=body)
        return resp.json()


# Globale Instanz
netcup_api = NetcupAPI()
