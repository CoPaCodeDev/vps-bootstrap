# VPS Bootstrap & Management

Bootstrap-Scripts und Management-CLI für Netcup VPS mit CloudVLAN (Debian 13).

## Workflow

### 1. Proxy aufsetzen
```bash
# Bei Netcup im VPS-Panel ausführen:
curl -sL https://raw.githubusercontent.com/CoPaCodeDev/vps-bootstrap/main/bootstrap-proxy.sh | bash
```

### 2. SSH-Key generieren
```bash
# Per SSH auf den Proxy verbinden:
ssh master@<proxy-ip>

# Key generieren:
sudo bash setup-proxy-key.sh
```

### 3. Key in bootstrap-vps.sh eintragen
Den angezeigten Public Key in `bootstrap-vps.sh` bei `PROXY_PUBKEY` eintragen, dann committen und pushen.

### 4. Weitere VPS aufsetzen
```bash
# Bei Netcup im VPS-Panel:
curl -sL https://raw.githubusercontent.com/CoPaCodeDev/vps-bootstrap/main/bootstrap-vps.sh -o bootstrap.sh
nano bootstrap.sh  # CLOUDVLAN_IP und HOSTNAME setzen
bash bootstrap.sh
```

### 5. VPS-CLI einrichten (auf dem Proxy)
```bash
sudo cp vps-cli.sh /usr/local/bin/vps
sudo chmod +x /usr/local/bin/vps
vps scan  # Netzwerk nach VPS scannen
```

## VPS Management CLI

Nach dem Bootstrap kann das CLI-Tool vom Proxy aus alle VPS verwalten.

### Befehle

| Befehl | Beschreibung |
|--------|--------------|
| `vps scan` | Scannt das Netzwerk und aktualisiert `/etc/vps-hosts` |
| `vps list` | Zeigt alle konfigurierten VPS |
| `vps status [host]` | Zeigt Updates, Reboot-Status und Load |
| `vps update [host]` | Führt apt upgrade aus (einzeln oder alle) |
| `vps reboot <host>` | Startet VPS neu (mit Bestätigung) |
| `vps exec <host> <cmd>` | Führt Befehl auf VPS aus |
| `vps ssh <host>` | Öffnet interaktive SSH-Session |

### Beispiele

```bash
vps scan                    # Netzwerk scannen
vps list                    # Alle VPS anzeigen
vps status                  # Status aller VPS
vps status webserver        # Status eines VPS
vps update                  # Alle VPS aktualisieren
vps update database         # Einzelnen VPS aktualisieren
vps exec webserver "df -h"  # Befehl ausführen
vps ssh webserver           # SSH-Verbindung öffnen
```

## Scripts

| Script | Verwendung |
|--------|------------|
| `bootstrap-proxy.sh` | Für den Proxy-Server (öffentlich erreichbar, 10.10.0.1) |
| `bootstrap-vps.sh` | Für alle anderen VPS (nur intern erreichbar) |
| `setup-proxy-key.sh` | Generiert SSH-Key auf dem Proxy |
| `vps-cli.sh` | Management-CLI für den Proxy |

## Netzwerk

- **Proxy:** 10.10.0.1 (öffentlich erreichbar)
- **VPS:** 10.10.0.2-254 (nur über CloudVLAN)
- **User:** `master` (sudo ohne Passwort)

## Ergebnis
- User `master` hat sudo-Rechte auf allen Systemen
- CloudVLAN ist konfiguriert
- Firewall erlaubt nur Verbindungen aus dem CloudVLAN
- Proxy kann sich per SSH auf alle VPS verbinden
- Zentrale Verwaltung aller VPS über CLI
