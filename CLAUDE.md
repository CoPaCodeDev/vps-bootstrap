# VPS Management Projekt

## Infrastruktur
- Proxy: 10.10.0.1
- VPS-Range: 10.10.0.2-254
- User `master` existiert bereits auf Proxy UND allen VPS
- SSH-Key ist bereits autorisiert
- Sudo ohne Passwort ist konfiguriert

## Dateien
- vps-cli.sh - Das CLI-Tool
- /etc/vps-hosts - Liste der VPS (auf dem Proxy)

## Netcup SCP REST API
- OpenAPI-Spec: docs/api/netcup-scp-openapi.json
- Base-URL: https://www.servercontrolpanel.de/scp-core
- Auth: OpenID Connect über /realms/scp/.well-known/openid-configuration
- SCP-Login = CCP-Kundennummer als Username
- Wichtige Endpunkte:
  - GET /api/v1/servers - Alle Server auflisten
  - GET /api/v1/servers/{serverId} - Server-Details (inkl. Live-Info)
  - PATCH /api/v1/servers/{serverId} - Server starten/stoppen/konfigurieren
- API-Konfiguration: /etc/vps-netcup (Token-Datei)

## Konventionen
- Bash-Scripts mit set -e
- Deutsche Benutzer-Ausgaben
