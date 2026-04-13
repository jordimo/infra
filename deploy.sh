#!/bin/bash
# =============================================================================
# Deploy to THECOLLECTIVE_AWS01
# =============================================================================
# Run from the corporate laptop (VPN connected).
#
# Usage:
#   ./deploy.sh infra                        # Deploy infra (pull + restart)
#   ./deploy.sh <project-name> <local-path>  # Sync project code + rebuild
#   ./deploy.sh --all                        # Deploy infra + rebuild all projects
#
# Examples:
#   ./deploy.sh infra
#   ./deploy.sh marie ~/Dev/THECOLLECTIVE/Marie/dev/Marie
#
# The infra repo (Deployer) is public, so the VM pulls it from GitHub.
# Project repos are private, so code is pushed from this machine via rsync.
#
# Prerequisites:
#   - VPN connected
#   - SSH alias 'aws01' configured in ~/.ssh/config:
#
#       Host aws01
#           HostName 10.251.8.172
#           User ubuntu
#           IdentityFile ~/.ssh/AWSNMTNAPP001-keypair.pem
#
# =============================================================================

set -e

VM="${VM:-aws01}"
VM_APP_DIR="/app"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

ssh_cmd() {
    ssh "$VM" "$@"
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
    local local_path="$2"
    local remote_dir="${VM_APP_DIR}/${name}"

    if [ -z "$local_path" ]; then
        echo -e "${RED}Usage: ./deploy.sh ${name} <local-path>${NC}"
        echo "  e.g. ./deploy.sh ${name} ~/Dev/THECOLLECTIVE/Marie/dev/Marie"
        exit 1
    fi

    if [ ! -d "$local_path" ]; then
        echo -e "${RED}Directory not found: ${local_path}${NC}"
        exit 1
    fi

    # Ensure remote directory exists
    ssh_cmd "mkdir -p ${remote_dir}"

    echo -e "${CYAN}[${name}] Syncing code to VM...${NC}"
    rsync -az --delete \
        --exclude 'node_modules' \
        --exclude '.git' \
        --exclude '.env' \
        --exclude 'dist' \
        --exclude '.turbo' \
        "${local_path}/" "${VM}:${remote_dir}/"

    echo -e "${CYAN}[${name}] Rebuilding containers...${NC}"
    ssh_cmd "cd ${remote_dir} && docker compose up -d --build"

    echo -e "${GREEN}[${name}] Done — http://52.72.211.242/${name}${NC}"
}

deploy_all() {
    deploy_infra

    echo ""
    # Rebuild all project containers on the VM
    local projects
    projects=$(ssh_cmd "find ${VM_APP_DIR} -maxdepth 2 -name 'docker-compose.yml' -not -path '*/Deployer/*' -exec dirname {} \;" 2>/dev/null)

    for project_dir in $projects; do
        local name=$(basename "$project_dir")
        echo ""
        echo -e "${CYAN}[${name}] Rebuilding containers...${NC}"
        ssh_cmd "cd ${project_dir} && docker compose up -d --build"
        echo -e "${GREEN}[${name}] Done${NC}"
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
        deploy_project "$1" "$2"
        ;;
esac

echo ""
echo -e "${GREEN}Deploy complete.${NC}"
