#!/bin/bash
#
# VPS Management CLI
# Verwaltung von VPS im CloudVLAN über SSH vom Proxy aus
#

set -e

# Konfiguration
HOSTS_FILE="/etc/vps-hosts"
SSH_USER="master"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes"
NETWORK_PREFIX="10.10.0"
SCAN_RANGE_START=2
SCAN_RANGE_END=254
PROXY_IP="10.10.0.1"
TRAEFIK_DIR="/opt/traefik"
VPS_HOME="/opt/vps"
TEMPLATES_DIR="${VPS_HOME}/templates"

# Netcup SCP API Konfiguration
NETCUP_CONFIG="${HOME}/.config/vps-cli/netcup"
NETCUP_API_BASE="https://www.servercontrolpanel.de/scp-core"
NETCUP_TOKEN_URL="https://www.servercontrolpanel.de/realms/scp/protocol/openid-connect/token"
NETCUP_DEVICE_URL="https://www.servercontrolpanel.de/realms/scp/protocol/openid-connect/auth/device"
NETCUP_REVOKE_URL="https://www.servercontrolpanel.de/realms/scp/protocol/openid-connect/revoke"
NETCUP_CLIENT_ID="scp"

# Farben für Ausgabe
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Hilfsfunktionen
print_error() {
    echo -e "${RED}Fehler: $1${NC}" >&2
}

print_success() {
    echo -e "${GREEN}$1${NC}"
}

print_warning() {
    echo -e "${YELLOW}$1${NC}"
}

# Prüft ob Hosts-Datei existiert
check_hosts_file() {
    if [[ ! -f "$HOSTS_FILE" ]]; then
        print_error "Hosts-Datei $HOSTS_FILE nicht gefunden. Führe zuerst 'vps scan' aus."
        exit 1
    fi
}

# Liest Hosts aus Konfigurationsdatei
# Gibt zurück: IP HOSTNAME pro Zeile
get_hosts() {
    check_hosts_file
    grep -v '^#' "$HOSTS_FILE" | grep -v '^$' | awk '{print $1, $2}'
}

