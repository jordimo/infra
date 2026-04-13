#!/bin/bash
# =============================================================================
# Deploy to THECOLLECTIVE_AWS01
# =============================================================================
# Run from the corporate laptop (VPN connected).
#
# Usage:
#   ./deploy.sh                  # Deploy infra only (pull + restart traefik)
#   ./deploy.sh <project-name>   # Deploy a specific project
#   ./deploy.sh --all            # Deploy infra + all projects
#
# Prerequisites:
#   - VPN connected
#   - SSH key configured for the VM
# =============================================================================

set -e

VM_USER="${VM_USER:-ubuntu}"
VM_HOST="52.72.211.242"
VM_APP_DIR="/app"
REPO_URL="${REPO_URL:-git@github.com:THECOLLECTIVE/Deployer.git}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

ssh_cmd() {
    ssh "${VM_USER}@${VM_HOST}" "$@"
}

deploy_infra() {
    echo -e "${CYAN}[infra] Pulling latest...${NC}"
    ssh_cmd "cd ${VM_APP_DIR}/Deployer && git pull"

    echo -e "${CYAN}[infra] Starting infrastructure...${NC}"
    ssh_cmd "cd ${VM_APP_DIR}/Deployer && ./start.sh"

    echo -e "${GREEN}[infra] Done${NC}"
}

deploy_project() {
    local name="$1"
    local project_dir="${VM_APP_DIR}/${name}"

    echo -e "${CYAN}[${name}] Pulling latest...${NC}"
    ssh_cmd "cd ${project_dir} && git pull"

    echo -e "${CYAN}[${name}] Rebuilding containers...${NC}"
    ssh_cmd "cd ${project_dir} && docker compose up -d --build"

    echo -e "${GREEN}[${name}] Done — http://${VM_HOST}/${name}${NC}"
}

deploy_all() {
    deploy_infra

    echo ""
    # Find all project dirs (any dir with a docker-compose.yml that isn't Deployer)
    local projects
    projects=$(ssh_cmd "find ${VM_APP_DIR} -maxdepth 2 -name 'docker-compose.yml' -not -path '*/Deployer/*' -exec dirname {} \;" 2>/dev/null)

    for project_dir in $projects; do
        local name=$(basename "$project_dir")
        echo ""
        deploy_project "$name"
    done
}

# ---- Main ----
case "${1:-}" in
    ""|infra)
        deploy_infra
        ;;
    --all)
        deploy_all
        ;;
    *)
        deploy_project "$1"
        ;;
esac

echo ""
echo -e "${GREEN}Deploy complete.${NC}"
