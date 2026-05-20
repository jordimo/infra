# Local-domain migration: `.local` → `.localhost`

**Date filed:** 2026-05-20
**Why:** macOS resolves `*.local` via mDNS/Bonjour even when `/etc/hosts` has an entry. The mDNS query waits its full 5-second timeout before falling back, adding **5 seconds to every browser/curl request** to any local dev hostname. This blocks silent-SSO UX in consumer apps (Librarian L2b had to revert to a redirect flow because of it).

**Goal:** Migrate every dev hostname from `.local` to `.localhost`. RFC 6761 reserves `.localhost`; macOS resolves `*.localhost` natively to 127.0.0.1 with no mDNS round-trip.

**Mode:** Per-repo PRs, autonomous unless an issue is hit.

---

## Scope

Hostnames touched:

```
thehub.local         → thehub.localhost
thebrain.local       → (drop — legacy alias)
marie.local          → marie.localhost
marie2.local         → marie2.localhost
librarian.local      → librarian.localhost
betty.local          → betty.localhost
lostriver.local      → lostriver.localhost
thecollective.local  → thecollective.localhost
neo4j.local          → neo4j.localhost
langfuse.local       → langfuse.localhost
mail.local           → mail.localhost
analytics.local      → analytics.localhost
```

Repos touched (in execution order):

1. `~/Dev/infra`
2. `~/Dev/THECOLLECTIVE/TheHub/dev/TheHub`
3. `~/Dev/THECOLLECTIVE/Marie/dev/Marie`
4. `~/Dev/THECOLLECTIVE/Librarian/dev/Librarian`
5. `~/Dev/THECOLLECTIVE/Web/dev/Web`
6. `~/Dev/LOSTRIVER/web`
7. (Betty, UPS_company_intel, etc. — if they live locally)

---

## What breaks (and is acceptable)

- **Old session cookies stop being applicable** to the new hostname (cookies are host-only — no `Domain=` attribute). Users re-login. Local dev only, fine.
- **JWTs signed with `iss: "https://thehub.local"` fail verification** on consumers expecting `https://thehub.localhost`. Flag-day cutover — old tokens are dead.
- **In-progress dev sessions across all apps need to reload** once.

---

## What does NOT change

- The `mkcert` local CA itself — same CA signs the new certs, no Keychain re-trust needed.
- Cert file names (`thehub.pem`, `marie.pem`, etc.) — Traefik wiring in `dynamic/tls.yml` stays unchanged.
- Production deploys — they use `.lostriver.llc`, not `.local`. Unaffected.

---

## Phase 0 — Prep (10 min)

- [ ] Stop the PR #33 / #34 cron watcher if still active, or accept that it might tick during the migration (won't interfere).
- [ ] Stop all dev containers:
  ```bash
  cd ~/Dev/infra && docker compose down
  cd ~/Dev/THECOLLECTIVE/TheHub/dev/TheHub && docker compose down
  cd ~/Dev/THECOLLECTIVE/Marie/dev/Marie && docker compose down
  cd ~/Dev/THECOLLECTIVE/Librarian/dev/Librarian && docker compose down
  cd ~/Dev/THECOLLECTIVE/Web/dev/Web && docker compose -f docker-compose.dev.yml down
  cd ~/Dev/LOSTRIVER/web && docker compose -f docker-compose.dev.yml down
  ```
- [ ] Snapshot `/etc/hosts`:
  ```bash
  sudo cp /etc/hosts /etc/hosts.bak-pre-localhost-migration
  ```

---

## Phase 1 — Infra (15 min)

Branch: `chore/migrate-to-localhost` in `~/Dev/infra`.

### Regenerate certs (one loop)

```bash
cd ~/Dev/infra/certs
for name in analytics betty infra lostriver marie neo4j thecollective thehub; do
  mkcert -cert-file "${name}.pem" -key-file "${name}-key.pem" \
    "${name}.localhost" "*.${name}.localhost"
done
```

Same CA, same file names → Traefik picks up new SANs on next reload (file watch).

### Update Traefik routing + middleware

