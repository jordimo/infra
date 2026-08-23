#!/bin/bash
# =============================================================================
# Deploy a project or infra
# =============================================================================
# Usage:
#   ./deploy.sh --target <target> <project>   Deploy a project
#   ./deploy.sh --target <target> infra        Deploy infra (git pull + restart)
#   ./deploy.sh --target <target> --all        Deploy infra + all projects
#
# Examples:
#   ./deploy.sh --target do:zora marie
#   ./deploy.sh --target do:zora infra
#   ./deploy.sh --target do:zora --all
#   ./deploy.sh --target aws marie
#
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Bitwarden item holding the GitHub Packages read token (read:packages PAT),
# used as NODE_AUTH_TOKEN at build time by projects that pull @jordimo/*
# (Marie, Librarian, TheBrain web). Vault: LOSTRIVER/Zora/_shared.
GH_PACKAGES_TOKEN_ITEM="0436e1bc-b325-4caa-b87f-1b0775894063"

# Resolve NODE_AUTH_TOKEN for GitHub Packages builds. Precedence:
#   1. existing $NODE_AUTH_TOKEN (operator override) — always wins.
#   2. Bitwarden, if the `bw` CLI is unlocked (BW_SESSION exported).
# Best-effort + non-fatal: a deploy that doesn't pull @jordimo (infra, or a
# project that builds the SDK locally) proceeds regardless; only a build that
# actually needs the token fails — with a clear npm 401 — if it can't be resolved.
# The repos' .npmrc uses ${NODE_AUTH_TOKEN}; the Dockerfile injects it as a
# BuildKit secret during `npm ci` (never baked into an image layer).
resolve_node_auth_token() {
    [ -n "${NODE_AUTH_TOKEN:-}" ] && { echo -e "${CYAN}NODE_AUTH_TOKEN: using value from environment.${NC}"; return 0; }
    if ! command -v bw >/dev/null 2>&1; then
        echo -e "${YELLOW}NODE_AUTH_TOKEN unset and 'bw' CLI not found — export it manually if this build pulls @jordimo packages.${NC}"
        return 0
    fi
    local bw_status
    bw_status="$(bw status 2>/dev/null | grep -o '"status":"[^"]*"' | cut -d'"' -f4)"
    if [ "$bw_status" != "unlocked" ]; then
        echo -e "${YELLOW}NODE_AUTH_TOKEN unset and Bitwarden is locked — run 'export BW_SESSION=\$(bw unlock --raw)' first, or export NODE_AUTH_TOKEN manually.${NC}"
        return 0
    fi
    local tok
    tok="$(bw get password "$GH_PACKAGES_TOKEN_ITEM" 2>/dev/null || true)"
    if [ -n "$tok" ]; then
        export NODE_AUTH_TOKEN="$tok"
        echo -e "${CYAN}NODE_AUTH_TOKEN: loaded from Bitwarden.${NC}"
    else
        echo -e "${YELLOW}Couldn't read NODE_AUTH_TOKEN from Bitwarden (item ${GH_PACKAGES_TOKEN_ITEM}). Export it manually if needed.${NC}"
    fi
}

usage() {
    echo "Usage: ./deploy.sh --target <target> <project|infra|--all>"
    echo ""
    echo "Targets:"
    echo "  do:<ssh-alias>  Remote server, e.g. do:zora (Hetzner). 'do:' is a legacy prefix from the DigitalOcean era; the part after the colon is your SSH alias from ~/.ssh/config."
    echo "  aws            AWS (aws01)"
    echo ""
    echo "Examples:"
    echo "  ./deploy.sh --target do:zora marie"
    echo "  ./deploy.sh --target do:zora infra"
    echo "  ./deploy.sh --target do:zora --all"
    exit 1
}

# ---- Parse args ----
TARGET=""
ACTION=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --target) TARGET="$2"; shift 2 ;;
        --all) ACTION="all"; shift ;;
        -*) echo "Unknown option: $1"; usage ;;
        *) ACTION="$1"; shift ;;
    esac
done

[ -z "$TARGET" ] && { echo -e "${RED}Error: --target is required${NC}"; echo ""; usage; }
[ -z "$ACTION" ] && usage

# ---- Environment config ----
case "$TARGET" in
    do:*)
        REMOTE="${TARGET#do:}"
        TARGET_KEY="${REMOTE}"
        INFRA_DIR="/home/deploy/infra"
        APP_DIR="/home/deploy"
        ;;
    aws)
        REMOTE="aws01"
        TARGET_KEY="aws01"
        INFRA_DIR="/app/infra"
        APP_DIR="/app"
        ;;
    *)
        echo -e "${RED}Error: Unknown target '${TARGET}'. Use do:<droplet> or aws.${NC}"
        exit 1
        ;;
esac

ssh_cmd() { ssh "$REMOTE" "$@"; }

