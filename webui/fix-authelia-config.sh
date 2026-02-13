#!/bin/bash
# Einmal-Fix für die fehlerhafte Authelia Cookie-Config
# Ausführen auf dem Proxy: bash /opt/vps/webui/fix-authelia-config.sh
set -e

CONFIG="/opt/authelia/config/configuration.yml"

if [[ ! -f "$CONFIG" ]]; then
    echo "Fehler: $CONFIG nicht gefunden"
    exit 1
fi

echo "Aktuelle Cookie-Config:"
grep -A 2 "domain:" "$CONFIG" | grep -v "^--$"
echo ""

# Backup
sudo cp "$CONFIG" "${CONFIG}.bak.$(date +%Y%m%d%H%M%S)"
echo "Backup erstellt."

# Fix: Für jede domain den authelia_url und default_redirection_url korrigieren
# Lese alle Cookie-Domains
domains=$(grep "^\s*- domain:" "$CONFIG" | sed "s/.*domain: '\(.*\)'/\1/")

for d in $domains; do
    echo "Fixe Domain: $d"
    # authelia_url -> https://auth.<domain>
    sudo sed -i "/domain: '${d}'/,/default_redirection_url:/ {
        s|authelia_url: '.*'|authelia_url: 'https://auth.${d}'|
        s|default_redirection_url: '.*'|default_redirection_url: 'https://${d}'|
    }" "$CONFIG"
done

echo ""
echo "Neue Cookie-Config:"
grep -A 2 "domain:" "$CONFIG" | grep -v "^--$"
echo ""

echo "Starte Authelia neu..."
cd /opt/authelia && docker compose restart

echo "Fertig!"
