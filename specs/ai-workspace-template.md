# Feature: Deploy-Template `ai-workspace`

## Beschreibung

Neues Deploy-Template fuer `vps deploy` das eine KI-Entwicklungsumgebung auf einem VPS einrichtet: Claude Code als dauerhaften Service mit API-Wrapper, Playwright fuer Tests und Video-Demos, und ein Dashboard fuer grafischen Workflow-Ueberblick.

Der Entwickler arbeitet mit VS Code + Remote-SSH von seiner Windows VM. Claude Code laeuft auf dem VPS — Agents arbeiten weiter auch wenn der Rechner aus ist.

## Warum

Das AI Workflow Kit laeuft aktuell nur lokal. Mit diesem Template:
- Claude Code laeuft dauerhaft auf dem VPS
- Agents arbeiten unabhaengig vom lokalen Rechner
- Dashboard zeigt Fortschritt grafisch im Browser
- Telegram-Steuerung ueber Claude Code Channels Plugin
- Mehrere Projekte gleichzeitig moeglich

## Wer nutzt es

- **Entwickler** — VS Code via Remote-SSH, Dashboard im Browser, Telegram am Handy
- **Stakeholder** (spaeter) — Dashboard fuer Demos und Feedback

## Kontext

Bestehende Templates als Referenz:
- `guacamole` — Remote Desktop (Docker + Traefik-Route + Authelia)
- `paperless-ngx` — Dokumenten-Management (Docker + Traefik-Route + Authelia + DB)
- `uptime-kuma` — Monitoring (Docker + Traefik-Route)

Das `ai-workspace` Template folgt demselben Muster: template.conf + docker-compose.yml + Dockerfiles.

## Architektur

```
Windows 11 VM                         VPS (CloudVLAN)
┌──────────────┐                      ┌─────────────────────────────────┐
│  VS Code     │──── SSH ────────────→│  /home/master/projects/         │
│  + Remote SSH│                      │                                 │
└──────────────┘                      │  claude-service Container       │
                                      │  ├── Session Manager            │
Browser (ueberall)                    │  │   ├── Projekt A → claude     │
┌──────────────┐                      │  │   └── Projekt B → claude     │
│  Dashboard   │──── HTTPS ──────────→│  ├── API Wrapper (FastAPI+WS)  │
└──────────────┘                      │  ├── Playwright + Chromium      │
                                      │  ├── Git, gh, Node.js, Python   │
Telegram (Handy)                      │  └── --channels telegram        │
┌──────────────┐                      │                                 │
│  Claude Code │←─── Channels ───────→│  dashboard Container            │
│  Channels    │                      │  ├── Vue 3 + PrimeVue Frontend  │
└──────────────┘                      │  └── FastAPI Backend            │
                                      │                                 │
                                      │  Traefik + Authelia             │
                                      └─────────────────────────────────┘
```

## Anforderungen

### template.conf

```bash
TEMPLATE_NAME="AI Workspace"
TEMPLATE_DESCRIPTION="KI-Entwicklungsumgebung: Claude Code Service + Dashboard + Playwright"
TEMPLATE_DEPLOY_DIR="/opt/ai-workspace"
TEMPLATE_REQUIRES_DOCKER=true
TEMPLATE_REQUIRES_ROUTE=true
TEMPLATE_ROUTE_PORT=8080

TEMPLATE_VARS=(
    "DOMAIN|Domain (z.B. workflow.example.de)||required"
    "ANTHROPIC_API_KEY|Anthropic API Key (sk-ant-...)||secret"
    "GIT_USER|Git User-Name fuer Commits||required"
    "GIT_EMAIL|Git Email fuer Commits||required"
    "GITHUB_TOKEN|GitHub Token fuer gh CLI (ghp_...)||secret"
)
```

### Docker Compose — 2 Services

#### 1. claude-service

Claude Code als dauerhafter Service mit API-Wrapper fuer Dashboard und Multi-Projekt-Support.

- **Base Image:** `node:20-bookworm` (Debian-basiert, volle Kompatibilitaet)
- **Custom Dockerfile** mit:

  **System-Packages (apt):**
  - git, openssh-client, curl, wget
  - jq, ripgrep
  - bash, sed, grep
  - ffmpeg (Video WebM → MP4)
  - Playwright Chromium Dependencies: libnss3, libgbm1, libasound2, libatk-bridge2.0-0, libdrm2, libxcomposite1, libxdamage1, libxrandr2, libpango-1.0-0, libcairo2

  **Node.js (global npm):**
  - `@anthropic-ai/claude-code` — Claude Code CLI
  - `@playwright/test` — Playwright fuer Tests und Video-Recording

  **Python (pip):**
  - fastapi, uvicorn, websockets — API Wrapper
  - watchfiles — File-Watcher fuer Projektdateien
  - pyyaml — Config-Parsing

  **CLI Tools:**
  - `gh` — GitHub CLI (fuer PRs, Issues, Repo-Sync)
  - `yq` — YAML Parser (fuer workflow.config.yaml)

  **NICHT noetig:**
  - build-essential (nichts wird kompiliert)
  - GUI-Libs wie libgtk (nur headless)
  - Firefox/WebKit (Chromium reicht)
  - MCP Server Packages (Claude hat eingebauten Dateizugriff, gh/git als CLI)

