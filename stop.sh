#!/bin/bash
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Stopping THECOLLECTIVE_AWS01 infrastructure..."
cd "$SCRIPT_DIR/traefik"
docker compose down
echo "Stopped."