# Findet IP zu Hostname oder gibt IP zurück wenn bereits IP
resolve_host() {
    local input="$1"

    # Prüfe ob es bereits eine IP ist
    if [[ "$input" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "$input"
        return 0
    fi

    # Spezieller Alias: "proxy" -> PROXY_IP
    if [[ "$input" == "proxy" ]]; then
        echo "$PROXY_IP"
        return 0
    fi

    # Suche in Hosts-Datei
    check_hosts_file
    local ip=$(grep -v '^#' "$HOSTS_FILE" | awk -v host="$input" '$2 == host {print $1; exit}')

    if [[ -z "$ip" ]]; then
        print_error "Host '$input' nicht gefunden in $HOSTS_FILE"
        exit 1
    fi

    echo "$ip"
}

# Prüft ob wir auf dem Proxy sind
is_local_proxy() {
    local ip="$1"
    [[ "$ip" == "$PROXY_IP" ]] && ip addr show | grep -q "$PROXY_IP"
}

# SSH-Befehl auf Host ausführen (oder lokal wenn Proxy)
ssh_exec() {
    local ip="$1"
    shift
    if is_local_proxy "$ip"; then
        # Lokale Ausführung auf dem Proxy
        bash -c "$*"
    else
        ssh $SSH_OPTS "${SSH_USER}@${ip}" "$@"
    fi
}

# SSH-Befehl mit stdin (für Heredocs)
ssh_exec_stdin() {
    local ip="$1"
    if is_local_proxy "$ip"; then
        bash -s
    else
        ssh $SSH_OPTS "${SSH_USER}@${ip}" 'bash -s'
    fi
}

# Befehl auf Proxy ausführen (lokal oder via SSH)
proxy_exec() {
    if is_local_proxy "$PROXY_IP"; then
        bash -c "$*"
    else
        ssh $SSH_OPTS "${SSH_USER}@${PROXY_IP}" "$@"
    fi
}

# Datei auf Proxy schreiben (von stdin)
proxy_write() {
    local dest="$1"
    if is_local_proxy "$PROXY_IP"; then
        sudo tee "$dest" > /dev/null
    else
        ssh $SSH_OPTS "${SSH_USER}@${PROXY_IP}" "sudo tee $dest > /dev/null"
    fi
}

# === SCAN ===
cmd_scan() {
    echo "Scanne Netzwerk ${NETWORK_PREFIX}.${SCAN_RANGE_START}-${SCAN_RANGE_END}..."

    local temp_file=$(mktemp)
    local count=0

    # Paralleler Scan mit Background-Jobs
    for i in $(seq $SCAN_RANGE_START $SCAN_RANGE_END); do
        (
            ip="${NETWORK_PREFIX}.${i}"
            # Schneller Ping-Test
            if ping -c 1 -W 1 "$ip" &>/dev/null; then
                # SSH-Verbindungstest und Hostname abfragen
                hostname=$(ssh $SSH_OPTS "${SSH_USER}@${ip}" "hostname" 2>/dev/null)
                if [[ -n "$hostname" ]]; then
                    echo "$ip $hostname"
                fi
            fi
        ) >> "$temp_file" &

        # Begrenze parallele Jobs
        if (( $(jobs -r | wc -l) >= 50 )); then
            wait -n
        fi
    done

    # Warte auf alle Jobs
    wait

    # Sortiere Ergebnisse nach IP
    sort -t. -k4 -n "$temp_file" > "${temp_file}.sorted"

    # Schreibe Hosts-Datei
    {
        echo "# VPS Hosts - generiert am $(date '+%Y-%m-%d %H:%M:%S')"
        echo "# IP          Hostname"
        cat "${temp_file}.sorted"
    } | sudo tee "$HOSTS_FILE" > /dev/null

    count=$(wc -l < "${temp_file}.sorted")
    rm -f "$temp_file" "${temp_file}.sorted"

    print_success "Scan abgeschlossen. $count VPS gefunden."
    echo "Hosts gespeichert in $HOSTS_FILE"
}

# === LIST ===
cmd_list() {
    check_hosts_file
    echo "Konfigurierte VPS:"
    echo ""
    printf "%-15s %s\n" "IP" "HOSTNAME"
    printf "%-15s %s\n" "---------------" "---------------"

    while read -r ip hostname; do
        [[ -z "$ip" ]] && continue
        printf "%-15s %s\n" "$ip" "$hostname"
    done < <(get_hosts)
}

# === STATUS ===
get_status_for_host() {
    local ip="$1"
    local hostname="$2"

    # Hole Status-Informationen parallel
    local updates reboot load

    updates=$(ssh_exec "$ip" "apt list --upgradable 2>/dev/null | grep -c upgradable; true" 2>/dev/null || echo "?")
    reboot=$(ssh_exec "$ip" "[ -f /var/run/reboot-required ] && echo 'ja' || echo 'nein'" 2>/dev/null || echo "?")
    load=$(ssh_exec "$ip" "uptime | awk -F'load average:' '{print \$2}' | awk -F, '{print \$1}' | tr -d ' '" 2>/dev/null || echo "?")

    printf "%-15s %-15s %-10s %-10s %s\n" "$hostname" "$ip" "$updates" "$reboot" "$load"
}

cmd_status() {
    local target="$1"

    printf "%-15s %-15s %-10s %-10s %s\n" "VPS" "IP" "Updates" "Reboot" "Load"
    printf "%-15s %-15s %-10s %-10s %s\n" "---------------" "---------------" "----------" "----------" "----------"

    if [[ -n "$target" ]]; then
        # Status für einzelnen Host
        local ip=$(resolve_host "$target")
        local hostname=$(grep -v '^#' "$HOSTS_FILE" | awk -v ip="$ip" '$1 == ip {print $2}')
        [[ -z "$hostname" ]] && hostname="$target"
        get_status_for_host "$ip" "$hostname"
    else
        # Status für alle Hosts (parallel)
        local pids=()
        local temp_dir=$(mktemp -d)

        while read -r ip hostname; do
            [[ -z "$ip" ]] && continue
            (
                get_status_for_host "$ip" "$hostname"
            ) > "$temp_dir/$ip" &
            pids+=($!)
        done < <(get_hosts)

        # Warte auf alle Jobs und zeige Ergebnisse
        for pid in "${pids[@]}"; do
            wait "$pid"
        done

        # Ausgabe in IP-Reihenfolge
        while read -r ip hostname; do
            [[ -z "$ip" ]] && continue
            [[ -f "$temp_dir/$ip" ]] && cat "$temp_dir/$ip"
        done < <(get_hosts)

        rm -rf "$temp_dir"
    fi
}

# === UPDATE ===
cmd_update() {
    local target="$1"

    run_update() {
        local ip="$1"
        local hostname="$2"
        echo "=== Update auf $hostname ($ip) ==="
        ssh_exec "$ip" "sudo apt update && sudo apt upgrade -y"
        echo ""
    }

    if [[ -n "$target" ]]; then
        local ip=$(resolve_host "$target")
        local hostname=$(grep -v '^#' "$HOSTS_FILE" | awk -v ip="$ip" '$1 == ip {print $2}')
        [[ -z "$hostname" ]] && hostname="$target"
        run_update "$ip" "$hostname"
    else
        # Alle Hosts aktualisieren
        while read -r ip hostname; do
            [[ -z "$ip" ]] && continue
            run_update "$ip" "$hostname"
        done < <(get_hosts)
    fi

    print_success "Update abgeschlossen."
}

# === REBOOT ===
cmd_reboot() {
    local target="$1"

    if [[ -z "$target" ]]; then
        print_error "Bitte Host angeben: vps reboot <host>"
        exit 1
    fi

    local ip=$(resolve_host "$target")
    local hostname=$(grep -v '^#' "$HOSTS_FILE" | awk -v ip="$ip" '$1 == ip {print $2}')
    [[ -z "$hostname" ]] && hostname="$target"

    print_warning "WARNUNG: $hostname ($ip) wird neu gestartet!"
    read -p "Fortfahren? [j/N] " confirm

    if [[ "$confirm" =~ ^[jJyY]$ ]]; then
        echo "Starte $hostname neu..."
        ssh_exec "$ip" "sudo reboot" || true
        print_success "Reboot-Befehl gesendet."
    else
        echo "Abgebrochen."
    fi
}

# === EXEC ===
cmd_exec() {
    local target="$1"
    shift
    local cmd="$*"

    if [[ -z "$target" ]] || [[ -z "$cmd" ]]; then
        print_error "Verwendung: vps exec <host> <befehl>"
        exit 1
    fi

    local ip=$(resolve_host "$target")
    ssh_exec "$ip" "$cmd"
}

# === SSH ===
cmd_ssh() {
    local target="$1"

    if [[ -z "$target" ]]; then
        print_error "Bitte Host angeben: vps ssh <host>"
        exit 1
    fi

    local ip=$(resolve_host "$target")
    echo "Verbinde zu $target ($ip)..."
    ssh -o StrictHostKeyChecking=no "${SSH_USER}@${ip}"
}

# === DOCKER ===
cmd_docker() {
    local target="$1"

    if [[ -z "$target" ]]; then
        print_error "Bitte Host angeben: vps docker <host>"
        exit 1
    fi

    local ip=$(resolve_host "$target")
    echo "Installiere Docker auf $target ($ip)..."

    # Docker-Installationsskript
    ssh_exec_stdin "$ip" << 'DOCKER_SCRIPT'
set -e

# Prüfe ob Docker bereits installiert ist
if command -v docker &>/dev/null; then
    echo "Docker ist bereits installiert:"
    docker --version
    exit 0
fi

echo "Installiere Docker CE..."

# Alte Versionen entfernen
sudo apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true

# Abhängigkeiten installieren
sudo apt-get update
sudo apt-get install -y \
    ca-certificates \
    curl \
    gnupg \
    lsb-release

# Docker GPG-Key hinzufügen
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

# Repository hinzufügen
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# Docker installieren
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# User zur docker-Gruppe hinzufügen
sudo usermod -aG docker $USER

# Docker starten
sudo systemctl enable docker
sudo systemctl start docker

echo "Docker installiert:"
docker --version
docker compose version
DOCKER_SCRIPT

    print_success "Docker-Installation auf $target abgeschlossen."
    print_warning "Hinweis: Bei der ersten Nutzung muss sich der User neu einloggen (docker-Gruppe)."
}

# === TRAEFIK ===
cmd_traefik() {
    local subcmd="$1"
    shift 2>/dev/null || true

    case "$subcmd" in
        setup)
            cmd_traefik_setup "$@"
            ;;
        status)
            cmd_traefik_status
            ;;
        logs)
            cmd_traefik_logs "$@"
            ;;
        restart)
            cmd_traefik_restart
            ;;
        *)
            print_error "Unbekannter Traefik-Befehl: $subcmd"
            echo "Verwendung: vps traefik <setup|status|logs|restart>"
            exit 1
            ;;
    esac
}

