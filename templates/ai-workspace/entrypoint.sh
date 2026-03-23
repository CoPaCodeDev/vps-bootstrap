#!/bin/bash
set -e

# Git-Konfiguration
if [ -n "$GIT_USER" ]; then
    git config --global user.name "$GIT_USER"
fi
if [ -n "$GIT_EMAIL" ]; then
    git config --global user.email "$GIT_EMAIL"
fi

# Sudo-Passwort setzen
if [ -n "$SUDO_PASSWORD" ]; then
    echo "coder:$SUDO_PASSWORD" | sudo chpasswd
fi

# Claude Code Konfiguration (API Key)
if [ -n "$ANTHROPIC_API_KEY" ]; then
    mkdir -p /home/coder/.claude
    cat > /home/coder/.claude/.env <<EOF
ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY
EOF
fi

# code-server starten
exec code-server \
    --bind-addr 0.0.0.0:8443 \
    --auth none \
    --disable-telemetry \
    /home/coder/projects
