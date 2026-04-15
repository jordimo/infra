#!/bin/bash
# =============================================================================
# One-time setup — Run after first clone on any machine
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}=== Infrastructure Setup ===${NC}"
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
echo -e "  ${GREEN}Docker $(docker --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+') OK${NC}"

# ---- .env file ----
echo ""
echo -e "${CYAN}[2/3] Checking .env...${NC}"
if [ ! -f "$SCRIPT_DIR/.env" ]; then
    echo -e "  ${YELLOW}No .env file found.${NC}"
    echo -e "  ${YELLOW}Run: ${GREEN}cp .env.example .env${NC}"
    echo -e "  ${YELLOW}Local dev defaults work out of the box.${NC}"
else
    echo -e "  ${GREEN}.env exists${NC}"
fi

# ---- Create network ----
echo ""
echo -e "${CYAN}[3/3] Checking Docker network...${NC}"
if docker network inspect infra &>/dev/null; then
    echo -e "  ${GREEN}infra network already exists${NC}"
else
    docker network create infra
    echo -e "  ${GREEN}Created infra network${NC}"
fi

echo ""
echo -e "${GREEN}=== Setup Complete ===${NC}"
echo ""
echo "  Next steps:"
echo "    1. Ensure .env is configured (see above)"
echo "    2. ./start.sh"
echo ""
