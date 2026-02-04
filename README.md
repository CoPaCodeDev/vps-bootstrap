# VPS Bootstrap & Management

Bootstrap-Scripts und Management-CLI für Netcup VPS mit CloudVLAN (Debian 13).

## Workflow

### 1. Proxy aufsetzen
Im Netcup SCP (Server Control Panel) unter "Medien" → "VNC-Konsole" → "Befehl ausführen":
- Inhalt von `bootstrap-proxy.sh` ins Textfeld einfügen
- Ausführen
- **GitHub Device-Code Auth:** Wenn der Code angezeigt wird, auf dem Handy/PC https://github.com/login/device öffnen und den Code eingeben
- Das Repository wird automatisch geklont und die VPS-CLI eingerichtet

### 2. SSH-Key generieren
```bash
# Per SSH auf den Proxy verbinden:
ssh master@<proxy-ip>

# Key generieren:
sudo bash /opt/vps/setup-proxy-key.sh
```

### 3. Key in bootstrap-vps.sh eintragen
Den angezeigten Public Key in `bootstrap-vps.sh` bei `PROXY_PUBKEY` eintragen.

### 4. Weitere VPS aufsetzen
Im Netcup SCP unter "Medien" → "VNC-Konsole" → "Befehl ausführen":
- Inhalt von `bootstrap-vps.sh` ins Textfeld einfügen
- **Vorher anpassen:** `CLOUDVLAN_IP` und `HOSTNAME` im Script setzen
- Ausführen

### 5. VPS-CLI nutzen
```bash
# Auf dem Proxy:
vps scan  # Netzwerk nach VPS scannen
vps list  # Alle VPS anzeigen
vps help  # Alle Befehle anzeigen
```

### Verzeichnisstruktur VPS-CLI
```
/opt/vps/
├── vps-cli.sh              # CLI-Skript
└── templates/
    └── traefik/            # Traefik-Templates
        ├── docker-compose.yml
        ├── traefik.yml
        └── route.yml.template

/usr/local/bin/vps → /opt/vps/vps-cli.sh (Symlink)
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
| `vps docker <host>` | Installiert Docker auf einem Host |
| `vps traefik <cmd>` | Traefik-Verwaltung (siehe unten) |
| `vps route <cmd>` | Route-Verwaltung (siehe unten) |

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

| Script | Verwendung | Ziel auf Proxy |
|--------|------------|----------------|
| `bootstrap-proxy.sh` | Für den Proxy-Server (öffentlich erreichbar, 10.10.0.1) | - |
| `bootstrap-vps.sh` | Für alle anderen VPS (nur intern erreichbar) | - |
| `setup-proxy-key.sh` | Generiert SSH-Key auf dem Proxy | - |
| `vps-cli.sh` | Management-CLI | `/opt/vps/vps-cli.sh` |
| `templates/` | Konfigurations-Templates | `/opt/vps/templates/` |

## Traefik Reverse Proxy

Traefik ermöglicht den Zugriff auf interne Services über HTTPS mit automatischen Let's Encrypt Zertifikaten.

### Setup

```bash
# 1. Docker auf Proxy installieren
vps docker proxy

# 2. Traefik einrichten (E-Mail für Let's Encrypt angeben)
vps traefik setup admin@example.com

# 3. DNS beim Provider konfigurieren
# subdomain.example.com → Public-IP des Proxy

# 4. Route hinzufügen
vps route add subdomain.example.com webserver 8080
```

### Route-Befehle

| Befehl | Beschreibung |
|--------|--------------|
| `vps route add <domain> <host> <port>` | Neue Route erstellen |
| `vps route list` | Alle Routes anzeigen |
| `vps route remove <domain>` | Route entfernen |

### Traefik-Befehle

| Befehl | Beschreibung |
|--------|--------------|
| `vps traefik setup <email>` | Traefik einrichten |
| `vps traefik status` | Container-Status anzeigen |
| `vps traefik logs [lines]` | Logs anzeigen |
| `vps traefik restart` | Traefik neu starten |

### Architektur

```
Internet → Proxy (10.10.0.1) → CloudVLAN → VPS-Services
              │
         [Traefik]
         Port 80/443
         Let's Encrypt
         File-Provider
```

### Verzeichnisstruktur auf dem Proxy

```
/opt/traefik/
├── docker-compose.yml      # Traefik Container
├── traefik.yml             # Statische Config
├── acme.json               # SSL-Zertifikate
└── conf.d/                 # Dynamische Routes
    └── subdomain.example.com.yml
```

## Netzwerk

- **Proxy:** 10.10.0.1 (öffentlich erreichbar)
- **VPS:** 10.10.0.2-254 (nur über CloudVLAN)
- **User:** `master` (sudo ohne Passwort)

## Konfigurationspfade

| Pfad | Beschreibung |
|------|--------------|
| `/opt/vps/` | VPS-CLI Installation |
| `/opt/traefik/` | Traefik-Konfiguration |
| `/etc/vps-hosts` | Liste der VPS |
| `/usr/local/bin/vps` | Symlink zum CLI |

## Ergebnis
- User `master` hat sudo-Rechte auf allen Systemen
- CloudVLAN ist konfiguriert
- Firewall erlaubt nur Verbindungen aus dem CloudVLAN
- Proxy kann sich per SSH auf alle VPS verbinden
- Zentrale Verwaltung aller VPS über CLI
