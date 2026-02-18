#!/bin/bash
set -e
#
# Bootstrap-Script für Proxy-VPS mit CloudVLAN (Debian 13)
# Erlaubt öffentlichen Zugang für SSH, HTTP, HTTPS
#

# Root-Check
if [[ $EUID -ne 0 ]]; then
    echo "Fehler: Dieses Script muss als root ausgeführt werden."
    echo "  sudo bash $0"
    exit 1
fi

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
echo "[1/11] User master konfiguriert"

# SSH härten: Root-Login und Passwort-Authentifizierung deaktivieren
sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
systemctl restart sshd
echo "[2/11] SSH gehärtet (Root-Login + Passwort deaktiviert)"

# Hostname setzen
hostnamectl set-hostname "$HOSTNAME"
echo "$HOSTNAME" > /etc/hostname
sed -i "/127.0.1.1/d" /etc/hosts
echo "127.0.1.1    $HOSTNAME" >> /etc/hosts
echo "${CLOUDVLAN_IP}    ${HOSTNAME}-vlan" >> /etc/hosts
echo "[3/11] Hostname gesetzt: $HOSTNAME"

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
echo "[4/11] CloudVLAN konfiguriert: $CLOUDVLAN_INTERFACE -> $CLOUDVLAN_IP"

# UFW Firewall und Abhängigkeiten installieren
apt-get update -qq
apt-get install -y -qq ufw jq curl samba-common-bin
echo "[5/11] Firewall wird konfiguriert..."

# fail2ban installieren (SSH Brute-Force Schutz)
apt-get install -y -qq fail2ban
systemctl enable fail2ban
systemctl start fail2ban
echo "[6/11] fail2ban installiert"

# Automatische Sicherheits-Updates
apt-get install -y -qq unattended-upgrades
cat > /etc/apt/apt.conf.d/50unattended-upgrades << 'UUEOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
};
Unattended-Upgrade::Automatic-Reboot "false";
UUEOF
systemctl enable unattended-upgrades
echo "[7/11] Automatische Sicherheits-Updates aktiviert"

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
echo "[8/11] Firewall aktiviert"

# Git und GitHub CLI installieren
apt-get install -y -qq git
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg 2>/dev/null
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli.list > /dev/null
apt-get update -qq
apt-get install -y -qq gh
echo "[9/11] GitHub CLI installiert"

# GitHub Authentifizierung (Device-Code)
echo ""
echo "=== GitHub Authentifizierung ==="
echo "Gleich wird ein Code angezeigt."
echo "Öffne https://github.com/login/device auf deinem Handy/PC"
echo "und gib den Code dort ein."
echo ""
read -p "Drücke ENTER um fortzufahren..."

if gh auth login --git-protocol https --web; then
    echo "[10/11] GitHub authentifiziert"

    # Repository klonen
    if gh repo clone CoPaCodeDev/vps-bootstrap /opt/vps; then
        # VPS-CLI einrichten
        chmod +x /opt/vps/vps-cli.sh
        ln -sf /opt/vps/vps-cli.sh /usr/local/bin/vps
        chown -R master:master /opt/vps
        echo "[11/11] VPS-CLI eingerichtet"

        echo ""
        echo "=== Fertig ==="
        echo "CloudVLAN IP: $CLOUDVLAN_IP"
        echo "Hostname: $HOSTNAME"
        echo ""
        echo "Repository: /opt/vps"
        echo "VPS-CLI: vps help"
        echo ""
        echo "Nächster Schritt: setup-proxy-key.sh ausführen"
        echo "  sudo bash /opt/vps/setup-proxy-key.sh"
    else
        echo "[!] Repository konnte nicht geklont werden"
        echo ""
        echo "=== Teilweise fertig ==="
        echo "CloudVLAN IP: $CLOUDVLAN_IP"
        echo "Hostname: $HOSTNAME"
        echo ""
        echo "Manuelles Setup:"
        echo "  gh repo clone CoPaCodeDev/vps-bootstrap /opt/vps"
        echo "  sudo chmod +x /opt/vps/vps-cli.sh"
        echo "  sudo ln -sf /opt/vps/vps-cli.sh /usr/local/bin/vps"
        echo "  sudo chown -R master:master /opt/vps"
    fi
else
    echo "[!] GitHub-Authentifizierung abgebrochen"
    echo ""
    echo "=== Teilweise fertig ==="
    echo "CloudVLAN IP: $CLOUDVLAN_IP"
    echo "Hostname: $HOSTNAME"
    echo ""
    echo "Manuelles Setup:"
    echo "  gh auth login"
    echo "  gh repo clone CoPaCodeDev/vps-bootstrap /opt/vps"
    echo "  sudo chmod +x /opt/vps/vps-cli.sh"
    echo "  sudo ln -sf /opt/vps/vps-cli.sh /usr/local/bin/vps"
    echo "  sudo chown -R master:master /opt/vps"
fi
