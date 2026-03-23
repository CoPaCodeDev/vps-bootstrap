# Feature: Deploy-Template `ai-workspace`

## Beschreibung

Neues Deploy-Template fuer `vps deploy` das eine KI-Entwicklungsumgebung auf einem VPS einrichtet: code-server (VS Code im Browser) mit Claude Code CLI, Playwright fuer Tests und Video-Demos, und Vorbereitung fuer das AI Workflow Dashboard.

## Warum

Das AI Workflow Kit laeuft aktuell nur lokal. Mit diesem Template kann ein Entwickler von ueberall — Browser, Tablet, anderer Rechner — an KI-gesteuerten Projekten arbeiten. Claude Code laeuft dauerhaft auf dem VPS, Agents arbeiten auch wenn der Rechner aus ist.

## Wer nutzt es

- **Entwickler** — Arbeitet remote mit Claude Code ueber den Browser
- Spaeter: Stakeholder schauen Demos ueber das Dashboard an (→ ai-workflow-platform Repo)

## Kontext

Bestehende Templates als Referenz:
- `guacamole` — Remote Desktop (Docker + Traefik-Route + Authelia)
- `paperless-ngx` — Dokumenten-Management (Docker + Traefik-Route + Authelia + DB)
- `uptime-kuma` — Monitoring (Docker + Traefik-Route)

Das `ai-workspace` Template folgt demselben Muster: template.conf + docker-compose.yml + Dockerfiles.

## Anforderungen

### template.conf

```bash
TEMPLATE_NAME="AI Workspace"
TEMPLATE_DESCRIPTION="KI-Entwicklungsumgebung: VS Code + Claude Code + Playwright im Browser"
TEMPLATE_DEPLOY_DIR="/opt/ai-workspace"
TEMPLATE_REQUIRES_DOCKER=true
TEMPLATE_REQUIRES_ROUTE=true
TEMPLATE_ROUTE_PORT=8443

TEMPLATE_VARS=(
    "DOMAIN|Domain (z.B. workflow.example.de)||required"
    "SUDO_PASSWORD|Passwort fuer code-server sudo||secret"
    "GIT_USER|Git User-Name fuer Commits||required"
    "GIT_EMAIL|Git Email fuer Commits||required"
)
```

### Docker Compose — 3 Services

#### 1. code-server

VS Code im Browser mit vorinstallierter Entwicklungsumgebung.

- **Base Image:** `codercom/code-server:latest`
- **Custom Dockerfile** mit:
  - Node.js 20 LTS (via nvm oder nodesource)
  - Python 3.11+ mit pip und venv
  - Git, curl, jq, ripgrep
  - Claude Code CLI (`npm install -g @anthropic-ai/claude-code`)
  - Playwright + Chromium Dependencies (`npx playwright install --with-deps chromium`)
  - AI Workflow Kit vorinstalliert in `/home/coder/.local/share/ai-workflow-kit/`
  - Setup-Script das bei neuem Projekt automatisch `setup.sh` anbietet
- **Volumes:**
  - `/home/coder/projects/` — Persistenter Workspace (Named Volume)
  - `/home/coder/.claude/` — Claude Code Config (Named Volume)
  - `/shared/videos/` — Shared Volume fuer Demo-Videos (geteilt mit Dashboard)
- **Port:** 8443 (intern)
- **Environment:**
  - `ANTHROPIC_API_KEY` — Claude API Key (aus .env Datei)
  - `GIT_USER`, `GIT_EMAIL` — Git-Konfiguration
- **Health Check:** HTTP GET auf code-server Login-Seite

#### 2. playwright

Dedizierter Container fuer headless Browser-Tests und Video-Recording.

- **Base Image:** `mcr.microsoft.com/playwright:v1.52.0-noble`
- **Zweck:**
  - Headless Chromium fuer Playwright-Tests
  - Video-Recording fuer Demos (WebM/MP4, 1280x720)
  - Shared Volume `/shared/videos/` fuer aufgenommene Videos
