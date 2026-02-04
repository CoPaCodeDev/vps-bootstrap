# Plan: Bootstrap-Proxy mit automatischem Repo-Setup

## Status: Implementiert

## Was wurde gemacht

### `bootstrap-proxy.sh` erweitert
- [x] Git installieren
- [x] GitHub CLI (`gh`) installieren
- [x] Device-Code Authentifizierung mit Benutzeranleitung
- [x] Repository `CoPaCodeDev/vps-bootstrap` nach `/opt/vps` klonen
- [x] VPS-CLI einrichten (chmod, symlink, chown)
- [x] Fallback bei Fehlern mit manueller Anleitung
- [x] Schrittzählung aktualisiert (7 → 10)

### `README.md` aktualisiert
- [x] Workflow mit Device-Code Auth Hinweis
- [x] Pfad zu setup-proxy-key.sh korrigiert
- [x] Schritt 5 vereinfacht

## Neuer Workflow

```
1. Bootstrap in VNC-Konsole ausführen
2. Device-Code auf Handy/PC eingeben (https://github.com/login/device)
3. Repository wird automatisch geklont
4. Per SSH verbinden: ssh master@<proxy-ip>
5. Key generieren: sudo bash /opt/vps/setup-proxy-key.sh
6. Fertig - vps help funktioniert
```

## Noch offen / Ideen für später

- [ ] Repository auf GitHub erstellen: `CoPaCodeDev/vps-bootstrap`
- [ ] Alle Dateien ins Repository pushen
- [ ] Optional: `gh auth logout` am Ende des Bootstraps (Sicherheit)
- [ ] Optional: Automatisches `vps scan` nach dem Setup

## Dateien im Repository

```
vps-bootstrap/
├── bootstrap-proxy.sh      # Proxy Bootstrap (mit gh CLI)
├── bootstrap-vps.sh        # VPS Bootstrap
├── setup-proxy-key.sh      # SSH-Key Generator
├── vps-cli.sh              # Management CLI
├── templates/              # Konfigurations-Templates
│   └── traefik/
├── README.md               # Dokumentation
├── CLAUDE.md               # Claude Code Kontext
└── PLAN.md                 # Diese Datei
```

## Verifikation nach Bootstrap

Nach dem Bootstrap sollte auf dem Proxy:
1. `vps help` funktionieren
2. `/opt/vps/` das Repository enthalten
3. `gh auth status` den angemeldeten User zeigen

## Commit-Message Vorschlag

```
feat: Bootstrap mit automatischem GitHub-Repo-Setup

- GitHub CLI Installation und Device-Code Auth
- Automatisches Klonen von CoPaCodeDev/vps-bootstrap
- VPS-CLI wird direkt eingerichtet
- Fallback mit manueller Anleitung bei Fehlern
```
