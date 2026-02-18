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
AUTHELIA_DIR="/opt/authelia"
VPS_HOME="/opt/vps"
TEMPLATES_DIR="${VPS_HOME}/templates"
DASHBOARD_DIR="${VPS_HOME}/webui"

# Netcup SCP API Konfiguration
NETCUP_CONFIG="${HOME}/.config/vps-cli/netcup"
NETCUP_API_BASE="https://www.servercontrolpanel.de/scp-core"
NETCUP_TOKEN_URL="https://www.servercontrolpanel.de/realms/scp/protocol/openid-connect/token"
NETCUP_DEVICE_URL="https://www.servercontrolpanel.de/realms/scp/protocol/openid-connect/auth/device"
NETCUP_REVOKE_URL="https://www.servercontrolpanel.de/realms/scp/protocol/openid-connect/revoke"
NETCUP_CLIENT_ID="scp"

# Backup Konfiguration
BACKUP_CONFIG="${HOME}/.config/vps-cli/backup"
RESTIC_VERSION="0.17.3"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

# Datei auf beliebigen Host schreiben (von stdin)
host_write() {
    local ip="$1"
    local dest="$2"
    if is_local_proxy "$ip"; then
        sudo tee "$dest" > /dev/null
    else
        ssh $SSH_OPTS "${SSH_USER}@${ip}" "sudo tee $dest > /dev/null"
    fi
}

# Verzeichnis auf Host erstellen (mit korrekten Rechten)
host_mkdir() {
    local ip="$1"
    local dir="$2"
    ssh_exec "$ip" "sudo mkdir -p $dir && sudo chown ${SSH_USER}:${SSH_USER} $dir"
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
                hostname=$(ssh $SSH_OPTS "${SSH_USER}@${ip}" "hostname" 2>/dev/null) || true
                if [[ -n "$hostname" ]]; then
                    echo "$ip $hostname"
                else
                    # Ping OK, aber kein SSH — als unmanaged markieren
                    echo "$ip $ip unmanaged"
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
    sudo chown master:master "$HOSTS_FILE"

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
    printf "%-15s %-20s %s\n" "IP" "HOSTNAME" "STATUS"
    printf "%-15s %-20s %s\n" "---------------" "--------------------" "----------"

    while IFS= read -r line; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        read -r ip hostname marker <<< "$line"
        [[ -z "$ip" ]] && continue
        if [[ "$marker" == "unmanaged" ]]; then
            printf "%-15s %-20s %s\n" "$ip" "$hostname" "unmanaged"
        else
            printf "%-15s %-20s %s\n" "$ip" "$hostname" "managed"
        fi
    done < "$HOSTS_FILE"
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
    local subcmd="$1"
    shift 2>/dev/null || true

    case "$subcmd" in
        install)
            cmd_docker_install "$@"
            ;;
        list|ls|ps)
            cmd_docker_list "$@"
            ;;
        start)
            cmd_docker_start "$@"
            ;;
        stop)
            cmd_docker_stop "$@"
            ;;
        help|--help|-h|"")
            cmd_docker_help
            ;;
        *)
            print_error "Unbekannter Docker-Befehl: $subcmd"
            echo "Verwende 'vps docker help' für eine Liste der Befehle."
            exit 1
            ;;
    esac
}

cmd_docker_help() {
    cat << 'EOF'
Docker-Verwaltung auf VPS

Verwendung: vps docker <befehl> [optionen]

Befehle:
  install <host>                  Docker CE installieren
  list                            Docker-Übersicht aller VPS
  list <host>                     Container auf einem Host anzeigen
  start <host> <container>        Container starten
  stop <host> <container>         Container stoppen
  help                            Diese Hilfe anzeigen

Beispiele:
  vps docker install webserver        # Docker installieren
  vps docker list                     # Übersicht aller VPS
  vps docker list webserver           # Container auflisten
  vps docker stop webserver myapp     # Container stoppen
  vps docker start webserver myapp    # Container starten
EOF
}

cmd_docker_install() {
    local target="$1"

    if [[ -z "$target" ]]; then
        print_error "Bitte Host angeben: vps docker install <host>"
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

cmd_docker_list() {
    local target="$1"

    # Ohne Host: Übersicht aller VPS
    if [[ -z "$target" ]]; then
        cmd_docker_list_all
        return
    fi

    local ip=$(resolve_host "$target")
    local hostname="$target"

    echo "Docker-Container auf $hostname ($ip):"
    echo ""

    # Prüfe ob Docker installiert ist
    if ! ssh_exec "$ip" "command -v docker" &>/dev/null; then
        print_error "Docker ist nicht installiert auf $hostname. Führe zuerst 'vps docker install $hostname' aus."
        exit 1
    fi

    # Alle Container anzeigen (laufende und gestoppte)
    ssh_exec "$ip" "sudo docker ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'"
}

cmd_docker_list_all() {
    check_hosts_file

    echo "Docker-Übersicht aller VPS:"
    echo ""
    printf "%-15s %-15s %-10s %-10s %s\n" "VPS" "IP" "DOCKER" "LAUFEND" "GESTOPPT"
    printf "%-15s %-15s %-10s %-10s %s\n" "---------------" "---------------" "----------" "----------" "----------"

    local pids=()
    local temp_dir=$(mktemp -d)

    while read -r ip hostname; do
        [[ -z "$ip" ]] && continue
        (
            if ssh_exec "$ip" "command -v docker" &>/dev/null; then
                local running stopped
                running=$(ssh_exec "$ip" "sudo docker ps -q 2>/dev/null | wc -l" 2>/dev/null || echo "?")
                stopped=$(ssh_exec "$ip" "sudo docker ps -aq --filter status=exited 2>/dev/null | wc -l" 2>/dev/null || echo "?")
                printf "%-15s %-15s %-10s %-10s %s\n" "$hostname" "$ip" "ja" "$running" "$stopped"
            else
                printf "%-15s %-15s %-10s %-10s %s\n" "$hostname" "$ip" "nein" "-" "-"
            fi
        ) > "$temp_dir/$ip" &
        pids+=($!)
    done < <(get_hosts)

    for pid in "${pids[@]}"; do
        wait "$pid"
    done

    # Ausgabe in IP-Reihenfolge
    while read -r ip hostname; do
        [[ -z "$ip" ]] && continue
        [[ -f "$temp_dir/$ip" ]] && cat "$temp_dir/$ip"
    done < <(get_hosts)

    rm -rf "$temp_dir"
}

cmd_docker_start() {
    local target="$1"
    local container="$2"

    if [[ -z "$target" ]] || [[ -z "$container" ]]; then
        print_error "Verwendung: vps docker start <host> <container>"
        exit 1
    fi

    local ip=$(resolve_host "$target")
    echo "Starte Container '$container' auf $target ($ip)..."
    ssh_exec "$ip" "sudo docker start $container"
    print_success "Container '$container' gestartet."
}

cmd_docker_stop() {
    local target="$1"
    local container="$2"

    if [[ -z "$target" ]] || [[ -z "$container" ]]; then
        print_error "Verwendung: vps docker stop <host> <container>"
        exit 1
    fi

    local ip=$(resolve_host "$target")
    echo "Stoppe Container '$container' auf $target ($ip)..."
    ssh_exec "$ip" "sudo docker stop $container"
    print_success "Container '$container' gestoppt."
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
    echo "=== Traefik Setup ==="
    echo ""

    # E-Mail abfragen
    local email=""
    while [[ -z "$email" ]]; do
        read -p "E-Mail-Adresse (für Let's Encrypt): " email
    done

    # Dashboard-Domain abfragen
    local domain=""
    while [[ -z "$domain" ]]; do
        read -p "Dashboard-Domain (z.B. traefik.example.de): " domain
    done

    # BasicAuth Zugangsdaten abfragen
    echo ""
    echo "Zugangsdaten für das Dashboard:"
    local auth_user=""
    while [[ -z "$auth_user" ]]; do
        read -p "Benutzername: " auth_user
    done

    local auth_pass=""
    while [[ -z "$auth_pass" ]]; do
        read -s -p "Passwort: " auth_pass
        echo ""
    done
    local auth_pass_confirm=""
    read -s -p "Passwort bestätigen: " auth_pass_confirm
    echo ""

    if [[ "$auth_pass" != "$auth_pass_confirm" ]]; then
        print_error "Passwörter stimmen nicht überein."
        exit 1
    fi

    # Zusammenfassung anzeigen
    echo ""
    echo "Zusammenfassung:"
    echo "  E-Mail:     $email"
    echo "  Dashboard:  https://$domain"
    echo "  Benutzer:   $auth_user"
    echo ""
    read -p "Einrichtung starten? (j/n): " confirm
    if [[ "$confirm" != "j" && "$confirm" != "J" ]]; then
        echo "Abgebrochen."
        exit 0
    fi

    echo ""
    echo "Richte Traefik auf Proxy ($PROXY_IP) ein..."

    # Prüfe ob Docker installiert ist
    if ! proxy_exec "command -v docker" &>/dev/null; then
        print_error "Docker ist nicht installiert. Führe zuerst 'vps docker install proxy' aus."
        exit 1
    fi

    # bcrypt-Hash für BasicAuth erzeugen
    echo "Erzeuge Zugangsdaten..."
    local auth_hash
    auth_hash=$(proxy_exec "echo '$auth_pass' | sudo docker run --rm -i httpd:2-alpine htpasswd -niB '$auth_user'" 2>/dev/null | tr -d '\n')
    if [[ -z "$auth_hash" ]]; then
        print_error "Konnte BasicAuth-Hash nicht erzeugen. Ist Docker auf dem Proxy installiert?"
        exit 1
    fi
    # Doppelte $-Zeichen escapen für Docker Compose
    local auth_escaped="${auth_hash//\$/\$\$}"

    # Erstelle Verzeichnisstruktur
    echo "Erstelle Verzeichnisstruktur..."
    proxy_exec "sudo mkdir -p ${TRAEFIK_DIR}/conf.d"

    # Kopiere Konfigurationsdateien
    echo "Kopiere Konfigurationsdateien..."

    # docker-compose.yml mit Dashboard-Domain und Auth
    sed -e "s/\${DASHBOARD_DOMAIN}/${domain}/" \
        -e "s|\${DASHBOARD_AUTH}|${auth_escaped}|" \
        "${TEMPLATES_DIR}/traefik/docker-compose.yml" | proxy_write "${TRAEFIK_DIR}/docker-compose.yml"

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
    echo "Dashboard: https://$domain"
    echo "Login:     $auth_user / ********"
    echo ""
    echo "Hinweis: DNS-Eintrag für '$domain' muss auf die Proxy-Public-IP zeigen."
    echo ""
    echo "Routen hinzufügen: vps route add <domain> <host> <port>"
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
        auth)
            cmd_route_auth "$@"
            ;;
        noauth)
            cmd_route_noauth "$@"
            ;;
        *)
            print_error "Unbekannter Route-Befehl: $subcmd"
            echo "Verwendung: vps route <add|list|remove|auth|noauth>"
            exit 1
            ;;
    esac
}

cmd_route_add() {
    local auth=false

    # Parse --auth Flag
    while [[ "${1:-}" == --* ]]; do
        case "$1" in
            --auth) auth=true; shift ;;
            *) print_error "Unbekannte Option: $1"; exit 1 ;;
        esac
    done

    local domain="$1"
    local host="$2"
    local port="$3"

    if [[ -z "$domain" ]] || [[ -z "$host" ]] || [[ -z "$port" ]]; then
        print_error "Verwendung: vps route add [--auth] <domain> <host> <port>"
        echo "Beispiel: vps route add app.example.com webserver 8080"
        echo "          vps route add --auth app.example.com webserver 8080"
        exit 1
    fi

    # Validiere Port
    if ! [[ "$port" =~ ^[0-9]+$ ]] || [[ "$port" -lt 1 ]] || [[ "$port" -gt 65535 ]]; then
        print_error "Ungültiger Port: $port"
        exit 1
    fi

    # Prüfe Authelia wenn --auth
    if [[ "$auth" == "true" ]]; then
        if ! proxy_exec "test -f ${TRAEFIK_DIR}/conf.d/_authelia.yml" 2>/dev/null; then
            print_error "Authelia-Middleware nicht gefunden. Führe zuerst 'vps authelia setup' aus."
            exit 1
        fi
    fi

    # Löse Host zu IP auf
    local host_ip=$(resolve_host "$host")

    # Generiere einen sicheren Namen aus der Domain
    local name=$(echo "$domain" | sed 's/[^a-zA-Z0-9]/-/g' | tr '[:upper:]' '[:lower:]')

    # Template wählen (mit oder ohne Auth)
    local template_file="${TEMPLATES_DIR}/traefik/route.yml.template"
    if [[ "$auth" == "true" ]]; then
        template_file="${TEMPLATES_DIR}/traefik/route-auth.yml.template"
    fi

    local auth_info=""
    if [[ "$auth" == "true" ]]; then
        auth_info=" (mit Authelia)"
    fi
    echo "Erstelle Route: $domain -> $host ($host_ip):$port${auth_info}"

    # Erstelle Route-Konfiguration aus Template
    local route_config=$(cat "${template_file}" | \
        sed "s/{{NAME}}/${name}/g" | \
        sed "s/{{DOMAIN}}/${domain}/g" | \
        sed "s/{{HOST_IP}}/${host_ip}/g" | \
        sed "s/{{PORT}}/${port}/g")

    # Schreibe Konfiguration auf Proxy
    echo "$route_config" | proxy_write "${TRAEFIK_DIR}/conf.d/${domain}.yml"

    print_success "Route hinzugefügt: $domain -> $host_ip:$port${auth_info}"
    echo ""
    echo "Hinweis: Stelle sicher, dass der DNS-Eintrag für $domain auf die Public-IP des Proxy zeigt."
}

cmd_route_list() {
    echo "Konfigurierte Routes:"
    echo ""
    printf "%-35s %-20s %-6s %s\n" "DOMAIN" "ZIEL" "AUTH" "DATEI"
    printf "%-35s %-20s %-6s %s\n" "-----------------------------------" "--------------------" "------" "--------------------"

    # Liste alle .yml Dateien im conf.d Verzeichnis (ohne _-Prefixed Middleware-Dateien)
    local routes=$(proxy_exec "ls -1 ${TRAEFIK_DIR}/conf.d/*.yml 2>/dev/null | grep -v '/_'" || true)

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

        # Prüfe ob Authelia-Middleware aktiv
        local auth="nein"
        if proxy_exec "grep -q 'authelia' ${route_file}" 2>/dev/null; then
            auth="ja"
        fi

        printf "%-35s %-20s %-6s %s\n" "$domain" "$target" "$auth" "$filename"
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

cmd_route_auth() {
    local domain="$1"

    if [[ -z "$domain" ]]; then
        print_error "Verwendung: vps route auth <domain>"
        exit 1
    fi

    local route_file="${TRAEFIK_DIR}/conf.d/${domain}.yml"

    if ! proxy_exec "test -f ${route_file}" 2>/dev/null; then
        print_error "Route für '$domain' nicht gefunden."
        exit 1
    fi

    if ! proxy_exec "test -f ${TRAEFIK_DIR}/conf.d/_authelia.yml" 2>/dev/null; then
        print_error "Authelia-Middleware nicht gefunden. Führe zuerst 'vps authelia setup' aus."
        exit 1
    fi

    if proxy_exec "grep -q 'authelia' ${route_file}" 2>/dev/null; then
        print_warning "Authelia ist bereits aktiv für $domain."
        return
    fi

    # Route-Informationen extrahieren
    local url=$(proxy_exec "grep -oP 'url: \"http://\K[^\"]+' ${route_file}")
    local host_ip=$(echo "$url" | cut -d: -f1)
    local port=$(echo "$url" | cut -d: -f2)
    local name=$(echo "$domain" | sed 's/[^a-zA-Z0-9]/-/g' | tr '[:upper:]' '[:lower:]')

    # Route mit Auth-Template neu generieren
    local route_config=$(cat "${TEMPLATES_DIR}/traefik/route-auth.yml.template" | \
        sed "s/{{NAME}}/${name}/g" | \
        sed "s/{{DOMAIN}}/${domain}/g" | \
        sed "s/{{HOST_IP}}/${host_ip}/g" | \
        sed "s/{{PORT}}/${port}/g")

    echo "$route_config" | proxy_write "${route_file}"

    print_success "Authelia aktiviert für: $domain"
}

cmd_route_noauth() {
    local domain="$1"

    if [[ -z "$domain" ]]; then
        print_error "Verwendung: vps route noauth <domain>"
        exit 1
    fi

    local route_file="${TRAEFIK_DIR}/conf.d/${domain}.yml"

    if ! proxy_exec "test -f ${route_file}" 2>/dev/null; then
        print_error "Route für '$domain' nicht gefunden."
        exit 1
    fi

    if ! proxy_exec "grep -q 'authelia' ${route_file}" 2>/dev/null; then
        print_warning "Authelia ist nicht aktiv für $domain."
        return
    fi

    # Route-Informationen extrahieren
    local url=$(proxy_exec "grep -oP 'url: \"http://\K[^\"]+' ${route_file}")
    local host_ip=$(echo "$url" | cut -d: -f1)
    local port=$(echo "$url" | cut -d: -f2)
    local name=$(echo "$domain" | sed 's/[^a-zA-Z0-9]/-/g' | tr '[:upper:]' '[:lower:]')

    # Route ohne Auth-Template neu generieren
    local route_config=$(cat "${TEMPLATES_DIR}/traefik/route.yml.template" | \
        sed "s/{{NAME}}/${name}/g" | \
        sed "s/{{DOMAIN}}/${domain}/g" | \
        sed "s/{{HOST_IP}}/${host_ip}/g" | \
        sed "s/{{PORT}}/${port}/g")

    echo "$route_config" | proxy_write "${route_file}"

    print_success "Authelia deaktiviert für: $domain"
}

# === AUTHELIA ===

cmd_authelia() {
    local subcmd="$1"
    shift 2>/dev/null || true

    case "$subcmd" in
        setup)
            cmd_authelia_setup "$@"
            ;;
        status)
            cmd_authelia_status
            ;;
        logs)
            cmd_authelia_logs "$@"
            ;;
        restart)
            cmd_authelia_restart
            ;;
        user)
            cmd_authelia_user "$@"
            ;;
        domain)
            cmd_authelia_domain "$@"
            ;;
        help|"")
            cmd_authelia_help
            ;;
        *)
            print_error "Unbekannter Authelia-Befehl: $subcmd"
            cmd_authelia_help
            exit 1
            ;;
    esac
}