- **Volumes:**
  - `projects:/home/claude/projects/` — Workspace (geteilt mit Dashboard, read-write)
  - `claude-config:/home/claude/.claude/` — Claude Code Config + API Key
  - `npm-cache:/home/claude/.npm/` — NPM Cache (Performance)
  - `pw-browsers:/home/claude/.cache/ms-playwright/` — Playwright Chromium (persistent)
  - `shared-videos:/shared/videos/` — Demo-Videos (geteilt mit Dashboard)

- **Ports:** 8000 (API, nur intern im Docker-Netzwerk)

- **Environment:**
  ```env
  ANTHROPIC_API_KEY=sk-ant-...
  GITHUB_TOKEN=ghp_...
  GIT_USER=Max Mustermann
  GIT_EMAIL=max@example.de
  DISABLE_AUTOUPDATER=1
  PLAYWRIGHT_BROWSERS_PATH=/home/claude/.cache/ms-playwright
  ```

- **Entrypoint:**
  1. Git global config setzen (User, Email, safe.directory)
  2. gh auth setup (Token aus Environment)
  3. Playwright Chromium installieren (falls nicht im Volume)
  4. API Wrapper starten (uvicorn)

- **Health Check:** HTTP GET auf `/api/health`

- **docker-compose extras:**
  - `ipc: host` — Chromium braucht Shared Memory
  - `restart: unless-stopped`

##### Session Manager (Kern des API Wrappers)

Verwaltet mehrere Claude Code Instanzen (eine pro Projekt):

```python
class SessionManager:
    sessions: dict[str, ClaudeSession]

    async def create(project_path: str, telegram: bool = False) -> Session
    async def send_input(project: str, text: str)
    async def get_output(project: str) -> AsyncStream
    async def stop(project: str)
    async def list() -> list[SessionStatus]
```

**REST API:**
```
GET    /api/health                        → Health Check
GET    /api/sessions                      → Alle Projekte/Sessions
POST   /api/sessions                      → Neue Session starten
GET    /api/sessions/{project}            → Status (Milestone, Tests, Tokens)
DELETE /api/sessions/{project}            → Session beenden
GET    /api/sessions/{project}/videos     → Demo-Videos
GET    /api/sessions/{project}/videos/{id} → Video-Stream
```

**WebSocket:**
```
WS /ws/sessions/{project}
  ← Claude Output (live stream)
  → User Input ("weiter", "/status", Feedback)
```

Dashboard und Telegram verbinden sich auf denselben Claude-Prozess. Input von ueberall kommt beim gleichen Claude an.

##### Telegram (via Claude Code Channels)

Kein eigener Bot-Code. Claude Code wird mit `--channels plugin:telegram@claude-plugins-official` gestartet. Der Session Manager startet Claude mit diesem Flag wenn `telegram: true` gesetzt ist.

Setup einmalig: Bot bei @BotFather erstellen, Token pairen.

#### 2. dashboard

AI Workflow Dashboard — grafischer Ueberblick ueber den Workflow.

- **Image:** Wird aus `ai-workflow-platform` Repo gebaut (separates Repo)
- **Vorerst (Phase 1):** Einfacher nginx Container mit Platzhalter-Seite
- **Spaeter:** Echtes Dashboard-Image mit Vue 3 + FastAPI
- **Port:** 8080 (intern)
- **Volumes:**
  - `projects:/projects:ro` — Projektdateien lesen (read-only)
  - `shared-videos:/shared/videos:ro` — Demo-Videos lesen (read-only)