cmd_traefik_setup() {
    local email="$1"

    if [[ -z "$email" ]]; then
        print_error "Bitte E-Mail-Adresse für Let's Encrypt angeben: vps traefik setup <email>"
        exit 1
    fi

    echo "Richte Traefik auf Proxy ($PROXY_IP) ein..."

    # Prüfe ob Docker installiert ist
    if ! proxy_exec "command -v docker" &>/dev/null; then
        print_error "Docker ist nicht installiert. Führe zuerst 'vps docker proxy' aus."
        exit 1
    fi

    # Erstelle Verzeichnisstruktur
    echo "Erstelle Verzeichnisstruktur..."
    proxy_exec "sudo mkdir -p ${TRAEFIK_DIR}/conf.d"

    # Kopiere Konfigurationsdateien
    echo "Kopiere Konfigurationsdateien..."

    # docker-compose.yml
    cat "${TEMPLATES_DIR}/traefik/docker-compose.yml" | proxy_write "${TRAEFIK_DIR}/docker-compose.yml"

    # traefik.yml mit E-Mail-Adresse
    sed "s/\${ACME_EMAIL}/${email}/" "${TEMPLATES_DIR}/traefik/traefik.yml" | proxy_write "${TRAEFIK_DIR}/traefik.yml"

    # Erstelle acme.json mit korrekten Berechtigungen
    proxy_exec "sudo touch ${TRAEFIK_DIR}/acme.json && sudo chmod 600 ${TRAEFIK_DIR}/acme.json"

    # Setze Berechtigungen
    proxy_exec "sudo chown -R ${SSH_USER}:${SSH_USER} ${TRAEFIK_DIR}"

    # Starte Traefik
    echo "Starte Traefik..."
    proxy_exec "cd ${TRAEFIK_DIR} && docker compose up -d"

    print_success "Traefik erfolgreich eingerichtet!"
    echo ""
    echo "Nächste Schritte:"
    echo "  1. DNS-Eintrag für Domain auf Proxy-Public-IP setzen"
    echo "  2. Route hinzufügen: vps route add <domain> <host> <port>"
}