cmd_authelia_help() {
    echo "=== Authelia - Single Sign-On (SSO) ==="
    echo ""
    echo "Authelia stellt zentrale Authentifizierung für alle Services bereit."
    echo "Einmal einloggen, überall angemeldet — auch über mehrere Domains."
    echo ""
    echo "Einrichtung:"
    echo "  vps authelia setup                     Interaktive Ersteinrichtung"
    echo ""
    echo "Status & Verwaltung:"
    echo "  vps authelia status                    Container-Status anzeigen"
    echo "  vps authelia logs [zeilen]             Logs anzeigen (Standard: 50)"
    echo "  vps authelia restart                   Authelia neu starten"
    echo ""
    echo "Benutzerverwaltung:"
    echo "  vps authelia user add                  Neuen Benutzer anlegen"
    echo "  vps authelia user list                 Alle Benutzer anzeigen"
    echo "  vps authelia user remove <user>        Benutzer entfernen"
    echo ""
    echo "Domain-Verwaltung (Multi-Domain SSO):"
    echo "  vps authelia domain add [domain]       Cookie-Domain hinzufügen"
    echo "  vps authelia domain list               Konfigurierte Domains anzeigen"
    echo "  vps authelia domain remove <domain>    Cookie-Domain entfernen"
    echo ""
    echo "Routen absichern:"
    echo "  vps route add --auth <domain> <host> <port>   Neue Route mit Auth"
    echo "  vps route auth <domain>                       Auth für Route aktivieren"
    echo "  vps route noauth <domain>                     Auth für Route deaktivieren"
    echo ""
    echo "Beispiel — Mehrere Domains:"
    echo "  vps authelia setup                     # Setup mit firma.de"
    echo "  vps authelia domain add privat.de      # privat.de nachträglich hinzufügen"
    echo "  vps authelia domain list               # Alle Domains anzeigen"
    echo "  vps route add --auth app.privat.de webserver 8080"
    echo ""
    echo "Hinweis: DNS-Einträge müssen auf die Proxy-Public-IP zeigen."
}

cmd_authelia_setup() {
    echo "=== Authelia Setup ==="
    echo ""

    # Prüfe ob Traefik installiert ist
    if ! proxy_exec "test -f ${TRAEFIK_DIR}/docker-compose.yml" 2>/dev/null; then
        print_error "Traefik ist nicht installiert. Führe zuerst 'vps traefik setup' aus."
        exit 1
    fi

    # Prüfe ob Docker installiert ist
    if ! proxy_exec "command -v docker" &>/dev/null; then
        print_error "Docker ist nicht installiert."
        exit 1
    fi

    # Domain abfragen
    local auth_domain=""
    while [[ -z "$auth_domain" ]]; do
        read -p "Authelia-Domain (z.B. auth.example.de): " auth_domain
    done

    # Cookie-Domains abfragen (Multi-Domain-Support)
    echo ""
    echo "Die Cookie-Domains bestimmen, für welche Domains SSO gilt."
    echo "Beispiel: Für app.example.de und docs.example.de -> example.de"
    echo "Du kannst mehrere Domains angeben (z.B. firma.de und privat.de)."
    echo ""
    local cookie_domains=()
    local cookie_domain=""
    while true; do
        local prompt_text="Cookie-Domain"
        if [[ ${#cookie_domains[@]} -gt 0 ]]; then
            prompt_text="Weitere Cookie-Domain (leer = fertig)"
        fi
        read -p "${prompt_text} (z.B. example.de): " cookie_domain
        if [[ -z "$cookie_domain" ]]; then
            if [[ ${#cookie_domains[@]} -eq 0 ]]; then
                print_error "Mindestens eine Cookie-Domain ist erforderlich."
                continue
            fi
            break
        fi
        cookie_domains+=("$cookie_domain")
        echo "  -> $cookie_domain hinzugefügt (${#cookie_domains[@]} Domain(s))"
    done

    # Admin-User erstellen
    echo ""
    echo "Admin-Benutzer erstellen:"
    local admin_user=""
    while [[ -z "$admin_user" ]]; do
        read -p "Benutzername: " admin_user
    done

    local admin_displayname=""
    while [[ -z "$admin_displayname" ]]; do
        read -p "Anzeigename: " admin_displayname
    done

    local admin_email=""
    while [[ -z "$admin_email" ]]; do
        read -p "E-Mail: " admin_email
    done

    local admin_pass=""
    while [[ -z "$admin_pass" ]]; do
        read -s -p "Passwort: " admin_pass
        echo ""
    done
    local admin_pass_confirm=""
    read -s -p "Passwort bestätigen: " admin_pass_confirm
    echo ""

    if [[ "$admin_pass" != "$admin_pass_confirm" ]]; then
        print_error "Passwörter stimmen nicht überein."
        exit 1
    fi

    # Zusammenfassung
    echo ""
    echo "Zusammenfassung:"
    echo "  Authelia:       https://$auth_domain"
    echo "  Cookie-Domains:"
    for d in "${cookie_domains[@]}"; do
        echo "    - $d (auth: auth.${d})"
    done
    echo "  DNS benötigt:"
    for d in "${cookie_domains[@]}"; do
        echo "    - auth.${d} -> Proxy-Public-IP"
    done
    echo "  Admin-User:     $admin_user ($admin_displayname)"
    echo "  E-Mail:         $admin_email"
    echo ""
    read -p "Einrichtung starten? (j/n): " confirm
    if [[ "$confirm" != "j" && "$confirm" != "J" ]]; then
        echo "Abgebrochen."
        exit 0
    fi

    echo ""
    echo "Richte Authelia auf Proxy ($PROXY_IP) ein..."

    # Passwort-Hash erzeugen
    echo "Erzeuge Passwort-Hash..."
    local password_hash
    password_hash=$(proxy_exec "docker run --rm authelia/authelia:latest authelia crypto hash generate argon2 --password '${admin_pass}'" 2>/dev/null | grep 'Digest:' | sed 's/Digest: //')
    if [[ -z "$password_hash" ]]; then
        print_error "Konnte Passwort-Hash nicht erzeugen."
        exit 1
    fi

    # Secrets generieren
    local session_secret=$(openssl rand -base64 64 | tr -d '/+=\n' | head -c 64)
    local storage_key=$(openssl rand -base64 64 | tr -d '/+=\n' | head -c 64)
    local jwt_secret=$(openssl rand -base64 64 | tr -d '/+=\n' | head -c 64)

    # Verzeichnisstruktur erstellen
    echo "Erstelle Verzeichnisstruktur..."
    proxy_exec "sudo mkdir -p ${AUTHELIA_DIR}/config ${AUTHELIA_DIR}/redis-data"

    # Konfigurationsdateien kopieren
    echo "Kopiere Konfigurationsdateien..."

    # docker-compose.yml (ohne Traefik-Labels, Routing über File-Provider)
    cat "${TEMPLATES_DIR}/authelia/docker-compose.yml" | proxy_write "${AUTHELIA_DIR}/docker-compose.yml"

    # Traefik-Route für alle Auth-Domains erstellen (File-Provider)
    echo "Erstelle Traefik-Routen für Auth-Domains..."
    local route_file
    route_file=$(mktemp)
    cat > "$route_file" <<'ROUTE_HEADER'
http:
  routers:
ROUTE_HEADER
    for d in "${cookie_domains[@]}"; do
        local auth_d="auth.${d}"
        local route_name="authelia-${d//\./-}"
        cat >> "$route_file" <<ROUTE_ROUTER
    ${route_name}:
      rule: "Host(\`${auth_d}\`)"
      entryPoints:
        - websecure
      service: authelia-svc
      tls:
        certResolver: letsencrypt
ROUTE_ROUTER
    done
    cat >> "$route_file" <<'ROUTE_SVC'
  services:
    authelia-svc:
      loadBalancer:
        servers:
          - url: "http://authelia:9091"
ROUTE_SVC
    cat "$route_file" | proxy_write "${TRAEFIK_DIR}/conf.d/_authelia-portal.yml"
    rm -f "$route_file"

    # Cookie-Domains-Block generieren (Temp-Datei für Multiline-Ersetzung)
    local cookie_block_file
    cookie_block_file=$(mktemp)
    for d in "${cookie_domains[@]}"; do
        echo "    - domain: '${d}'" >> "$cookie_block_file"
        echo "      authelia_url: 'https://auth.${d}'" >> "$cookie_block_file"
        echo "      default_redirection_url: 'https://${d}'" >> "$cookie_block_file"
    done

    # configuration.yml
    sed -e "s|{{AUTH_DOMAIN}}|${auth_domain}|g" \
        -e "s|{{SESSION_SECRET}}|${session_secret}|g" \
        -e "s|{{STORAGE_ENCRYPTION_KEY}}|${storage_key}|g" \
        -e "s|{{JWT_SECRET}}|${jwt_secret}|g" \
        "${TEMPLATES_DIR}/authelia/configuration.yml" | \
        sed -e "/{{COOKIE_DOMAINS}}/{r ${cookie_block_file}" -e "d}" | \
        proxy_write "${AUTHELIA_DIR}/config/configuration.yml"
    rm -f "$cookie_block_file"

    # users_database.yml
    sed -e "s|{{ADMIN_USER}}|${admin_user}|g" \
        -e "s|{{ADMIN_DISPLAYNAME}}|${admin_displayname}|g" \
        -e "s|{{ADMIN_PASSWORD_HASH}}|${password_hash}|g" \
        -e "s|{{ADMIN_EMAIL}}|${admin_email}|g" \
        "${TEMPLATES_DIR}/authelia/users_database.yml" | proxy_write "${AUTHELIA_DIR}/config/users_database.yml"

    # Traefik ForwardAuth Middleware installieren
    echo "Installiere Traefik-Middleware..."
    cat "${TEMPLATES_DIR}/traefik/authelia-middleware.yml" | proxy_write "${TRAEFIK_DIR}/conf.d/_authelia.yml"

    # Berechtigungen
    proxy_exec "sudo chown -R ${SSH_USER}:${SSH_USER} ${AUTHELIA_DIR}"

    # Starte Authelia
    echo "Starte Authelia..."
    proxy_exec "cd ${AUTHELIA_DIR} && docker compose up -d"

    # Traefik-Dashboard auf Authelia umstellen
    echo ""
    read -p "Traefik-Dashboard auch mit Authelia absichern? [J/n] " dashboard_confirm
    if [[ ! "$dashboard_confirm" =~ ^[nN]$ ]]; then
        echo "Aktualisiere Traefik-Dashboard..."
        proxy_exec "sed -i 's/middlewares=dashboard-auth/middlewares=authelia@file/' ${TRAEFIK_DIR}/docker-compose.yml"
        proxy_exec "sed -i '/dashboard-auth\.basicauth/d' ${TRAEFIK_DIR}/docker-compose.yml"
        proxy_exec "cd ${TRAEFIK_DIR} && docker compose up -d"
        echo "Traefik-Dashboard ist jetzt mit Authelia abgesichert."
    fi

    print_success "Authelia erfolgreich eingerichtet!"
    echo ""
    echo "Portal: https://$auth_domain"
    echo "Login:  $admin_user / ********"
    echo ""
    echo "Hinweis: DNS-Einträge müssen auf die Proxy-Public-IP zeigen:"
    for d in "${cookie_domains[@]}"; do
        echo "  - auth.${d}"
    done
    echo ""
    echo "Routen mit Authelia absichern:"
    echo "  vps route add --auth <domain> <host> <port>    # Neue Route mit Auth"
    echo "  vps route auth <domain>                         # Bestehende Route absichern"
}

cmd_authelia_status() {
    echo "Authelia-Status auf Proxy ($PROXY_IP):"
    proxy_exec "cd ${AUTHELIA_DIR} && docker compose ps" 2>/dev/null || print_error "Authelia ist nicht installiert."
}

cmd_authelia_logs() {
    local lines="${1:-50}"
    proxy_exec "cd ${AUTHELIA_DIR} && docker compose logs --tail=${lines}"
}

cmd_authelia_restart() {
    echo "Starte Authelia neu..."
    proxy_exec "cd ${AUTHELIA_DIR} && docker compose restart"
    print_success "Authelia neu gestartet."
}

# Authelia Benutzerverwaltung
cmd_authelia_user() {
    local subcmd="$1"
    shift 2>/dev/null || true

    case "$subcmd" in
        add)
            cmd_authelia_user_add "$@"
            ;;
        list|ls)
            cmd_authelia_user_list
            ;;
        remove|rm)
            cmd_authelia_user_remove "$@"
            ;;
        *)
            print_error "Unbekannter User-Befehl: $subcmd"
            echo "Verwendung: vps authelia user <add|list|remove>"
            exit 1
            ;;
    esac
}

cmd_authelia_user_add() {
    local users_file="${AUTHELIA_DIR}/config/users_database.yml"

    if ! proxy_exec "test -f ${users_file}" 2>/dev/null; then
        print_error "Authelia ist nicht eingerichtet. Führe zuerst 'vps authelia setup' aus."
        exit 1
    fi

    local username=""
    while [[ -z "$username" ]]; do
        read -p "Benutzername: " username
    done

    # Prüfe ob User bereits existiert
    if proxy_exec "grep -q '  ${username}:' ${users_file}" 2>/dev/null; then
        print_error "Benutzer '$username' existiert bereits."
        exit 1
    fi

    local displayname=""
    while [[ -z "$displayname" ]]; do
        read -p "Anzeigename: " displayname
    done

    local email=""
    while [[ -z "$email" ]]; do
        read -p "E-Mail: " email
    done

    local password=""
    while [[ -z "$password" ]]; do
        read -s -p "Passwort: " password
        echo ""
    done
    local password_confirm=""
    read -s -p "Passwort bestätigen: " password_confirm
    echo ""

    if [[ "$password" != "$password_confirm" ]]; then
        print_error "Passwörter stimmen nicht überein."
        exit 1
    fi

    # Hash erzeugen
    echo "Erzeuge Passwort-Hash..."
    local password_hash
    password_hash=$(proxy_exec "docker run --rm authelia/authelia:latest authelia crypto hash generate argon2 --password '${password}'" 2>/dev/null | grep 'Digest:' | sed 's/Digest: //')
    if [[ -z "$password_hash" ]]; then
        print_error "Konnte Passwort-Hash nicht erzeugen."
        exit 1
    fi

    # User zur Datei hinzufügen
    proxy_exec "sudo tee -a ${users_file} > /dev/null << USEREOF
  ${username}:
    disabled: false
    displayname: '${displayname}'
    password: '${password_hash}'
    email: '${email}'
USEREOF"

    print_success "Benutzer '$username' hinzugefügt."
    echo "Authelia erkennt die Änderung automatisch."
}

cmd_authelia_user_list() {
    local users_file="${AUTHELIA_DIR}/config/users_database.yml"

    if ! proxy_exec "test -f ${users_file}" 2>/dev/null; then
        print_error "Authelia ist nicht eingerichtet."
        exit 1
    fi

    echo "Authelia-Benutzer:"
    echo ""
    printf "%-20s %-25s %s\n" "BENUTZER" "ANZEIGENAME" "E-MAIL"
    printf "%-20s %-25s %s\n" "--------------------" "-------------------------" "-------------------------"

    # Parse users_database.yml
    local current_user="" current_display="" current_email=""
    while IFS= read -r line; do
        if [[ "$line" =~ ^\ \ ([a-zA-Z0-9_-]+):$ ]]; then
            # Vorherigen User ausgeben
            if [[ -n "$current_user" ]]; then
                printf "%-20s %-25s %s\n" "$current_user" "$current_display" "$current_email"
            fi
            current_user="${BASH_REMATCH[1]}"
            current_display=""
            current_email=""
        elif [[ "$line" =~ displayname:\ *\'(.+)\' ]]; then
            current_display="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ email:\ *\'(.+)\' ]]; then
            current_email="${BASH_REMATCH[1]}"
        fi
    done < <(proxy_exec "cat ${users_file}")

    # Letzten User ausgeben
    if [[ -n "$current_user" ]]; then
        printf "%-20s %-25s %s\n" "$current_user" "$current_display" "$current_email"
    fi
}

cmd_authelia_user_remove() {
    local username="$1"

    if [[ -z "$username" ]]; then
        print_error "Verwendung: vps authelia user remove <benutzername>"
        exit 1
    fi

    local users_file="${AUTHELIA_DIR}/config/users_database.yml"

    if ! proxy_exec "test -f ${users_file}" 2>/dev/null; then
        print_error "Authelia ist nicht eingerichtet."
        exit 1
    fi

    if ! proxy_exec "grep -q '  ${username}:' ${users_file}" 2>/dev/null; then
        print_error "Benutzer '$username' nicht gefunden."
        exit 1
    fi

    print_warning "Benutzer '$username' wird entfernt."
    read -p "Fortfahren? [j/N] " confirm

    if [[ "$confirm" =~ ^[jJyY]$ ]]; then
        # Lösche Benutzerblock (Username-Zeile + 4 Eigenschaftszeilen)
        proxy_exec "sudo sed -i '/^  ${username}:$/,+4d' ${users_file}"
        print_success "Benutzer '$username' entfernt."
        echo "Authelia erkennt die Änderung automatisch."
    else
        echo "Abgebrochen."
    fi
}

# Prüft ob Authelia auf dem Proxy eingerichtet ist
authelia_is_installed() {
    proxy_exec "test -f ${AUTHELIA_DIR}/docker-compose.yml" 2>/dev/null
}

# Authelia Domain-Verwaltung
cmd_authelia_domain() {
    local subcmd="$1"
    shift 2>/dev/null || true

    case "$subcmd" in
        add)
            cmd_authelia_domain_add "$@"
            ;;
        list|ls)
            cmd_authelia_domain_list
            ;;
        remove|rm)
            cmd_authelia_domain_remove "$@"
            ;;
        *)
            print_error "Unbekannter Domain-Befehl: $subcmd"
            echo "Verwendung: vps authelia domain <add|list|remove>"
            exit 1
            ;;
    esac
}

