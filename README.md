# infra

Shared infrastructure for all environments: **Hetzner** (zora), **AWS** (THECOLLECTIVE_AWS01), and **local dev**.

One `docker-compose.yml`, all environments. Differences live in `.env`.

> **History:** the primary production server was DigitalOcean (`isidora`) until 2026-05-02. It was migrated to Hetzner (`zora`) on that date. The target key `do:zora` in `deploy.sh` / `init-project.sh` is vestigial — `do:` no longer literally means DigitalOcean; it just routes to the host alias after the colon (matched against `~/.ssh/config`). Renaming the target key is queued; see `docs/dev-diary/` for the cutover notes.

## What this repo provides

Traefik, PostgreSQL (pgvector), Redis, Langfuse, and Mailpit (local only) — running on every environment with the same conventions. Projects connect via the `infra` Docker network.

### Shared services

| Service  | From containers     | From host (dev)          | From host (server)              |
|----------|--------------------|--------------------------|---------------------------------|
| Postgres | `postgres:5432`    | `localhost:5432`         | Internal only                   |
| Redis    | `redis:6379`       | `localhost:6379`         | Internal only                   |
| Langfuse | `langfuse:3000`    | `https://langfuse.local` | SSH tunnel `localhost:3030`     |
| Traefik  | N/A                | `https://*.local`        | Ports 80/443                    |
| Mailpit  | `mailpit:1025`     | `localhost:8025`         | N/A (local only)                |

## Repository structure

```
infra/
├── docker-compose.yml        ← Unified infra (all environments)
├── .env.example              ← Template (covers local + server)
├── dynamic/                  ← Traefik dynamic config
│   ├── dynamic.yml           ← Health checks, security headers (committed)
│   ├── middlewares.yml       ← Shared middlewares (committed)
│   ├── tls.yml               ← Local mkcert certs (gitignored)
│   └── routing-*.yml         ← Local project routing (gitignored)
├── certs/                    ← Local mkcert certificates (gitignored)
├── init-project.sh           ← Set up a new project (any environment)
├── deploy.sh                 ← Deploy from corporate laptop over SSH
├── traefik/                  ← AWS-specific infra (path-based routing)
└── docs/
    ├── plans/
    └── dev-diary/
```

## Quick start

### Local dev

```bash
cp .env.example .env
docker compose --profile local up -d
```

Services: Traefik (`:8080`), Postgres (`:5432`), Redis (`:6379`), Langfuse (`:3030`), Mailpit (`:8025`)

### Server (zora / AWS)

```bash
cp .env.example .env
# Edit .env: production secrets, COMPOSE_PROFILES (drop "local" to disable Mailpit),
# TRAEFIK_INSECURE=false, ACME_EMAIL, CF_DNS_API_TOKEN, etc.
docker compose up -d
```

The same `.env.example` covers both — comments inline call out which fields are local-only vs production-required.

## Environments

### Hetzner — zora (178.156.133.68)

Primary production server. Host- and path-based routing with Let's Encrypt TLS (DNS-01 via Cloudflare). All public domains sit behind the Cloudflare proxy (orange cloud) — origin IP is not reachable from typical corporate networks running SSL inspection.

```
/home/deploy/
├── infra/                                ← this repo
└── THECOLLECTIVE/
    ├── TheHub/                           ← thecollective.lostriver.llc/thehub
    ├── Marie/                            ← thecollective.lostriver.llc/marie
    ├── Librarian/                        ← thecollective.lostriver.llc/librarian
    ├── newsintel/                        ← newsintel.lostriver.llc
    ├── company-intel/                    ← intel.lostriver.llc
    └── vault/                            ← vault.lostriver.llc
```

(The shared `thecollective.lostriver.llc` host serves multiple tools under path prefixes; each project owns its own `docker-compose.zora.yml` overlay with Traefik labels. Per-tool subdomains like `marie.lostriver.llc` are archived — see `docs/dev-diary/` for the cutover.)

**SSH:**
```bash
ssh zora                            # Shell (alias resolves to deploy@178.156.133.68)
ssh -L 3030:localhost:3030 zora     # Langfuse UI
ssh -L 8080:localhost:8080 zora     # Traefik dashboard
```

### AWS — THECOLLECTIVE_AWS01 (10.251.8.172 via VPN)

Internal server. Path-based routing, no TLS (VPN access only). Uses `traefik/docker-compose.yml`.

### Local dev

Uses `~/Dev/infra/` with mkcert TLS and `*.local` domains. Same compose file as servers, with `COMPOSE_PROFILES=local` for Mailpit and dev-only defaults.

## Day-to-day: deploying

All scripts run from this repo (`~/Dev/infra/`). They SSH into the server, pull the latest code, and rebuild.

```bash
# Deploy a project
./deploy.sh --target do:zora marie

# Deploy infra (git pull + restart services)
./deploy.sh --target do:zora infra

# Deploy everything (infra + all projects)
./deploy.sh --target do:zora --all

# AWS
./deploy.sh --target aws marie
```

> The `do:` prefix is a legacy name from the DigitalOcean era; the part after the colon is the SSH alias (resolved via `~/.ssh/config`). `do:zora` reaches the Hetzner box at `178.156.133.68`. A future cleanup will rename the prefix to something host-neutral (`host:zora`) — until then the `do:` token is stable and scripts depend on it.

The deploy script doesn't need the git URL — the repo is already cloned on the server (set up by `init-project.sh`). It just does `git pull && docker compose up -d --build`.

