# VPS Management Projekt

## Infrastruktur
- Proxy: 10.10.0.1
- VPS-Range: 10.10.0.2-254
- User `master` existiert bereits auf Proxy UND allen VPS
- SSH-Key ist bereits autorisiert
- Sudo ohne Passwort ist konfiguriert

## Dateien
- vps-cli.sh — Das CLI-Tool (~3500 Zeilen, alle Befehle)
- bootstrap-proxy.sh — Ersteinrichtung des Proxy
- bootstrap-vps.sh — Ersteinrichtung einzelner VPS
- setup-proxy-key.sh — SSH-Key Generator für den Proxy
- backup/ — Systemd Timer/Services und Backup-Script
- templates/ — App-Templates (guacamole, paperless-ngx, uptime-kuma, traefik)
- docs/api/ — Netcup SCP OpenAPI-Spec und API-Referenz
- /etc/vps-hosts — Liste der VPS (auf dem Proxy)

## Netcup SCP REST API
- OpenAPI-Spec: docs/api/netcup-scp-openapi.json
- VPS-Installation API-Referenz: docs/api/vps-install-api.md
- Base-URL: https://www.servercontrolpanel.de/scp-core
- Auth: Device Code Flow über Keycloak
  - Device-Endpoint: /realms/scp/protocol/openid-connect/auth/device
  - Token-Endpoint: /realms/scp/protocol/openid-connect/token
  - Revoke-Endpoint: /realms/scp/protocol/openid-connect/revoke
  - client_id=scp, scope=offline_access openid
- Access Token läuft nach 300s ab, Refresh Token nach 30 Tagen Inaktivität
- Token-Datei: ~/.config/vps-cli/netcup

## Konventionen
- Bash-Scripts mit set -e
- Deutsche Benutzer-Ausgaben