cmd_authelia_domain_add() {
    local config_file="${AUTHELIA_DIR}/config/configuration.yml"

    if ! proxy_exec "test -f ${config_file}" 2>/dev/null; then
        print_error "Authelia ist nicht eingerichtet. Führe zuerst 'vps authelia setup' aus."
        exit 1
    fi

    local new_domain="$1"
    if [[ -z "$new_domain" ]]; then
        read -p "Neue Cookie-Domain (z.B. privat.de): " new_domain
    fi

    if [[ -z "$new_domain" ]]; then
        print_error "Keine Domain angegeben."
        exit 1
    fi

    # Prüfe ob Domain bereits existiert
    if proxy_exec "grep -q \"domain: '${new_domain}'\" ${config_file}" 2>/dev/null; then
        print_error "Domain '$new_domain' ist bereits konfiguriert."
        exit 1
    fi

    # Authelia-URL aus bestehender Config lesen
    local auth_url
    auth_url=$(proxy_exec "grep 'authelia_url:' ${config_file} | head -1 | sed \"s/.*authelia_url: '\\(.*\\)'/\\1/\"" 2>/dev/null)
    if [[ -z "$auth_url" ]]; then
        print_error "Konnte Authelia-URL nicht aus der Konfiguration lesen."
        exit 1
    fi

    echo "Füge Domain '$new_domain' hinzu..."
    echo "  Authelia-URL: $auth_url"
    echo ""
    read -p "Fortfahren? [J/n] " confirm
    if [[ "$confirm" =~ ^[nN]$ ]]; then
        echo "Abgebrochen."
        exit 0
    fi

    # Neuen Cookie-Block vor dem redis:-Abschnitt einfügen
    proxy_exec "sudo sed -i '/^  redis:/i\\    - domain: '\''${new_domain}'\''\\n      authelia_url: '\''https://auth.${new_domain}'\''\\n      default_redirection_url: '\''https://${new_domain}'\''' ${config_file}"

    # Authelia neu starten
    echo "Starte Authelia neu..."
    proxy_exec "cd ${AUTHELIA_DIR} && docker compose restart"

    print_success "Domain '$new_domain' hinzugefügt."
    echo ""
    echo "Hinweis: DNS-Einträge für Subdomains von '$new_domain' müssen auf die Proxy-Public-IP zeigen."
}

cmd_authelia_domain_list() {
    local config_file="${AUTHELIA_DIR}/config/configuration.yml"

    if ! proxy_exec "test -f ${config_file}" 2>/dev/null; then
        print_error "Authelia ist nicht eingerichtet."
        exit 1
    fi

    echo "Konfigurierte Cookie-Domains:"
    echo ""

    local domains
    domains=$(proxy_exec "grep \"domain: '\" ${config_file} | sed \"s/.*domain: '\\(.*\\)'/\\1/\"" 2>/dev/null)

    if [[ -z "$domains" ]]; then
        echo "  Keine Domains konfiguriert."
        return
    fi

    local i=1
    while IFS= read -r domain; do
        echo "  ${i}. ${domain}"
        ((i++))
    done <<< "$domains"

    echo ""
    echo "Gesamt: $((i - 1)) Domain(s)"
}

cmd_authelia_domain_remove() {
    local config_file="${AUTHELIA_DIR}/config/configuration.yml"

    if ! proxy_exec "test -f ${config_file}" 2>/dev/null; then
        print_error "Authelia ist nicht eingerichtet."
        exit 1
    fi

    local domain="$1"
    if [[ -z "$domain" ]]; then
        print_error "Verwendung: vps authelia domain remove <domain>"
        exit 1
    fi

    # Prüfe ob Domain existiert
    if ! proxy_exec "grep -q \"domain: '${domain}'\" ${config_file}" 2>/dev/null; then
        print_error "Domain '$domain' ist nicht konfiguriert."
        exit 1
    fi

    # Prüfe ob es die letzte Domain wäre
    local domain_count
    domain_count=$(proxy_exec "grep -c \"domain: '\" ${config_file}" 2>/dev/null)
    if [[ "$domain_count" -le 1 ]]; then
        print_error "Kann die letzte Domain nicht entfernen. Mindestens eine Cookie-Domain ist erforderlich."
        exit 1
    fi

    print_warning "Domain '$domain' wird entfernt."
    read -p "Fortfahren? [j/N] " confirm

    if [[ "$confirm" =~ ^[jJyY]$ ]]; then
        # Lösche den 3-Zeilen Cookie-Block (domain + authelia_url + default_redirection_url)
        proxy_exec "sudo sed -i \"/domain: '${domain}'/,+2d\" ${config_file}"

        # Authelia neu starten
        echo "Starte Authelia neu..."
        proxy_exec "cd ${AUTHELIA_DIR} && docker compose restart"

        print_success "Domain '$domain' entfernt."
    else
        echo "Abgebrochen."
    fi
}

# === DASHBOARD ===

cmd_dashboard() {
    local subcmd="$1"
    shift 2>/dev/null || true

    case "$subcmd" in
        setup)
            cmd_dashboard_setup "$@"
            ;;
        status)
            cmd_dashboard_status
            ;;
        logs)
            cmd_dashboard_logs "$@"
            ;;
        restart)
            cmd_dashboard_restart
            ;;
        update)
            cmd_dashboard_update
            ;;
        help|"")
            cmd_dashboard_help
            ;;
        *)
            print_error "Unbekannter Dashboard-Befehl: $subcmd"
            cmd_dashboard_help
            exit 1
            ;;
    esac
}

cmd_dashboard_help() {
    echo "=== Dashboard - Web-Oberfläche ==="
    echo ""
    echo "Das Dashboard bietet eine Web-Oberfläche zur Verwaltung aller VPS."
    echo "Es läuft auf dem Proxy und wird über Traefik geroutet."
    echo ""
    echo "Einrichtung:"
    echo "  vps dashboard setup              Interaktive Ersteinrichtung"
    echo ""
    echo "Status & Verwaltung:"
    echo "  vps dashboard status             Container-Status anzeigen"
    echo "  vps dashboard logs [zeilen]      Logs anzeigen (Standard: 50)"
    echo "  vps dashboard restart            Dashboard neu starten"
    echo "  vps dashboard update             Dashboard neu bauen und starten"
    echo ""
    echo "Hinweis: DNS-Eintrag muss auf die Proxy-Public-IP zeigen."
}

cmd_dashboard_setup() {
    echo "=== Dashboard Setup ==="
    echo ""

    # Prüfe ob Traefik installiert ist
    if ! proxy_exec "test -f ${TRAEFIK_DIR}/docker-compose.yml" 2>/dev/null; then
        print_error "Traefik ist nicht installiert. Führe zuerst 'vps traefik setup' aus."
        exit 1
    fi

    # Prüfe ob Docker installiert ist
    if ! proxy_exec "command -v docker" &>/dev/null; then
        print_error "Docker ist nicht installiert."
        exit 1
    fi

    # Prüfe ob webui-Verzeichnis existiert
    if ! proxy_exec "test -d ${DASHBOARD_DIR}" 2>/dev/null; then
        print_error "Dashboard-Verzeichnis ${DASHBOARD_DIR} nicht gefunden."
        exit 1
    fi

    # Domain abfragen
    local dashboard_domain=""
    while [[ -z "$dashboard_domain" ]]; do
        read -p "Dashboard-Domain (z.B. dash.example.de): " dashboard_domain
    done

    # Authelia-Absicherung abfragen (nur wenn Authelia installiert)
    local use_authelia="n"
    if proxy_exec "test -f ${TRAEFIK_DIR}/conf.d/_authelia.yml" 2>/dev/null; then
        echo ""
        read -p "Dashboard mit Authelia absichern? (J/n): " use_authelia
        use_authelia="${use_authelia:-j}"
    fi

    # Middleware bestimmen
    local middlewares=""
    if [[ "$use_authelia" == "j" || "$use_authelia" == "J" ]]; then
        middlewares="authelia@file"
    fi

    # Zusammenfassung
    echo ""
    echo "Zusammenfassung:"
    echo "  Dashboard:  https://$dashboard_domain"
    if [[ -n "$middlewares" ]]; then
        echo "  Authelia:   Ja (authelia@file)"
    else
        echo "  Authelia:   Nein"
    fi
    echo "  Verzeichnis: ${DASHBOARD_DIR}"
    echo ""
    echo "  DNS benötigt:"
    echo "    - $dashboard_domain -> Proxy-Public-IP"
    echo ""
    read -p "Einrichtung starten? (j/n): " confirm
    if [[ "$confirm" != "j" && "$confirm" != "J" ]]; then
        echo "Abgebrochen."
        exit 0
    fi

    echo ""
    echo "Richte Dashboard auf Proxy ($PROXY_IP) ein..."

    # .env Datei erstellen
    echo "Erstelle .env..."
    printf 'DASHBOARD_DOMAIN=%s\nDASHBOARD_MIDDLEWARES=%s\n' \
        "$dashboard_domain" "$middlewares" \
        | proxy_write "${DASHBOARD_DIR}/.env"

    # SSH-Key für Container→Host Verbindung einrichten
    # Das Backend läuft im Docker-Container und muss per SSH auf den Host zugreifen
    echo "Richte SSH-Zugang für Container ein..."
    proxy_exec 'grep -qF "$(cat ~/.ssh/id_ed25519.pub)" ~/.ssh/authorized_keys 2>/dev/null || cat ~/.ssh/id_ed25519.pub >> ~/.ssh/authorized_keys'

    # Container bauen und starten
    echo "Baue und starte Dashboard (das kann etwas dauern)..."
    proxy_exec "cd ${DASHBOARD_DIR} && docker compose -f docker-compose.prod.yml up -d --build"

    # Alte File-Provider-Route entfernen falls vorhanden
    if proxy_exec "ls ${TRAEFIK_DIR}/conf.d/dash*.yml" &>/dev/null; then
        echo "Entferne alte Traefik-File-Provider-Routen..."
        proxy_exec "sudo rm -f ${TRAEFIK_DIR}/conf.d/dash*.yml"
    fi

    echo ""
    print_success "Dashboard eingerichtet!"
    echo ""
    echo "  URL: https://$dashboard_domain"
    echo ""
    echo "  DNS-Eintrag nicht vergessen:"
    echo "    $dashboard_domain -> Proxy-Public-IP"
    echo ""
    echo "  Status prüfen: vps dashboard status"
    echo "  Logs anzeigen:  vps dashboard logs"
}

cmd_dashboard_status() {
    echo "Dashboard-Status auf Proxy ($PROXY_IP):"
    proxy_exec "cd ${DASHBOARD_DIR} && docker compose -f docker-compose.prod.yml ps" 2>/dev/null || print_error "Dashboard ist nicht installiert."
}

cmd_dashboard_logs() {
    local lines="${1:-50}"
    proxy_exec "cd ${DASHBOARD_DIR} && docker compose -f docker-compose.prod.yml logs --tail=${lines}"
}

cmd_dashboard_restart() {
    echo "Starte Dashboard neu..."
    proxy_exec "cd ${DASHBOARD_DIR} && docker compose -f docker-compose.prod.yml restart"
    print_success "Dashboard neu gestartet."
}

cmd_dashboard_update() {
    echo "Aktualisiere Dashboard (Rebuild)..."
    proxy_exec "cd ${DASHBOARD_DIR} && docker compose -f docker-compose.prod.yml up -d --build"
    print_success "Dashboard aktualisiert."
}

# === DEPLOY ===

# Template-Konfiguration laden und validieren
deploy_load_template() {
    local template="$1"
    local template_dir="${TEMPLATES_DIR}/${template}"
    local conf="${template_dir}/template.conf"

    if [[ ! -d "$template_dir" ]]; then
        print_error "Template '$template' nicht gefunden."
        echo "Verfügbare Templates: vps deploy list"
        exit 1
    fi

    if [[ ! -f "$conf" ]]; then
        print_error "Template '$template' hat keine template.conf"
        exit 1
    fi

    # Defaults setzen
    TEMPLATE_NAME=""
    TEMPLATE_DESCRIPTION=""
    TEMPLATE_DEPLOY_DIR=""
    TEMPLATE_REQUIRES_DOCKER=true
    TEMPLATE_REQUIRES_ROUTE=false
    TEMPLATE_ROUTE_PORT=""
    TEMPLATE_VARS=()
    TEMPLATE_DEFAULTS=()
    TEMPLATE_COMPOSE_PROFILES=()
    TEMPLATE_ADDITIONAL_ROUTES=()

    source "$conf"
}

# Variablen interaktiv abfragen
deploy_collect_vars() {
    local -n result_vars=$1
    shift
    local vars=("$@")

    for var_def in "${vars[@]}"; do
        IFS='|' read -r var_name var_desc var_default var_type var_condition <<< "$var_def"

        # Bedingte Variable: nur abfragen wenn Bedingung erfüllt
        # Format: VARIABLE=wert1,wert2
        if [[ -n "$var_condition" ]]; then
            local cond_var="${var_condition%%=*}"
            local cond_vals="${var_condition#*=}"
            local cond_match=false
            IFS=',' read -ra cond_list <<< "$cond_vals"
            for cv in "${cond_list[@]}"; do
                if [[ "${result_vars[$cond_var]}" == "$cv" ]]; then
                    cond_match=true
                    break
                fi
            done
            if [[ "$cond_match" != "true" ]]; then
                continue
            fi
        fi

        local value=""
        if [[ "$var_type" == "generate" ]]; then
            value=$(openssl rand -base64 32 | tr -d '/+=' | head -c 32)
            echo "${var_desc}: (automatisch generiert)"
        elif [[ "$var_type" == "secret" ]]; then
            while [[ -z "$value" ]]; do
                read -s -p "${var_desc}: " value
                echo ""
            done
        elif [[ -n "$var_default" ]]; then
            read -p "${var_desc} [${var_default}]: " value
            [[ -z "$value" ]] && value="$var_default"
        else
            while [[ -z "$value" ]]; do
                read -p "${var_desc}: " value
            done
        fi

        result_vars["$var_name"]="$value"
    done
}

