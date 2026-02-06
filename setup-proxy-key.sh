#!/bin/bash
set -e
#
# Generiert SSH-Keypair für User master auf dem Proxy
# Ermöglicht SSH-Zugriff vom Proxy auf alle VPS im CloudVLAN
#

# Root-Check
if [[ $EUID -ne 0 ]]; then
    echo "Fehler: Dieses Script muss als root ausgeführt werden."
    echo "  sudo bash $0"
    exit 1
fi

echo "Generiere SSH-Keypair für master..."

mkdir -p /home/master/.ssh
ssh-keygen -t ed25519 -f /home/master/.ssh/id_ed25519 -N "" -C "proxy@cloudvlan"
chown -R master:master /home/master/.ssh
chmod 700 /home/master/.ssh
chmod 600 /home/master/.ssh/id_ed25519

echo ""
echo "=== PUBLIC KEY (in bootstrap-vps.sh eintragen) ==="
echo ""
cat /home/master/.ssh/id_ed25519.pub
echo ""