cmd_traefik_status() {
    echo "Traefik-Status auf Proxy ($PROXY_IP):"
    proxy_exec "cd ${TRAEFIK_DIR} && docker compose ps" 2>/dev/null || print_error "Traefik ist nicht installiert."
}

cmd_traefik_logs() {
    local lines="${1:-50}"
    proxy_exec "cd ${TRAEFIK_DIR} && docker compose logs --tail=${lines}"
}

cmd_traefik_restart() {
    echo "Starte Traefik neu..."
    proxy_exec "cd ${TRAEFIK_DIR} && docker compose restart"
    print_success "Traefik neu gestartet."
}

# === ROUTE ===
cmd_route() {
    local subcmd="$1"
    shift 2>/dev/null || true

    case "$subcmd" in
        add)
            cmd_route_add "$@"
            ;;
        list|ls)
            cmd_route_list
            ;;
        remove|rm)
            cmd_route_remove "$@"
            ;;
        *)
            print_error "Unbekannter Route-Befehl: $subcmd"
            echo "Verwendung: vps route <add|list|remove>"
            exit 1
            ;;
    esac
}

cmd_route_add() {
    local domain="$1"
    local host="$2"
    local port="$3"

    if [[ -z "$domain" ]] || [[ -z "$host" ]] || [[ -z "$port" ]]; then
        print_error "Verwendung: vps route add <domain> <host> <port>"
        echo "Beispiel: vps route add app.example.com webserver 8080"
        exit 1
    fi

    # Validiere Port
    if ! [[ "$port" =~ ^[0-9]+$ ]] || [[ "$port" -lt 1 ]] || [[ "$port" -gt 65535 ]]; then
        print_error "Ungültiger Port: $port"
        exit 1
    fi

    # Löse Host zu IP auf
    local host_ip=$(resolve_host "$host")

    # Generiere einen sicheren Namen aus der Domain
    local name=$(echo "$domain" | sed 's/[^a-zA-Z0-9]/-/g' | tr '[:upper:]' '[:lower:]')

    echo "Erstelle Route: $domain -> $host ($host_ip):$port"

    # Erstelle Route-Konfiguration aus Template
    local route_config=$(cat "${TEMPLATES_DIR}/traefik/route.yml.template" | \
        sed "s/{{NAME}}/${name}/g" | \
        sed "s/{{DOMAIN}}/${domain}/g" | \
        sed "s/{{HOST_IP}}/${host_ip}/g" | \
        sed "s/{{PORT}}/${port}/g")

    # Schreibe Konfiguration auf Proxy
    echo "$route_config" | proxy_write "${TRAEFIK_DIR}/conf.d/${domain}.yml"

    print_success "Route hinzugefügt: $domain -> $host_ip:$port"
    echo ""
    echo "Hinweis: Stelle sicher, dass der DNS-Eintrag für $domain auf die Public-IP des Proxy zeigt."
}