# Template-Dateien substituieren und auf Host deployen
deploy_files() {
    local ip="$1"
    local template_dir="$2"
    local deploy_dir="$3"
    shift 3

    # Assoziatives Array aus den restlichen Argumenten aufbauen
    # Format: KEY=VALUE KEY2=VALUE2 ...
    local -A vars
    while [[ $# -gt 0 ]]; do
        local key="${1%%=*}"
        local val="${1#*=}"
        vars["$key"]="$val"
        shift
    done

    # Verzeichnis erstellen
    host_mkdir "$ip" "$deploy_dir"

    # Alle Dateien im Template verarbeiten (außer template.conf)
    while IFS= read -r file; do
        local rel_path="${file#${template_dir}/}"
        local dest_path="${deploy_dir}/${rel_path}"

        # Unterverzeichnis erstellen falls nötig
        local dest_dir
        dest_dir=$(dirname "$dest_path")
        if [[ "$dest_dir" != "$deploy_dir" ]]; then
            host_mkdir "$ip" "$dest_dir"
        fi

        # Datei lesen und Variablen substituieren
        local content
        content=$(cat "$file")

        for var_name in "${!vars[@]}"; do
            content=$(echo "$content" | sed "s|{{${var_name}}}|${vars[$var_name]}|g")
        done

        echo "$content" | host_write "$ip" "$dest_path"
    done < <(find "$template_dir" -type f ! -name "template.conf" ! -name "authelia.conf" ! -name ".gitkeep")
}

# Verfügbare Templates auflisten
cmd_deploy_list() {
    echo "Verfügbare Templates:"
    echo ""
    printf "%-20s %s\n" "NAME" "BESCHREIBUNG"
    printf "%-20s %s\n" "--------------------" "----------------------------------------"

    for dir in "${TEMPLATES_DIR}"/*/; do
        [[ ! -d "$dir" ]] && continue
        local conf="${dir}template.conf"
        [[ ! -f "$conf" ]] && continue

        local name description
        name=$(basename "$dir")
        TEMPLATE_DESCRIPTION=""
        source "$conf"
        description="$TEMPLATE_DESCRIPTION"

        printf "%-20s %s\n" "$name" "$description"
    done
}

# Deployment auf einem Host anzeigen
cmd_deploy_status() {
    local target="$1"

    if [[ -z "$target" ]]; then
        print_error "Bitte Host angeben: vps deploy status <host>"
        exit 1
    fi

    local ip=$(resolve_host "$target")
    echo "Deployments auf $target ($ip):"
    echo ""

    # Prüfe /opt auf Verzeichnisse mit docker-compose.yml
    local deployments
    deployments=$(ssh_exec "$ip" "find /opt -maxdepth 2 -name 'docker-compose.yml' -type f 2>/dev/null" || true)

    if [[ -z "$deployments" ]]; then
        echo "Keine Deployments gefunden."
        return
    fi

    printf "%-20s %-15s %s\n" "APP" "STATUS" "VERZEICHNIS"
    printf "%-20s %-15s %s\n" "--------------------" "---------------" "--------------------"

    for compose_file in $deployments; do
        local app_dir
        app_dir=$(dirname "$compose_file")
        local app_name
        app_name=$(basename "$app_dir")
        local status
        status=$(ssh_exec "$ip" "cd $app_dir && docker compose ps --format '{{.Status}}' 2>/dev/null | head -1" || echo "unbekannt")

        [[ -z "$status" ]] && status="gestoppt"
        printf "%-20s %-15s %s\n" "$app_name" "$status" "$app_dir"
    done
}

# Deployment entfernen
cmd_deploy_remove() {
    local target="$1"
    local app="$2"

    if [[ -z "$target" ]] || [[ -z "$app" ]]; then
        print_error "Verwendung: vps deploy remove <host> <app>"
        exit 1
    fi

    local ip=$(resolve_host "$target")
    local deploy_dir="/opt/${app}"

    # Prüfe ob Deployment existiert
    if ! ssh_exec "$ip" "test -f ${deploy_dir}/docker-compose.yml" 2>/dev/null; then
        print_error "Kein Deployment '${app}' auf ${target} gefunden."
        exit 1
    fi

    print_warning "WARNUNG: Deployment '${app}' auf ${target} wird entfernt!"
    print_warning "Container werden gestoppt und Daten in ${deploy_dir} gelöscht."
    read -p "Fortfahren? [j/N] " confirm

    if [[ "$confirm" =~ ^[jJyY]$ ]]; then
        echo "Stoppe Container..."
        ssh_exec "$ip" "cd ${deploy_dir} && docker compose down -v" 2>/dev/null || true
        echo "Entferne Dateien..."
        ssh_exec "$ip" "sudo rm -rf ${deploy_dir}"
        print_success "Deployment '${app}' entfernt."
    else
        echo "Abgebrochen."
    fi
}

# Haupt-Deploy-Funktion
cmd_deploy_app() {
    local template="$1"
    local target="$2"

    if [[ -z "$template" ]] || [[ -z "$target" ]]; then
        print_error "Verwendung: vps deploy <template> <host>"
        echo "Beispiel: vps deploy uptime-kuma webserver"
        exit 1
    fi

    local ip=$(resolve_host "$target")
    local template_dir="${TEMPLATES_DIR}/${template}"

    # Template laden
    deploy_load_template "$template"

    local deploy_dir="${TEMPLATE_DEPLOY_DIR:-/opt/${template}}"

    echo "=== Deploy: ${TEMPLATE_NAME:-$template} ==="
    echo "Ziel: $target ($ip)"
    echo "Verzeichnis: $deploy_dir"
    echo ""

    # Prüfe ob bereits deployed
    if ssh_exec "$ip" "test -f ${deploy_dir}/docker-compose.yml" 2>/dev/null; then
        print_warning "${template} ist bereits auf ${target} deployed."
        read -p "Überschreiben? [j/N] " confirm
        if [[ ! "$confirm" =~ ^[jJyY]$ ]]; then
            echo "Abgebrochen."
            exit 0
        fi
        echo "Stoppe bestehende Container..."
        ssh_exec "$ip" "cd ${deploy_dir} && docker compose down" 2>/dev/null || true
    fi

    # Docker sicherstellen
    if [[ "$TEMPLATE_REQUIRES_DOCKER" == "true" ]]; then
        if ! ssh_exec "$ip" "command -v docker" &>/dev/null; then
            echo "Docker nicht gefunden, installiere..."
            cmd_docker_install "$target"
            echo ""
        fi
    fi

    # Variablen abfragen
    local -A collected_vars
    if [[ ${#TEMPLATE_VARS[@]} -gt 0 ]]; then
        echo "Konfiguration:"
        deploy_collect_vars collected_vars "${TEMPLATE_VARS[@]}"
        echo ""
    fi

    # HOST_IP automatisch setzen
    collected_vars["HOST_IP"]="$ip"

    # Template-Defaults setzen (interne Variablen ohne Abfrage)
    if [[ ${#TEMPLATE_DEFAULTS[@]} -gt 0 ]]; then
        for default_def in "${TEMPLATE_DEFAULTS[@]}"; do
            local dkey="${default_def%%=*}"
            local dval="${default_def#*=}"
            collected_vars["$dkey"]="$dval"
        done
    fi

    # Authelia-Integration prüfen
    local use_authelia=false
    if [[ "$TEMPLATE_REQUIRES_ROUTE" == "true" ]] && authelia_is_installed; then
        echo ""
        read -p "Route mit Authelia absichern? [J/n] " auth_confirm
        if [[ ! "$auth_confirm" =~ ^[nN]$ ]]; then
            use_authelia=true
            # Template-spezifische Authelia-Variablen laden
            local authelia_conf="${template_dir}/authelia.conf"
            if [[ -f "$authelia_conf" ]]; then
                local AUTHELIA_TEMPLATE_VARS=()
                source "$authelia_conf"
                for av in "${AUTHELIA_TEMPLATE_VARS[@]}"; do
                    local akey="${av%%=*}"
                    local aval="${av#*=}"
                    collected_vars["$akey"]="$aval"
                done
            fi
        fi
        echo ""
    fi

    # Zusammenfassung
    echo "Zusammenfassung:"
    echo "  Template:   ${TEMPLATE_NAME:-$template}"
    echo "  Ziel:       $target ($ip)"
    echo "  Verzeichnis: $deploy_dir"
    if [[ "$use_authelia" == "true" ]]; then
        echo "  Authelia:   ja"
    fi
    for key in "${!collected_vars[@]}"; do
        [[ "$key" == "HOST_IP" ]] && continue
        # Typ der Variable ermitteln
        local var_type=""
        for var_def in "${TEMPLATE_VARS[@]}"; do
            IFS='|' read -r vn vd vdf vt _vc <<< "$var_def"
            if [[ "$vn" == "$key" ]]; then
                var_type="$vt"
                break
            fi
        done
        if [[ "$var_type" == "secret" ]]; then
            echo "  ${key}: ********"
        else
            echo "  ${key}: ${collected_vars[$key]}"
        fi
    done
    echo ""
    read -p "Deployment starten? [j/N] " confirm
    if [[ ! "$confirm" =~ ^[jJyY]$ ]]; then
        echo "Abgebrochen."
        exit 0
    fi

    echo ""

    # Dateien deployen
    echo "Kopiere Dateien..."
    local var_args=()
    for key in "${!collected_vars[@]}"; do
        var_args+=("${key}=${collected_vars[$key]}")
    done
    deploy_files "$ip" "$template_dir" "$deploy_dir" "${var_args[@]}"

    # Compose Profiles ermitteln
    local profiles=""
    if [[ ${#TEMPLATE_COMPOSE_PROFILES[@]} -gt 0 ]]; then
        local -A active_profiles
        for profile_def in "${TEMPLATE_COMPOSE_PROFILES[@]}"; do
            IFS='|' read -r prof_var prof_val prof_name <<< "$profile_def"
            if [[ "${collected_vars[$prof_var]}" == "$prof_val" ]]; then
                active_profiles["$prof_name"]=1
            fi
        done
        for prof in "${!active_profiles[@]}"; do
            profiles+=" --profile ${prof}"
        done
    fi

    # Container starten
    echo "Starte Container..."
    ssh_exec "$ip" "cd ${deploy_dir} && docker compose${profiles} up -d"

    # Route anlegen
    local route_auth_flag=""
    if [[ "$use_authelia" == "true" ]]; then
        route_auth_flag="--auth"
    fi

    if [[ "$TEMPLATE_REQUIRES_ROUTE" == "true" && -n "${collected_vars[DOMAIN]}" ]]; then
        echo "Lege Traefik-Route an..."
        cmd_route_add $route_auth_flag "${collected_vars[DOMAIN]}" "$target" "${TEMPLATE_ROUTE_PORT}"
    fi

    # Zusätzliche Routen anlegen
    if [[ ${#TEMPLATE_ADDITIONAL_ROUTES[@]} -gt 0 ]]; then
        for route_def in "${TEMPLATE_ADDITIONAL_ROUTES[@]}"; do
            IFS='|' read -r route_var route_port <<< "$route_def"
            if [[ -n "${collected_vars[$route_var]}" ]]; then
                echo "Lege Traefik-Route an (${collected_vars[$route_var]})..."
                cmd_route_add $route_auth_flag "${collected_vars[$route_var]}" "$target" "$route_port"
            fi
        done
    fi

    echo ""
    print_success "${TEMPLATE_NAME:-$template} erfolgreich deployed auf ${target}!"
    if [[ -n "${collected_vars[DOMAIN]}" ]]; then
        echo "Erreichbar unter: https://${collected_vars[DOMAIN]}"
    fi
    # Zusätzliche URLs anzeigen
    if [[ ${#TEMPLATE_ADDITIONAL_ROUTES[@]} -gt 0 ]]; then
        for route_def in "${TEMPLATE_ADDITIONAL_ROUTES[@]}"; do
            IFS='|' read -r route_var route_port <<< "$route_def"
            if [[ -n "${collected_vars[$route_var]}" ]]; then
                echo "Erreichbar unter: https://${collected_vars[$route_var]}"
            fi
        done
    fi

    # Generierte Zugangsdaten einmalig anzeigen
    local has_generated=false
    for var_def in "${TEMPLATE_VARS[@]}"; do
        IFS='|' read -r vn vd vdf vt _vc <<< "$var_def"
        if [[ "$vt" == "generate" && -n "${collected_vars[$vn]}" ]]; then
            has_generated=true
            break
        fi
    done
    if [[ "$has_generated" == "true" ]]; then
        echo ""
        echo "========================================="
        echo "  GENERIERTE ZUGANGSDATEN (jetzt sichern!)"
        echo "========================================="
        for var_def in "${TEMPLATE_VARS[@]}"; do
            IFS='|' read -r vn vd vdf vt _vc <<< "$var_def"
            if [[ "$vt" == "generate" && -n "${collected_vars[$vn]}" ]]; then
                echo "  ${vd}: ${collected_vars[$vn]}"
            fi
        done
        echo "========================================="
    fi
}

# Deploy Hilfe
cmd_deploy_help() {
    cat << 'EOF'
App-Deployment auf VPS

Verwendung: vps deploy <befehl> [optionen]

Befehle:
  <template> <host>       Template auf einen Host deployen
  list                    Verfügbare Templates anzeigen
  status <host>           Deployments auf einem Host anzeigen
  remove <host> <app>     Deployment entfernen
  help                    Diese Hilfe anzeigen

Beispiele:
  vps deploy list                       # Templates anzeigen
  vps deploy uptime-kuma webserver      # Uptime Kuma deployen
  vps deploy status webserver           # Deployments anzeigen
  vps deploy remove webserver uptime-kuma  # Deployment entfernen
EOF
}

# Deploy Unterbefehl-Router
cmd_deploy() {
    local subcmd="$1"
    shift 2>/dev/null || true

    case "$subcmd" in
        list|ls)
            cmd_deploy_list
            ;;
        status)
            cmd_deploy_status "$@"
            ;;
        remove|rm)
            cmd_deploy_remove "$@"
            ;;
        help|--help|-h|"")
            cmd_deploy_help
            ;;
        *)
            # Alles andere ist ein Template-Name
            cmd_deploy_app "$subcmd" "$@"
            ;;
    esac
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

# Führt einen API-Aufruf aus und gibt HTTP-Status + Body zurück (ohne exit bei Fehler)
netcup_api_raw() {
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

    echo "${http_code}"
    echo "$body"
}

# Extrahiert userId aus dem JWT Access-Token
netcup_get_user_id() {
    netcup_load_tokens

    local user_id

    # 1. Tasks-API: executingUser.id aus bisherigen Tasks lesen (zuverlässigste Quelle)
    local tasks
    tasks=$(netcup_api GET "/api/v1/tasks" 2>/dev/null || true)
    if [[ -n "$tasks" ]]; then
        user_id=$(echo "$tasks" | jq -r '
            [.[] | .executingUser.id // empty] |
            map(select(. != null and . > 0)) |
            if length > 0 then .[0] | tostring else empty end
        ' 2>/dev/null)
        if [[ -n "$user_id" && "$user_id" =~ ^[0-9]+$ ]]; then
            echo "$user_id"
            return 0
        fi
    fi

    # 2. JWT-Claims durchprobieren
    local payload
    payload=$(echo "$NETCUP_ACCESS_TOKEN" | cut -d. -f2)
    local pad=$(( 4 - ${#payload} % 4 ))
    if [[ $pad -ne 4 ]]; then
        payload="${payload}$(printf '%0.s=' $(seq 1 $pad))"
    fi
    local decoded
    decoded=$(echo "$payload" | base64 -d 2>/dev/null)

    for claim in userId user_id uid scp_user_id preferred_username; do
        user_id=$(echo "$decoded" | jq -r --arg c "$claim" '.[$c] // empty' 2>/dev/null)
        if [[ -n "$user_id" && "$user_id" =~ ^[0-9]+$ ]]; then
            echo "$user_id"
            return 0
        fi
    done

    # 3. Nichts gefunden - Debug-Ausgabe
    print_error "Konnte numerische userId nicht ermitteln."
    echo "  JWT-Claims:" >&2
    echo "$decoded" | jq -r 'to_entries[] | "    \(.key) = \(.value)"' 2>/dev/null >&2
    exit 1
}

# Pollt einen asynchronen Task bis er fertig ist
netcup_poll_task() {
    local task_uuid="$1"
    local task_name="${2:-Task}"
    local max_polls=360
    local poll=0

    while [[ $poll -lt $max_polls ]]; do
        sleep 5
        ((++poll))

        local response
        response=$(netcup_api GET "/api/v1/tasks/${task_uuid}")

        local state progress
        state=$(echo "$response" | jq -r '.state // "UNKNOWN"')
        progress=$(echo "$response" | jq -r '.taskProgress.progressInPercent // 0' | cut -d. -f1)

        # Fortschritt auf einer Zeile anzeigen
        printf "\r  ${task_name}... %s%% (%s)   " "$progress" "$state"

        case "$state" in
            FINISHED)
                printf "\r  ${task_name}... 100%% (FINISHED)   \n"
                return 0
                ;;
            ERROR|CANCELED|ROLLBACK)
                printf "\r  ${task_name}... %s%% (%s)   \n" "$progress" "$state"
                local msg
                msg=$(echo "$response" | jq -r '.responseError.message // .message // "Unbekannter Fehler"')
                print_error "${task_name} fehlgeschlagen: $msg"
                return 1
                ;;
        esac
    done

    echo ""
    print_error "${task_name}: Zeitüberschreitung nach 30 Minuten."
    return 1
}

# Ermittelt die VLAN-ID aus bestehenden Server-Interfaces
netcup_get_vlan_id() {
    echo "  Suche VLAN-ID in bestehenden Servern..." >&2

    local servers
    servers=$(netcup_api GET "/api/v1/servers")

    local server_ids
    server_ids=$(echo "$servers" | jq -r '.[].id')

    for sid in $server_ids; do
        local info
        info=$(netcup_api GET "/api/v1/servers/${sid}?loadServerLiveInfo=true")

        local vlan_id
        vlan_id=$(echo "$info" | jq -r '
            .serverLiveInfo.interfaces // [] |
            map(select(.vlanInterface == true)) |
            if length > 0 then .[0].vlanId | tostring else empty end
        ')

        if [[ -n "$vlan_id" && "$vlan_id" != "null" && "$vlan_id" != "0" ]]; then
            echo "$vlan_id"
            return 0
        fi
    done

    print_error "Kein CloudVLAN gefunden. Kein bestehender Server hat ein VLAN-Interface."
    return 1
}

# Ermittelt die nächste freie CloudVLAN-IP aus /etc/vps-hosts
netcup_next_free_ip() {
    local used_ips=()

    # Proxy-IP ist immer belegt
    used_ips+=("1")

    # Vergebene IPs aus /etc/vps-hosts sammeln
    if [[ -f "$HOSTS_FILE" ]]; then
        while read -r ip _hostname; do
            [[ -z "$ip" ]] && continue
            # Nur IPs im 10.10.0.x-Bereich
            if [[ "$ip" =~ ^10\.10\.0\.([0-9]+)$ ]]; then
                used_ips+=("${BASH_REMATCH[1]}")
            fi
        done < <(grep -v '^#' "$HOSTS_FILE" | grep -v '^$')
    fi

    # Erste freie IP im Bereich 2-254 finden
    for i in $(seq 2 254); do
        local found=false
        for used in "${used_ips[@]}"; do
            if [[ "$used" -eq "$i" ]]; then
                found=true
                break
            fi
        done
        if [[ "$found" == "false" ]]; then
            echo "${NETWORK_PREFIX}.${i}"
            return 0
        fi
    done

    print_error "Keine freie IP im Bereich ${NETWORK_PREFIX}.2-254 verfügbar."
    return 1
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
        ((++attempt))

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
    local input="$1"

    if [[ -z "$input" ]]; then
        print_error "Bitte Server angeben: vps netcup info <id|hostname|name>"
        exit 1
    fi

    local server_id
    server_id=$(netcup_resolve_server_id "$input")

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

# Löst Server-ID aus Hostname/Name auf
netcup_resolve_server_id() {
    local input="$1"

    # Wenn es eine Zahl ist, direkt als ID verwenden
    if [[ "$input" =~ ^[0-9]+$ ]]; then
        echo "$input"
        return
    fi

    # Per API nach Hostname/Name suchen
    local response
    response=$(netcup_api GET "/api/v1/servers?q=$(printf '%s' "$input" | jq -sRr @uri)")

    local count
    count=$(echo "$response" | jq 'length')

    if [[ "$count" -eq 0 ]]; then
        print_error "Kein Server gefunden für: $input"
        exit 1
    fi

    # Exakten Match auf hostname oder name suchen
    local exact_id
    exact_id=$(echo "$response" | jq -r --arg q "$input" '
        [.[] | select(.hostname == $q or .name == $q or .nickname == $q)] |
        if length == 1 then .[0].id | tostring
        elif length > 1 then "MULTIPLE"
        else empty end')

    if [[ "$exact_id" == "MULTIPLE" ]]; then
        print_error "Mehrere Server gefunden für '$input'. Bitte ID verwenden:"
        echo "$response" | jq -r --arg q "$input" '
            .[] | select(.hostname == $q or .name == $q or .nickname == $q) |
            "  " + (.id | tostring) + "  " + (.name // "-") + "  (" + (.hostname // "-") + ")"'
        exit 1
    fi

    if [[ -n "$exact_id" ]]; then
        echo "$exact_id"
        return
    fi

    # Kein exakter Match - wenn nur ein Ergebnis, das nehmen
    if [[ "$count" -eq 1 ]]; then
        echo "$response" | jq -r '.[0].id | tostring'
        return
    fi

    # Mehrere ungenaue Treffer
    print_error "Mehrere Server gefunden für '$input'. Bitte genauer angeben:"
    echo "$response" | jq -r '.[] | "  " + (.id | tostring) + "  " + (.name // "-") + "  (" + (.hostname // "-") + ")"'
    exit 1
}

# === NETCUP INSTALL ===
cmd_netcup_install() {
    local input="$1"

    if [[ -z "$input" ]]; then
        print_error "Bitte Server angeben: vps netcup install <id|hostname|name>"
        exit 1
    fi

    # Schritt 1: Server identifizieren
    echo "=== VPS Installation ==="
    echo ""

    local server_id
    server_id=$(netcup_resolve_server_id "$input")

    local server_info
    server_info=$(netcup_api GET "/api/v1/servers/${server_id}?loadServerLiveInfo=true")

    local server_name server_hostname server_state public_ip
    server_name=$(echo "$server_info" | jq -r '.name // "-"')
    server_hostname=$(echo "$server_info" | jq -r '.hostname // "-"')
    public_ip=$(echo "$server_info" | jq -r '.ipv4Addresses[0].ip // "-"')
    server_state=$(echo "$server_info" | jq -r '.serverLiveInfo.state // "-"')

    local server_nickname
    server_nickname=$(echo "$server_info" | jq -r '.nickname // empty')

    echo "Server:     ${server_name} (ID: ${server_id})"
    echo "Hostname:   ${server_hostname}"
    echo "Nickname:   ${server_nickname:-"-"}"
    echo "Public IP:  ${public_ip}"
    echo "Status:     ${server_state}"

    # Bestehenden Eintrag in /etc/vps-hosts suchen (Nickname oder Hostname)
    local existing_vlan_ip="" existing_hostname=""
    if [[ -f "$HOSTS_FILE" ]]; then
        for lookup in "$server_nickname" "$server_hostname"; do
            [[ -z "$lookup" || "$lookup" == "-" ]] && continue
            existing_vlan_ip=$(grep -v '^#' "$HOSTS_FILE" | awk -v h="$lookup" '$2 == h {print $1; exit}')
            if [[ -n "$existing_vlan_ip" ]]; then
                existing_hostname="$lookup"
                break
            fi
        done
    fi

    if [[ -n "$existing_vlan_ip" ]]; then
        echo ""
        print_warning "Bestehender Eintrag: ${existing_vlan_ip} ${existing_hostname}"
    fi
    echo ""

    # Schritt 2: Bestätigung
    print_warning "WARNUNG: Alle Daten auf diesem Server werden gelöscht!"
    read -p "Bist du sicher? [j/N] " confirm
    if [[ ! "$confirm" =~ ^[jJyY]$ ]]; then
        echo "Abgebrochen."
        exit 0
    fi
    echo ""

    # Schritt 3: Image-Auswahl
    echo "Lade verfügbare Images..."
    local images
    images=$(netcup_api GET "/api/v1/servers/${server_id}/imageflavours")

    local image_count
    image_count=$(echo "$images" | jq 'length')

    if [[ "$image_count" -eq 0 ]]; then
        print_error "Keine Images verfügbar für diesen Server."
        exit 1
    fi

    echo "Verfügbare Images:"
    echo ""

    # Image-Anzeigenamen: "image.name - name" (z.B. "Debian 13 - minimal")
    local default_idx=0
    local i=0
    echo "$images" | jq -r '.[] | (.image.name // "?") + " - " + (.name // "?")' | while IFS= read -r display_name; do
        local num=$((i + 1))
        echo "  ${num}) ${display_name}"
        i=$((i + 1))
    done

    # Default-Index finden (Debian 13 + Minimal)
    default_idx=$(echo "$images" | jq -r '
        to_entries |
        map(select(
            ((.value.image.name // "") | test("Debian.*13"; "i")) and
            ((.value.name // "") | test("Minimal"; "i"))
        )) |
        if length > 0 then .[0].key + 1 else 0 end
    ' 2>/dev/null || echo "0")

    echo ""
    local image_choice
    if [[ "$default_idx" -gt 0 ]]; then
        local default_name
        default_name=$(echo "$images" | jq -r ".[$((default_idx - 1))] | (.image.name // \"?\") + \" - \" + (.name // \"?\")")
        read -p "Image wählen [${default_idx} - ${default_name}]: " image_choice
        [[ -z "$image_choice" ]] && image_choice="$default_idx"
    else
        read -p "Image wählen: " image_choice
    fi

    if [[ -z "$image_choice" ]] || ! [[ "$image_choice" =~ ^[0-9]+$ ]] || [[ "$image_choice" -lt 1 ]] || [[ "$image_choice" -gt "$image_count" ]]; then
        print_error "Ungültige Auswahl."
        exit 1
    fi

    local image_idx=$((image_choice - 1))
    local image_id image_name
    image_id=$(echo "$images" | jq -r ".[$image_idx].id")
    image_name=$(echo "$images" | jq -r ".[$image_idx] | (.image.name // \"?\") + \" - \" + (.name // \"?\")")
    echo "  -> ${image_name}"
    echo ""

    # Schritt 4: Disk ermitteln (automatisch)
    local disks
    disks=$(netcup_api GET "/api/v1/servers/${server_id}/disks")

    local disk_name disk_size_mib disk_size_gib
    disk_name=$(echo "$disks" | jq -r '.[0].name')
    disk_size_mib=$(echo "$disks" | jq -r '.[0].capacityInMiB // 0')
    disk_size_gib=$(( disk_size_mib / 1024 ))

    echo "Disk: ${disk_name} (${disk_size_gib} GiB)"
    echo ""

    # Schritt 5: Hostname eingeben
    local new_hostname
    local hostname_default="${existing_hostname:-${server_nickname}}"
    [[ "$hostname_default" == "-" ]] && hostname_default=""
    while true; do
        if [[ -n "$hostname_default" ]]; then
            read -p "Hostname [${hostname_default}]: " new_hostname
            [[ -z "$new_hostname" ]] && new_hostname="$hostname_default"
        else
            read -p "Hostname: " new_hostname
        fi
        if [[ -z "$new_hostname" ]]; then
            print_error "Hostname darf nicht leer sein."
            continue
        fi
        if [[ ! "$new_hostname" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]; then
            print_error "Ungültiger Hostname. Erlaubt: Buchstaben, Zahlen, Bindestriche (max 63 Zeichen)."
            continue
        fi
        break
    done
    echo ""

    # Schritt 6: Passwort für master-User
    local password
    while true; do
        read -s -p "Passwort für User 'master': " password
        echo ""
        if [[ ${#password} -lt 8 ]]; then
            print_error "Passwort muss mindestens 8 Zeichen lang sein."
            continue
        fi
        if [[ ! "$password" =~ [A-Z] ]]; then
            print_error "Passwort muss mindestens einen Großbuchstaben enthalten."
            continue
        fi
        if [[ ! "$password" =~ [a-z] ]]; then
            print_error "Passwort muss mindestens einen Kleinbuchstaben enthalten."
            continue
        fi
        if [[ ! "$password" =~ [0-9] ]]; then
            print_error "Passwort muss mindestens eine Zahl enthalten."
            continue
        fi

        local password_confirm
        read -s -p "Passwort bestätigen: " password_confirm
        echo ""
        if [[ "$password" != "$password_confirm" ]]; then
            print_error "Passwörter stimmen nicht überein."
            continue
        fi
        break
    done
    echo ""

    # Schritt 7: CloudVLAN einrichten?
    local setup_vlan=true
    local vlan_ip="" vlan_id=""
    read -p "CloudVLAN einrichten? [J/n] " vlan_choice
    if [[ "$vlan_choice" =~ ^[nN]$ ]]; then
        setup_vlan=false
    fi

    if [[ "$setup_vlan" == "true" ]]; then
        if [[ -n "$existing_vlan_ip" ]]; then
            vlan_ip="$existing_vlan_ip"
            echo "  Bisherige IP: ${vlan_ip}"
        else
            vlan_ip=$(netcup_next_free_ip)
            echo "  Nächste freie IP: ${vlan_ip}"
        fi

        vlan_id=$(netcup_get_vlan_id)
        if [[ -z "$vlan_id" ]]; then
            exit 1
        fi
        echo "  VLAN-ID: ${vlan_id}"
    fi
    echo ""

    # Schritt 8: SSH-Key sicherstellen
    echo "Prüfe SSH-Key..."
    local user_id
    user_id=$(netcup_get_user_id)

    local proxy_pubkey
    proxy_pubkey=$(proxy_exec "cat /home/master/.ssh/id_ed25519.pub")

    if [[ -z "$proxy_pubkey" ]]; then
        print_error "Konnte Proxy-Pubkey nicht lesen (/home/master/.ssh/id_ed25519.pub)."
        exit 1
    fi

    # Pubkey-Fingerprint zum Vergleich (nur der Key-Teil, ohne Kommentar)
    local pubkey_data
    pubkey_data=$(echo "$proxy_pubkey" | awk '{print $1 " " $2}')

    local ssh_keys ssh_key_id
    ssh_keys=$(netcup_api GET "/api/v1/users/${user_id}/ssh-keys")

    # Prüfen ob Key bereits existiert (vergleiche key-Feld)
    ssh_key_id=$(echo "$ssh_keys" | jq -r --arg key "$pubkey_data" '
        [.[] | select(.key | startswith($key))] |
        if length > 0 then .[0].id | tostring else empty end
    ')

    if [[ -z "$ssh_key_id" ]]; then
        echo "  SSH-Key wird hochgeladen..."
        local key_response
        key_response=$(netcup_api POST "/api/v1/users/${user_id}/ssh-keys" \
            -H "Content-Type: application/json" \
            -d "$(jq -n --arg name "proxy-key-$(hostname 2>/dev/null || echo 'vps')" \
                       --arg key "$proxy_pubkey" \
                       '{name: $name, key: $key}')")
        ssh_key_id=$(echo "$key_response" | jq -r '.id')
        echo "  SSH-Key hochgeladen (ID: ${ssh_key_id})"
    else
        echo "  SSH-Key bereits vorhanden (ID: ${ssh_key_id})"
    fi
    echo ""

    # Schritt 9: Zusammenfassung + letzte Bestätigung
    echo "Zusammenfassung:"
    echo "  Server:    ${server_name} (ID: ${server_id})"
    echo "  Image:     ${image_name}"
    echo "  Disk:      ${disk_name} (${disk_size_gib} GiB)"
    echo "  Hostname:  ${new_hostname}"
    echo "  User:      master"
    if [[ "$setup_vlan" == "true" ]]; then
        echo "  CloudVLAN: ${vlan_ip} (VLAN: ${vlan_id})"
    else
        echo "  CloudVLAN: nein"
    fi
    echo ""
    read -p "Installation jetzt starten? [j/N] " confirm
    if [[ ! "$confirm" =~ ^[jJyY]$ ]]; then
        echo "Abgebrochen."
        exit 0
    fi
    echo ""

    # Schritt 10: Post-Install-Script zusammenbauen
    local custom_script
    custom_script='#!/bin/bash
set -e

# SSH Root-Login deaktivieren
sed -i '"'"'s/^#*PermitRootLogin.*/PermitRootLogin no/'"'"' /etc/ssh/sshd_config
systemctl restart sshd

# Sudo ohne Passwort fuer master
echo '"'"'master ALL=(ALL) NOPASSWD:ALL'"'"' > /etc/sudoers.d/master
chmod 440 /etc/sudoers.d/master
'

    if [[ "$setup_vlan" == "true" ]]; then
        custom_script+='
# CloudVLAN-Interface finden
CLOUDVLAN_INTERFACE=""
for iface in ens6 eth1 ens7 eth2; do
    ip link show "$iface" 2>/dev/null && CLOUDVLAN_INTERFACE="$iface" && break
done
[[ -z "$CLOUDVLAN_INTERFACE" ]] && CLOUDVLAN_INTERFACE="ens6"

cat >> /etc/network/interfaces << IFACE

auto ${CLOUDVLAN_INTERFACE}
iface ${CLOUDVLAN_INTERFACE} inet static
    address '"${vlan_ip}"'/24
    mtu 1400
IFACE

ifup "$CLOUDVLAN_INTERFACE" 2>/dev/null || true

# UFW: nur CloudVLAN-Zugriff
apt-get update -qq
apt-get install -y -qq ufw
ufw default deny incoming
ufw default allow outgoing
ufw allow from 10.10.0.0/24
ufw --force enable
'
    else
        custom_script+='
# UFW mit SSH offen
apt-get update -qq
apt-get install -y -qq ufw
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp
ufw allow from 10.10.0.0/24
ufw --force enable
'
    fi

    # Image installieren
    echo "Starte Image-Installation..."
    local install_body
    install_body=$(jq -n \
        --argjson imageFlavourId "$image_id" \
        --arg diskName "$disk_name" \
        --arg hostname "$new_hostname" \
        --arg password "$password" \
        --argjson sshKeyId "$ssh_key_id" \
        --arg customScript "$custom_script" \
        '{
            imageFlavourId: $imageFlavourId,
            diskName: $diskName,
            rootPartitionFullDiskSize: true,
            hostname: $hostname,
            locale: "de_DE.UTF-8",
            timezone: "Europe/Berlin",
            additionalUserUsername: "master",
            additionalUserPassword: $password,
            sshKeyIds: [$sshKeyId],
            sshPasswordAuthentication: false,
            customScript: $customScript,
            emailToExecutingUser: false
        }')

    local install_response
    install_response=$(netcup_api_raw POST "/api/v1/servers/${server_id}/image" \
        -H "Content-Type: application/json" \
        -d "$install_body")

    local install_http_code
    install_http_code=$(echo "$install_response" | head -1)
    local install_body_response
    install_body_response=$(echo "$install_response" | tail -n +2)

    if [[ "$install_http_code" -ge 400 ]]; then
        local msg
        msg=$(echo "$install_body_response" | jq -r '.message // empty' 2>/dev/null)
        print_error "Installation fehlgeschlagen (HTTP ${install_http_code}): ${msg:-$install_body_response}"
        # Feld-Validierungsfehler anzeigen (422)
        local field_errors
        field_errors=$(echo "$install_body_response" | jq -r '.errors[]? | "  \(.field): \(.message)"' 2>/dev/null)
        if [[ -n "$field_errors" ]]; then
            echo "$field_errors" >&2
        fi
        exit 1
    fi

    local task_uuid
    task_uuid=$(echo "$install_body_response" | jq -r '.uuid')

    if [[ -z "$task_uuid" || "$task_uuid" == "null" ]]; then
        print_error "Konnte Task-UUID nicht ermitteln."
        exit 1
    fi

    if ! netcup_poll_task "$task_uuid" "Installation"; then
        print_error "Image-Installation fehlgeschlagen."
        exit 1
    fi
    print_success "Image-Installation abgeschlossen."
    echo ""

    # Schritt 11: CloudVLAN-Interface anlegen (wenn gewählt)
    if [[ "$setup_vlan" == "true" ]]; then
        echo "Prüfe CloudVLAN-Interface..."

        # Live-Info neu laden um aktuelle Interfaces zu prüfen
        local live_info
        live_info=$(netcup_api GET "/api/v1/servers/${server_id}?loadServerLiveInfo=true")

        local has_vlan_interface
        has_vlan_interface=$(echo "$live_info" | jq '
            [.serverLiveInfo.interfaces // [] | .[] | select(.vlanInterface == true)] | length
        ')

        if [[ "$has_vlan_interface" -eq 0 ]]; then
            echo "  Lege CloudVLAN-Interface an..."
            local vlan_response
            vlan_response=$(netcup_api_raw POST "/api/v1/servers/${server_id}/interfaces" \
                -H "Content-Type: application/json" \
                -d "$(jq -n --argjson vlanId "$vlan_id" '{vlanId: $vlanId, networkDriver: "VIRTIO"}')")

            local vlan_http_code
            vlan_http_code=$(echo "$vlan_response" | head -1)
            local vlan_body
            vlan_body=$(echo "$vlan_response" | tail -n +2)

            if [[ "$vlan_http_code" -ge 400 ]]; then
                local msg
                msg=$(echo "$vlan_body" | jq -r '.message // empty' 2>/dev/null)
                print_warning "VLAN-Interface konnte nicht angelegt werden (HTTP ${vlan_http_code}): ${msg:-$vlan_body}"
            else
                local vlan_task_uuid
                vlan_task_uuid=$(echo "$vlan_body" | jq -r '.uuid // empty')

                if [[ -n "$vlan_task_uuid" && "$vlan_task_uuid" != "null" ]]; then
                    if ! netcup_poll_task "$vlan_task_uuid" "VLAN-Interface"; then
                        print_warning "VLAN-Interface-Erstellung fehlgeschlagen."
                    else
                        print_success "VLAN-Interface angelegt."
                    fi
                fi
            fi
        else
            echo "  VLAN-Interface bereits vorhanden."
        fi
        echo ""
    fi

    # Schritt 12: Server starten
    echo "Starte Server..."
    local start_response
    start_response=$(netcup_api_raw PATCH "/api/v1/servers/${server_id}" \
        -H "Content-Type: application/merge-patch+json" \
        -d '{"state": "ON"}')

    local start_http_code
    start_http_code=$(echo "$start_response" | head -1)
    local start_body
    start_body=$(echo "$start_response" | tail -n +2)

    if [[ "$start_http_code" -ge 400 ]]; then
        print_warning "Server konnte nicht gestartet werden. Bitte manuell starten."
    else
        # Prüfen ob async (202) oder sync (200)
        local start_task_uuid
        start_task_uuid=$(echo "$start_body" | jq -r '.uuid // empty' 2>/dev/null)
        if [[ -n "$start_task_uuid" && "$start_task_uuid" != "null" ]]; then
            netcup_poll_task "$start_task_uuid" "Server starten" || true
        fi
        print_success "Server gestartet."
    fi
    echo ""

    # Schritt 13: Hostname + Nickname setzen
    echo "Setze Hostname und Nickname..."
    netcup_api_raw PATCH "/api/v1/servers/${server_id}" \
        -H "Content-Type: application/merge-patch+json" \
        -d "$(jq -n --arg hostname "$new_hostname" '{hostname: $hostname}')" > /dev/null

    netcup_api_raw PATCH "/api/v1/servers/${server_id}" \
        -H "Content-Type: application/merge-patch+json" \
        -d "$(jq -n --arg nickname "$new_hostname" '{nickname: $nickname}')" > /dev/null

    echo "  Hostname: ${new_hostname}"
    echo "  Nickname: ${new_hostname}"
    echo ""

    # Schritt 14: In /etc/vps-hosts eintragen (wenn CloudVLAN)
    if [[ "$setup_vlan" == "true" ]]; then
        echo "Trage in /etc/vps-hosts ein..."

        local hosts_updated=false

        # Alten Eintrag entfernen (alte IP oder alter Hostname)
        if [[ -f "$HOSTS_FILE" ]]; then
            if [[ -n "$existing_vlan_ip" ]]; then
                proxy_exec "sudo sed -i '/^${existing_vlan_ip} /d' ${HOSTS_FILE}" 2>/dev/null
                hosts_updated=true
            fi
            if [[ -n "$existing_hostname" && "$existing_hostname" != "$new_hostname" ]]; then
                proxy_exec "sudo sed -i '/ ${existing_hostname}\$/d' ${HOSTS_FILE}" 2>/dev/null
                hosts_updated=true
            fi
            # Auch neuen Hostname entfernen falls schon mit anderer IP vorhanden
            proxy_exec "sudo sed -i '/ ${new_hostname}\$/d' ${HOSTS_FILE}" 2>/dev/null
        fi

        # Neuen Eintrag hinzufügen
        proxy_exec "echo '${vlan_ip} ${new_hostname}' | sudo tee -a ${HOSTS_FILE} > /dev/null && sudo chown master:master ${HOSTS_FILE}"

        if [[ "$hosts_updated" == "true" ]]; then
            echo "  ${vlan_ip} ${new_hostname} aktualisiert."
        else
            echo "  ${vlan_ip} ${new_hostname} eingetragen."
        fi
        echo ""
    fi

    # Schritt 15: SSH-Verbindungstest (wenn CloudVLAN)
    if [[ "$setup_vlan" == "true" ]]; then
        echo "Warte auf SSH-Verbindung über CloudVLAN..."
        local ssh_ok=false
        for attempt in $(seq 1 12); do
            sleep 10
            printf "\r  Versuch %d/12..." "$attempt"
            if proxy_exec "ssh ${SSH_OPTS} master@${vlan_ip} hostname" &>/dev/null; then
                ssh_ok=true
                break
            fi
        done
        echo ""

        if [[ "$ssh_ok" == "true" ]]; then
            print_success "SSH-Verbindung erfolgreich!"
        else
            print_warning "SSH-Verbindung konnte nicht hergestellt werden. Bitte manuell prüfen."
        fi
        echo ""
    fi

    # Schritt 16: Fertigmeldung
    echo ""
    print_success "VPS '${new_hostname}' ist bereit!"
    if [[ "$setup_vlan" == "true" ]]; then
        echo "  CloudVLAN-IP: ${vlan_ip}"
        echo "  SSH: vps ssh ${new_hostname}"
    fi
    echo "  Öffentliche IP: ${public_ip}"
}

# Netcup Hilfe
cmd_netcup_help() {
    cat << 'EOF'
Netcup Server Control Panel - API Befehle

Verwendung: vps netcup <befehl> [optionen]

Befehle:
  login                 Login via Browser (Device Code Flow)
  logout                Logout und Token widerrufen
  list [suche]          Alle Server auflisten (optional mit Suchbegriff)
  info <server>         Server-Details anzeigen
  install <server>      VPS neu installieren (interaktiv)
  help                  Diese Hilfe anzeigen

Server-Identifikation:
  Bei 'info' und 'install' kann der Server per ID, Hostname oder Name angegeben werden.
  Beispiel: vps netcup info 12345
            vps netcup info v2202501234567
            vps netcup info mein-server

Beispiele:
  vps netcup login              # Login via Browser
  vps netcup list               # Alle Server anzeigen
  vps netcup list webserver     # Server mit 'webserver' suchen
  vps netcup info 12345         # Server-Details per ID
  vps netcup info v2202501234   # Server-Details per Hostname
  vps netcup install 12345      # VPS interaktiv installieren
EOF
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
        install)
            cmd_netcup_install "$@"
            ;;
        help|--help|-h|"")
            cmd_netcup_help
            ;;
        *)
            print_error "Unbekannter Netcup-Befehl: $subcmd"
            echo "Verwende 'vps netcup help' für eine Liste der Befehle."
            exit 1
            ;;
    esac
}

# === BACKUP ===

# Stellt sicher, dass die Backup-Konfiguration existiert
backup_ensure_config() {
    local config_dir
    config_dir="$(dirname "$BACKUP_CONFIG")"
    if [[ ! -d "$config_dir" ]]; then
        mkdir -p "$config_dir"
        chmod 700 "$config_dir"
    fi
}

# Lädt Backup-Konfiguration
backup_load_config() {
    if [[ ! -f "$BACKUP_CONFIG" ]]; then
        return 1
    fi
    source "$BACKUP_CONFIG"
}

# Speichert Backup-Konfiguration
backup_save_config() {
    local storage_host="$1"
    local storage_user="$2"
    local repo_password="$3"
    backup_ensure_config
    cat > "$BACKUP_CONFIG" << EOF
STORAGE_HOST=${storage_host}
STORAGE_USER=${storage_user}
REPO_PASSWORD=${repo_password}
EOF
    chmod 600 "$BACKUP_CONFIG"
}

# Ermittelt Restic-Download-URL für die aktuelle Architektur
backup_restic_url() {
    echo "https://github.com/restic/restic/releases/download/v${RESTIC_VERSION}/restic_${RESTIC_VERSION}_linux_amd64.bz2"
}

# Erkennt Dienste auf einem Host und gibt passende Pre-Backup Hooks zurück
backup_detect_services() {
    local ip="$1"
    local services=""

    # Paperless-ngx
    if ssh_exec "$ip" "test -f /opt/paperless-ngx/docker-compose.yml" 2>/dev/null; then
        services="${services} paperless"
    fi

    # Guacamole
    if ssh_exec "$ip" "test -f /opt/guacamole/docker-compose.yml" 2>/dev/null; then
        services="${services} guacamole"
    fi

    # Uptime Kuma
    if ssh_exec "$ip" "test -f /opt/uptime-kuma/docker-compose.yml" 2>/dev/null; then
        services="${services} uptime-kuma"
    fi

    echo "$services"
}

# Prüft ob ein Host der Proxy ist
backup_is_proxy() {
    local ip="$1"
    [[ "$ip" == "$PROXY_IP" ]]
}

# Generiert die includes-Datei für einen Host
backup_generate_includes() {
    local ip="$1"
    local services="$2"

    if backup_is_proxy "$ip"; then
        cat << 'INCLUDES'
/opt/traefik/
/etc/vps-hosts
/home/master/.ssh/
/home/master/.config/vps-cli/
/opt/vps/
/etc/restic/
INCLUDES
    else
        cat << 'INCLUDES'
/opt/
/etc/restic/
/home/master/.ssh/
/tmp/backups/
INCLUDES
    fi
}

# Generiert Pre-Backup Hook für Paperless
backup_hook_paperless() {
    cat << 'HOOK'
#!/bin/bash
set -euo pipefail
mkdir -p /tmp/backups
echo "Dumpe Paperless-ngx Datenbank..."
docker exec paperless-ngx-db pg_dumpall -U paperless > /tmp/backups/paperless-db.sql
echo "Paperless-ngx Dump abgeschlossen."
HOOK
}

# Generiert Pre-Backup Hook für Guacamole
backup_hook_guacamole() {
    cat << 'HOOK'
#!/bin/bash
set -euo pipefail
mkdir -p /tmp/backups
echo "Dumpe Guacamole Datenbank..."
docker exec guacamole-db pg_dumpall -U guacamole > /tmp/backups/guacamole-db.sql
echo "Guacamole Dump abgeschlossen."
HOOK
}

# Generiert Pre-Backup Hook für Uptime Kuma
backup_hook_uptime_kuma() {
    cat << 'HOOK'
#!/bin/bash
set -euo pipefail
mkdir -p /tmp/backups
echo "Sichere Uptime Kuma Datenbank..."
sqlite3 /opt/uptime-kuma/data/kuma.db ".backup /tmp/backups/kuma.db"
echo "Uptime Kuma Backup abgeschlossen."
HOOK
}

cmd_backup_setup() {
    local target="${1:-}"

    if [[ -z "$target" ]]; then
        print_error "Bitte Host angeben: vps backup setup <host|all>"
        exit 1
    fi

    # Konfiguration laden oder abfragen
    if ! backup_load_config 2>/dev/null; then
        echo ""
        echo "=== Hetzner Storage Box Konfiguration ==="
        echo "Diese Daten werden einmalig abgefragt und gespeichert."
        echo ""

        read -rp "Storage Box Hostname (z.B. uXXXXXX.your-storagebox.de): " storage_host
        read -rp "Storage Box Benutzername (z.B. uXXXXXX): " storage_user

        echo ""
        echo "Repository-Passwort:"
        echo "  1) Automatisch generieren (empfohlen)"
        echo "  2) Manuell eingeben"
        read -rp "Auswahl [1]: " pw_choice
        pw_choice="${pw_choice:-1}"

        if [[ "$pw_choice" == "1" ]]; then
            repo_password=$(openssl rand -base64 32)
            echo ""
            print_warning "Generiertes Passwort (bitte sicher aufbewahren!):"
            echo "  $repo_password"
            echo ""
        else
            read -rsp "Repository-Passwort: " repo_password
            echo ""
            read -rsp "Passwort bestätigen: " repo_password2
            echo ""
            if [[ "$repo_password" != "$repo_password2" ]]; then
                print_error "Passwörter stimmen nicht überein."
                exit 1
            fi
        fi

        backup_save_config "$storage_host" "$storage_user" "$repo_password"
        print_success "Konfiguration gespeichert in ${BACKUP_CONFIG}"

        # SSH-Key für Storage Box generieren
        echo ""
        echo "=== SSH-Key für Storage Box ==="
        local key_file="${HOME}/.ssh/backup_storagebox"
        if [[ ! -f "$key_file" ]]; then
            echo "Generiere SSH-Key für Storage Box..."
            ssh-keygen -t ed25519 -f "$key_file" -N "" -C "vps-backup@$(hostname)"
            print_success "SSH-Key generiert: ${key_file}"
        else
            print_warning "SSH-Key existiert bereits: ${key_file}"
        fi

        echo ""
        echo "Bitte den Public Key auf der Storage Box hinterlegen:"
        echo "  ssh-copy-id -s -p 23 -i ${key_file}.pub ${storage_user}@${storage_host}"
        echo ""
        read -rp "Enter drücken wenn der Key hinterlegt wurde..."
    else
        echo "Backup-Konfiguration geladen."
    fi

    # Setup auf Host(s) ausführen
    if [[ "$target" == "all" ]]; then
        # Proxy zuerst (initialisiert das Repository)
        echo ""
        echo "=== Setup auf Proxy ==="
        _backup_setup_host "$PROXY_IP" "proxy"

        # Dann alle VPS
        while read -r ip hostname; do
            echo ""
            echo "=== Setup auf $hostname ($ip) ==="
            _backup_setup_host "$ip" "$hostname"
        done < <(get_hosts)
    else
        local ip=$(resolve_host "$target")
        _backup_setup_host "$ip" "$target"
    fi
}

# Internes: Setup auf einem einzelnen Host
_backup_setup_host() {
    local ip="$1"
    local name="$2"

    backup_load_config

    local restic_url
    restic_url=$(backup_restic_url)

    # Dienste erkennen
    echo "Erkenne Dienste auf ${name}..."
    local services
    services=$(backup_detect_services "$ip")

    if [[ -n "$services" ]]; then
        echo "  Erkannte Dienste:${services}"
    else
        echo "  Keine speziellen Dienste erkannt."
    fi

    # Includes generieren
    local includes
    includes=$(backup_generate_includes "$ip" "$services")

    # SSH-Key auf den Host kopieren (für Storage Box Zugriff)
    local key_file="${HOME}/.ssh/backup_storagebox"
    echo "Kopiere SSH-Key auf ${name}..."
    ssh_exec "$ip" "sudo mkdir -p /root/.ssh && sudo chmod 700 /root/.ssh" 2>/dev/null || true

    # Key-Dateien übertragen
    cat "$key_file" | host_write "$ip" "/root/.ssh/backup_storagebox"
    ssh_exec "$ip" "sudo chmod 600 /root/.ssh/backup_storagebox"
    cat "${key_file}.pub" | host_write "$ip" "/root/.ssh/backup_storagebox.pub"

    # SSH-Config für Storage Box Port 23
    ssh_exec "$ip" "sudo bash -c 'grep -q \"Host ${STORAGE_HOST}\" /root/.ssh/config 2>/dev/null || cat >> /root/.ssh/config << SSHCONF

Host ${STORAGE_HOST}
    Port 23
    IdentityFile /root/.ssh/backup_storagebox
    StrictHostKeyChecking accept-new
SSHCONF
chmod 600 /root/.ssh/config'"

    # Restic installieren + konfigurieren via SSH
    ssh_exec_stdin "$ip" << SETUP_SCRIPT
set -euo pipefail

# Restic installieren
if ! restic version &>/dev/null; then
    # bunzip2 sicherstellen (auf Minimal-Systemen nicht immer vorhanden)
    if ! command -v bunzip2 &>/dev/null; then
        echo "Installiere bzip2..."
        sudo apt-get update -qq && sudo apt-get install -y -qq bzip2
    fi
    echo "Installiere Restic ${RESTIC_VERSION}..."
    curl -sL "${restic_url}" | bunzip2 | sudo tee /usr/local/bin/restic > /dev/null
    sudo chmod 755 /usr/local/bin/restic
    echo "Restic installiert: \$(restic version)"
else
    echo "Restic bereits installiert: \$(restic version)"
fi

# Konfigurationsverzeichnis anlegen
sudo mkdir -p /etc/restic/pre-backup.d

# Env-Datei
sudo tee /etc/restic/env > /dev/null << ENVFILE
RESTIC_REPOSITORY="sftp:${STORAGE_USER}@${STORAGE_HOST}:./restic-repo"
RESTIC_PASSWORD_FILE="/etc/restic/password"
ENVFILE
sudo chmod 600 /etc/restic/env

# Passwort-Datei
echo '${REPO_PASSWORD}' | sudo tee /etc/restic/password > /dev/null
sudo chmod 600 /etc/restic/password

# Includes
sudo tee /etc/restic/includes > /dev/null << 'INCFILE'
${includes}
INCFILE

# Excludes
sudo tee /etc/restic/excludes > /dev/null << 'EXCLFILE'
/proc
/sys
/dev
/run
/tmp
/var/cache
/var/tmp
*.sock
*.pid
lost+found
EXCLFILE

echo "Konfiguration deployed."
SETUP_SCRIPT

    # Pre-Backup Hooks deployen
    for svc in $services; do
        echo "Deploye Hook: ${svc}..."
        case "$svc" in
            paperless)
                backup_hook_paperless | host_write "$ip" "/etc/restic/pre-backup.d/10-paperless.sh"
                ssh_exec "$ip" "sudo chmod 755 /etc/restic/pre-backup.d/10-paperless.sh"
                ;;
            guacamole)
                backup_hook_guacamole | host_write "$ip" "/etc/restic/pre-backup.d/10-guacamole.sh"
                ssh_exec "$ip" "sudo chmod 755 /etc/restic/pre-backup.d/10-guacamole.sh"
                ;;
            uptime-kuma)
                backup_hook_uptime_kuma | host_write "$ip" "/etc/restic/pre-backup.d/10-uptime-kuma.sh"
                ssh_exec "$ip" "sudo chmod 755 /etc/restic/pre-backup.d/10-uptime-kuma.sh"
                ;;
        esac
    done

    # Backup-Script deployen
    host_write "$ip" "/usr/local/bin/vps-backup.sh" << 'BACKUP_SCRIPT'
