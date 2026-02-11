# VPS Management CLI

Management-Tool für Netcup VPS mit CloudVLAN. Läuft auf dem Proxy (10.10.0.1) und verwaltet alle VPS im internen Netzwerk.

## Ersteinrichtung

### 1. Proxy aufsetzen

Im Netcup SCP unter "Medien" > "VNC-Konsole" > "Befehl ausführen":
- Inhalt von `bootstrap-proxy.sh` einfügen und ausführen
- GitHub Device-Code Auth: Den angezeigten Code auf https://github.com/login/device eingeben
- Das Repo wird automatisch nach `/opt/vps` geklont

### 2. SSH-Key generieren

```bash
ssh master@<proxy-ip>
sudo bash /opt/vps/setup-proxy-key.sh
```

### 3. Neue VPS aufsetzen

**Option A: Automatisch über Netcup API** (empfohlen)
```bash
vps netcup login
vps netcup list                    # Server finden
vps netcup install <server-id>     # Interaktive Installation
```

Das installiert Debian 13, richtet CloudVLAN, Firewall, SSH und den `master`-User automatisch ein.

**Option B: Manuell über VNC-Konsole**
- `bootstrap-vps.sh` anpassen (`CLOUDVLAN_IP`, `HOSTNAME`) und in der VNC-Konsole ausführen

### 4. Loslegen

```bash
vps scan     # Netzwerk scannen, VPS finden
vps list     # Alle VPS anzeigen
vps help     # Alle Befehle
```

---

## Befehle

### VPS verwalten

```bash
vps scan                           # Netzwerk nach VPS scannen
vps list                           # Alle VPS anzeigen
vps status [host]                  # Updates, Reboot-Status, Load
vps update [host]                  # apt upgrade (einzeln oder alle)
vps reboot <host>                  # Neustart mit Bestätigung
vps exec <host> <cmd>              # Befehl auf VPS ausführen
vps ssh <host>                     # Interaktive SSH-Session
```

Kurzformen: `ls` = `list`, `st` = `status`, `up` = `update`

### Docker

```bash
vps docker install <host>          # Docker CE installieren
vps docker list [host]             # Container-Übersicht
vps docker start <host> <name>     # Container starten
vps docker stop <host> <name>      # Container stoppen
```

### Traefik Reverse Proxy

Traefik läuft auf dem Proxy und leitet HTTPS-Traffic über CloudVLAN an die VPS weiter. Let's Encrypt Zertifikate werden automatisch erstellt.

```bash
vps docker install proxy           # Docker auf Proxy
vps traefik setup                  # Traefik einrichten (interaktiv)
vps traefik status                 # Status anzeigen
vps traefik logs [lines]           # Logs anzeigen
vps traefik restart                # Neu starten
```

### Routes

Routes verbinden eine Domain mit einem Service auf einem VPS.

```bash
vps route add <domain> <host> <port>   # Route anlegen
vps route list                         # Alle Routes anzeigen
vps route remove <domain>              # Route entfernen
```

Voraussetzung: DNS muss auf die Public-IP des Proxy zeigen.

### Apps deployen

Templates für fertige Anwendungen. Docker und Traefik-Route werden automatisch eingerichtet.

```bash
vps deploy list                        # Verfügbare Templates
vps deploy <template> <host>           # App deployen (interaktiv)
vps deploy status <host>               # Deployments anzeigen
vps deploy remove <host> <app>         # Deployment entfernen
```

Verfügbare Templates:

| Template | Beschreibung |
|----------|-------------|
| `guacamole` | Remote Desktop Gateway (RDP, VNC, SSH im Browser) |
| `paperless-ngx` | Dokumenten-Management mit OCR und Volltextsuche |
| `uptime-kuma` | Monitoring-Dashboard für Websites und Services |

Beispiel:
```bash
vps deploy uptime-kuma webserver       # Fragt Domain ab, deployed alles
```

### Netcup API

VPS direkt über die Netcup SCP API verwalten und installieren.

```bash
vps netcup login                       # Login via Browser (Device Code)
vps netcup logout                      # Logout
vps netcup list [suche]                # Server auflisten
vps netcup info <server>               # Server-Details (ID, Name oder Hostname)
vps netcup install <server>            # VPS neu installieren (interaktiv)
```

### Backup

