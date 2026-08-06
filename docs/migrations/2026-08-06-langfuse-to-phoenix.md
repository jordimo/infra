# LLM observability: Langfuse → Arize Phoenix

**Date filed:** 2026-08-06
**Why:** Langfuse v4 needs six moving parts (web, worker, ClickHouse, S3/MinIO, Postgres, Redis) and ~1.85 GiB even after tuning. Phoenix does the same job in one container against the Postgres we already run, at ~400 MiB. On aws01 — 7.5 GiB shared with ~1.4 GiB of IT-managed agents — that is the difference between ~61% and a measured **39%** host memory use.

**Goal:** One observability stack on every host. Same tool, same shape, same auth model on local, zora and aws01.

**Status:** Local cut over and verified. **aws01 deployed and verified** (aws01-stack PR #1). zora unreachable, undeployed.

---

## Decision

Phoenix is the standard. Langfuse stays in `docker-compose.yml` behind its `langfuse` profile — working and tested, not the default anywhere.

The intermediate position (Langfuse on personal infra, Phoenix on aws01) was explicitly rejected: two systems to learn and debug for one job. Standardise on whatever fits the most constrained host.

### Measured, not assumed

Both stacks on the same machine, same OTLP payloads, 2026-08-06:

| | containers | resident | external deps |
|---|---|---|---|
| Langfuse v4 (tuned) | 4 | 1848 MiB | Postgres + Redis + ClickHouse + S3 |
| Phoenix 19.18.0 | 1 | ~400 MiB | Postgres only |

Phoenix ingested 500 spans under a 1 GiB cap at 411 MiB, no OOM, no restarts.

### Feature parity — verified against the live schema

Comparison write-ups frame Phoenix as the "lightweight alternative", which reads as feature-poor. It isn't. Querying the database directly:

| capability | Phoenix tables | notes |
|---|---|---|
| model prices | `generative_models` (268), `token_prices` (797) | separate input / output / cache-read / cache-write rates; knows `claude-opus-5`, `claude-sonnet-5`, `gpt-5`, `gpt-5.4` |
| prompt management | `prompts`, `prompt_versions`, `prompt_version_tags`, `prompt_labels` | versioning + labels |
| datasets / experiments | `datasets`, `dataset_versions`, `experiments`, `experiment_runs` | |
| evals | `builtin_evaluators`, `evaluators` | |

The cost catalog matters specifically: `totalCost: 0` on current models is what forced the Langfuse v2 → v3 migration in April. Phoenix covers it out of the box.

### What we actually give up

1. **Licensing.** Phoenix is Elastic License 2.0 — not OSI open source. Langfuse core is MIT. No practical constraint for internal use; know it before shipping anything customer-facing on top.
2. **Scale ceiling.** Phoenix stores spans in Postgres. ClickHouse exists in Langfuse precisely because Postgres stops keeping up at high trace volume. Nowhere near that here — but it is the thing that forces a revisit.

---

## Where the data lives

Everything is in the shared Postgres, database `phoenix` (62 tables, 12 MB with one project): spans, projects, users, roles, datasets, experiments, prompts, model prices.

The `phoenix_data` volume (`PHOENIX_WORKING_DIR`) is **0 bytes** — it only carries data in SQLite mode.

Consequences:

- **Backups:** whatever covers Postgres covers Phoenix. No separate path.
- **Growth:** spans land in the same Postgres as `librarian` (182 MB), `marie`, `caitie_db`, `hub` and 13 others. `PHOENIX_RETENTION_DAYS=90` bounds it — upstream defaults to keep-forever (`0`).

---

## Runbook — per host

```bash
# 1. create the database (Phoenix builds its own schema, not the database)
docker exec postgres createdb -U postgres phoenix

# 2. generate two secrets — they MUST differ
openssl rand -hex 32   # -> PHOENIX_SECRET
openssl rand -hex 32   # -> PHOENIX_ADMIN_SECRET

# 3. set in .env
#    COMPOSE_PROFILES=local,phoenix     (local)
#    COMPOSE_PROFILES=phoenix           (server)
#    PHOENIX_SECRET / PHOENIX_ADMIN_SECRET / PHOENIX_ADMIN_PASSWORD
#    Server: leave PHOENIX_TRAEFIK=false and tunnel instead.

# 4. start
./start.sh                                    # local (mints the mkcert cert)
docker compose --profile phoenix up -d        # server
```

`start.sh` refuses to start if the secrets are unset or identical, and creates the database if missing.

**Access:** `https://phoenix.localhost` locally; `ssh -L 6006:localhost:6006 <host>` on a server. Login `admin@localhost` / `PHOENIX_ADMIN_PASSWORD`.

**Instrumentation:** apps send OTLP in-cluster to `http://phoenix:6006/v1/traces` (HTTP) or `phoenix:4317` (gRPC) with `Authorization: Bearer $PHOENIX_ADMIN_SECRET`.

### aws01

aws01 does not run this repo — it runs `JordiMartinez-TMA/aws01-stack`. The equivalent change lives there as `phoenix/docker-compose.yml` + `phoenix/.env.example`, with `deploy.sh` hooked to deploy it only once `phoenix/.env` exists. Same runbook, `stack` network instead of `infra`.

---

## Gotchas — all found by running it, not reading docs

1. **The image is distroless.** No `sh`, `wget` or `curl`. A `CMD-SHELL` healthcheck fails with "executable not found" and the container never reports healthy — which also means Traefik never publishes a router for it. Use the exec form with `python`, the one interpreter present.
2. **OTLP/HTTP requires protobuf.** The same JSON payload Langfuse accepts returns **HTTP 415**. Use an OTLP SDK exporter, not hand-rolled JSON.
3. **Auth ships OFF.** Without `PHOENIX_ENABLE_AUTH=True` the UI and the entire API are open to anything that can reach the container. This compose turns it on and leaves `/healthz` unauthenticated so the healthcheck still passes.
4. **`PHOENIX_ADMIN_SECRET` must differ from `PHOENIX_SECRET`**, be ≥32 chars, and contain a digit and a lowercase letter. `openssl rand -hex 32` satisfies all three.
5. **Retention defaults to keep-forever.** Nothing else prunes the spans table.

---

## Rollback

Langfuse was not deleted. Its four services remain in `docker-compose.yml` behind `profiles: [langfuse]`, the `langfuse` Postgres database (13 MB) is intact, and the three `langfuse_*` volumes are untouched.

```bash
docker compose --profile phoenix down
# set COMPOSE_PROFILES=local,langfuse in .env
./start.sh
```

Langfuse's own constraints still apply on the way back — see `docs/dev-diary/2026-08-06.md`, in particular that `LANGFUSE_ENCRYPTION_KEY` cannot be rotated without invalidating every encrypted row.

---

## aws01 — deployed 2026-08-06

Landed as `JordiMartinez-TMA/aws01-stack` PR #1 and deployed. Verified on the box: healthy, 0 restarts, **446 MiB against a 1 GiB cap**, 401 unauthenticated / 200 with bearer, `/healthz` 200, 62 tables with 797 token prices, and `10.251.8.172:6006` **refused** from the VPN (loopback only).

**Host: 3013 / 7677 MiB = 39% used**, 4.6 GiB available, swap untouched. Tuned Langfuse on the same box would have been ~61%, untuned ~76%.

Note `deploy.sh` recreates the infra and app containers as part of its reconcile — everything except `puncher-*` restarts during a run.

## Open

- **zora:** unverified — SSH times out during banner exchange from this network. The one host not yet on Phoenix.
- **Instrumentation:** no app is sending traces yet. The stack is up on two hosts; nothing reports into it. newsintel and company_intel are Python — OpenInference instrumentors against `http://phoenix:6006/v1/traces` with the bearer token.
- **`~/.ssh/config`:** still has `aws01-langfuse` forwarding 3030; wants `aws01-phoenix` forwarding 6006.
