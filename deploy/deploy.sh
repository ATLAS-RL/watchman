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

    echo "  Copying binary..."
    scp "$BINARY" "${worker}:/tmp/watchman-agent"
    ssh "$worker" "sudo mv /tmp/watchman-agent /usr/local/bin/watchman-agent && sudo chmod +x /usr/local/bin/watchman-agent"

    echo "  Copying systemd unit..."
    scp "$SERVICE" "${worker}:/tmp/watchman-agent.service"
    ssh "$worker" "sudo mv /tmp/watchman-agent.service /etc/systemd/system/watchman-agent.service"

    echo "  Enabling and starting service..."
    ssh "$worker" "sudo systemctl daemon-reload && sudo systemctl enable --now watchman-agent"

    echo "  Verifying..."
    if ssh "$worker" "curl -sf http://localhost:8085/health" > /dev/null 2>&1; then
        echo "  ✓ $worker is healthy"
    else
        echo "  ⚠ $worker health check failed (may need a moment to start)"
    fi

    echo ""
done

echo "Deployment complete."