```bash
cd ~/Dev/infra
find dynamic -name "*.yml" -exec sed -i '' 's/\.local`/\.localhost`/g; s/\.local"/\.localhost"/g' {} \;
sed -i '' 's/\.local/\.localhost/g' docker-compose.yml
```

Manually verify each `dynamic/routing-*.yml` after the sed — the Host rules use backticks: `Host(\`thehub.local\`)` → `Host(\`thehub.localhost\`)`.

### Update scripts

```bash
# project.sh + init-project.sh: replace ${NAME}.local with ${NAME}.localhost
sed -i '' 's/${NAME}\.local/${NAME}.localhost/g' project.sh init-project.sh
sed -i '' 's/\.local/\.localhost/g' start.sh bootstrap.sh
```

Spot-review the result — `sed` can over-match.

### Bring infra back up

```bash
docker compose up -d
sleep 5
curl -sk https://mail.localhost/api/health -o /dev/null -w "%{time_total}s\n" || true
curl -sk https://langfuse.localhost -o /dev/null -w "%{time_total}s\n"
```

Both should be sub-second. If 5s, mDNS is still firing — investigate before continuing.

### Commit + PR

```bash
git add -A
git commit -m "chore: migrate dev hostnames .local → .localhost"
gh pr create --base main --title "chore: migrate dev hostnames .local → .localhost" --body "$(...)"
```

---

## Phase 2 — Per-repo (10–15 min each)

For each app repo, on branch `chore/migrate-to-localhost`:

### TheHub (`~/Dev/THECOLLECTIVE/TheHub/dev/TheHub`)

- [ ] `.env.example`:
  - `JWT_ISSUER=https://thehub.localhost`
  - `ALLOWED_LOGIN_RETURN_URLS`: replace `https://marie.local/...` → `https://marie.localhost/...` (keep `localhost:PORT` entries)
- [ ] Local `.env` (not committed): same edits
- [ ] `docker-compose.yml`: Traefik labels if any
- [ ] Search and update all `.local` references in source/tests:
  ```bash
  git grep -l '\.local' -- ':!*.md' ':!docs/'
  ```
  Expect hits in tests that hardcode `https://thehub.local` as the JWT issuer fixture, and DEV_LOGIN_HINTS.
- [ ] CLAUDE.md: update the `~/Dev/infra` section's URLs
- [ ] Commit, push, open PR

### Marie (`~/Dev/THECOLLECTIVE/Marie/dev/Marie`)

- [ ] `.env.example`:
  - `THEHUB_JWKS_URL=https://thehub.localhost/.well-known/jwks.json`
  - `JWT_ISSUER=https://thehub.localhost`
  - `FRONTEND_URL=https://marie.localhost`
- [ ] Local `.env`: same edits
- [ ] `docker-compose.yml`: Traefik labels
- [ ] Source/test grep: `git grep -l '\.local' -- ':!*.md' ':!docs/'`
- [ ] CLAUDE.md update
- [ ] Commit, push, PR

### Librarian (`~/Dev/THECOLLECTIVE/Librarian/dev/Librarian`)

- [ ] `.env.example` and local `.env`: TheHub URLs + own frontend URL
- [ ] `docker-compose.yml`
- [ ] Source/test grep
- [ ] CLAUDE.md
- [ ] Commit, push, PR

### THECOLLECTIVE/Web (`~/Dev/THECOLLECTIVE/Web/dev/Web`)

- [ ] `vite.config.ts`: dev server host + any proxy targets
- [ ] `docker-compose.dev.yml`
- [ ] `marie/v1/index.html` + `marie/index.html`: any hardcoded URLs
- [ ] CLAUDE.md, README.md
- [ ] Commit, push, PR

### LOSTRIVER/web (`~/Dev/LOSTRIVER/web`)

- [ ] `docker-compose.dev.yml`
- [ ] Any vite/next config
- [ ] Commit, push, PR

### Other (Betty, UPS_company_intel, newsintel)

These have routing entries in `~/Dev/infra/dynamic/`. If the repos exist locally and have `.local` references, repeat the pattern. If they only run on the server, the infra changes alone are enough.

---

## Phase 3 — Local DNS hygiene (5 min)