#!/bin/bash
#
# VPS Backup Script (Restic + Hetzner Storage Box)
# Wird auf jedem Host nach /usr/local/bin/vps-backup.sh deployed
#
set -euo pipefail

ACTION="${1:-backup}"

# Konfiguration laden
if [[ ! -f /etc/restic/env ]]; then
    echo "Fehler: /etc/restic/env nicht gefunden. Bitte zuerst 'vps backup setup' ausführen." >&2
    exit 1
fi
source /etc/restic/env

export RESTIC_REPOSITORY
export RESTIC_PASSWORD_FILE

case "$ACTION" in
    backup)
        echo "=== Starte Backup auf $(hostname) ==="

        # Pre-Backup Hooks ausführen (Datenbank-Dumps etc.)
        if [[ -d /etc/restic/pre-backup.d ]]; then
            for hook in /etc/restic/pre-backup.d/*.sh; do
                [[ -x "$hook" ]] || continue
                echo "--- Führe Hook aus: $(basename "$hook") ---"
                bash "$hook"
            done
        fi

        # Restic Backup (SSH-Verbindung via /root/.ssh/config)
        restic backup \
            --verbose \
            --exclude-file=/etc/restic/excludes \
            --files-from=/etc/restic/includes \
            --tag auto \
            --host "$(hostname)"

        # Cleanup temporäre Dumps
        rm -rf /tmp/backups/

        echo "=== Backup abgeschlossen ==="
        ;;

    forget)
        echo "=== Starte Retention/Prune auf $(hostname) ==="
        restic forget \
            --keep-daily 7 \
            --keep-weekly 4 \
            --keep-monthly 6 \
            --keep-yearly 1 \
            --host "$(hostname)" \
            --prune
        echo "=== Prune abgeschlossen ==="
        ;;

    check)
        echo "=== Prüfe Repository-Integrität ==="
        restic check
        echo "=== Check abgeschlossen ==="
        ;;

    snapshots)
        restic snapshots --host "$(hostname)"
        ;;

    *)
        echo "Verwendung: vps-backup.sh {backup|forget|check|snapshots}" >&2
        exit 1
        ;;
esac
BACKUP_SCRIPT
    ssh_exec "$ip" "sudo chmod 755 /usr/local/bin/vps-backup.sh"

    # Repository initialisieren (nur wenn noch nicht vorhanden)
    echo "Initialisiere Repository (falls nötig)..."
    ssh_exec "$ip" "sudo bash -c 'source /etc/restic/env && export RESTIC_REPOSITORY RESTIC_PASSWORD_FILE && restic snapshots &>/dev/null || restic init'" 2>/dev/null || true

    # systemd Units deployen
    echo "Deploye systemd Units..."

    # Backup Service
    host_write "$ip" "/etc/systemd/system/restic-backup.service" << 'UNIT'
[Unit]
Description=Restic Backup
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/vps-backup.sh backup
Nice=10
IOSchedulingClass=idle
UNIT

    # Backup Timer
    host_write "$ip" "/etc/systemd/system/restic-backup.timer" << 'UNIT'
[Unit]
Description=Tägliches Restic Backup

[Timer]
OnCalendar=*-*-* 02:00:00
RandomizedDelaySec=1800
Persistent=true

[Install]
WantedBy=timers.target
UNIT

    # Prune Service
    host_write "$ip" "/etc/systemd/system/restic-prune.service" << 'UNIT'
[Unit]
Description=Restic Retention/Prune
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/vps-backup.sh forget
Nice=10
IOSchedulingClass=idle
UNIT

    # Prune Timer
    host_write "$ip" "/etc/systemd/system/restic-prune.timer" << 'UNIT'
[Unit]
Description=Wöchentliches Restic Prune

[Timer]
OnCalendar=Sun *-*-* 04:00:00
Persistent=true

[Install]
WantedBy=timers.target
UNIT

    # Timer aktivieren
    ssh_exec "$ip" "sudo systemctl daemon-reload && sudo systemctl enable --now restic-backup.timer restic-prune.timer"

    print_success "Setup auf ${name} abgeschlossen."

    # Test-Backup ausführen
    echo "Führe Test-Backup aus..."
    ssh_exec "$ip" "sudo /usr/local/bin/vps-backup.sh backup"
    print_success "Test-Backup auf ${name} erfolgreich."
}

cmd_backup_run() {
    local target="${1:-}"

    if [[ -z "$target" ]]; then
        print_error "Bitte Host angeben: vps backup run <host|all>"
        exit 1
    fi

    if [[ "$target" == "all" ]]; then
        # Proxy
        echo "=== Backup auf Proxy ==="
        ssh_exec "$PROXY_IP" "sudo /usr/local/bin/vps-backup.sh backup"
        print_success "Proxy-Backup abgeschlossen."

        # Alle VPS
        while read -r ip hostname; do
            echo ""
            echo "=== Backup auf $hostname ($ip) ==="
            ssh_exec "$ip" "sudo /usr/local/bin/vps-backup.sh backup"
            print_success "Backup auf $hostname abgeschlossen."
        done < <(get_hosts)
    else
        local ip=$(resolve_host "$target")
        echo "=== Backup auf $target ($ip) ==="
        ssh_exec "$ip" "sudo /usr/local/bin/vps-backup.sh backup"
        print_success "Backup auf $target abgeschlossen."
    fi
}

cmd_backup_list() {
    local target="${1:-}"

    if [[ -z "$target" ]]; then
        # Alle Snapshots im Repository anzeigen
        echo "=== Alle Snapshots im Repository ==="
        backup_load_config
        ssh_exec "$PROXY_IP" "sudo bash -c 'source /etc/restic/env && export RESTIC_REPOSITORY RESTIC_PASSWORD_FILE && restic snapshots'"
    else
        local ip=$(resolve_host "$target")
        echo "=== Snapshots für $target ==="
        ssh_exec "$ip" "sudo /usr/local/bin/vps-backup.sh snapshots"
    fi
}

cmd_backup_files() {
    local target="${1:-}"
    local snapshot="${2:-latest}"

    if [[ -z "$target" ]]; then
        print_error "Bitte Host angeben: vps backup files <host> [snapshot]"
        exit 1
    fi

    local ip=$(resolve_host "$target")

    echo "=== Dateien in Snapshot '${snapshot}' auf $target ==="
    ssh_exec "$ip" "sudo bash -c 'source /etc/restic/env && export RESTIC_REPOSITORY RESTIC_PASSWORD_FILE && restic ls ${snapshot} --host \$(hostname)'" | grep -v "^snapshot " | grep -v "^$"
}

cmd_backup_status() {
    local target="${1:-}"

    _backup_show_status() {
        local ip="$1"
        local name="$2"

        echo "--- ${name} (${ip}) ---"

        # Timer-Status
        local timer_status
        timer_status=$(ssh_exec "$ip" "systemctl is-active restic-backup.timer 2>/dev/null" 2>/dev/null || echo "nicht installiert")
        echo "  Timer: ${timer_status}"

        if [[ "$timer_status" == "active" ]]; then
            # Nächster Timer-Lauf
            local next_run
            next_run=$(ssh_exec "$ip" "systemctl show restic-backup.timer --property=NextElapseUSecRealtime --value 2>/dev/null" 2>/dev/null || echo "unbekannt")
            echo "  Nächstes Backup: ${next_run}"

            # Letzter Lauf
            local last_run
            last_run=$(ssh_exec "$ip" "systemctl show restic-backup.service --property=ExecMainExitTimestamp --value 2>/dev/null" 2>/dev/null || echo "unbekannt")
            local last_result
            last_result=$(ssh_exec "$ip" "systemctl show restic-backup.service --property=Result --value 2>/dev/null" 2>/dev/null || echo "unbekannt")
            echo "  Letztes Backup: ${last_run} (${last_result})"
        fi

        # Letzter Snapshot
        local latest_snapshot
        latest_snapshot=$(ssh_exec "$ip" "sudo bash -c 'source /etc/restic/env && export RESTIC_REPOSITORY RESTIC_PASSWORD_FILE && restic snapshots --host \$(hostname) --latest 1 --compact 2>/dev/null'" 2>/dev/null || echo "  Keine Snapshots gefunden")
        echo "  Letzter Snapshot:"
        echo "$latest_snapshot" | sed 's/^/    /'
        echo ""
    }

    if [[ -z "$target" || "$target" == "all" ]]; then
        echo "=== Backup-Status aller Hosts ==="
        echo ""

        # Proxy
        _backup_show_status "$PROXY_IP" "proxy"

        # Alle VPS
        while read -r ip hostname; do
            _backup_show_status "$ip" "$hostname"
        done < <(get_hosts)
    else
        local ip=$(resolve_host "$target")
        echo "=== Backup-Status für $target ==="
        echo ""
        _backup_show_status "$ip" "$target"
    fi
}

cmd_backup_forget() {
    local target="${1:-}"

    if [[ -z "$target" ]]; then
        print_error "Bitte Host angeben: vps backup forget <host|all>"
        exit 1
    fi

    echo "Retention Policy: 7 daily, 4 weekly, 6 monthly, 1 yearly"
    echo ""

    if [[ "$target" == "all" ]]; then
        # Proxy
        echo "=== Prune auf Proxy ==="
        ssh_exec "$PROXY_IP" "sudo /usr/local/bin/vps-backup.sh forget"
        print_success "Prune auf Proxy abgeschlossen."

        # Alle VPS
        while read -r ip hostname; do
            echo ""
            echo "=== Prune auf $hostname ($ip) ==="
            ssh_exec "$ip" "sudo /usr/local/bin/vps-backup.sh forget"
            print_success "Prune auf $hostname abgeschlossen."
        done < <(get_hosts)
    else
        local ip=$(resolve_host "$target")
        echo "=== Prune auf $target ($ip) ==="
        ssh_exec "$ip" "sudo /usr/local/bin/vps-backup.sh forget"
        print_success "Prune auf $target abgeschlossen."
    fi
}

cmd_backup_check() {
    echo "=== Repository-Integrität prüfen ==="
    ssh_exec "$PROXY_IP" "sudo /usr/local/bin/vps-backup.sh check"
    print_success "Check abgeschlossen."
}

cmd_backup_restore() {
    local target=""
    local snapshot=""
    local service=""
    local restore_path=""

    # Argument-Parsing: Positionsargs + --service / --path
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --service)
                service="${2:-}"
                if [[ -z "$service" ]]; then
                    print_error "--service benötigt einen Dienstnamen"
                    exit 1
                fi
                shift 2
                ;;
            --path)
                restore_path="${2:-}"
                if [[ -z "$restore_path" ]]; then
                    print_error "--path benötigt einen Pfad"
                    exit 1
                fi
                shift 2
                ;;
            -*)
                print_error "Unbekannte Option: $1"
                exit 1
                ;;
            *)
                if [[ -z "$target" ]]; then
                    target="$1"
                elif [[ -z "$snapshot" ]]; then
                    snapshot="$1"
                else
                    print_error "Zu viele Argumente: $1"
                    exit 1
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$target" ]]; then
        print_error "Bitte Host angeben: vps backup restore <host> [snapshot] [--service <name>] [--path <pfad>]"
        exit 1
    fi

    if [[ -n "$service" && -n "$restore_path" ]]; then
        print_error "--service und --path können nicht gleichzeitig verwendet werden"
        exit 1
    fi

    local ip=$(resolve_host "$target")

    # Snapshots anzeigen
    echo "=== Verfügbare Snapshots für $target ==="
    ssh_exec "$ip" "sudo /usr/local/bin/vps-backup.sh snapshots"
    echo ""

    # Snapshot auswählen
    if [[ -z "$snapshot" ]]; then
        read -rp "Snapshot-ID eingeben (oder 'latest' für den letzten): " snapshot
    fi
    snapshot="${snapshot:-latest}"

    # Restore-Modus bestimmen und Bestätigung einholen
    echo ""
    if [[ -n "$service" ]]; then
        print_warning "ACHTUNG: Dienst '${service}' auf ${target} ($ip) wird wiederhergestellt!"
    elif [[ -n "$restore_path" ]]; then
        print_warning "ACHTUNG: Pfad '${restore_path}' auf ${target} ($ip) wird wiederhergestellt!"
    else
        print_warning "ACHTUNG: Dies stellt den GESAMTEN VPS ${target} ($ip) wieder her!"
    fi
    print_warning "Vorhandene Dateien werden überschrieben!"
    echo ""
    read -rp "Bist du sicher? (ja/nein): " confirm
    if [[ "$confirm" != "ja" ]]; then
        echo "Abgebrochen."
        return 0
    fi

    echo ""

    if [[ -n "$service" ]]; then
        # === Service-spezifischer Restore ===
        echo "=== Service-Restore: ${service} auf $target ==="

        local include_paths=""
        local db_dump=""
        local db_container=""
        local db_user=""
        local db_type=""
        local compose_dir=""

        case "$service" in
            paperless)
                include_paths="/opt/paperless-ngx /tmp/backups/paperless-db.sql"
                db_dump="/tmp/backups/paperless-db.sql"
                db_container="paperless-ngx-db"
                db_user="paperless"
                db_type="postgres"
                compose_dir="/opt/paperless-ngx"
                ;;
            guacamole)
                include_paths="/opt/guacamole /tmp/backups/guacamole-db.sql"
                db_dump="/tmp/backups/guacamole-db.sql"
                db_container="guacamole-db"
                db_user="guacamole"
                db_type="postgres"
                compose_dir="/opt/guacamole"
                ;;
            uptime-kuma)
                include_paths="/opt/uptime-kuma /tmp/backups/kuma.db"
                db_dump="/tmp/backups/kuma.db"
                db_type="sqlite"
                compose_dir="/opt/uptime-kuma"
                ;;
            *)
                print_error "Unbekannter Dienst: ${service}"
                echo "Verfügbare Dienste: paperless, guacamole, uptime-kuma"
                exit 1
                ;;
        esac

        # Dienst stoppen
        echo "Stoppe ${service}..."
        ssh_exec "$ip" "cd ${compose_dir} && sudo docker compose stop" 2>/dev/null || true

        # Restic Restore mit --include für Service-Pfade
        echo "Stelle Snapshot ${snapshot} für ${service} wieder her..."
        local include_args=""
        for p in $include_paths; do
            include_args="${include_args} --include ${p}"
        done
        ssh_exec "$ip" "sudo bash -c 'source /etc/restic/env && export RESTIC_REPOSITORY RESTIC_PASSWORD_FILE && restic restore ${snapshot} --target / ${include_args}'"

        # Datenbank-Restore
        if ssh_exec "$ip" "test -f ${db_dump}" 2>/dev/null; then
            echo "Stelle ${service} Datenbank wieder her..."
            if [[ "$db_type" == "postgres" ]]; then
                ssh_exec "$ip" "cd ${compose_dir} && sudo docker compose up -d db && sleep 5 && sudo docker exec -i ${db_container} psql -U ${db_user} < ${db_dump}"
            elif [[ "$db_type" == "sqlite" ]]; then
                ssh_exec "$ip" "sudo cp ${db_dump} /opt/uptime-kuma/data/kuma.db"
            fi
            print_success "${service} DB wiederhergestellt."
        fi

        # Dienst starten
        echo "Starte ${service}..."
        ssh_exec "$ip" "cd ${compose_dir} && sudo docker compose up -d"

        echo ""
        print_success "Service-Restore von ${service} auf ${target} abgeschlossen."
        echo ""
        echo "Bitte manuell prüfen:"
        echo "  - Ist ${service} erreichbar?"
        echo "  - Sind die Daten korrekt?"

    elif [[ -n "$restore_path" ]]; then
        # === Pfad-basierter Restore ===
        echo "=== Pfad-Restore: ${restore_path} auf $target ==="

        echo "Stelle Snapshot ${snapshot} für Pfad ${restore_path} wieder her..."
        ssh_exec "$ip" "sudo bash -c 'source /etc/restic/env && export RESTIC_REPOSITORY RESTIC_PASSWORD_FILE && restic restore ${snapshot} --target / --include ${restore_path}'"

        echo ""
        print_success "Pfad-Restore von ${restore_path} auf ${target} abgeschlossen."
        echo ""
        echo "Bitte manuell prüfen:"
        echo "  - Sind die wiederhergestellten Dateien korrekt?"

    else
        # === Ganzer VPS (bestehende Logik) ===
        echo "=== Vollständiger Restore auf $target ==="

        # Docker-Dienste stoppen
        echo "Stoppe Docker-Dienste..."
        ssh_exec "$ip" "sudo docker ps -q 2>/dev/null | xargs -r sudo docker stop" 2>/dev/null || true

        # Restore ausführen
        echo "Stelle Snapshot ${snapshot} wieder her..."
        ssh_exec "$ip" "sudo bash -c 'source /etc/restic/env && export RESTIC_REPOSITORY RESTIC_PASSWORD_FILE && restic restore ${snapshot} --target /'"

        # Datenbank-Restores
        echo "Prüfe Datenbank-Restores..."

        # Paperless-ngx
        if ssh_exec "$ip" "test -f /tmp/backups/paperless-db.sql" 2>/dev/null; then
            echo "Stelle Paperless-ngx Datenbank wieder her..."
            ssh_exec "$ip" "cd /opt/paperless-ngx && sudo docker compose up -d db && sleep 5 && sudo docker exec -i paperless-ngx-db psql -U paperless < /tmp/backups/paperless-db.sql"
            print_success "Paperless-ngx DB wiederhergestellt."
        fi

        # Guacamole
        if ssh_exec "$ip" "test -f /tmp/backups/guacamole-db.sql" 2>/dev/null; then
            echo "Stelle Guacamole Datenbank wieder her..."
            ssh_exec "$ip" "cd /opt/guacamole && sudo docker compose up -d db && sleep 5 && sudo docker exec -i guacamole-db psql -U guacamole < /tmp/backups/guacamole-db.sql"
            print_success "Guacamole DB wiederhergestellt."
        fi

        # Uptime Kuma (SQLite - Datei wurde direkt restored)
        if ssh_exec "$ip" "test -f /tmp/backups/kuma.db" 2>/dev/null; then
            echo "Stelle Uptime Kuma Datenbank wieder her..."
            ssh_exec "$ip" "sudo cp /tmp/backups/kuma.db /opt/uptime-kuma/data/kuma.db"
            print_success "Uptime Kuma DB wiederhergestellt."
        fi

        # Docker-Dienste starten
        echo "Starte Docker-Dienste..."
        ssh_exec "$ip" "for compose in /opt/*/docker-compose.yml; do dir=\$(dirname \"\$compose\"); echo \"Starte \$dir...\"; cd \"\$dir\" && sudo docker compose up -d; done" 2>/dev/null || true

        echo ""
        print_success "Restore auf ${target} abgeschlossen."
        echo ""
        echo "Bitte manuell prüfen:"
        echo "  - Sind alle Dienste erreichbar?"
        echo "  - Sind die Daten korrekt?"
        echo "  - Funktionieren die Datenbanken?"
    fi
}