- **Kommunikation:** Verbindet sich mit claude-service API (http://claude-service:8000)

### Traefik-Routing

Eine Domain, zwei Services:

```yaml
# Dashboard (Hauptzugang)
- "traefik.http.routers.ai-dashboard.rule=Host(`${DOMAIN}`)"
- "traefik.http.routers.ai-dashboard.entrypoints=websecure"
- "traefik.http.routers.ai-dashboard.tls.certresolver=letsencrypt"
- "traefik.http.routers.ai-dashboard.middlewares=authelia@file"
- "traefik.http.services.ai-dashboard.loadbalancer.server.port=8080"

# Claude API + WebSocket (fuer Dashboard-Backend)
- "traefik.http.routers.ai-api.rule=Host(`${DOMAIN}`) && PathPrefix(`/api`)"
- "traefik.http.routers.ai-api.entrypoints=websecure"
- "traefik.http.routers.ai-api.tls.certresolver=letsencrypt"
- "traefik.http.routers.ai-api.middlewares=authelia@file"
- "traefik.http.services.ai-api.loadbalancer.server.port=8000"
```

Beide hinter Authelia geschuetzt. WebSocket wird von Traefik automatisch durchgeleitet.

### .env Template

```env
DOMAIN=workflow.example.de
ANTHROPIC_API_KEY=sk-ant-...
GITHUB_TOKEN=ghp_...
GIT_USER=Max Mustermann
GIT_EMAIL=max@example.de
```

### Post-Deploy Script

Nach dem Deployment:
1. `.env` aus Template-Variablen erstellen
2. Claude Code Konfiguration erstellen (API Key in Config)
3. Git global config setzen (User, Email)
4. gh CLI authentifizieren (Token)
5. AI Workflow Kit klonen nach `/home/claude/.local/share/ai-workflow-kit/`
6. Playwright Chromium installieren
7. Smoke Test:
   - claude-service API erreichbar (`/api/health`)
   - Dashboard erreichbar (HTTP 200)
   - Claude Code antwortet (`claude --version`)
   - Playwright funktioniert (`npx playwright test --list`)
   - gh CLI authentifiziert (`gh auth status`)

### SSH-Zugang fuer VS Code Remote

Der Entwickler verbindet sich mit VS Code Remote-SSH direkt auf den VPS:

```
Host ai-workspace
    HostName 10.10.0.X    # oder ueber Proxy
    User master
    IdentityFile ~/.ssh/id_ed25519
```

Projekte liegen in `/home/master/projects/` — das gleiche Verzeichnis das als Volume im claude-service Container gemountet ist. Aenderungen in VS Code sind sofort fuer Claude sichtbar und umgekehrt.

## Acceptance Criteria

1. `vps deploy ai-workspace webserver` fragt Domain, API-Key, GitHub-Token und Git-Config ab
2. `vps deploy ai-workspace webserver` deployed beide Container und richtet Traefik-Route ein
3. `workflow.domain.de` zeigt Dashboard (Platzhalter oder echtes)
4. `workflow.domain.de/api/health` gibt `{"status": "ok"}` zurueck
5. `workflow.domain.de/api/sessions` gibt leere Liste zurueck
6. VS Code Remote-SSH auf den VPS funktioniert, Projekte in `/home/master/projects/`
7. Im claude-service Container: `claude --version` gibt Version zurueck
8. Im claude-service Container: `gh auth status` zeigt authentifiziert
9. Im claude-service Container: `npx playwright test --list` funktioniert
10. Projekte in `projects` Volume ueberleben Container-Neustart
11. Claude-Config in `claude-config` Volume ueberlebt Container-Neustart
12. `vps deploy status webserver` zeigt ai-workspace als deployed
13. `vps deploy remove webserver ai-workspace` raeumt alles sauber auf

## Nicht im Scope

- Dashboard-Funktionalitaet (→ ai-workflow-platform Repo)
- Eigener Telegram-Bot-Code (→ Claude Code Channels Plugin)
- code-server / VS Code im Browser (→ VS Code Remote-SSH stattdessen)
- noVNC / Live-Desktop (→ spaeter, optional)
- Multi-User / mehrere Workspaces auf einem VPS
- Automatische Backups der Projekte (→ bestehendes `vps backup` deckt /opt/ ab)

## Dateien die erstellt werden

```
templates/ai-workspace/
├── template.conf                # Template-Konfiguration fuer vps deploy
├── docker-compose.yml           # 2 Services: claude-service, dashboard
├── Dockerfile.claude-service    # Node.js 20 + Claude Code + Playwright + Python + gh
├── Dockerfile.dashboard         # Platzhalter: nginx mit Coming Soon Seite
├── dashboard-placeholder/
│   └── index.html               # Coming Soon Seite
├── api-wrapper/                 # FastAPI Session Manager
│   ├── main.py                  # FastAPI App + WebSocket
│   ├── session_manager.py       # Claude-Prozess-Verwaltung
│   ├── models.py                # Pydantic-Modelle
│   └── requirements.txt         # Python Dependencies
├── entrypoint.sh                # Startup: Git-Config, gh-Auth, Playwright, API starten
└── .env.template                # Vorlage fuer Umgebungsvariablen
```
