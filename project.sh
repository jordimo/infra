#!/bin/bash
# =============================================================================
# Project Manager — Add/Remove Traefik routing for VM projects
# =============================================================================
# Usage:
#   ./project.sh add <name> [--api <port>] [--web <port>]
#   ./project.sh rm <name>
#   ./project.sh ls
#
# Examples:
#   ./project.sh add joann --api 3000 --web 3001
#   ./project.sh add betty --api 3000 --web 3001
#   ./project.sh rm betty
#   ./project.sh ls
#
# Defaults: --api 3000 --web 3001
#
# Routing (path-based on public IP):
#   /project-name/api  → project-api container (stripped to /api)
#   /project-name      → project-web container (stripped to /)
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DYNAMIC_DIR="$SCRIPT_DIR/traefik/dynamic"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

usage() {
    echo "Usage:"
    echo "  ./project.sh add <name> [--api <port>] [--web <port>]"
    echo "  ./project.sh rm <name>"
    echo "  ./project.sh ls"
    exit 1
}

cmd_add() {
    local name="$1"; shift
    local api_port="3000"
    local web_port="3001"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --api) api_port="$2"; shift 2 ;;
            --web) web_port="$2"; shift 2 ;;
            *) echo -e "${RED}Unknown option: $1${NC}"; usage ;;
        esac
    done

    local config="$DYNAMIC_DIR/${name}.yml"

    if [ -f "$config" ]; then
        echo -e "${YELLOW}Project '${name}' already exists at ${config}${NC}"
        echo "Remove it first: ./project.sh rm ${name}"
        exit 1
    fi

    cat > "$config" <<EOF
http:
  routers:
    ${name}-api:
      rule: "PathPrefix(\`/${name}/api\`)"
      entryPoints:
        - web
      middlewares:
        - ${name}-strip-prefix
      service: ${name}-api
      priority: 200

    ${name}-web:
      rule: "PathPrefix(\`/${name}\`)"
      entryPoints:
        - web
      middlewares:
        - ${name}-strip-prefix
      service: ${name}-web
      priority: 100

  middlewares:
    ${name}-strip-prefix:
      stripPrefix:
        prefixes:
          - "/${name}"

  services:
    ${name}-api:
      loadBalancer:
        servers:
          - url: "http://${name}-api:${api_port}"

    ${name}-web:
      loadBalancer:
        servers:
          - url: "http://${name}-web:${web_port}"
EOF

    echo -e "${GREEN}Added project '${name}'${NC}"
    echo ""
    echo "  Web:  http://<IP>/${name}      -> ${name}-web:${web_port}"
    echo "  API:  http://<IP>/${name}/api  -> ${name}-api:${api_port}"
    echo ""
    echo "Traefik picks this up automatically (file watch)."
    echo ""
}

cmd_rm() {
    local name="$1"
    local config="$DYNAMIC_DIR/${name}.yml"

    if [ ! -f "$config" ]; then
        echo -e "${RED}Project '${name}' not found${NC}"
        exit 1
    fi

    rm "$config"

    echo -e "${GREEN}Removed project '${name}'${NC}"
    echo "Traefik picks this up automatically."
}

cmd_ls() {
    echo -e "${CYAN}Registered projects:${NC}"
    echo ""
    local found=false
    printf "  %-15s %-30s %-30s\n" "NAME" "WEB" "API"
    printf "  %-15s %-30s %-30s\n" "----" "---" "---"
    for f in "$DYNAMIC_DIR"/*.yml; do
        [ -f "$f" ] || continue
        local base="$(basename "$f" .yml)"
        [[ "$base" == "middlewares" ]] && continue
        local web_url=$(grep -A2 "${base}-web:" "$f" | grep "url:" | tail -1 | sed 's/.*url: *"//' | sed 's/".*//')
        local api_url=$(grep -A2 "${base}-api:" "$f" | grep "url:" | tail -1 | sed 's/.*url: *"//' | sed 's/".*//')
        printf "  %-15s %-30s %-30s\n" "$base" "/<${base}> -> ${web_url}" "/<${base}>/api -> ${api_url}"
        found=true
    done
    if [ "$found" = false ]; then
        echo "  (none)"
    fi
    echo ""
}

# ---- Main ----
[[ $# -lt 1 ]] && usage

case "$1" in
    add)
        [[ $# -lt 2 ]] && usage
        shift; cmd_add "$@"
        ;;
    rm|remove)
        [[ $# -lt 2 ]] && usage
        cmd_rm "$2"
        ;;
    ls|list)
        cmd_ls
        ;;
    *)
        usage
        ;;
esac