cmd_backup_help() {
    cat << 'EOF'
VPS Backup (Restic + Hetzner Storage Box)

Verwendung: vps backup <befehl> [optionen]

Befehle:
  setup <host|all>          Backup einrichten (Restic + Config + Timer)
  run <host|all>            Backup jetzt ausführen
  list [host]               Snapshots anzeigen (alle oder pro Host)
  status [host|all]         Backup-Status anzeigen (Timer, letztes Backup)
  forget <host|all>         Retention Policy anwenden + Prune
  check                     Repository-Integrität prüfen
  restore <host> [snapshot] [optionen]  Wiederherstellung
  help                                Diese Hilfe anzeigen

Restore-Optionen:
  --service <name>     Nur einen Dienst wiederherstellen (paperless, guacamole, uptime-kuma)
  --path <pfad>        Nur einen bestimmten Pfad wiederherstellen
  (ohne Optionen)      Ganzer VPS (alle Dienste, alle Daten)

Setup:
  Beim ersten Aufruf von 'vps backup setup' werden die Hetzner Storage Box
  Zugangsdaten abgefragt und ein SSH-Key generiert. Danach wird auf dem
  Zielhost Restic installiert, konfiguriert und ein täglicher Backup-Timer
  eingerichtet.

  Dienste wie Paperless-ngx, Guacamole und Uptime Kuma werden automatisch
  erkannt und passende Pre-Backup Hooks (Datenbank-Dumps) installiert.

Retention Policy:
  --keep-daily 7       Letzte 7 Tage
  --keep-weekly 4      Letzte 4 Wochen
  --keep-monthly 6     Letzte 6 Monate
  --keep-yearly 1      1 Jahres-Snapshot

Automatische Backups:
  - Tägliches Backup um 02:00 Uhr (± 30 Min. zufällige Verzögerung)
  - Wöchentliches Prune am Sonntag um 04:00 Uhr

Beispiele:
  vps backup setup proxy            # Backup auf Proxy einrichten
  vps backup setup all              # Backup auf allen Hosts einrichten
  vps backup run webserver          # Backup sofort ausführen
  vps backup list webserver         # Snapshots für webserver anzeigen
  vps backup files webserver        # Dateien im letzten Snapshot anzeigen
  vps backup status all             # Status aller Hosts
  vps backup forget all             # Alte Snapshots aufräumen
  vps backup check                  # Repository prüfen
  vps backup restore webserver      # Ganzer VPS (interaktiv)
  vps backup restore webserver --service paperless      # Nur Paperless
  vps backup restore webserver latest --path /opt/traefik/  # Nur Pfad

Konfiguration:
  Proxy: ~/.config/vps-cli/backup   (Storage Box Zugangsdaten)
  Hosts: /etc/restic/               (Restic-Konfiguration pro Host)
EOF
}

