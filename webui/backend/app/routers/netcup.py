import asyncio
import logging
import re

from fastapi import APIRouter, Depends, HTTPException

from ..config import settings
from ..dependencies import get_current_user
from ..models.netcup import DeviceCodeResponse, LoginStatus, Server, InstallRequest
from ..models.task import TaskCreate
from ..services.netcup_api import netcup_api
from ..services.ssh import run_ssh
from ..services.ssh_utils import run_on_proxy
from ..services.task_manager import task_manager

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/netcup", tags=["Netcup"])


@router.post("/login/device", response_model=DeviceCodeResponse)
async def start_device_login(user: str = Depends(get_current_user)):
    """Device Code Flow starten."""
    try:
        result = await netcup_api.start_device_login()
        return DeviceCodeResponse(**result)
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.get("/login/status/{sid}", response_model=LoginStatus)
async def check_login(sid: str, user: str = Depends(get_current_user)):
    """Login-Status prüfen."""
    result = await netcup_api.check_login_status(sid)
    return LoginStatus(**result)


@router.post("/logout")
async def logout(user: str = Depends(get_current_user)):
    """Von Netcup abmelden."""
    await netcup_api.logout()
    return {"message": "Abgemeldet"}


@router.get("/servers")
async def list_servers(user: str = Depends(get_current_user)):
    """Netcup-Server auflisten."""
    try:
        servers = await netcup_api.list_servers()
    except Exception as e:
        raise HTTPException(status_code=401, detail=str(e))

    # vps-hosts vom Proxy lesen
    try:
        hosts_content = await run_on_proxy(f"cat {settings.vps_hosts_file} 2>/dev/null || true")
    except Exception as e:
        logger.warning("Konnte vps-hosts nicht vom Proxy lesen: %s", e)
        hosts_content = ""

    # Hostname → IP Mapping aufbauen
    vlan_map = {}
    for line in hosts_content.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split(None, 1)
        if len(parts) == 2:
            vlan_map[parts[1]] = parts[0]

    logger.debug("vlan_map: %s", vlan_map)

    # Jeden Server mit vlanIp anreichern (Match über nickname oder hostname)
    for server in servers:
        nickname = server.get("nickname", "")
        hostname = server.get("hostname", "")
        vlan_ip = vlan_map.get(nickname) or vlan_map.get(hostname) or ""
        server["vlanIp"] = vlan_ip

    return servers


@router.get("/servers/{server_id}")
async def get_server(server_id: str, user: str = Depends(get_current_user)):
    """Server-Details abrufen."""
    try:
        server = await netcup_api.get_server(server_id)
        return server
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.post("/servers/{server_id}/state/{action}")
async def change_server_state(
    server_id: str,
    action: str,
    user: str = Depends(get_current_user),
):
    """Server starten, stoppen oder neustarten."""
    state_map = {"start": "ON", "stop": "OFF", "restart": "OFF"}
    if action not in state_map:
        raise HTTPException(status_code=400, detail=f"Ungültige Aktion: {action}")

    try:
        result = await netcup_api.set_server_state(server_id, state_map[action])
        if action == "restart":
            await asyncio.sleep(3)
            result = await netcup_api.set_server_state(server_id, "ON")
        return {"message": f"Server {action} erfolgreich", "result": result}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.get("/servers/{server_id}/images")
