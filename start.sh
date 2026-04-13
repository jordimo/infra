#!/bin/bash
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Starting THECOLLECTIVE_AWS01 infrastructure..."

cd "$SCRIPT_DIR/traefik"
docker compose up -d

echo ""
echo "Running:"
echo "  Traefik dashboard: http://52.72.211.242:8080"
echo "  PostgreSQL:        postgres:5432 (internal)"
echo "  Redis:             redis:6379 (internal)"
echo ""
echo "Add projects with: ./project.sh add <name>"
echo ""
