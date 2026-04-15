#!/bin/bash
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Check .env exists
if [ ! -f .env ]; then
    echo "No .env file found."
    echo ""
    echo "  cp .env.example .env"
    echo ""
    exit 1
fi

# Detect profile
PROFILE_FLAG=""
if grep -q '^COMPOSE_PROFILES=.*local' .env 2>/dev/null; then
    PROFILE_FLAG="--profile local"
fi

echo "Starting infrastructure..."
docker compose $PROFILE_FLAG up -d

# Show what's running
echo ""
echo "Running:"
echo "  Traefik dashboard: http://localhost:8080"
echo "  PostgreSQL:        localhost:5432"
echo "  Redis:             localhost:6379"
echo "  Langfuse:          http://localhost:3030"
echo "  Umami:             http://localhost:3040"
if [ -n "$PROFILE_FLAG" ]; then
    echo "  Mailpit:           http://localhost:8025"
fi
echo ""
echo "Add projects with: ./project.sh add <name>"
echo ""
