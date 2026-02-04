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
echo "[1/7] User master konfiguriert"

# SSH Root-Login deaktivieren
sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
systemctl restart sshd
echo "[2/7] SSH Root-Login deaktiviert"

# Hostname setzen
hostnamectl set-hostname "$HOSTNAME"
echo "$HOSTNAME" > /etc/hostname
sed -i "/127.0.1.1/d" /etc/hosts
echo "127.0.1.1    $HOSTNAME" >> /etc/hosts
echo "${CLOUDVLAN_IP}    ${HOSTNAME}-vlan" >> /etc/hosts
echo "[3/7] Hostname gesetzt: $HOSTNAME"

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
echo "[4/7] CloudVLAN konfiguriert: $CLOUDVLAN_INTERFACE -> $CLOUDVLAN_IP"

# UFW Firewall installieren und konfigurieren
apt-get update -qq
apt-get install -y -qq ufw
echo "[5/7] Firewall wird konfiguriert..."

# fail2ban installieren (SSH Brute-Force Schutz)
apt-get install -y -qq fail2ban
systemctl enable fail2ban
systemctl start fail2ban
echo "[6/7] fail2ban installiert"

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
echo "[7/7] Firewall aktiviert"
echo ""
echo "=== Fertig ==="
echo "CloudVLAN IP: $CLOUDVLAN_IP"
echo "Hostname: $HOSTNAME"
echo ""
echo "Nächster Schritt: setup-proxy-key.sh ausführen"
