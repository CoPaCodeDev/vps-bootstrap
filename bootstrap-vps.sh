#!/bin/bash
#
# Bootstrap-Script für Netcup VPS mit CloudVLAN (Debian 13)
#

###############################################################################
# KONFIGURATION - Hier anpassen
###############################################################################

CLOUDVLAN_IP="10.10.0.X"  # <-- Hier die IP eintragen (z.B. 10.10.0.1, 10.10.0.2, etc.)
HOSTNAME="mein-vps"       # <-- Hier den Hostnamen eintragen (z.B. vps1, webserver, etc.)

# Proxy Public Key (ermöglicht SSH-Zugriff vom Proxy)
PROXY_PUBKEY="ssh-ed25519 XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX proxy@cloudvlan"

###############################################################################
# Ab hier nichts mehr ändern
###############################################################################

# Validierung
[[ "$CLOUDVLAN_IP" == "10.10.0.X" ]] && exit 1
[[ "$HOSTNAME" == "mein-vps" || -z "$HOSTNAME" ]] && exit 1
[[ "$CLOUDVLAN_IP" =~ ^10\.10\.0\.([1-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-4])$ ]] || exit 1

# User master als Admin konfigurieren
usermod -aG sudo master
echo "master ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/master
chmod 440 /etc/sudoers.d/master

# Hostname setzen
hostnamectl set-hostname "$HOSTNAME"
echo "$HOSTNAME" > /etc/hostname
sed -i "/127.0.1.1/d" /etc/hosts
echo "127.0.1.1    $HOSTNAME" >> /etc/hosts
echo "${CLOUDVLAN_IP}    ${HOSTNAME}-vlan" >> /etc/hosts

# CloudVLAN Interface finden
CLOUDVLAN_INTERFACE=""
for iface in ens6 eth1 ens7 eth2; do
    ip link show "$iface" &>/dev/null && CLOUDVLAN_INTERFACE="$iface" && break
done
[[ -z "$CLOUDVLAN_INTERFACE" ]] && CLOUDVLAN_INTERFACE="ens6"

# CloudVLAN konfigurieren
cat >> /etc/network/interfaces << EOF

auto ${CLOUDVLAN_INTERFACE}
iface ${CLOUDVLAN_INTERFACE} inet static
    address ${CLOUDVLAN_IP}/24
    mtu 1400
EOF

ifup "$CLOUDVLAN_INTERFACE" 2>/dev/null

# UFW Firewall installieren und konfigurieren
apt-get update -qq
apt-get install -y -qq ufw

# Defaults: Ausgehend erlauben, Eingehend blockieren
ufw default deny incoming
ufw default allow outgoing

# Nur Verbindungen aus dem CloudVLAN erlauben
ufw allow from 10.10.0.0/24

# UFW aktivieren
ufw --force enable

# Proxy SSH-Key installieren (ermöglicht Zugriff vom Proxy)
mkdir -p /home/master/.ssh
echo "$PROXY_PUBKEY" >> /home/master/.ssh/authorized_keys
chown -R master:master /home/master/.ssh
chmod 700 /home/master/.ssh
chmod 600 /home/master/.ssh/authorized_keys