deploy_infra() {
    echo -e "${CYAN}[infra] Syncing to origin/main...${NC}"
    # Self-heal: force the deploy mirror to origin/main regardless of current state
    # (detached HEAD, wrong branch, or local drift). A bare `git pull` fails on a
    # detached/stranded checkout — which is exactly how prod gets wedged.
    ssh_cmd "cd ${INFRA_DIR} && git fetch origin --prune -q && git checkout -f -B main origin/main"

    echo -e "${CYAN}[infra] Restarting services...${NC}"
    ssh_cmd "cd ${INFRA_DIR} && docker compose up -d"

    echo -e "${GREEN}[infra] Done${NC}"
}

deploy_project() {
    local name="$1"
    local project_dir="${APP_DIR}/${name}"

    # Check project exists
    if ! ssh_cmd "test -d ${project_dir}"; then
        echo -e "${RED}[${name}] Directory ${project_dir} not found.${NC}"
        echo ""
        echo "  To set up this project for the first time, run:"
        echo "    ./init-project.sh ${name} --target ${TARGET} --repo <git-url>"
        echo ""
        return 1
    fi

    # Pick the compose file. Order of preference:
    #   1. docker-compose.<target_key>.yml — host-specific (e.g. aws01,
    #      zora). Use this when a project's prod routing differs by
    #      target (e.g. Marie on aws01 needs path-based + HTTP, on zora
    #      needs path-based under thecollective.lostriver.llc + HTTPS —
    #      labels can't sanely be parametrized in a single file).
    #   2. docker-compose.prod.yml — generic prod compose, works for any
    #      server. The default for projects whose prod config is uniform.
    #   3. docker-compose.yml — fallback for projects that haven't split
    #      out a prod-specific file yet.
    local COMPOSE_FILE=""
    for candidate in "docker-compose.${TARGET_KEY}.yml" "docker-compose.prod.yml" "docker-compose.yml"; do
        if ssh_cmd "test -f ${project_dir}/${candidate}"; then
            COMPOSE_FILE="$candidate"
            break
        fi
    done

    if [ -z "$COMPOSE_FILE" ]; then
        echo -e "${RED}[${name}] No compose file found in ${project_dir}${NC}"
        echo ""
        echo "  Looked for: docker-compose.${TARGET_KEY}.yml, docker-compose.prod.yml, docker-compose.yml"
        echo "  Add one. See the README for templates."
        echo ""
        return 1
    fi

    # Assemble the `-f` args. A docker-compose override file is included when
    # present so its overlay (e.g. build: contexts that the primary prod
    # compose omits) is merged in. Docker only auto-loads
    # docker-compose.override.yml when invoked without `-f`; since we always
    # pass `-f`, the override must be listed explicitly or `--build` below
    # silently rebuilds nothing. Host-specific override wins if both exist.
    local COMPOSE_FILES="-f ${COMPOSE_FILE}"
    for override in "docker-compose.${TARGET_KEY}.override.yml" "docker-compose.override.yml"; do
        # Skip if it's the primary file we already selected.
        [ "$override" = "$COMPOSE_FILE" ] && continue
        if ssh_cmd "test -f ${project_dir}/${override}"; then
            COMPOSE_FILES="${COMPOSE_FILES} -f ${override}"
            echo -e "${CYAN}[${name}] Including override ${override}${NC}"
            break
        fi
    done

    echo -e "${CYAN}[${name}] Syncing to origin/main...${NC}"
    # Self-heal: force this deploy mirror to origin/main regardless of current state
    # (detached HEAD, wrong branch, local drift). A bare `git pull` fails on a
    # detached/stranded checkout — both zora consumer dirs were wedged this way.
    ssh_cmd "cd ${project_dir} && git fetch origin --prune -q && git checkout -f -B main origin/main"

    # Resolve the GitHub Packages build token (no-op if already set / not needed).
    resolve_node_auth_token
    # Inject NODE_AUTH_TOKEN into the REMOTE build env only when we have one — the
    # build runs on the host, and projects pulling @jordimo/* need it for npm ci.
    # Omitted when empty so non-package builds don't get a spurious export.
    local remote_env=""
    [ -n "${NODE_AUTH_TOKEN:-}" ] && remote_env="export NODE_AUTH_TOKEN='${NODE_AUTH_TOKEN}' && "

    echo -e "${CYAN}[${name}] Rebuilding containers (${COMPOSE_FILES})...${NC}"
    ssh_cmd "cd ${project_dir} && ${remote_env}docker compose ${COMPOSE_FILES} up -d --build"

    echo -e "${GREEN}[${name}] Done${NC}"
}

deploy_all() {
    deploy_infra
    echo ""

    # Find all projects with a compose file
    local projects
    projects=$(ssh_cmd "ls -d ${APP_DIR}/*/docker-compose*.yml 2>/dev/null | xargs -I{} dirname {} | sort -u" || true)

    for project_dir in $projects; do
        local name=$(basename "$project_dir")
        # Skip infra directory
        [ "$name" = "infra" ] && continue
        echo ""
        deploy_project "$name"
    done
}

# ---- Main ----
case "$ACTION" in
    infra)
        deploy_infra
        ;;
    all)
        deploy_all
        ;;
    *)
        deploy_project "$ACTION"
        ;;
esac

echo ""
echo -e "${GREEN}Deploy complete.${NC}"
