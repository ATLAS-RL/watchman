#!/usr/bin/env bash
set -euo pipefail

BINARY="target/x86_64-unknown-linux-gnu/release/watchman-agent"
SERVICE="deploy/watchman-agent.service"
WORKERS=("ivantha-worker-0" "ivantha-worker-1")

if [ ! -f "$BINARY" ]; then
    echo "Error: Binary not found at $BINARY"
    echo "Run 'make build-agent' first."
    exit 1
fi

for worker in "${WORKERS[@]}"; do
    echo "=== Deploying to $worker ==="

    echo "  Creating directories..."
    ssh "$worker" "mkdir -p ~/.local/bin ~/.config/systemd/user"

    echo "  Stopping existing service..."
    ssh "$worker" "systemctl --user stop watchman-agent 2>/dev/null || true"

    echo "  Copying binary..."
    scp "$BINARY" "${worker}:~/.local/bin/watchman-agent"
    ssh "$worker" "chmod +x ~/.local/bin/watchman-agent"

    echo "  Copying systemd unit..."
    scp "$SERVICE" "${worker}:~/.config/systemd/user/watchman-agent.service"

    echo "  Enabling and starting service..."
    ssh "$worker" "systemctl --user daemon-reload && systemctl --user enable --now watchman-agent"

    echo "  Waiting for startup..."
    sleep 2

    echo "  Verifying..."
    if ssh "$worker" "curl -sf http://localhost:8085/health" > /dev/null 2>&1; then
        echo "  ✓ $worker is healthy"
    else
        echo "  ⚠ $worker health check failed (may need a moment to start)"
    fi

    echo ""
done

echo "Deployment complete."
echo ""
echo "NOTE: For the agent to run when not logged in, enable lingering on each worker:"
echo "  sudo loginctl enable-linger ivantha"