If a project isn't found, the script suggests running `init-project.sh`.

## Adding a new project

### Using `init-project.sh` (recommended)

The script automates database creation, repo cloning, .env setup, mkcert certificates, /etc/hosts, Traefik routing, container builds, and migrations.

```bash
# Local — project already cloned
./init-project.sh acme --target local --dir ~/Dev/THECOLLECTIVE/Acme

# Local — clone and set up
./init-project.sh acme --target local --dir ~/Dev/Acme --repo git@github.com:jordimo/Acme.git

# Zora — clone from GitHub
./init-project.sh acme --target do:zora --repo git@github.com:jordimo/Acme.git

# Zora — project already on server
./init-project.sh acme --target do:zora

# AWS
./init-project.sh acme --target aws --repo git@github.com:jordimo/Acme.git

# Custom database name
./init-project.sh acme --target do:zora --db acme_production --repo git@github.com:jordimo/Acme.git
```

Options:
- `--target` — **Required.** `local`, `do:<host-alias>`, or `aws`
- `--dir` — Project directory (required for local, defaults to `/home/deploy/<name>` on server)
- `--repo` — Git repo URL (clones if directory doesn't exist)
- `--db` — Database name (defaults to project name)

**After running the script**, update `docs/plans/infra-unification.md` → `registry.yml` with the new app entry (domain, containers, ports, db, redis_db).

### Manual setup

If you prefer manual steps or the script doesn't fit your case:

#### 1. Deploy key (servers only)

```bash
ssh zora
ssh-keygen -t ed25519 -f ~/.ssh/github_deploy_acme -N ""
cat ~/.ssh/github_deploy_acme.pub
```

Add at `https://github.com/<user>/Acme/settings/keys` (read-only).

For multiple deploy keys, add to `~/.ssh/config`:
```
Host github.com-acme
    HostName github.com
    User git
    IdentityFile ~/.ssh/github_deploy_acme
```

#### 2. Project compose files

Each project has at minimum two compose files:

- **`docker-compose.yml`** — local dev (volume mounts, hot reload, no Traefik labels)
- **`docker-compose.prod.yml`** — generic prod (production builds, Traefik labels, healthchecks)

For most projects, runtime differences between servers live in `.env` only (`DOMAIN`, `DATABASE_URL`).

**Host-specific compose files (when `.env` isn't enough):** `docker-compose.<target>.yml`. Use this when a project's prod **routing** itself differs by target — e.g. subdomain `Host()` + HTTPS on zora vs path-based `PathPrefix` + plain HTTP on aws01, or subdomain vs path-based on zora itself (the lostriver path-based migration). Traefik labels can't sanely be parametrized end-to-end through env vars, so two files is the cleanest split.

Recognized target keys (matched by `deploy.sh`):
- `aws01` for `--target aws`
- the SSH alias (e.g. `zora`) for `--target do:zora`

`deploy.sh` resolution order: `docker-compose.<target_key>.yml` → `docker-compose.prod.yml` → `docker-compose.yml`. So a project can add a host-specific overlay without breaking other targets.

**Example:** Marie ships `docker-compose.prod.yml` (legacy subdomain HTTPS shape — archived) and `docker-compose.zora.yml` (path-based under `thecollective.lostriver.llc/marie`). Librarian ships `docker-compose.zora.yml` mirroring Marie's path-based pattern.

#### 3. `.env.example`

```env
# --- Server-specific (change per environment) ---
DOMAIN=acme.local
DATABASE_URL=postgresql://postgres:postgres@postgres:5432/acme

# --- Secrets (generate once, store in Bitwarden) ---
JWT_SECRET=
OPENAI_API_KEY=

# --- Langfuse (per-project keys from Langfuse UI) ---
LANGFUSE_BASEURL=http://langfuse:3000
LANGFUSE_PUBLIC_KEY=
LANGFUSE_SECRET_KEY=

# --- Defaults (usually don't change) ---
PORT=3000
NODE_ENV=production
```

#### 4. DNS (zora only)

In Cloudflare for `lostriver.llc`:
1. Add an A record: `acme.lostriver.llc → 178.156.133.68`
2. **Enable the orange-cloud proxy** on the record (this is the default convention)

Why proxied: corp SSL-inspection filters often block traffic to single-host IP ranges. Cloudflare IPs are universally trusted. Also hides origin IP and adds DDoS / edge caching.

Certs are issued via DNS-01 ACME challenge using `CF_DNS_API_TOKEN` in infra `.env`, so the orange cloud doesn't break renewals. Cache bypass rule for `/api/*` is already configured zone-wide.

#### 5. Langfuse integration

1. Access Langfuse UI (`ssh -L 3030:localhost:3030 zora`, then `http://localhost:3030`)
2. **New Project** → name it "Acme"
3. **Settings → API Keys → Create API Key**
4. Add to the project's `.env`:
   ```env
   LANGFUSE_BASEURL=http://langfuse:3000
   LANGFUSE_PUBLIC_KEY=pk-lf-...
   LANGFUSE_SECRET_KEY=sk-lf-...
   ```

## Secrets

All server secrets are in Bitwarden:
- **THECOLLECTIVE_AWS01** Secure Note — AWS credentials and env vars
- Hetzner/zora secrets stored similarly (one Secure Note per project + a shared "infra" note for Postgres / Traefik / Cloudflare credentials)

Convention: if it goes in `.env`, it goes in Bitwarden.
