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

    # Suche in Hosts-Datei
    check_hosts_file
    local ip=$(grep -v '^#' "$HOSTS_FILE" | awk -v host="$input" '$2 == host {print $1; exit}')

    if [[ -z "$ip" ]]; then
        print_error "Host '$input' nicht gefunden in $HOSTS_FILE"
        exit 1
    fi

    echo "$ip"
}

# SSH-Befehl auf Host ausführen
ssh_exec() {
    local ip="$1"
    shift
    ssh $SSH_OPTS "${SSH_USER}@${ip}" "$@"
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

    updates=$(ssh_exec "$ip" "apt list --upgradable 2>/dev/null | grep -c upgradable || echo 0" 2>/dev/null || echo "?")
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

# === HELP ===
cmd_help() {
    cat << 'EOF'
VPS Management CLI

Verwendung: vps <befehl> [optionen]

Befehle:
  scan              Scannt das Netzwerk nach erreichbaren VPS
  list              Zeigt alle konfigurierten VPS
  status [host]     Zeigt Update-Status, Reboot-Pending, Load
  update [host]     Führt apt update && apt upgrade aus
  reboot <host>     Startet einen VPS neu (mit Bestätigung)
  exec <host> <cmd> Führt Befehl auf VPS aus
  ssh <host>        Öffnet interaktive SSH-Session
  help              Zeigt diese Hilfe

Beispiele:
  vps scan                    # Netzwerk scannen
  vps list                    # Alle VPS anzeigen
  vps status                  # Status aller VPS
  vps status webserver        # Status eines VPS
  vps update database         # Database-Server aktualisieren
  vps exec webserver "df -h"  # Befehl ausführen
  vps ssh webserver           # SSH-Verbindung öffnen

Konfiguration:
  Hosts-Datei: /etc/vps-hosts
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