cmd_backup() {
    local subcmd="$1"
    shift 2>/dev/null || true

    case "$subcmd" in
        setup)
            cmd_backup_setup "$@"
            ;;
        run)
            cmd_backup_run "$@"
            ;;
        list|ls)
            cmd_backup_list "$@"
            ;;
        files)
            cmd_backup_files "$@"
            ;;
        status|st)
            cmd_backup_status "$@"
            ;;
        forget|prune)
            cmd_backup_forget "$@"
            ;;
        check)
            cmd_backup_check "$@"
            ;;
        restore)
            cmd_backup_restore "$@"
            ;;
        help|--help|-h|"")
            cmd_backup_help
            ;;
        *)
            print_error "Unbekannter Backup-Befehl: $subcmd"
            echo "Verwende 'vps backup help' für eine Liste der Befehle."
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
  docker install <host>             Installiert Docker auf einem Host
  docker list [host]                Zeigt Docker-Übersicht oder Container
  docker start <host> <container>   Startet einen Container
  docker stop <host> <container>    Stoppt einen Container
  docker help                       Zeigt Docker-Hilfe
  traefik setup                      Richtet Traefik auf dem Proxy ein (interaktiv)
  traefik status                    Zeigt Traefik-Status
  traefik logs [lines]              Zeigt Traefik-Logs
  traefik restart                   Startet Traefik neu

