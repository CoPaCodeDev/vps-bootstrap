# CoPa CAD — Deployment auf dem VPS

## Uebersicht

CoPa CAD besteht aus drei Services die auf dem VPS deployed werden muessen.
Alle laufen als Docker-Container hinter Traefik.

## Services und Domains

| Service | Repo | Domain | Port | Template |
|---------|------|--------|------|----------|
| **CoPa Website** | copa-cad-web | `copa-cad.de` | 3000 | `templates/copa-website/` |
| **CoPa App** (CAD-Editor) | copa-cad | `app.copa-cad.de` | 3001 | `templates/copa-app/` |
| **CoPa Server** (API) | copa-cad | `api.copa-cad.de` | 4000 | `templates/copa-server/` |

## Zusaetzliche Infrastruktur

Diese Services werden von copa-server benoetigt und laufen als Teil des
copa-server Templates (oder als eigene Templates):

| Service | Zweck | Port (intern) |
|---------|-------|---------------|
| **PostgreSQL 16** | Datenbank fuer copa-server | 5432 |
| **PostgreSQL 16** | Datenbank fuer copa-website | 5433 |
| **Redis 7** | Sessions, Rate-Limiting, Job-Queue | 6379 |
| **MinIO** | S3-kompatibler Dateispeicher (Cloud-Sync) | 9000 (API), 9001 (Console) |
| **Hocuspocus** | WebSocket Collaboration-Relay (ab M28) | 4001 |

## Traefik-Routes

```bash
# Website (oeffentlich)
vps route add copa-cad.de <webserver> 3000

# CAD-App (oeffentlich)
vps route add app.copa-cad.de <webserver> 3001

# API-Server (oeffentlich, Auth per Token)
vps route add api.copa-cad.de <webserver> 4000

# MinIO Console (intern, mit Authelia)
vps route add --auth minio.copa-cad.de <webserver> 9001
```

## Netzwerk

Alle CoPa-Services teilen ein Docker-Netzwerk `copa-network`, damit sie
sich intern erreichen koennen (z.B. copa-server → PostgreSQL, copa-server →
MinIO). Nach aussen kommunizieren sie ueber Traefik.

```
Internet
   ↓
Traefik (Proxy, 10.10.0.1)
   ↓ (CloudVLAN)
Webserver (10.10.0.x)
   ├── copa-website :3000    (copa-cad.de)
   ├── copa-app :3001        (app.copa-cad.de)
   ├── copa-server :4000     (api.copa-cad.de)
   ├── postgresql-web :5433  (intern)
   ├── postgresql-api :5432  (intern)
   ├── redis :6379           (intern)
   ├── minio :9000/:9001     (intern + Console)
   └── hocuspocus :4001      (intern, ab M28)
```

## Backup

Keine eigenen Backup-Skripte noetig. Das bestehende Restic-System sichert
automatisch alles unter `/opt/` (inkl. Datenbank-Volumes).

Fuer PostgreSQL-Dumps muss ein Pre-Backup-Hook angelegt werden:
`/etc/restic/pre-backup.d/copa-db-dump.sh`

## TODO: Templates erstellen

Fuer jedes CoPa-Service muss ein Template in `templates/` angelegt werden:

- [ ] `templates/copa-website/` — Next.js Website
- [ ] `templates/copa-server/` — Hono API + PostgreSQL + Redis + MinIO
- [ ] `templates/copa-app/` — Statischer CAD-Editor (Vite Build)

Die Templates werden erstellt sobald die jeweiligen Docker-Konfigurationen
in den App-Repos fertig sind.
