# Sicherheitsanalyse VPS-System

**Erstellt:** 2026-02-16

## Architektur-Überblick

- **Proxy** (10.10.0.1): Einziger öffentlich erreichbarer Server (SSH, HTTP, HTTPS)
- **VPS-Hosts** (10.10.0.2-254): Nur über CloudVLAN erreichbar, keine öffentlichen Ports
- **Dashboard**: Vue 3 + FastAPI, hinter Authelia Forward-Auth via Traefik

## Stärken (Status Quo)

| Bereich | Maßnahme |
|---------|----------|
| Netzwerk | CloudVLAN-Isolation — VPS-Hosts sind nicht öffentlich erreichbar |
| Firewall | UFW auf allen Hosts, Proxy erlaubt nur 22/80/443 + VLAN |
| SSH | Root-Login deaktiviert, Key-basierte Authentifizierung |
| Brute-Force | fail2ban auf dem Proxy |
| TLS | Traefik mit automatischem Let's Encrypt, TLS 1.2+ Default |
| Auth | Authelia Forward-Auth mit Rate-Limiting (3 Versuche, 5 Min Ban) |
| Berechtigungen | `master`-User mit sudo, kein direkter Root-Zugang |

## Umgesetzte Verbesserungen

### 1. SSH: Passwort-Login deaktiviert
- **Risiko:** SSH-Brute-Force auf `master`-Account trotz fail2ban möglich
- **Fix:** `PasswordAuthentication no` in `bootstrap-proxy.sh` und `bootstrap-vps.sh`
- **Dateien:** `bootstrap-proxy.sh`, `bootstrap-vps.sh`

### 2. Automatische Sicherheits-Updates
- **Risiko:** Ohne `unattended-upgrades` bleiben bekannte Sicherheitslücken offen
- **Fix:** `unattended-upgrades` installiert und auf Security-Only konfiguriert (kein Auto-Reboot)
- **Dateien:** `bootstrap-proxy.sh`, `bootstrap-vps.sh`

### 3. Security-Headers in nginx
- **Risiko:** Fehlende Browser-Sicherheitsrichtlinien (Clickjacking, MIME-Sniffing)
- **Fix:** `X-Frame-Options`, `X-Content-Type-Options`, `Referrer-Policy` hinzugefügt
- **Datei:** `webui/frontend/nginx.conf`

### 4. Command-Injection Fix (Authelia)
- **Risiko:** Passwörter mit `'` brechen aus Shell-Befehl aus → Command Injection
- **Fix:** `shlex.quote()` für Passwort-Parameter
- **Datei:** `webui/backend/app/routers/authelia.py`

### 5. WebSocket-Auth für Tasks-Endpoint
- **Risiko:** `/tasks/ws/{task_id}` ohne Auth-Check — Task-Output für jeden mit Task-ID lesbar
- **Fix:** Auth-Check analog zum Terminal-WebSocket (Remote-User Header)
- **Datei:** `webui/backend/app/routers/tasks.py`

## Bewusst nicht umgesetzt

| Maßnahme | Begründung |
|----------|------------|
| SSH-Port ändern | Security through obscurity, fail2ban reicht |
| AppArmor/SELinux | Overkill für dieses Setup |
| IDS/IPS | Unnötig bei CloudVLAN-Isolation |
| Rate-Limiting im Backend | Authelia hat eigenes Rate-Limiting |
| TLS-Minimum-Version erzwingen | Traefik nutzt bereits TLS 1.2+ als Default |
| Input-Validation für alle Pydantic-Models | Backend nur intern erreichbar, hinter Authelia |
| CSP-Header | Zu komplex für den Nutzen |
| HSTS-Header | Wird bereits von Traefik gesetzt |

## Verifikation

1. **SSH:** `grep -E 'PasswordAuth|PermitRoot' /etc/ssh/sshd_config`
2. **Updates:** `systemctl status unattended-upgrades`
3. **nginx Headers:** `curl -I https://dashboard.example.de`
4. **Authelia-Fix:** Benutzer mit `'` im Passwort anlegen
5. **Tasks-WebSocket:** WebSocket ohne Auth-Header öffnen → sollte in Prod loggen