Routing:
  route add [--auth] <domain> <host> <port>  Fügt eine Route hinzu (--auth für Authelia)
  route list                        Zeigt alle Routes (mit Auth-Status)
  route remove <domain>             Entfernt eine Route
  route auth <domain>               Aktiviert Authelia für eine Route
  route noauth <domain>             Deaktiviert Authelia für eine Route

Authelia (Proxy-Auth):
  authelia setup                    Richtet Authelia auf dem Proxy ein
  authelia status                   Zeigt Authelia-Status
  authelia logs [lines]             Zeigt Authelia-Logs
  authelia restart                  Startet Authelia neu
  authelia user add                 Neuen Benutzer hinzufügen
  authelia user list                Benutzer anzeigen
  authelia user remove <user>       Benutzer entfernen
  authelia domain add [domain]      Cookie-Domain hinzufügen
  authelia domain list              Cookie-Domains anzeigen
  authelia domain remove <domain>   Cookie-Domain entfernen

Dashboard (Web-Oberfläche):
  dashboard setup                   Richtet das Dashboard auf dem Proxy ein
  dashboard status                  Zeigt Dashboard-Status
  dashboard logs [lines]            Zeigt Dashboard-Logs
  dashboard restart                 Startet Dashboard neu
  dashboard update                  Dashboard neu bauen und starten

Deployment:
  deploy <template> <host>          Deployed ein Template auf einen Host
  deploy list                       Zeigt verfügbare Templates
  deploy status <host>              Zeigt Deployments auf einem Host
  deploy remove <host> <app>        Entfernt ein Deployment
  deploy help                       Zeigt Deploy-Hilfe

Netcup API:
  netcup login                      Login via Browser (Device Code Flow)
  netcup logout                     Logout (Token widerrufen)
  netcup list [suche]               Zeigt alle Netcup Server
  netcup info <server>              Zeigt Server-Details (ID, Hostname oder Name)
  netcup install <server>           VPS über API installieren
  netcup help                       Zeigt Netcup-Hilfe mit allen Details

Backup (Restic + Hetzner Storage Box):
  backup setup <host|all>           Backup einrichten (Restic + Timer)
  backup run <host|all>             Backup jetzt ausführen
  backup list [host]                Snapshots anzeigen
  backup files <host> [snapshot]    Dateien in Snapshot anzeigen
  backup status [host|all]          Backup-Status anzeigen
  backup forget <host|all>          Alte Snapshots aufräumen (Prune)
  backup check                      Repository-Integrität prüfen
  backup restore <host> [snapshot] [--service|--path]  Wiederherstellung
  backup help                       Zeigt Backup-Hilfe

  help                              Zeigt diese Hilfe

Beispiele:
  vps scan                          # Netzwerk scannen
  vps list                          # Alle VPS anzeigen
  vps status webserver              # Status eines VPS
  vps docker install proxy           # Docker auf Proxy installieren
  vps docker list webserver          # Container auf VPS anzeigen
  vps docker stop webserver myapp    # Container stoppen
  vps traefik setup                 # Traefik einrichten (interaktiv)
  vps route add app.de webserver 80       # Route hinzufügen
  vps route add --auth app.de ws 80      # Route mit Authelia
  vps route auth app.de                  # Authelia für Route aktivieren
  vps route list                         # Routes anzeigen
  vps authelia setup                     # Authelia einrichten
  vps authelia user add                  # Benutzer hinzufügen
  vps authelia user list                 # Benutzer anzeigen
  vps authelia domain add privat.de      # Weitere Domain hinzufügen
  vps authelia domain list               # Domains anzeigen
  vps dashboard setup                    # Dashboard einrichten
  vps dashboard status                   # Dashboard-Status anzeigen
  vps deploy list                   # Verfügbare Templates
  vps deploy uptime-kuma webserver  # App deployen
  vps deploy status webserver       # Deployments anzeigen
  vps netcup login                  # Login via Browser
  vps netcup list                   # Netcup Server auflisten
  vps netcup info v2202501234       # Server-Details (per Hostname)
  vps netcup install 12345          # VPS interaktiv installieren
  vps backup setup proxy             # Backup auf Proxy einrichten
  vps backup setup all               # Backup auf allen Hosts
  vps backup run webserver           # Backup sofort ausführen
  vps backup status all              # Backup-Status anzeigen
  vps backup restore webserver       # Ganzer VPS wiederherstellen
  vps backup restore ws --service paperless  # Nur Paperless

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
        deploy)
            cmd_deploy "$@"
            ;;
        authelia)
            cmd_authelia "$@"
            ;;
        dashboard)
            cmd_dashboard "$@"
            ;;
        netcup)
            cmd_netcup "$@"
            ;;
        backup)
            cmd_backup "$@"
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