cmd_route_list() {
    echo "Konfigurierte Routes:"
    echo ""
    printf "%-35s %-20s %s\n" "DOMAIN" "ZIEL" "DATEI"
    printf "%-35s %-20s %s\n" "-----------------------------------" "--------------------" "--------------------"

    # Liste alle .yml Dateien im conf.d Verzeichnis
    local routes=$(proxy_exec "ls -1 ${TRAEFIK_DIR}/conf.d/*.yml 2>/dev/null" || true)

    if [[ -z "$routes" ]]; then
        echo "Keine Routes konfiguriert."
        return
    fi

    for route_file in $routes; do
        # Extrahiere Informationen aus der Route-Datei
        local filename=$(basename "$route_file")
        local domain=$(echo "$filename" | sed 's/\.yml$//')

        # Extrahiere URL aus der Datei
        local target=$(proxy_exec "grep -oP 'url: \"http://\K[^\"]+' ${route_file} 2>/dev/null" || echo "?")

        printf "%-35s %-20s %s\n" "$domain" "$target" "$filename"
    done
}

cmd_route_remove() {
    local domain="$1"

    if [[ -z "$domain" ]]; then
        print_error "Bitte Domain angeben: vps route remove <domain>"
        exit 1
    fi

    local route_file="${TRAEFIK_DIR}/conf.d/${domain}.yml"

    # Prüfe ob Route existiert
    if ! proxy_exec "test -f ${route_file}"; then
        print_error "Route für '$domain' nicht gefunden."
        exit 1
    fi

    print_warning "Route für $domain wird entfernt."
    read -p "Fortfahren? [j/N] " confirm

    if [[ "$confirm" =~ ^[jJyY]$ ]]; then
        proxy_exec "sudo rm -f ${route_file}"
        print_success "Route entfernt: $domain"
    else
        echo "Abgebrochen."
    fi
}

# === NETCUP API ===

# Stellt sicher, dass die Konfigurationsdatei existiert
netcup_ensure_config_dir() {
    local config_dir
    config_dir="$(dirname "$NETCUP_CONFIG")"
    if [[ ! -d "$config_dir" ]]; then
        mkdir -p "$config_dir"
        chmod 700 "$config_dir"
    fi
}

# Speichert Token-Daten in die Konfigurationsdatei
netcup_save_tokens() {
    local access_token="$1"
    local refresh_token="$2"
    netcup_ensure_config_dir
    cat > "$NETCUP_CONFIG" << EOF
NETCUP_ACCESS_TOKEN=${access_token}
NETCUP_REFRESH_TOKEN=${refresh_token}
EOF
    chmod 600 "$NETCUP_CONFIG"
}

# Lädt Token-Daten aus der Konfigurationsdatei
netcup_load_tokens() {
    if [[ ! -f "$NETCUP_CONFIG" ]]; then
        print_error "Nicht eingeloggt. Führe zuerst 'vps netcup login' aus."
        exit 1
    fi
    source "$NETCUP_CONFIG"
}

# Erneuert den Access-Token mit dem Refresh-Token
netcup_refresh_token() {
    local response
    response=$(curl -s -X POST "$NETCUP_TOKEN_URL" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "client_id=${NETCUP_CLIENT_ID}" \
        -d "grant_type=refresh_token" \
        -d "refresh_token=${NETCUP_REFRESH_TOKEN}")

    local access_token refresh_token error
    error=$(echo "$response" | jq -r '.error // empty')

    if [[ -n "$error" ]]; then
        local error_desc
        error_desc=$(echo "$response" | jq -r '.error_description // empty')
        print_error "Token-Erneuerung fehlgeschlagen: ${error_desc:-$error}"
        print_warning "Bitte erneut einloggen mit 'vps netcup login'."
        exit 1
    fi

    access_token=$(echo "$response" | jq -r '.access_token')
    refresh_token=$(echo "$response" | jq -r '.refresh_token')

    if [[ -z "$access_token" || "$access_token" == "null" ]]; then
        print_error "Token-Erneuerung fehlgeschlagen. Bitte erneut einloggen mit 'vps netcup login'."
        exit 1
    fi

    NETCUP_ACCESS_TOKEN="$access_token"
    NETCUP_REFRESH_TOKEN="$refresh_token"
    netcup_save_tokens "$access_token" "$refresh_token"
}