- **Kein eigener Port** — wird von code-server/Claude via Playwright MCP angesprochen
- **Laeuft im Hintergrund**, wird bei Bedarf genutzt

#### 3. dashboard (Platzhalter)

Vorbereitung fuer das AI Workflow Dashboard (wird spaeter aus ai-workflow-platform deployed).

- **Vorerst:** Einfacher nginx Container der eine "Coming Soon" Seite zeigt
- **Port:** 8080 (intern)
- **Spaeter:** Wird durch das echte Dashboard-Image aus ai-workflow-platform ersetzt
- **Volume:** Liest aus dem gleichen `/home/coder/projects/` Volume (read-only)

### Traefik-Routing

Zwei Subpaths auf einer Domain:

```yaml
# code-server (Hauptzugang)
- "traefik.http.routers.ai-workspace.rule=Host(`${DOMAIN}`)"
- "traefik.http.routers.ai-workspace.middlewares=authelia@file"

# Dashboard (Subpath)
- "traefik.http.routers.ai-dashboard.rule=Host(`${DOMAIN}`) && PathPrefix(`/dashboard`)"
- "traefik.http.routers.ai-dashboard.middlewares=authelia@file"
```

Beide hinter Authelia geschuetzt.

### .env Template

```env
DOMAIN=workflow.example.de
SUDO_PASSWORD=changeme
ANTHROPIC_API_KEY=sk-ant-...
GIT_USER=Max Mustermann
GIT_EMAIL=max@example.de
```

Der `ANTHROPIC_API_KEY` wird bei `vps deploy` abgefragt und in `.env` gespeichert (wie DB-Passwoerter bei anderen Templates).

### Post-Deploy Script

Nach dem Deployment:
1. Claude Code Konfiguration erstellen (API Key, MCP Server)
2. Git global config setzen (User, Email)
3. AI Workflow Kit klonen und `setup.sh` Pfad in PATH aufnehmen
4. Playwright Chromium installieren
5. Smoke Test: code-server erreichbar, Claude Code antwortet

## Acceptance Criteria

1. `vps deploy ai-workspace webserver` fragt Domain, Passwort, API-Key und Git-Config ab
2. `vps deploy ai-workspace webserver` deployed alle Container und richtet Traefik-Route ein
3. `workflow.domain.de` zeigt code-server Login (Authelia)
4. Nach Login: VS Code im Browser mit funktionierendem Terminal
5. Im Terminal: `claude --version` gibt eine Version zurueck
6. Im Terminal: `claude` startet eine interaktive Session
7. Im Terminal: `npx playwright test` fuehrt einen Test aus (Chromium headless)
8. `workflow.domain.de/dashboard` zeigt Platzhalter-Seite
9. Projekte in `/home/coder/projects/` ueberleben Container-Neustart
10. Claude-Config in `/home/coder/.claude/` ueberlebt Container-Neustart
11. `vps deploy status webserver` zeigt ai-workspace als deployed
12. `vps deploy remove webserver ai-workspace` raeumt alles sauber auf

## Nicht im Scope

- Dashboard-Funktionalitaet (→ ai-workflow-platform Repo, Phase 1)
- Telegram-Integration (→ ai-workflow-platform Repo, Phase 3)
- noVNC / Live-Desktop (→ spaeter, optional)
- Multi-User / mehrere Workspaces auf einem VPS
- Automatische Backups der Projekte (→ bestehendes `vps backup` deckt /opt/ ab)

## Dateien die erstellt werden

```
templates/ai-workspace/
├── template.conf              # Template-Konfiguration fuer vps deploy
├── docker-compose.yml         # 3 Services: code-server, playwright, dashboard
├── Dockerfile.code-server     # Custom Image: Node.js, Python, Claude Code, Playwright
├── Dockerfile.dashboard       # Platzhalter: nginx mit Coming Soon Seite
├── dashboard-placeholder/
│   └── index.html             # Coming Soon Seite
├── entrypoint.sh              # code-server Startup (Git-Config, Claude-Setup)
└── .env.template              # Vorlage fuer Umgebungsvariablen
```
