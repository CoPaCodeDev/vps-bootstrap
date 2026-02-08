# Analyse: Was fehlt noch für das erste Template?

## Ist-Zustand

### Was bereits funktioniert
- **SSH-Infrastruktur**: Proxy -> VPS Zugriff über `ssh_exec`, `ssh_exec_stdin`
- **Docker-Installation**: `vps docker install <host>`
- **Traefik Reverse Proxy**: Setup, Routen, TLS — alles funktionsfähig
- **Host-Auflösung**: Hostname -> IP über `/etc/vps-hosts`
- **Template-Verzeichnis**: `$VPS_HOME/templates/` existiert
- **Variable Substitution**: sed-basiert, funktioniert für Traefik

### Bestehendes Template-Muster (Traefik)
```
templates/traefik/
├── docker-compose.yml      # ${DASHBOARD_DOMAIN}, ${DASHBOARD_AUTH}
├── traefik.yml             # ${ACME_EMAIL}
├── route.yml.template      # {{NAME}}, {{DOMAIN}}, {{HOST_IP}}, {{PORT}}
└── conf.d/.gitkeep
```

Der Traefik-Setup-Flow:
1. Interaktive Abfrage der Parameter (E-Mail, Domain, Credentials)
2. Template-Dateien kopieren mit sed-Substitution
3. Verzeichnisse auf Ziel erstellen
4. `docker compose up -d`

---

## Was fehlt

### 1. CLI-Befehl: `vps deploy`

Es gibt keinen generischen Befehl zum Deployen von Anwendungen. Benötigt wird:

```
vps deploy <template> <host> [optionen]
vps deploy list                    # Verfügbare Templates anzeigen
vps deploy status <host>           # Deployments auf einem Host anzeigen
vps deploy remove <host> <app>     # Deployment entfernen
```

Aktuell müsste man für jede Anwendung eine eigene Funktion wie `cmd_traefik_setup` schreiben — das skaliert nicht.

### 2. Template-Format / Struktur

Es gibt kein standardisiertes Format für App-Templates. Vorschlag:

```
templates/<app-name>/
├── template.conf           # Metadaten + Variablen-Definition
├── docker-compose.yml      # Haupt-Compose-Datei (mit Variablen)
└── config/                 # Optionale weitere Konfig-Dateien
    └── *.template
```

**`template.conf`** — fehlt komplett, wird benötigt:
```bash
# Template-Metadaten
NAME="Guacamole"
DESCRIPTION="Apache Guacamole Remote Desktop Gateway"
DEPLOY_DIR="/opt/guacamole"          # Wo auf dem Ziel deployed wird

# Benötigte Variablen (Name|Beschreibung|Default|Typ)
VARS=(
    "DOMAIN|Domain für den Zugriff||required"
    "DB_PASSWORD|Datenbank-Passwort||secret"
    "GUACD_PORT|Guacamole Daemon Port|4822|optional"
)

# Voraussetzungen
REQUIRES_DOCKER=true
REQUIRES_ROUTE=true                  # Automatisch Traefik-Route anlegen
ROUTE_PORT=8080                      # Interner Port für die Route
```

### 3. Generische Deploy-Funktion

Eine Funktion, die für jedes Template:
1. `template.conf` liest und validiert
2. Variablen interaktiv abfragt (oder aus Argumenten nimmt)
3. Prüft, ob Docker auf dem Ziel installiert ist
4. Template-Dateien mit Variablen substituiert
5. Dateien auf das Ziel kopiert (via SSH)
6. `docker compose up -d` auf dem Ziel ausführt
7. Optional eine Traefik-Route anlegt

### 4. Datei-Transfer zum VPS

Aktuell fehlt eine Funktion, um Dateien auf einen beliebigen VPS zu schreiben. `proxy_write` funktioniert nur für den Proxy. Benötigt:

```bash
# Datei auf beliebigen Host schreiben (von stdin)
host_write() {
    local ip="$1"
    local dest="$2"
    ssh $SSH_OPTS "${SSH_USER}@${ip}" "sudo tee $dest > /dev/null"
}

# Verzeichnis auf Host erstellen
host_mkdir() {
    local ip="$1"
    local dir="$2"
    ssh_exec "$ip" "sudo mkdir -p $dir && sudo chown ${SSH_USER}:${SSH_USER} $dir"
}
```

### 5. Variablen-Substitution vereinheitlichen

Aktuell werden zwei Formate gemischt:
- `${VAR}` in Traefik-Configs
- `{{VAR}}` in Route-Templates

Sollte auf ein Format vereinheitlicht werden. Vorschlag: `{{VAR}}` — kollidiert nicht mit Docker Compose `${VAR}` Syntax und Shell-Variablen.

---

## Minimaler Scope für das erste Template

Für ein erstes funktionsfähiges Template (z.B. Guacamole) reicht:

| Komponente | Status | Aufwand |
|-----------|--------|---------|
| `template.conf` Format definieren | fehlt | klein |
| `host_write` / `host_mkdir` Funktionen | fehlt | klein |
| `cmd_deploy` Basis-Funktion | fehlt | mittel |
| Variablen-Abfrage (interaktiv) | fehlt | klein |
| Template-Substitution (`{{VAR}}` -> Wert) | existiert teilweise | klein |
| Docker-Prüfung auf Ziel | existiert (`docker list`) | - |
| Traefik-Route anlegen | existiert (`route add`) | - |
| Erstes Template erstellen | fehlt | mittel |

### Reihenfolge der Umsetzung

1. **`host_write` + `host_mkdir`** — Basisfunktionen für Datei-Transfer
2. **`template.conf` Format** — Metadaten und Variablen-Definition festlegen
3. **`cmd_deploy`** — Template lesen, Variablen abfragen, deployen
4. **Erstes Template** — z.B. Guacamole oder eine einfachere App zum Testen
5. **`deploy list`** — Verfügbare Templates auflisten

### Was wir NICHT brauchen für V1

- Kein Template-Versioning oder Rollback
- Keine Template-Komposition/Vererbung
- Kein Secret-Management (Passwörter direkt in docker-compose.yml reicht erstmal)
- Keine Deployment-State-Datenbank
- Kein Update-Mechanismus

---

## Entscheidungen die noch offen sind

1. **Variablen-Format**: `{{VAR}}` verwenden? (Empfehlung: ja)
2. **Deploy-Verzeichnis**: Immer `/opt/<app-name>` oder pro Template konfigurierbar?
3. **Automatische Route**: Soll `deploy` automatisch `route add` aufrufen wenn `REQUIRES_ROUTE=true`?
4. **Docker-Auto-Install**: Soll `deploy` Docker automatisch installieren wenn es fehlt?
