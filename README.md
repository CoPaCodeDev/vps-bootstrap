# VPS Bootstrap Scripts

Bootstrap-Scripts für Netcup VPS mit CloudVLAN (Debian 13).

## Workflow

### 1. Proxy aufsetzen
```bash
# Bei Netcup im VPS-Panel ausführen:
curl -sL https://raw.githubusercontent.com/CoPaCodeDev/vps-bootstrap/main/bootstrap-proxy.sh | bash
```

### 2. SSH-Key generieren
```bash
# Per SSH auf den Proxy verbinden:
ssh master@<proxy-ip>

# Key generieren:
sudo bash setup-proxy-key.sh
```

### 3. Key in bootstrap-vps.sh eintragen
Den angezeigten Public Key in `bootstrap-vps.sh` bei `PROXY_PUBKEY` eintragen, dann committen und pushen.

### 4. Weitere VPS aufsetzen
```bash
# Bei Netcup im VPS-Panel:
curl -sL https://raw.githubusercontent.com/CoPaCodeDev/vps-bootstrap/main/bootstrap-vps.sh -o bootstrap.sh
nano bootstrap.sh  # CLOUDVLAN_IP und HOSTNAME setzen
bash bootstrap.sh
```

Der Proxy kann sich nun per SSH auf alle VPS verbinden:
```bash
ssh master@10.10.0.X
```

## Scripts

| Script | Verwendung |
|--------|------------|
| `bootstrap-proxy.sh` | Für den Proxy-Server (öffentlich erreichbar, 10.10.0.1) |
| `bootstrap-vps.sh` | Für alle anderen VPS (nur intern erreichbar) |
| `setup-proxy-key.sh` | Generiert SSH-Key auf dem Proxy |

## Ergebnis
- User `master` hat sudo-Rechte
- CloudVLAN ist konfiguriert
- Firewall erlaubt nur Verbindungen aus dem CloudVLAN
- Proxy kann sich per SSH auf alle VPS verbinden
