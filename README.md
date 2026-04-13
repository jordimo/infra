# THECOLLECTIVE_AWS_INFRA

Infrastructure and deployment tooling for **THECOLLECTIVE_AWS01** (EC2 at `52.72.211.242`).

## Architecture

```
Personal laptop  →  GitHub  ←  Corporate laptop  →  VM
  (git push)       (repos)      (deploy scripts)    (runs containers)
```

- **Personal laptop**: write code, push to GitHub
- **Corporate laptop**: runs deploy scripts over SSH (VPN required)
- **VM**: Docker containers behind Traefik reverse proxy

### What runs on the VM

```
/app/
├── Deployer/               ← this repo (infra + scripts)
│   ├── traefik/
│   │   ├── docker-compose.yml   ← Traefik, Postgres, Redis, Langfuse
│   │   └── dynamic/             ← per-project routing configs
│   ├── deploy.sh
│   ├── init-project.sh
│   ├── project.sh
│   ├── start.sh / stop.sh / setup.sh
│   └── bootstrap.sh
│
├── marie/                   ← project repo (cloned via deploy key)
│   ├── docker-compose.vm.yml
│   └── .env
│
└── <future-project>/
    ├── docker-compose.vm.yml
    └── .env
```

### Routing

Traefik is the only container exposed to the internet (port 80). Everything else is internal. Routing is path-based:

```
http://52.72.211.242/marie      → marie-web container
http://52.72.211.242/marie/api  → marie-api container
```

### Shared services (internal only)

| Service  | Access from containers | Notes |
|----------|----------------------|-------|
| Postgres | `postgres:5432`      | pgvector/pg16, one DB per project |
| Redis    | `redis:6379`         | DB 0-15 per project |
| Langfuse | `langfuse:3000`      | SSH tunnel for UI: `ssh -L 3030:localhost:3030 aws01` |

## Prerequisites (corporate laptop)

### SSH config

Add to `~/.ssh/config`:

```
Host aws01
    HostName 10.251.8.172
    User ubuntu
    IdentityFile ~/.ssh/AWSNMTNAPP001-keypair.pem
```

### Clone this repo

```bash
git clone git@github.com-personal:jordimo/THECOLLECTIVE_AWS_INFRA.git ~/Dev/THECOLLECTIVE/Deployer
```

## Day-to-day: deploying changes

After pushing code to GitHub from the dev laptop:

```bash
# Deploy a project (pulls latest code on VM + rebuilds containers)
./deploy.sh marie

# Deploy infrastructure changes
./deploy.sh infra

# Deploy everything
./deploy.sh --all
```

## First-time: bootstrapping the VM

If the VM is completely fresh (no Docker, no Git):

```bash
ssh ubuntu@10.251.8.172 'curl -fsSL https://raw.githubusercontent.com/jordimo/THECOLLECTIVE_AWS_INFRA/main/bootstrap.sh | bash'
```

Then set the Postgres password:

```bash
ssh aws01 'echo "POSTGRES_PASSWORD=<from-bitwarden>" > /app/Deployer/traefik/.env'
ssh aws01 'echo "LANGFUSE_SECRET=<from-bitwarden>" >> /app/Deployer/traefik/.env'
ssh aws01 'echo "LANGFUSE_SALT=<from-bitwarden>" >> /app/Deployer/traefik/.env'
ssh aws01 'cd /app/Deployer && ./start.sh'
```

## First-time: adding a new project

### 1. Set up a deploy key on the VM

```bash
# Generate key (one-time)
ssh aws01 'ssh-keygen -t ed25519 -f ~/.ssh/github_deploy_<project> -N ""'
ssh aws01 'cat ~/.ssh/github_deploy_<project>.pub'
```

Add the public key at `https://github.com/<user>/<repo>/settings/keys` → read-only.

If this is a second deploy key, update `~/.ssh/config` on the VM to map each key to the right repo.

### 2. Add `docker-compose.vm.yml` to the project repo

Same as `docker-compose.yml` but adapted for the VM:
- Network: `traefik-public` (external)
- No volume mounts (no hot reload)
- `restart: unless-stopped`
- `NODE_ENV=production`

### 3. Add `.env.example.vm` to the project repo

Template for VM-specific env vars. Use the shared Postgres (`postgres:5432`) and Langfuse (`langfuse:3000`).

### 4. Run init-project.sh

```bash
./init-project.sh <name> git@github.com:<user>/<repo>.git
```

This clones the repo, creates the DB, pauses for `.env` setup, registers Traefik routing, builds containers, runs migrations, and creates the admin user.

### 5. Store secrets in Bitwarden

Add all `.env` values to the `THECOLLECTIVE_AWS01` Secure Note as hidden custom fields.

## Scripts reference

| Script | Run from | Purpose |
|--------|----------|---------|
| `bootstrap.sh` | VM (first time) | Install Docker, Git, clone repo |
| `setup.sh` | VM | Create network, scaffold `.env` |
| `start.sh` | VM | Start Traefik + Postgres + Redis + Langfuse |
| `stop.sh` | VM | Stop infrastructure |
| `project.sh add <name>` | VM | Register Traefik routing for a project |
| `project.sh rm <name>` | VM | Remove Traefik routing |
| `project.sh ls` | VM | List registered projects |
| `init-project.sh` | Corporate laptop | Full first-time project setup |
| `deploy.sh` | Corporate laptop | Pull + rebuild (day-to-day deploys) |

## SSH access

```bash
ssh aws01                              # Shell on the VM
ssh -L 3030:localhost:3030 aws01       # Langfuse UI → http://localhost:3030
ssh -L 8080:localhost:8080 aws01       # Traefik dashboard → http://localhost:8080
```

## Secrets

All secrets are in Bitwarden under the `THECOLLECTIVE_AWS01` Secure Note. Convention: if it goes in a `.env` file, it goes in Bitwarden.
