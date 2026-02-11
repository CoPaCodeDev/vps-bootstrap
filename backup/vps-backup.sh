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
