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

# Detect profiles
PROFILE_FLAG=""
if grep -q '^COMPOSE_PROFILES=.*local' .env 2>/dev/null; then
    PROFILE_FLAG="--profile local"
fi
if grep -q '^COMPOSE_PROFILES=.*phoenix' .env 2>/dev/null; then
    PROFILE_FLAG="$PROFILE_FLAG --profile phoenix"

    # Phoenix ships with auth OFF; this compose turns it on, which means these
    # two must be set or the container comes up unauthenticated-or-broken.
    MISSING=""
    for var in PHOENIX_SECRET PHOENIX_ADMIN_SECRET PHOENIX_ADMIN_PASSWORD; do
        grep -qE "^${var}=.+" .env 2>/dev/null || MISSING="$MISSING $var"
    done
    if [ -n "$MISSING" ]; then
        echo "COMPOSE_PROFILES includes 'phoenix' but these are unset in .env:"
        for var in $MISSING; do echo "    $var"; done
        echo ""
        echo "Generate the two secrets with:  openssl rand -hex 32"
        echo "PHOENIX_ADMIN_SECRET must DIFFER from PHOENIX_SECRET."
        exit 1
    fi
    if grep -q "^PHOENIX_SECRET=$(grep '^PHOENIX_ADMIN_SECRET=' .env | cut -d= -f2-)$" .env 2>/dev/null; then
        echo "PHOENIX_SECRET and PHOENIX_ADMIN_SECRET are identical — Phoenix rejects that."
        exit 1
    fi

    # Phoenix creates its schema but not the database.
    if docker ps --format '{{.Names}}' | grep -qx postgres; then
        if ! docker exec postgres psql -U "${POSTGRES_USER:-postgres}" -lqt 2>/dev/null | cut -d\| -f1 | grep -qw phoenix; then
            echo "Creating 'phoenix' database in postgres..."
            docker exec postgres createdb -U "${POSTGRES_USER:-postgres}" phoenix
        fi
    fi
fi
if grep -q '^COMPOSE_PROFILES=.*langfuse' .env 2>/dev/null; then
    PROFILE_FLAG="$PROFILE_FLAG --profile langfuse"

    # Langfuse has three secrets with no safe default. They are NOT enforced by
    # compose itself: a `${VAR:?}` guard is evaluated at parse time even for
    # services whose profile is inactive, which would break `docker compose` on
    # every host that doesn't run Langfuse. So the check lives here instead.
    MISSING=""
    for var in LANGFUSE_ENCRYPTION_KEY CLICKHOUSE_PASSWORD MINIO_ROOT_PASSWORD; do
        if ! grep -qE "^${var}=.+" .env 2>/dev/null; then
            MISSING="$MISSING $var"
        fi
    done
    if [ -n "$MISSING" ]; then
        echo "COMPOSE_PROFILES includes 'langfuse' but these are unset in .env:"
        for var in $MISSING; do echo "    $var"; done
        echo ""
        echo "Generate each with:  openssl rand -hex 32"
        echo "LANGFUSE_ENCRYPTION_KEY must be exactly 64 hex chars and can never"
        echo "be rotated without invalidating every encrypted row — set it once."
        exit 1
    fi

    # Prisma migrates the schema but will not create the database itself.
    if docker ps --format '{{.Names}}' | grep -qx postgres; then
        if ! docker exec postgres psql -U "${POSTGRES_USER:-postgres}" -lqt 2>/dev/null | cut -d\| -f1 | grep -qw langfuse; then
            echo "Creating 'langfuse' database in postgres..."
            docker exec postgres createdb -U "${POSTGRES_USER:-postgres}" langfuse
        fi
    fi
fi

# ---------------------------------------------------------------------------
# Local dev: ensure .localhost domains for infra services
# ---------------------------------------------------------------------------
if grep -q '^COMPOSE_PROFILES=.*local' .env 2>/dev/null; then
    # Infra services that need .localhost domains
    # Format: name:domain (cert files use the name, not the domain)
    INFRA_DOMAINS=(
        "analytics:analytics.localhost"
    )
    if grep -q '^COMPOSE_PROFILES=.*phoenix' .env 2>/dev/null; then
        INFRA_DOMAINS+=("phoenix:phoenix.localhost")
    fi
    # Only mint a langfuse cert when the langfuse profile is actually enabled.
    if grep -q '^COMPOSE_PROFILES=.*langfuse' .env 2>/dev/null; then
        INFRA_DOMAINS+=("langfuse:langfuse.localhost")
    fi

    for entry in "${INFRA_DOMAINS[@]}"; do
        CERT_NAME="${entry%%:*}"
        DOMAIN="${entry##*:}"

        # /etc/hosts
        if ! grep -q "$DOMAIN" /etc/hosts; then
            echo "Adding $DOMAIN to /etc/hosts (requires sudo)..."
            echo "127.0.0.1 $DOMAIN" | sudo tee -a /etc/hosts >/dev/null
        fi

        # mkcert certificate
        if [ ! -f "certs/${CERT_NAME}.pem" ]; then
            if command -v mkcert &>/dev/null; then
                mkcert -cert-file "certs/${CERT_NAME}.pem" -key-file "certs/${CERT_NAME}-key.pem" "$DOMAIN"
            else
                echo "Warning: mkcert not installed — install with: brew install mkcert"
            fi
        fi
    done
fi

echo "Starting infrastructure..."
docker compose $PROFILE_FLAG up -d

# Show what's running
echo ""
echo "Running:"
echo "  Traefik dashboard: http://localhost:8080"
echo "  PostgreSQL:        localhost:5432"
echo "  Redis:             localhost:6379"
if grep -q '^COMPOSE_PROFILES=.*local' .env 2>/dev/null; then
    echo "  Umami:             https://analytics.localhost  (admin / umami)"
    echo "  Mailpit:           http://localhost:8025"
    if grep -q '^COMPOSE_PROFILES=.*phoenix' .env 2>/dev/null; then
        echo "  Phoenix:           https://phoenix.localhost    (admin@localhost / see PHOENIX_ADMIN_PASSWORD)"
    fi
    if grep -q '^COMPOSE_PROFILES=.*langfuse' .env 2>/dev/null; then
        echo "  Langfuse:          https://langfuse.localhost   ($(grep '^LANGFUSE_INIT_USER_EMAIL=' .env | cut -d= -f2-) / see LANGFUSE_INIT_USER_PASSWORD)"
        echo "  MinIO console:     http://localhost:9091"
    fi
else
    echo "  Umami:             http://localhost:3040"
    if grep -q '^COMPOSE_PROFILES=.*phoenix' .env 2>/dev/null; then
        echo "  Phoenix:           http://localhost:6006"
    fi
    if grep -q '^COMPOSE_PROFILES=.*langfuse' .env 2>/dev/null; then
        echo "  Langfuse:          http://localhost:3030"
    fi
fi
echo ""
echo "Add projects with: ./init-project.sh <name> --target local --dir <path>"
echo ""
