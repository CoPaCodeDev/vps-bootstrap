# VPS CLI - Testanleitung

## Voraussetzungen
- Root-Zugang zum Proxy (10.10.0.1)
- Root-Zugang zu mindestens einem VPS im Netzwerk 10.10.0.2-254

---

## 0. Bootstrap (optional)

> **Hinweis:** Der User `master` existiert bereits auf dem Proxy und allen VPS.
> SSH-Key ist autorisiert, Sudo ohne Passwort ist konfiguriert.
> Dieser Abschnitt ist nur relevant, wenn neue VPS hinzugefügt werden.

<details>
<summary>Bootstrap-Anleitung für neue VPS</summary>

### 0.1 Proxy einrichten (10.10.0.1)

```bash
# Als root auf dem Proxy einloggen
ssh root@10.10.0.1

# User master anlegen (falls nicht vorhanden)
useradd -m -s /bin/bash master
echo "master ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/master

# SSH-Key für master generieren
su - master
ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519

# Public Key anzeigen (für später)
cat ~/.ssh/id_ed25519.pub
# --> Diesen Key kopieren!
```

### 0.2 VPS einrichten (auf jedem VPS wiederholen)

```bash
# Als root auf dem VPS einloggen
ssh root@10.10.0.X

# User master anlegen
useradd -m -s /bin/bash master

# SSH-Verzeichnis erstellen
mkdir -p /home/master/.ssh
chmod 700 /home/master/.ssh

# Public Key vom Proxy eintragen
echo "HIER_DEN_PUBLIC_KEY_EINFÜGEN" >> /home/master/.ssh/authorized_keys
chmod 600 /home/master/.ssh/authorized_keys
chown -R master:master /home/master/.ssh

# Sudo-Rechte ohne Passwort
echo "master ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/master
chmod 440 /etc/sudoers.d/master
```

### 0.3 Verbindung testen (vom Proxy aus)

```bash
# Auf dem Proxy als master
su - master

# SSH-Verbindung zum VPS testen
ssh -o StrictHostKeyChecking=no master@10.10.0.X "hostname"
```

**Erwartetes Ergebnis:** Hostname des VPS wird angezeigt, keine Passwort-Abfrage

</details>

---

## 1. Installation auf dem Proxy

```bash
# Script auf den Proxy kopieren
scp vps-cli.sh master@10.10.0.1:/tmp/

# Auf dem Proxy einloggen
ssh master@10.10.0.1

# Script installieren
sudo mv /tmp/vps-cli.sh /usr/local/bin/vps
sudo chmod +x /usr/local/bin/vps

# Prüfen ob es funktioniert
vps help
```

**Erwartetes Ergebnis:** Hilfetext wird angezeigt

---

## 2. Netzwerk scannen

```bash
vps scan
```

**Erwartetes Ergebnis:**
- Scannt alle IPs 10.10.0.2-254
- Zeigt Anzahl gefundener VPS
- Erstellt `/etc/vps-hosts`

**Prüfen:**
```bash
cat /etc/vps-hosts
```

---

## 3. VPS auflisten

```bash
vps list
```

**Erwartetes Ergebnis:** Tabelle mit IP und Hostname aller gefundenen VPS

---

## 4. Status abfragen

```bash
# Status aller VPS
vps status

# Status eines einzelnen VPS (Name oder IP)
vps status webserver
vps status 10.10.0.2
```

**Erwartetes Ergebnis:**
```
VPS             IP              Updates    Reboot     Load
--------------- --------------- ---------- ---------- ----------
webserver       10.10.0.2       3          nein       0.12
database        10.10.0.3       0          ja         0.45
```

---

## 5. Befehl ausführen

```bash
# Speicherplatz anzeigen
vps exec webserver "df -h"

# Wer ist eingeloggt
vps exec webserver "who"

# Kernel-Version
vps exec webserver "uname -a"
```

**Erwartetes Ergebnis:** Ausgabe des jeweiligen Befehls

---

## 6. Updates durchführen

```bash
# Einzelnen VPS updaten
vps update webserver

# Alle VPS updaten
vps update
```

**Erwartetes Ergebnis:** apt update && apt upgrade läuft durch

---

## 7. SSH-Session öffnen

```bash
vps ssh webserver
```

**Erwartetes Ergebnis:** Interaktive Shell auf dem VPS, Beenden mit `exit`

---

## 8. Reboot testen

```bash
vps reboot webserver
```

**Erwartetes Ergebnis:**
- Warnung wird angezeigt
- Fragt nach Bestätigung (j/N)
- Bei "j": VPS startet neu

---

## Fehlerfälle testen

| Test | Befehl | Erwartung |
|------|--------|-----------|
| Unbekannter Host | `vps status xyz` | Fehlermeldung |
| Ohne Hosts-Datei | `rm /etc/vps-hosts && vps list` | Hinweis auf `vps scan` |
| Falscher Befehl | `vps foo` | Fehlermeldung + Hilfe-Hinweis |

---

## Kurzformen

Diese Aliase funktionieren ebenfalls:
- `vps ls` = `vps list`
- `vps st` = `vps status`
- `vps up` = `vps update`