async def get_images(server_id: str, user: str = Depends(get_current_user)):
    """Verfügbare Images für einen Server abrufen."""
    try:
        images = await netcup_api.get_images(server_id)
        return images
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.post("/servers/{server_id}/install", response_model=TaskCreate)
async def install_server(
    server_id: str,
    req: InstallRequest,
    user: str = Depends(get_current_user),
):
    """VPS installieren (Background-Task) — analog zu vps-cli.sh cmd_netcup_install."""

    async def do_install(task_id: str):
        out = task_manager.push_output

        await out(task_id, "=== VPS Installation ===")
        await out(task_id, f"Server: {server_id}")
        await out(task_id, f"Hostname: {req.hostname}")
        await out(task_id, f"Image: {req.image}")
        await out(task_id, f"CloudVLAN: {'ja' if req.setup_vlan else 'nein'}")
        await out(task_id, "")

        try:
            # 1. Image-ID finden
            await out(task_id, "Suche Image...")
            images = await netcup_api.get_images(server_id)
            image_id = None
            image_label = ""
            for img in images:
                image_name = img.get("image", {}).get("name", "") or img.get("name", "")
                flavour_name = img.get("name", "")
                search_text = f"{image_name} {flavour_name}".lower()
                if req.image.lower() in search_text:
                    image_id = img.get("id") or img.get("imageFlavourId")
                    image_label = (
                        f"{image_name} ({flavour_name})"
                        if image_name != flavour_name
                        else flavour_name
                    )
                    break

            if not image_id:
                raise Exception(f"Image '{req.image}' nicht gefunden")
            await out(task_id, f"  Image gefunden: {image_label} (ID: {image_id})")

            # 2. Disk ermitteln
            await out(task_id, "Ermittle Disk...")
            disks = await netcup_api.get_disks(server_id)
            if not disks:
                raise Exception("Keine Disks für diesen Server gefunden")
            disk_name = disks[0].get("name", "vda")
            disk_size_mib = disks[0].get("capacityInMiB", 0)
            disk_size_gib = disk_size_mib // 1024
            await out(task_id, f"  Disk: {disk_name} ({disk_size_gib} GiB)")

            # 3. User-ID ermitteln
            await out(task_id, "Ermittle User-ID...")
            user_id = await netcup_api.get_user_id()
            await out(task_id, f"  User-ID: {user_id}")

            # 4. Proxy-Pubkey lesen
            await out(task_id, "Lese Proxy-SSH-Key...")
            proxy_pubkey = await run_on_proxy("cat /home/master/.ssh/id_ed25519.pub")
            if not proxy_pubkey.strip():
                raise Exception("Konnte Proxy-Pubkey nicht lesen")
            pubkey_data = " ".join(proxy_pubkey.strip().split()[:2])
            await out(task_id, "  Proxy-Pubkey gelesen")

            # 5. SSH-Key bei Netcup suchen/hochladen
            await out(task_id, "Prüfe SSH-Key bei Netcup...")
            ssh_keys = await netcup_api.get_ssh_keys(user_id)
            ssh_key_id = None
            for key in ssh_keys:
                if key.get("key", "").startswith(pubkey_data):
                    ssh_key_id = key["id"]
                    break

            if ssh_key_id is None:
                await out(task_id, "  SSH-Key wird hochgeladen...")
                key_resp = await netcup_api.upload_ssh_key(
                    user_id, "proxy-key-dashboard", proxy_pubkey.strip()
                )
                ssh_key_id = key_resp["id"]
                await out(task_id, f"  SSH-Key hochgeladen (ID: {ssh_key_id})")
            else:
                await out(task_id, f"  SSH-Key bereits vorhanden (ID: {ssh_key_id})")

            # 6. CloudVLAN vorbereiten (vor Installation, damit IP im Script steht)
            vlan_ip = ""
            vlan_id = 0
            if req.setup_vlan:
                await out(task_id, "Bereite CloudVLAN vor...")
                vlan_id = await netcup_api.get_vlan_id()
                await out(task_id, f"  VLAN-ID: {vlan_id}")

                # Nächste freie IP aus /etc/vps-hosts auf dem Proxy ermitteln
                hosts_content = await run_on_proxy(
                    f"cat {settings.vps_hosts_file} 2>/dev/null || true"
                )
                used_octets = {1}  # Proxy ist immer .1
                for line in hosts_content.splitlines():
                    line = line.strip()
                    if not line or line.startswith("#"):
                        continue
                    ip = line.split()[0] if line.split() else ""
                    m = re.match(r"^10\.10\.0\.(\d+)$", ip)
                    if m:
                        used_octets.add(int(m.group(1)))

                # Prüfe ob Hostname schon einen Eintrag hat
                for line in hosts_content.splitlines():
                    parts = line.strip().split()
                    if len(parts) >= 2 and parts[1] == req.hostname:
                        vlan_ip = parts[0]
                        break

                if not vlan_ip:
                    for i in range(2, 255):
                        if i not in used_octets:
                            vlan_ip = f"10.10.0.{i}"
                            break

                if not vlan_ip:
                    raise Exception("Keine freie CloudVLAN-IP verfügbar")
                await out(task_id, f"  CloudVLAN-IP: {vlan_ip}")

            # 7. Post-Install-Script zusammenbauen
            await out(task_id, "Erstelle Post-Install-Script...")
            custom_script = (
                "#!/bin/bash\n"
                "set -e\n"
                "\n"
                "# SSH Root-Login deaktivieren\n"
                "sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config\n"
                "systemctl restart sshd\n"
                "\n"
                "# Sudo ohne Passwort fuer master\n"
                "echo 'master ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/master\n"
                "chmod 440 /etc/sudoers.d/master\n"
            )

            if req.setup_vlan:
                custom_script += (
                    "\n"
                    "# CloudVLAN-Interface finden\n"
                    "CLOUDVLAN_INTERFACE=\"\"\n"
                    "for iface in ens6 eth1 ens7 eth2; do\n"
                    "    ip link show \"$iface\" 2>/dev/null && CLOUDVLAN_INTERFACE=\"$iface\" && break\n"
                    "done\n"
                    "[[ -z \"$CLOUDVLAN_INTERFACE\" ]] && CLOUDVLAN_INTERFACE=\"ens6\"\n"
                    "\n"
                    "cat >> /etc/network/interfaces << IFACE\n"
                    "\n"
                    "auto ${CLOUDVLAN_INTERFACE}\n"
                    "iface ${CLOUDVLAN_INTERFACE} inet static\n"
                    f"    address {vlan_ip}/24\n"
                    "    mtu 1400\n"
                    "IFACE\n"
                    "\n"
                    "ifup \"$CLOUDVLAN_INTERFACE\" 2>/dev/null || true\n"
                    "\n"
                    "# UFW: nur CloudVLAN-Zugriff\n"
                    "apt-get update -qq\n"
                    "apt-get install -y -qq ufw\n"
                    "ufw default deny incoming\n"
                    "ufw default allow outgoing\n"
                    "ufw allow from 10.10.0.0/24\n"
                    "ufw --force enable\n"
                )
            else:
                custom_script += (
                    "\n"
                    "# UFW mit SSH offen\n"
                    "apt-get update -qq\n"
                    "apt-get install -y -qq ufw\n"
                    "ufw default deny incoming\n"
                    "ufw default allow outgoing\n"
                    "ufw allow 22/tcp\n"
                    "ufw allow from 10.10.0.0/24\n"
                    "ufw --force enable\n"
                )

            await out(task_id, "  Post-Install-Script erstellt")

            # 8. Image installieren
            await out(task_id, "")
            await out(task_id, "Starte Image-Installation...")
            install_body = {
                "imageFlavourId": int(image_id),
                "diskName": disk_name,
                "rootPartitionFullDiskSize": True,
                "hostname": req.hostname,
                "locale": "de_DE.UTF-8",
                "timezone": "Europe/Berlin",
                "additionalUserUsername": "master",
                "additionalUserPassword": req.password,
                "sshKeyIds": [int(ssh_key_id)],
                "sshPasswordAuthentication": False,
                "customScript": custom_script,
                "emailToExecutingUser": False,
            }
            install_result = await netcup_api.install_image(server_id, install_body)
            task_uuid = install_result.get("uuid")
            if not task_uuid:
                raise Exception("Konnte Task-UUID nicht ermitteln")
            await out(task_id, f"  Netcup-Task: {task_uuid}")

            # 9. Task pollen
            async def progress_callback(msg: str):
                await out(task_id, msg)

            success = await netcup_api.poll_netcup_task(
                task_uuid, "Installation", callback=progress_callback
            )
            if not success:
                raise Exception("Image-Installation fehlgeschlagen")
            await out(task_id, "Image-Installation abgeschlossen.")
            await out(task_id, "")

            # 10. CloudVLAN-Interface anlegen
            if req.setup_vlan:
                await out(task_id, "Prüfe CloudVLAN-Interface...")
                server_info = await netcup_api.get_server(server_id)
                interfaces = (server_info.get("serverLiveInfo") or {}).get("interfaces", [])
                has_vlan = any(i.get("vlanInterface") for i in interfaces)

                if not has_vlan:
                    await out(task_id, "  Lege CloudVLAN-Interface an...")
                    try:
                        vlan_result = await netcup_api.create_vlan_interface(server_id, vlan_id)
                        vlan_task_uuid = vlan_result.get("uuid")
                        if vlan_task_uuid:
                            vlan_ok = await netcup_api.poll_netcup_task(
                                vlan_task_uuid, "VLAN-Interface", callback=progress_callback
                            )
                            if vlan_ok:
                                await out(task_id, "  VLAN-Interface angelegt.")
                            else:
                                await out(task_id, "  WARNUNG: VLAN-Interface-Erstellung fehlgeschlagen.")
                    except Exception as e:
                        await out(task_id, f"  WARNUNG: VLAN-Interface konnte nicht angelegt werden: {e}")
                else:
                    await out(task_id, "  VLAN-Interface bereits vorhanden.")
                await out(task_id, "")

            # 11. Server starten
            await out(task_id, "Starte Server...")
            try:
                start_result = await netcup_api.set_server_state(server_id, "ON")
                start_task_uuid = start_result.get("uuid")
                if start_task_uuid:
                    await netcup_api.poll_netcup_task(
                        start_task_uuid, "Server starten", callback=progress_callback
                    )
                await out(task_id, "Server gestartet.")
            except Exception as e:
                await out(task_id, f"WARNUNG: Server konnte nicht gestartet werden: {e}")
            await out(task_id, "")

            # 12. Hostname + Nickname setzen
            await out(task_id, "Setze Hostname und Nickname...")
            try:
                await netcup_api.set_hostname(server_id, req.hostname)
                await netcup_api.set_nickname(server_id, req.hostname)
                await out(task_id, f"  Hostname: {req.hostname}")
                await out(task_id, f"  Nickname: {req.hostname}")
            except Exception as e:
                await out(task_id, f"  WARNUNG: Hostname/Nickname setzen fehlgeschlagen: {e}")
            await out(task_id, "")

            # 13. In /etc/vps-hosts eintragen (wenn CloudVLAN)
            if req.setup_vlan:
                await out(task_id, "Trage in /etc/vps-hosts ein...")
                try:
                    # Alten Eintrag entfernen
                    await run_on_proxy(
                        f"sudo sed -i '/ {req.hostname}$/d' {settings.vps_hosts_file} 2>/dev/null; "
                        f"sudo sed -i '/^{vlan_ip} /d' {settings.vps_hosts_file} 2>/dev/null; "
                        f"echo '{vlan_ip} {req.hostname}' | sudo tee -a {settings.vps_hosts_file}"
                    )
                    await out(task_id, f"  {vlan_ip} {req.hostname} eingetragen.")
                except Exception as e:
                    await out(task_id, f"  WARNUNG: vps-hosts Eintrag fehlgeschlagen: {e}")
                await out(task_id, "")

            # 14. SSH-Verbindungstest (wenn CloudVLAN)
            if req.setup_vlan:
                await out(task_id, "Warte auf SSH-Verbindung über CloudVLAN...")
                ssh_ok = False
                for attempt in range(1, 13):
                    await asyncio.sleep(10)
                    await out(task_id, f"  Versuch {attempt}/12...")
                    rc, _, _ = await run_ssh(
                        settings.proxy_host,
                        f"ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "
                        f"-o ConnectTimeout=5 -o BatchMode=yes master@{vlan_ip} hostname",
                        timeout=15,
                    )
                    if rc == 0:
                        ssh_ok = True
                        break

                if ssh_ok:
                    await out(task_id, "SSH-Verbindung erfolgreich!")
                else:
                    await out(task_id, "WARNUNG: SSH-Verbindung konnte nicht hergestellt werden. Bitte manuell prüfen.")
                await out(task_id, "")

            # 15. Fertigmeldung
            await out(task_id, f"=== VPS '{req.hostname}' ist bereit! ===")
            if req.setup_vlan:
                await out(task_id, f"  CloudVLAN-IP: {vlan_ip}")

        except Exception as e:
            await out(task_id, f"FEHLER: {e}")
            raise

    task_id = task_manager.create_task(
        "netcup_install",
        f"VPS-Installation Server {server_id}",
        coro_factory=do_install,
    )
    return TaskCreate(task_id=task_id)
