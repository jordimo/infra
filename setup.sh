#!/bin/bash
# =============================================================================
# One-time setup for THECOLLECTIVE_AWS01
# =============================================================================
# Run this once on the VM after first clone.
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}=== THECOLLECTIVE_AWS01 Setup ===${NC}"
echo ""

# ---- Docker check ----
echo -e "${CYAN}[1/3] Checking Docker...${NC}"
if ! command -v docker &> /dev/null; then
    echo -e "${RED}Docker not found. Install Docker first.${NC}"
    exit 1
fi
if ! docker compose version &> /dev/null; then
    echo -e "${RED}Docker Compose V2 not found. Update Docker.${NC}"
    exit 1
fi
echo -e "  ${GREEN}Docker $(docker --version | grep -oP '\d+\.\d+\.\d+') OK${NC}"

# ---- .env file ----
echo ""
echo -e "${CYAN}[2/3] Checking .env...${NC}"
if [ ! -f "$SCRIPT_DIR/traefik/.env" ]; then
    cp "$SCRIPT_DIR/traefik/.env.example" "$SCRIPT_DIR/traefik/.env"
    echo -e "  ${YELLOW}Created traefik/.env from .env.example${NC}"
    echo -e "  ${YELLOW}>>> Edit traefik/.env and set a strong POSTGRES_PASSWORD <<<${NC}"
else
    echo -e "  ${GREEN}traefik/.env exists${NC}"
fi

# ---- Create network ----
echo ""
echo -e "${CYAN}[3/3] Creating Docker network...${NC}"
if docker network inspect traefik-public &>/dev/null; then
    echo -e "  ${GREEN}traefik-public network already exists${NC}"
else
    docker network create traefik-public
    echo -e "  ${GREEN}Created traefik-public network${NC}"
fi

echo ""
echo -e "${GREEN}=== Setup Complete ===${NC}"
echo ""
echo "  Next steps:"
echo "    1. Edit traefik/.env with a strong POSTGRES_PASSWORD"
echo "    2. ./start.sh"
echo ""
