# Plan: `vps install` — VPS über die Netcup API installieren

## Übersicht

Der Befehl `vps install <server> <hostname>` installiert eine VPS vollautomatisch
über die Netcup SCP REST API. Kein VNC oder manueller Schritt nötig.

## Eingaben

| Parameter | Quelle | Beschreibung |
|-----------|--------|-------------|
| Server | Argument | Server-ID, Name oder Hostname (aus `vps netcup list`) |
| Hostname | Argument | Wird als Hostname und Nickname gesetzt |
| Master-Passwort | Interaktive Abfrage (verdeckt) | Passwort für den `master`-User (min 8 Zeichen, Groß+Klein+Zahl) |

## Ablauf

### 1. Server identifizieren
- `GET /api/v1/servers` bzw. `GET /api/v1/servers/{serverId}`
- Öffentliche IP und Server-ID ermitteln
- Prüfen ob Server erreichbar ist (State: RUNNING oder SHUTOFF)

### 2. Debian 13 Image finden
- `GET /api/v1/servers/{serverId}/imageflavours`
- Automatisch das Debian 13 Image anhand des Namens auswählen
- Abbruch mit Fehlermeldung falls kein Debian 13 verfügbar

### 3. Disk ermitteln
- `GET /api/v1/servers/{serverId}/disks`
- Erste/größte Disk verwenden (typisch: `vda`)

### 4. Proxy SSH-Key sicherstellen
- `GET /api/v1/users/{userId}/ssh-keys` — prüfen ob Key bereits hochgeladen
- Falls nicht: Public Key vom Proxy lesen (`/home/master/.ssh/id_ed25519.pub`)
- `POST /api/v1/users/{userId}/ssh-keys` — Key hochladen
- Key-ID für die Installation merken

### 5. Nächste freie CloudVLAN-IP ermitteln
- `/etc/vps-hosts` lesen und bereits vergebene IPs sammeln
- Netzwerk-Scan (optional) für zusätzliche Sicherheit
- Nächste freie IP im Bereich 10.10.0.2-254 vergeben

### 6. Image installieren
- `POST /api/v1/servers/{serverId}/image`

```json
{
  "imageFlavourId": <debian-13-id>,
  "diskName": "vda",
  "rootPartitionFullDiskSize": true,
  "hostname": "<hostname>",
  "locale": "de_DE",
  "timezone": "Europe/Berlin",
  "additionalUserUsername": "master",
  "additionalUserPassword": "<eingegebenes-passwort>",
  "sshKeyIds": [<proxy-key-id>],
  "sshPasswordAuthentication": false,
  "customScript": "<post-install-script>",
  "emailToExecutingUser": false
}
```

### 7. Auf Fertigstellung warten
- TaskInfo UUID aus der Response
- Status pollen bis `state` = `FINISHED` oder `ERROR`
- Fortschritt anzeigen (Spinner/Statusmeldungen)

### 8. CloudVLAN-Interface anlegen
- `POST /api/v1/servers/{serverId}/interfaces`

```json
{
  "vlanId": <cloudvlan-id>,
  "networkDriver": "VIRTIO"
}
```

- Falls Interface bereits existiert, diesen Schritt überspringen

### 9. Hostname und Nickname setzen
- `PATCH /api/v1/servers/{serverId}` → `{"hostname": "<hostname>"}`
- `PATCH /api/v1/servers/{serverId}` → `{"nickname": "<hostname>"}`

### 10. In `/etc/vps-hosts` eintragen
- Neue Zeile: `10.10.0.X <hostname>`
- Eintrag nur hinzufügen wenn noch nicht vorhanden

### 11. Verbindung testen
- SSH-Verbindung über CloudVLAN testen: `ssh master@10.10.0.X hostname`
- Erfolgsmeldung oder Hinweis auf manuelle Prüfung

## Post-Install-Script (customScript)

Das Script wird bei der Image-Installation automatisch ausgeführt und richtet ein:

```bash
#!/bin/bash
set -e

# CloudVLAN-Interface konfigurieren
cat > /etc/network/interfaces.d/cloudvlan <<IFACE
auto ens1
iface ens1 inet static
    address 10.10.0.X/24
IFACE

ifup ens1 || true

# UFW installieren und konfigurieren
apt-get update -qq
apt-get install -y -qq ufw

ufw default deny incoming
ufw default allow outgoing
ufw allow from 10.10.0.0/24
ufw --force enable

# SSH-Key des Proxy für master-User einrichten
# (wird bereits über sshKeyIds bei der Installation gemacht)

# SSH Root-Login deaktivieren
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
systemctl restart sshd

# Sudo ohne Passwort für master
echo 'master ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/master
chmod 440 /etc/sudoers.d/master
```

**Hinweis:** Die CloudVLAN-IP (`10.10.0.X`) und das Interface (`ens1`) werden
dynamisch im Script eingesetzt bevor es an die API übergeben wird.

## Beispielaufruf

```
$ vps install myserver webshop
Netcup-Server: myserver (ID: 12345)
Öffentliche IP: 203.0.113.42

Passwort für User 'master': ********
Passwort bestätigen: ********

Image: Debian 13 (ID: 67)
Disk: vda (50 GiB, eine Partition)
CloudVLAN-IP: 10.10.0.5

Installation wird gestartet...
  ✓ SSH-Key hochgeladen
  ✓ Image-Installation gestartet
  ⠋ Warte auf Fertigstellung... (2:34)
  ✓ Image installiert
  ✓ CloudVLAN-Interface angelegt
  ✓ Hostname und Nickname gesetzt
  ✓ In /etc/vps-hosts eingetragen
  ✓ SSH-Verbindung über CloudVLAN erfolgreich

VPS 'webshop' ist bereit! (10.10.0.5)
```

## Offene Fragen

- **VLAN-ID**: Muss ermittelt werden — entweder aus bestehenden Server-Interfaces
  auslesen oder als Konfiguration hinterlegen.
- **Interface-Name**: `ens1` für CloudVLAN — muss geprüft werden ob das bei
  Debian 13 korrekt ist oder ob es z.B. `eth1` heißt.
- **userId für SSH-Keys**: Muss aus dem Token oder einem API-Call ermittelt werden.
