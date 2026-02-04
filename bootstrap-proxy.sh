#!/bin/bash
#
# Bootstrap-Script für Proxy-VPS mit CloudVLAN (Debian 13)
# Erlaubt öffentlichen Zugang für SSH, HTTP, HTTPS
#

###############################################################################
# FESTE WERTE - Nicht ändern
###############################################################################

CLOUDVLAN_IP="10.10.0.1"
HOSTNAME="proxy"

###############################################################################
# Ab hier nichts mehr ändern
###############################################################################

echo "=== Proxy Bootstrap ==="
echo ""

# User master als Admin konfigurieren
usermod -aG sudo master
echo "master ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/master
chmod 440 /etc/sudoers.d/master
echo "[1/5] User master konfiguriert"

# Hostname setzen
hostnamectl set-hostname "$HOSTNAME"
echo "$HOSTNAME" > /etc/hostname
sed -i "/127.0.1.1/d" /etc/hosts
echo "127.0.1.1    $HOSTNAME" >> /etc/hosts
echo "${CLOUDVLAN_IP}    ${HOSTNAME}-vlan" >> /etc/hosts
echo "[2/5] Hostname gesetzt: $HOSTNAME"

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
echo "[3/5] CloudVLAN konfiguriert: $CLOUDVLAN_INTERFACE -> $CLOUDVLAN_IP"

# UFW Firewall installieren und konfigurieren
apt-get update -qq
apt-get install -y -qq ufw
echo "[4/5] Firewall wird konfiguriert..."

# Defaults: Ausgehend erlauben, Eingehend blockieren
ufw default deny incoming
ufw default allow outgoing

# SSH von überall erlauben (öffentlicher Zugang)
ufw allow 22/tcp

# HTTP von überall erlauben
ufw allow 80/tcp

# HTTPS von überall erlauben
ufw allow 443/tcp

# Alles aus dem CloudVLAN erlauben
ufw allow from 10.10.0.0/24

# UFW aktivieren
ufw --force enable
echo "[5/5] Firewall aktiviert"
echo ""
echo "=== Fertig ==="
echo "CloudVLAN IP: $CLOUDVLAN_IP"
echo "Hostname: $HOSTNAME"
echo ""
echo "Nächster Schritt: setup-proxy-key.sh ausführen"