Alle Hosts werden mit [Restic](https://restic.net/) auf eine Hetzner Storage Box gesichert. Vor jedem Backup werden Datenbank-Dumps automatisch erstellt, sodass ein Restore immer einen konsistenten Stand liefert.

#### Backup einrichten

```bash
vps backup setup all                   # Proxy + alle VPS auf einen Schlag
vps backup setup webserver             # Einzelnen Host einrichten
```

Beim ersten Aufruf werden die Storage Box Zugangsdaten abgefragt. `setup` installiert Restic, deployt SSH-Keys, richtet systemd-Timer ein und führt ein Test-Backup aus.

#### Szenarien

**VPS komplett kaputt / neu aufsetzen**

```bash
vps netcup install <server-id>         # VPS neu installieren (oder bootstrap-vps.sh)
vps backup setup <host>                # Restic + Keys wieder deployen
vps backup list <host>                 # Snapshot auswählen
vps backup restore <host> <snapshot>   # Full Restore
```

Alle Docker-Container werden gestoppt, Dateien wiederhergestellt, DB-Dumps automatisch zurückgespielt und Services neu gestartet.

**Einzelnen Service wiederherstellen** (z.B. Paperless-DB korrupt)

```bash
vps backup restore <host> --service paperless
```

Stoppt den Service, stellt Dateien + Datenbank-Dump wieder her und startet neu. Funktioniert für: `paperless`, `guacamole`, `uptime-kuma`.

**Service auf älteren Stand zurückrollen**

```bash
vps backup list <host>                                    # Snapshots durchgehen
vps backup files <host> <snapshot-id>                     # Inhalt prüfen
vps backup restore <host> <snapshot-id> --service paperless   # Gezielt wiederherstellen
```

**Einzelne Datei/Verzeichnis wiederherstellen**

```bash
vps backup restore <host> latest --path /opt/traefik/conf.d/
```

Nützlich wenn z.B. eine Config versehentlich gelöscht wurde. Kann jeden beliebigen Pfad wiederherstellen.

**Backup-Status prüfen / Probleme erkennen**

```bash
vps backup status all                  # Timer aktiv? Letztes Backup erfolgreich?
vps backup check                       # Repository-Integrität prüfen
```

#### Kurzreferenz

| Befehl | Beschreibung |
|--------|-------------|
| `backup setup <host\|all>` | Restic installieren, Keys deployen, Timer einrichten |
| `backup run <host\|all>` | Backup sofort ausführen |
| `backup list [host]` | Snapshots anzeigen (optional nach Host filtern) |
| `backup files <host> [snapshot]` | Dateien in Snapshot auflisten (default: `latest`) |
| `backup status [host\|all]` | Timer-Status, letztes Backup, nächster Lauf |
| `backup restore <host> [snapshot]` | Ganzen VPS wiederherstellen |
| `backup restore ... --service <name>` | Nur einen Service (paperless, guacamole, uptime-kuma) |
| `backup restore ... --path <pfad>` | Nur einen Pfad wiederherstellen |
| `backup forget <host\|all>` | Alte Snapshots nach Retention-Policy aufräumen |
| `backup check` | Repository-Integrität prüfen |

#### Was gesichert wird

| Host | Pfade | Datenbank-Dumps |
|------|-------|-----------------|
| **Proxy** | Traefik-Config, `/etc/vps-hosts`, SSH-Keys, VPS-CLI Config | — |
| **VPS** | Alles unter `/opt/` (alle Services), SSH-Keys | PostgreSQL (Paperless, Guacamole), SQLite (Uptime Kuma) |

#### Automatik

- **Tägliches Backup** um 02:00 Uhr (±30 Min. Jitter) — verpasste Backups werden nachgeholt
- **Wöchentliches Aufräumen** am Sonntag um 04:00 Uhr
- **Retention:** 7 Tage, 4 Wochen, 6 Monate, 1 Jahr
- **Pre-Backup Hooks:** DB-Dumps werden vor jedem Backup in `/tmp/backups/` erstellt und danach aufgeräumt

---

## Netzwerk

```
Internet --> Proxy (10.10.0.1) --> CloudVLAN (10.10.0.0/24) --> VPS
                 |
            [Traefik]
            Port 80/443
            Let's Encrypt
```

- **Proxy:** 10.10.0.1 (öffentlich erreichbar)
- **VPS:** 10.10.0.2-254 (nur über CloudVLAN erreichbar)
- **User:** `master` mit sudo auf allen Systemen
