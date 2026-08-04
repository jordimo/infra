# An unrouted app answers 200 from the marketing site

**Status:** open · **Raised:** 2026-08-04 · **Affects:** thebrain, marie, librarian

## The problem

`dynamic/routing-thecollective.yml` gives the marketing site a **priority-1 catch-all** on the
whole host:

```yaml
thecollective-web:
  rule: "Host(`thecollective.localhost`)"
  priority: 1   # lowest-priority catch-all
```

That is correct as a fallback for the bare host. What it also does — and what nobody intended
— is answer for `/thebrain/*`, `/marie/*` and `/librarian/*` **whenever that app's own router
is absent**. The SPA serves its index for any path, so the response is:

```
HTTP/2 200        content-type: text/html
```

An app that is running, healthy, and simply missing from the routing table is therefore
indistinguishable from a working one, to anything that checks a status code.

## Why this is worth fixing rather than documenting

It has now cost real time three times:

- **2026-08-04, twice.** `librarian-api` was recreated without its localhost compose overlay
  (the base compose sets `traefik.enable=false`, so every router it has comes from the
  overlay). Both times `/librarian/api/health` returned 200 throughout, and both times that
  200 is what made the failure hard to see.
- **The `/thehub` → `/thebrain` rename.** The org `CLAUDE.md` already carries the warning:
  *the old path silently falls through to the marketing site and answers 200, so it looks
  alive when it isn't routing.* That note exists because someone lost time to it.

It is also the same shape as Librarian T-080's finding that container healthchecks reported
`healthy` for a dead process: **a success response that means nothing.**

Two mitigations already shipped, and neither closes the hole:

- Librarian's `docker-compose.override.yml` symlink (librarian#240) removes the easiest way to
  trigger it — but only for Librarian, and only once a checkout has it.
- `dev-stack.sh routing()` (thecollective#28) now asserts `application/json` rather than 200,
  so the stack script catches it — but only when someone runs that script.

Every other consumer — a browser, Scout, a curl in a debugging session, CI — still gets a 200.

## Proposed fix

Add a guard tier **between** the app routers (priority 100–200) and the catch-all (1): routers
that match the app path prefixes and fail loudly when no app router outranks them.

```yaml
# dynamic/routing-app-guard.yml
http:
  routers:
    app-prefix-guard:
      rule: >-
        Host(`thecollective.localhost`) &&
        (PathPrefix(`/thebrain`) || PathPrefix(`/marie`) || PathPrefix(`/librarian`))
      entryPoints: [websecure]
      service: app-unrouted
      tls: {}
      priority: 50        # above the catch-all (1), below every real app router (100+)

  services:
    app-unrouted:
      loadBalancer:
        servers:
          - url: "http://127.0.0.1:1"   # nothing listens — Traefik answers 502
```

A 502 is the honest answer: the path belongs to an app, and that app is not there. Anything
checking the response — human or script — sees a failure instead of a marketing page.

### Checks before landing it

- Confirm the real app routers all sit above 50. Librarian's is `priority: 200`; verify
  thebrain and marie.
- `/products/{marie,thebrain,betty}` are **marketing** pages and must keep hitting the
  catch-all — the guard rule must not match them (it does not, they are under `/products`).
- Decide whether the guard belongs on the `web` entrypoint too, or only `websecure`.

### Alternative considered

Excluding the app prefixes from the catch-all's own rule. Rejected: it puts the knowledge of
which prefixes exist into the marketing router, so adding a fourth app means editing an
unrelated file — and forgetting to would silently restore the current behaviour.

## Loose end in this repo

`dynamic/routing-librarian.yml.disabled` and `routing-marie.yml.disabled` are untracked and
sitting alongside the live routing files. Whoever disabled them should say whether they are
dead or pending — they are the same subject area as this note.