# Führt einen API-Aufruf aus (mit automatischem Token-Refresh bei 401)
netcup_api() {
    local method="$1"
    local endpoint="$2"
    shift 2
    local extra_args=("$@")

    netcup_load_tokens

    local response http_code
    response=$(curl -s -w "\n%{http_code}" -X "$method" \
        "${NETCUP_API_BASE}${endpoint}" \
        -H "Authorization: Bearer ${NETCUP_ACCESS_TOKEN}" \
        -H "Accept: application/json" \
        "${extra_args[@]}")

    http_code=$(echo "$response" | tail -1)
    local body
    body=$(echo "$response" | sed '$d')

    # Bei 401: Token erneuern und nochmal versuchen
    if [[ "$http_code" == "401" ]]; then
        netcup_refresh_token
        response=$(curl -s -w "\n%{http_code}" -X "$method" \
            "${NETCUP_API_BASE}${endpoint}" \
            -H "Authorization: Bearer ${NETCUP_ACCESS_TOKEN}" \
            -H "Accept: application/json" \
            "${extra_args[@]}")
        http_code=$(echo "$response" | tail -1)
        body=$(echo "$response" | sed '$d')
    fi

    if [[ "$http_code" -ge 400 ]]; then
        local msg
        msg=$(echo "$body" | jq -r '.message // empty' 2>/dev/null)
        print_error "API-Fehler (HTTP $http_code): ${msg:-$body}"
        exit 1
    fi

    echo "$body"
}

# Login via Device Code Flow (wie GitHub)
cmd_netcup_login_device() {
    echo "Netcup SCP API Login (Device Code)"
    echo ""

    # Schritt 1: Device Code anfordern
    local device_response
    device_response=$(curl -s -X POST "$NETCUP_DEVICE_URL" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "client_id=${NETCUP_CLIENT_ID}" \
        -d "scope=offline_access openid")

    local device_code user_code verification_uri interval error
    error=$(echo "$device_response" | jq -r '.error // empty')

    if [[ -n "$error" ]]; then
        local error_desc
        error_desc=$(echo "$device_response" | jq -r '.error_description // empty')
        print_error "Device Code Anfrage fehlgeschlagen: ${error_desc:-$error}"
        exit 1
    fi

    device_code=$(echo "$device_response" | jq -r '.device_code')
    user_code=$(echo "$device_response" | jq -r '.user_code')
    verification_uri=$(echo "$device_response" | jq -r '.verification_uri_complete // .verification_uri')
    interval=$(echo "$device_response" | jq -r '.interval // 5')

    if [[ -z "$device_code" || "$device_code" == "null" ]]; then
        print_error "Device Code Anfrage fehlgeschlagen. Unerwartete Antwort vom Server."
        exit 1
    fi

    # Schritt 2: User auffordern, im Browser zu bestätigen
    echo "Öffne diese URL im Browser und melde dich an:"
    echo ""
    echo "  $verification_uri"
    echo ""
    echo "Falls nach einem Code gefragt wird:  $user_code"
    echo ""
    echo "Warte auf Bestätigung..."

    # Schritt 3: Token-Endpoint pollen
    local max_attempts=60
    local attempt=0

    while [[ $attempt -lt $max_attempts ]]; do
        sleep "$interval"
        ((attempt++))

        local response
        response=$(curl -s -X POST "$NETCUP_TOKEN_URL" \
            -H "Content-Type: application/x-www-form-urlencoded" \
            -d "client_id=${NETCUP_CLIENT_ID}" \
            -d "grant_type=urn:ietf:params:oauth:grant-type:device_code" \
            -d "device_code=${device_code}")

        local token_error
        token_error=$(echo "$response" | jq -r '.error // empty')

        case "$token_error" in
            "authorization_pending")
                # User hat noch nicht bestätigt - weiter warten
                continue
                ;;
            "slow_down")
                # Zu schnell - Intervall erhöhen
                ((interval++))
                continue
                ;;
            "expired_token")
                print_error "Der Code ist abgelaufen. Bitte erneut versuchen."
                exit 1
                ;;
            "access_denied")
                print_error "Zugriff verweigert."
                exit 1
                ;;
            "")
                # Kein Fehler - Token erhalten!
                local access_token refresh_token
                access_token=$(echo "$response" | jq -r '.access_token')
                refresh_token=$(echo "$response" | jq -r '.refresh_token')

                if [[ -z "$access_token" || "$access_token" == "null" ]]; then
                    print_error "Login fehlgeschlagen. Unerwartete Antwort vom Server."
                    exit 1
                fi

                netcup_save_tokens "$access_token" "$refresh_token"
                echo ""
                print_success "Login erfolgreich! Token gespeichert."
                return 0
                ;;
            *)
                local error_desc
                error_desc=$(echo "$response" | jq -r '.error_description // empty')
                print_error "Login fehlgeschlagen: ${error_desc:-$token_error}"
                exit 1
                ;;
        esac
    done

    print_error "Zeitüberschreitung. Bitte erneut versuchen."
    exit 1
}

