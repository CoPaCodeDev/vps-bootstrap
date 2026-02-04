# VPS Bootstrap Scripts

Bootstrap-Scripts für Netcup VPS mit CloudVLAN (Debian 13).

## Workflow

### 1. Neuen VPS bestellen
- Netcup VPS mit Debian 13 bestellen
- CloudVLAN zum VPS hinzufügen

### 2. Script auswählen

| Script | Verwendung |
|--------|------------|
| `bootstrap-proxy.sh` | Für den Proxy-Server (öffentlich erreichbar) |
| `bootstrap-vps.sh` | Für alle anderen VPS (nur intern erreichbar) |

### 3. Script ausführen

**Proxy-VPS:**
```bash
curl -sL https://raw.githubusercontent.com/CoPaCodeDev/vps-bootstrap/main/bootstrap-proxy.sh | bash
```

**Andere VPS:**
```bash
# Erst IP und Hostname im Script anpassen, dann:
curl -sL https://raw.githubusercontent.com/CoPaCodeDev/vps-bootstrap/main/bootstrap-vps.sh -o bootstrap.sh
nano bootstrap.sh  # CLOUDVLAN_IP und HOSTNAME setzen
bash bootstrap.sh
```

### 4. Fertig
- User `master` hat sudo-Rechte
- CloudVLAN ist konfiguriert
- Firewall ist aktiv
