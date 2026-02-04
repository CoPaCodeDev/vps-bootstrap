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

## Konventionen
- Bash-Scripts mit set -e
- Deutsche Benutzer-Ausgaben