Edit `/etc/hosts` (sudo). `.localhost` resolves natively on macOS, so the entries are technically unnecessary. Keep them commented as a safety net for now:

```
# Pre-localhost-migration .local entries (commented 2026-05-20 — can drop after a week)
# 127.0.0.1   thehub.local thebrain.local
# 127.0.0.1   marie.local marie2.local
# ...

# Belt-and-suspenders explicit .localhost entries (macOS resolves these natively anyway):
127.0.0.1     thehub.localhost
127.0.0.1     marie.localhost marie2.localhost
127.0.0.1     librarian.localhost
127.0.0.1     betty.localhost
127.0.0.1     lostriver.localhost
127.0.0.1     thecollective.localhost
127.0.0.1     neo4j.localhost
127.0.0.1     langfuse.localhost
127.0.0.1     mail.localhost
127.0.0.1     analytics.localhost
```

---

## Phase 4 — Bring back up + verify (15 min)

```bash
cd ~/Dev/infra && docker compose up -d
sleep 3
cd ~/Dev/THECOLLECTIVE/TheHub/dev/TheHub && docker compose up -d
```

### Smoke tests

```bash
# Should be sub-second
curl -sk https://thehub.localhost/api/health -o /dev/null -w "%{time_total}s\n"

# Login fresh
curl -sk -c /tmp/c.txt -X POST https://thehub.localhost/api/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"email":"jordi@local.dev","password":"...REDACTED..."}' \
  -o /dev/null -w "login=%{time_total}s\n"

# SSO issue-token — the original 5-second offender
time curl -sk -b /tmp/c.txt -X POST https://thehub.localhost/api/auth/sso/issue-token \
  -H 'Content-Type: application/json' \
  -d '{"returnTo":"http://localhost:5174/auth/callback"}'
```

Expected: every probe well under 1s.

### Browser test

- Open `https://thehub.localhost` → no cert warning → log in fresh
- Click through to Librarian via SSO link → silent handoff, no frozen screen
- **Success criterion**: the Librarian L2b silent-SSO flow that was previously slow is now snappy. Unrevert the silent-SSO path in Librarian.

### Bring up the rest

```bash
cd ~/Dev/THECOLLECTIVE/Marie/dev/Marie && docker compose up -d
cd ~/Dev/THECOLLECTIVE/Librarian/dev/Librarian && docker compose up -d
# etc.
```

Verify each app's auth handoff works against the new TheHub URL.

---

## Phase 5 — Cleanup (5 min)

- [ ] Revert `perf/sso-issue-token-timing` markers (no longer needed)
- [ ] After a week with no issues, drop the commented `.local` block from `/etc/hosts`
- [ ] Drop the `thebrain.local` legacy alias entirely (no longer referenced anywhere)

---

## Rollback plan

Every change is a `sed` reversal. Each repo's `chore/migrate-to-localhost` branch is recoverable.

```bash
# /etc/hosts
sudo cp /etc/hosts.bak-pre-localhost-migration /etc/hosts

# Per repo: drop the branch
git -C <repo> checkout main

# Infra: regenerate old certs
cd ~/Dev/infra/certs
for name in analytics betty infra lostriver marie neo4j thecollective thehub; do
  mkcert -cert-file "${name}.pem" -key-file "${name}-key.pem" \
    "${name}.local" "*.${name}.local"
done
docker compose down && docker compose up -d
```

JWT/cookie state self-recovers — users re-login once.

---

## Time estimate

- Phase 0+1+3+4+5: ~45 min
- Phase 2: ~10 min × 5–6 repos ≈ 60 min
- **Total: ~1.5–2 hours**

---

## Pre-execution gates

1. PR #34 (service-account hardening) merged to main — avoids merging during a config-rename storm.
2. No active work-in-progress on the dev environment that requires `.local` URLs to stay live.

## Open questions (resolved)

- **Mode**: per-repo PRs, autonomously unless an issue is hit. ✅
- **Production**: no prod surface uses `.local`. ✅
- **Cert tool**: `mkcert`, already-installed CA, no Keychain re-trust. ✅
- **TLD choice**: `.localhost` (RFC 6761, native macOS resolution). ✅