# Login-Alias
cmd_netcup_login() {
    cmd_netcup_login_device
}

# Logout: Widerruft Token serverseitig und löscht lokale Datei
cmd_netcup_logout() {
    if [[ ! -f "$NETCUP_CONFIG" ]]; then
        echo "Nicht eingeloggt."
        return
    fi

    source "$NETCUP_CONFIG"

    # Refresh Token serverseitig widerrufen
    if [[ -n "$NETCUP_REFRESH_TOKEN" ]]; then
        curl -s -X POST "$NETCUP_REVOKE_URL" \
            -d "client_id=${NETCUP_CLIENT_ID}" \
            -d "token=${NETCUP_REFRESH_TOKEN}" \
            -d "token_type_hint=refresh_token" > /dev/null 2>&1 || true
    fi

    rm -f "$NETCUP_CONFIG"
    print_success "Logout erfolgreich. Token widerrufen und lokal gelöscht."
}

# Listet alle Server auf
cmd_netcup_list() {
    local search="$1"
    local endpoint="/api/v1/servers"

    if [[ -n "$search" ]]; then
        endpoint="${endpoint}?q=$(printf '%s' "$search" | jq -sRr @uri)"
    fi

    local response
    response=$(netcup_api GET "$endpoint")

    local count
    count=$(echo "$response" | jq 'length')

    if [[ "$count" -eq 0 ]]; then
        echo "Keine Server gefunden."
        return
    fi

    echo "Netcup Server ($count):"
    echo ""
    printf "%-8s %-25s %-20s %-15s %s\n" "ID" "NAME" "HOSTNAME" "NICKNAME" "STATUS"
    printf "%-8s %-25s %-20s %-15s %s\n" "--------" "-------------------------" "--------------------" "---------------" "--------"

    echo "$response" | jq -r '.[] | [
        (.id | tostring),
        (.name // "-"),
        (.hostname // "-"),
        (.nickname // "-"),
        (if .disabled then "deaktiviert" else "aktiv" end)
    ] | @tsv' | while IFS=$'\t' read -r id name hostname nickname status; do
        printf "%-8s %-25s %-20s %-15s %s\n" "$id" "$name" "$hostname" "$nickname" "$status"
    done
}

# Zeigt Details zu einem Server
cmd_netcup_info() {
    local server_id="$1"

    if [[ -z "$server_id" ]]; then
        print_error "Bitte Server-ID angeben: vps netcup info <id>"
        exit 1
    fi

    local response
    response=$(netcup_api GET "/api/v1/servers/${server_id}")

    echo "Server-Details:"
    echo ""
    echo "$response" | jq -r '
        "  Name:         " + (.name // "-"),
        "  Hostname:     " + (.hostname // "-"),
        "  Nickname:     " + (.nickname // "-"),
        "  Status:       " + (if .disabled then "deaktiviert" else "aktiv" end),
        "  Standort:     " + (.site.city // "-"),
        "  Architektur:  " + (.architecture // "-"),
        "  Max CPUs:     " + (.maxCpuCount // 0 | tostring),
        "  Freier Speicher: " + ((.disksAvailableSpaceInMiB // 0 | tostring) + " MiB"),
        "  Snapshots:    " + (.snapshotCount // 0 | tostring),
        "  Rescue aktiv: " + (if .rescueSystemActive then "ja" else "nein" end)'

    # IPv4-Adressen
    local ipv4_count
    ipv4_count=$(echo "$response" | jq '.ipv4Addresses | length')
    if [[ "$ipv4_count" -gt 0 ]]; then
        echo ""
        echo "  IPv4-Adressen:"
        echo "$response" | jq -r '.ipv4Addresses[] | "    - " + .ip'
    fi

    # IPv6-Adressen
    local ipv6_count
    ipv6_count=$(echo "$response" | jq '.ipv6Addresses | length')
    if [[ "$ipv6_count" -gt 0 ]]; then
        echo ""
        echo "  IPv6-Adressen:"
        echo "$response" | jq -r '.ipv6Addresses[] | "    - " + .networkPrefix + "/" + (.networkPrefixLength | tostring)'
    fi

    # Live-Info (Status, Uptime, RAM etc.)
    local has_live_info
    has_live_info=$(echo "$response" | jq '.serverLiveInfo != null')
    if [[ "$has_live_info" == "true" ]]; then
        echo ""
        echo "  Live-Info:"
        echo "$response" | jq -r '.serverLiveInfo |
            "    State:      " + (.state // "-"),
            "    Uptime:     " + ((.uptimeInSeconds // 0) / 3600 | floor | tostring) + " Stunden",
            "    RAM:        " + (.currentServerMemoryInMiB // 0 | tostring) + " / " + (.maxServerMemoryInMiB // 0 | tostring) + " MiB",
            "    CPUs:       " + (.cpuCount // 0 | tostring) + " / " + (.cpuMaxCount // 0 | tostring)'
    fi
}

# Netcup Unterbefehl-Router
cmd_netcup() {
    local subcmd="$1"
    shift 2>/dev/null || true

    case "$subcmd" in
        login)
            cmd_netcup_login "$@"
            ;;
        logout)
            cmd_netcup_logout "$@"
            ;;
        list|ls)
            cmd_netcup_list "$@"
            ;;
        info)
            cmd_netcup_info "$@"
            ;;
        *)
            print_error "Unbekannter Netcup-Befehl: $subcmd"
            echo "Verwendung: vps netcup <login|logout|list|info>"
            exit 1
            ;;
    esac
}

# === HELP ===
cmd_help() {
    cat << 'EOF'
VPS Management CLI

Verwendung: vps <befehl> [optionen]

Befehle:
  scan                              Scannt das Netzwerk nach erreichbaren VPS
  list                              Zeigt alle konfigurierten VPS
  status [host]                     Zeigt Update-Status, Reboot-Pending, Load
  update [host]                     Führt apt update && apt upgrade aus
  reboot <host>                     Startet einen VPS neu (mit Bestätigung)
  exec <host> <cmd>                 Führt Befehl auf VPS aus
  ssh <host>                        Öffnet interaktive SSH-Session

Docker & Traefik:
  docker <host>                     Installiert Docker auf einem Host
  traefik setup <email>             Richtet Traefik auf dem Proxy ein
  traefik status                    Zeigt Traefik-Status
  traefik logs [lines]              Zeigt Traefik-Logs
  traefik restart                   Startet Traefik neu

Routing:
  route add <domain> <host> <port>  Fügt eine Route hinzu
  route list                        Zeigt alle Routes
  route remove <domain>             Entfernt eine Route

Netcup API:
  netcup login                      Login via Browser (Device Code Flow)
  netcup logout                     Logout (Token widerrufen)
  netcup list [suche]               Zeigt alle Netcup Server
  netcup info <id>                  Zeigt Server-Details

  help                              Zeigt diese Hilfe

Beispiele:
  vps scan                          # Netzwerk scannen
  vps list                          # Alle VPS anzeigen
  vps status webserver              # Status eines VPS
  vps docker proxy                  # Docker auf Proxy installieren
  vps traefik setup admin@mail.de   # Traefik einrichten
  vps route add app.de webserver 80 # Route hinzufügen
  vps route list                    # Routes anzeigen
  vps netcup login                  # Login via Browser
  vps netcup list                   # Netcup Server auflisten
  vps netcup info 12345             # Server-Details anzeigen

Konfiguration:
  Hosts-Datei: /etc/vps-hosts
  Traefik-Dir: /opt/traefik
  SSH-User: master
EOF
}

# === MAIN ===
main() {
    local cmd="${1:-help}"
    shift 2>/dev/null || true

    case "$cmd" in
        scan)
            cmd_scan "$@"
            ;;
        list|ls)
            cmd_list "$@"
            ;;
        status|st)
            cmd_status "$@"
            ;;
        update|up)
            cmd_update "$@"
            ;;
        reboot)
            cmd_reboot "$@"
            ;;
        exec)
            cmd_exec "$@"
            ;;
        ssh)
            cmd_ssh "$@"
            ;;
        docker)
            cmd_docker "$@"
            ;;
        traefik)
            cmd_traefik "$@"
            ;;
        route)
            cmd_route "$@"
            ;;
        netcup)
            cmd_netcup "$@"
            ;;
        help|--help|-h)
            cmd_help
            ;;
        *)
            print_error "Unbekannter Befehl: $cmd"
            echo "Verwende 'vps help' für eine Liste der Befehle."
            exit 1
            ;;
    esac
}

main "$@"
