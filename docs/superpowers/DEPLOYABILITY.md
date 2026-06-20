# CodeVibes deployment — deployability checklist

**Date:** 2026-06-20
**Verdict:** Implementation complete and verified to the limits possible without live cloud resources. Ready for the human to follow the runbooks to provision Cloudflare + Hetzner and deploy.

This maps every spec section to the artifact(s) that implement it and the evidence that they work. Spec: `docs/superpowers/specs/2026-06-20-production-deployment-design.md`. Plan: `docs/superpowers/plans/2026-06-20-production-deployment.md`.

## Spec coverage

| Spec § | Requirement | Artifact(s) | Evidence |
|--------|-------------|-------------|----------|
| §2 | Tunnel + Access | `deploy/quadlet/codevibes-cloudflared.container`, `deploy/cloudflared/config.yml.template`, `cloudflare-zerotrust` runbook | quadlet dry-run OK; ingress + 404 fallback asserted (quadlet.bats) |
| §3 | GitHub OAuth + DeepSeek per-user | backend env in `codevibes-backend.container`; setup runbook (OAuth App) | `setAuthCookie` confirmed prod-safe (httpOnly/secure/sameSite); env wired in quadlet |
| §4 | Single-origin pod (caddy+backend+cloudflared) | `Caddyfile`, `Dockerfile.web`, quadlet units | both images build; backend smoke `/api/health`→200; Caddyfile validates |
| §5 | CI builds, server pulls; public ghcr; rollback | `.github/workflows/build.yml`, `deploy/deploy.sh` | actionlint clean; deploy.bats: deploy/rollback/failed-smoke (3/3) |
| §6 | Asserting codemod | `patches/apply.sh` | apply.bats 4/4 (incl. fail-on-missing, idempotent); runs clean in both image builds |
| §7 | Logs/disk guards | journald drop-in (cloud-init), prune timer, stdout logging | cloudinit.bats; prune unit present |
| §8 | Code changes (API base, CORS) | `patches/apply.sh` | applied + asserted; web/backend images build with edits |
| §9 | CX22 / Ubuntu 26.04 / Falkenstein | setup runbook | documented |
| §10 | Resolved decisions | spec + DECISIONS-LOG | all reconciled (WS-K) |
| §11 | cloud-init provisioning | `deploy/cloud-init.template.yaml`, `gen-cloud-init.sh` | renders 2506 B (<32 KiB), valid YAML, no leftover placeholders, idempotent volume mount |
| §12 | Secrets broker + fetch | `secrets-broker/`, `deploy/fetch-secrets.sh`, `bootstrap-secrets.sh` | worker vitest 3/3; wrangler dry-run OK; secrets.bats 3/3 |
| §13 | Detachable data volume + backup | `codevibes-data.volume`, `deploy/backup.sh` | dry-run generates correct bind `volume create`; backend smoke created DB+WAL on mounted volume |
| §14 | Runbooks + diagrams | `docs/runbooks/*.html`, `docs/runbooks/diagrams/*` | runbooks.bats 3/3 (self-contained, no external assets); 4 diagrams valid JSON+SVG |

## Verification evidence (local)

- `make test` — 37 bats + 3 worker vitest tests pass (1 quadlet test skips on macOS, runs on Linux).
- `make verify` — Caddyfile valid; wrangler `--dry-run` OK.
- OrbStack Ubuntu (mirrors Hetzner rootless): `quadlet -dryrun` → 19 units, exit 0, no warnings.
- **Backend image** builds (native `better-sqlite3` compile under musl) → `codevibes-backend:test`.
- **Web image** builds (codemod → `vite build` → caddy) → `codevibes-web:test`.
- **Backend pod smoke**: container boots, `/api/health` → `{"status":"ok",...}`, SQLite DB + WAL created on the mounted volume.

## Not exercised locally (needs live cloud / x86 CI)

- x86 image builds (local is arm64 functional smoke; CI on GitHub Actions x86 is authoritative).
- Live Cloudflare Tunnel + Access enforcement, real Secrets Store, GitHub OAuth round-trip.
- End-to-end deploy timer on a real Hetzner box; Hetzner Volume detach/reattach.

## Residual human punch-list (do at/before deploy — see runbooks)

1. Secrets Store: install wrangler ≥4, create the store, uncomment + fill `store_id` in the five `secrets-broker/wrangler.toml` `[[secrets_store_secrets]]` blocks, `wrangler deploy`. (Worker serves test stubs until then.)
2. `ENCRYPTION_KEY`: `openssl rand -hex 16` **once**, store immutably; never rotate.
3. `deploy/config.env`: set `TUNNEL_ID` after creating the tunnel; confirm `GHCR_OWNER`/`FORK_REPO`.
4. After first CI build: set both ghcr packages **public**.
5. Confirm `.github/workflows/build.yml` installs wrangler ≥4 if it runs `wrangler deploy`.
6. First live pod smoke: confirm the Hetzner Volume bind mounts at runtime.

> Item from WS-K punch-list "audit `setAuthCookie`" is **already satisfied** — verified `src/utils/auth.ts` sets `httpOnly`, `secure: NODE_ENV==='production'`, `sameSite: 'lax'`.
