#!/bin/bash
set -e

# Git-Konfiguration
if [ -n "$GIT_USER" ]; then
    git config --global user.name "$GIT_USER"
fi
if [ -n "$GIT_EMAIL" ]; then
    git config --global user.email "$GIT_EMAIL"
fi
git config --global --add safe.directory '*'

# GitHub CLI authentifizieren
if [ -n "$GITHUB_TOKEN" ]; then
    echo "$GITHUB_TOKEN" | gh auth login --with-token 2>/dev/null || true
fi

# Playwright Chromium installieren (falls nicht im Volume)
if [ ! -d "$PLAYWRIGHT_BROWSERS_PATH/chromium"* ] 2>/dev/null; then
    echo "Installiere Playwright Chromium..."
    npx playwright install chromium
fi

# API Wrapper starten
exec uvicorn main:app --host 0.0.0.0 --port 8000 --app-dir /opt/api-wrapper
