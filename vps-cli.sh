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

    source "$conf"
}

# Variablen interaktiv abfragen
deploy_collect_vars() {
    local -n result_vars=$1
    shift
    local vars=("$@")

    for var_def in "${vars[@]}"; do
        IFS='|' read -r var_name var_desc var_default var_type <<< "$var_def"

        local value=""
        if [[ "$var_type" == "secret" ]]; then
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
    done < <(find "$template_dir" -type f ! -name "template.conf" ! -name ".gitkeep")
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

    # Zusammenfassung
    echo "Zusammenfassung:"
    echo "  Template:   ${TEMPLATE_NAME:-$template}"
    echo "  Ziel:       $target ($ip)"
    echo "  Verzeichnis: $deploy_dir"
    for key in "${!collected_vars[@]}"; do
        [[ "$key" == "HOST_IP" ]] && continue
        # Secrets nicht anzeigen
        local is_secret=false
        for var_def in "${TEMPLATE_VARS[@]}"; do
            IFS='|' read -r vn vd vdf vt <<< "$var_def"
            if [[ "$vn" == "$key" && "$vt" == "secret" ]]; then
                is_secret=true
                break
            fi
        done
        if [[ "$is_secret" == "true" ]]; then
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

    # Container starten
    echo "Starte Container..."
    ssh_exec "$ip" "cd ${deploy_dir} && docker compose up -d"

    # Route anlegen
    if [[ "$TEMPLATE_REQUIRES_ROUTE" == "true" && -n "${collected_vars[DOMAIN]}" ]]; then
        echo "Lege Traefik-Route an..."
        cmd_route_add "${collected_vars[DOMAIN]}" "$target" "${TEMPLATE_ROUTE_PORT}"
    fi

    echo ""
    print_success "${TEMPLATE_NAME:-$template} erfolgreich deployed auf ${target}!"
    if [[ -n "${collected_vars[DOMAIN]}" ]]; then
        echo "Erreichbar unter: https://${collected_vars[DOMAIN]}"
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

    # JWT-Payload ist der 2. Teil (Base64-kodiert)
    local payload
    payload=$(echo "$NETCUP_ACCESS_TOKEN" | cut -d. -f2)

    # Base64-Padding korrigieren
    local pad=$(( 4 - ${#payload} % 4 ))
    if [[ $pad -ne 4 ]]; then
        payload="${payload}$(printf '%0.s=' $(seq 1 $pad))"
    fi

    local decoded
    decoded=$(echo "$payload" | base64 -d 2>/dev/null)

    # Claims durchprobieren: userId, user_id, sub
    local user_id
    user_id=$(echo "$decoded" | jq -r '.userId // empty' 2>/dev/null)
    if [[ -z "$user_id" ]]; then
        user_id=$(echo "$decoded" | jq -r '.user_id // empty' 2>/dev/null)
    fi
    if [[ -z "$user_id" ]]; then
        user_id=$(echo "$decoded" | jq -r '.sub // empty' 2>/dev/null)
    fi

    if [[ -z "$user_id" ]]; then
        print_error "Konnte userId nicht aus dem Token extrahieren."
        exit 1
    fi

    echo "$user_id"
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

# Ermittelt die VLAN-ID des Benutzers
netcup_get_vlan_id() {
    local user_id="$1"

    local response
    response=$(netcup_api GET "/api/v1/users/${user_id}/vlans")

    local count
    count=$(echo "$response" | jq 'length')

    if [[ "$count" -eq 0 ]]; then
        print_error "Kein CloudVLAN gefunden. Bitte zuerst ein VLAN im SCP anlegen."
        return 1
    fi

    if [[ "$count" -eq 1 ]]; then
        echo "$response" | jq -r '.[0].id'
        return 0
    fi

    # Mehrere VLANs: Benutzer wählen lassen
    echo "Mehrere CloudVLANs gefunden:" >&2
    echo "" >&2
    local i=1
    echo "$response" | jq -r '.[] | "\(.id)\t\(.name // "-")"' | while IFS=$'\t' read -r vid vname; do
        echo "  $i) VLAN $vid ($vname)" >&2
        ((++i))
    done

    local choice
    read -p "Auswahl [1]: " choice >&2
    [[ -z "$choice" ]] && choice=1

    echo "$response" | jq -r ".[$((choice - 1))].id"
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

    echo "Server:     ${server_name} (ID: ${server_id})"
    echo "Hostname:   ${server_hostname}"
    echo "Public IP:  ${public_ip}"
    echo "Status:     ${server_state}"
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

    # Default erkennen (Debian 13 Minimal)
    local default_idx=0
    local i=0
    echo "$images" | jq -r '.[].name' | while IFS= read -r name; do
        local num=$((i + 1))
        echo "  ${num}) ${name}"
        i=$((i + 1))
    done

    # Default-Index finden
    default_idx=$(echo "$images" | jq -r '
        [range(length)] as $indices |
        [$indices[] | select(
            (.[$indices[.]] | .name) as $n |
            ($n | test("Debian.*13"; "i")) and ($n | test("Minimal"; "i"))
        )] |
        if length > 0 then .[0] + 1 else 0 end
    ' 2>/dev/null || echo "0")

    # Fallback: jq-Ausdruck vereinfacht
    if [[ "$default_idx" == "0" || -z "$default_idx" ]]; then
        default_idx=$(echo "$images" | jq -r '
            to_entries |
            map(select(.value.name | test("Debian.*13"; "i")) | select(.value.name | test("Minimal"; "i"))) |
            if length > 0 then .[0].key + 1 else 0 end
        ' 2>/dev/null || echo "0")
    fi

    echo ""
    local image_choice
    if [[ "$default_idx" -gt 0 ]]; then
        local default_name
        default_name=$(echo "$images" | jq -r ".[$((default_idx - 1))].name")
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
    image_name=$(echo "$images" | jq -r ".[$image_idx].name")
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
    while true; do
        read -p "Hostname: " new_hostname
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
        vlan_ip=$(netcup_next_free_ip)
        echo "  Nächste freie IP: ${vlan_ip}"

        local user_id
        user_id=$(netcup_get_user_id)

        vlan_id=$(netcup_get_vlan_id "$user_id")
        if [[ -z "$vlan_id" ]]; then
            exit 1
        fi
        echo "  VLAN-ID: ${vlan_id}"
    fi
    echo ""

    # Schritt 8: SSH-Key sicherstellen
    echo "Prüfe SSH-Key..."
    local user_id
    if [[ -z "${user_id:-}" ]]; then
        user_id=$(netcup_get_user_id)
    fi

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
            locale: "de_DE",
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

        local interfaces
        interfaces=$(netcup_api GET "/api/v1/servers/${server_id}/interfaces")

        local has_vlan_interface
        has_vlan_interface=$(echo "$interfaces" | jq '[.[] | select(.vlanInterface == true)] | length')

        if [[ "$has_vlan_interface" -eq 0 ]]; then
            echo "  Lege CloudVLAN-Interface an..."
            local vlan_response
            vlan_response=$(netcup_api_raw POST "/api/v1/servers/${server_id}/interfaces" \
                -H "Content-Type: application/merge-patch+json" \
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

        # Prüfen ob IP oder Hostname schon vorhanden
        local already_exists=false
        if [[ -f "$HOSTS_FILE" ]]; then
            if grep -q "^${vlan_ip} " "$HOSTS_FILE" 2>/dev/null || \
               grep -q " ${new_hostname}$" "$HOSTS_FILE" 2>/dev/null; then
                already_exists=true
            fi
        fi

        if [[ "$already_exists" == "true" ]]; then
            print_warning "  IP oder Hostname bereits in ${HOSTS_FILE} vorhanden. Übersprungen."
        else
            proxy_exec "echo '${vlan_ip} ${new_hostname}' | sudo tee -a ${HOSTS_FILE}" > /dev/null
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
  route add <domain> <host> <port>  Fügt eine Route hinzu
  route list                        Zeigt alle Routes
  route remove <domain>             Entfernt eine Route

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

  help                              Zeigt diese Hilfe

Beispiele:
  vps scan                          # Netzwerk scannen
  vps list                          # Alle VPS anzeigen
  vps status webserver              # Status eines VPS
  vps docker install proxy           # Docker auf Proxy installieren
  vps docker list webserver          # Container auf VPS anzeigen
  vps docker stop webserver myapp    # Container stoppen
  vps traefik setup                 # Traefik einrichten (interaktiv)
  vps route add app.de webserver 80 # Route hinzufügen
  vps route list                    # Routes anzeigen
  vps deploy list                   # Verfügbare Templates
  vps deploy uptime-kuma webserver  # App deployen
  vps deploy status webserver       # Deployments anzeigen
  vps netcup login                  # Login via Browser
  vps netcup list                   # Netcup Server auflisten
  vps netcup info v2202501234       # Server-Details (per Hostname)
  vps netcup install 12345          # VPS interaktiv installieren

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
