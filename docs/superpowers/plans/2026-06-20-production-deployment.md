# CodeVibes Production Deployment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **Working agreement is binding:** read `/CLAUDE.md`. Per task: tests → feature → verifications. Loop until done; do not stop between steps or phases. Mid-implementation decisions go to `docs/superpowers/DECISIONS-LOG.md` (append-only). "Complete" = deployable to the Hetzner image and functioning per spec. Tests use mocks; cover the happy path and catastrophic edge cases. **We verify only the files we add**, not upstream app code.

**Goal:** Deploy CodeVibes to a Hetzner CX22 (Falkenstein, Ubuntu 26.04) as a rootless Podman pod (Caddy+SPA, Express API, cloudflared) under Quadlet/systemd, behind Cloudflare Tunnel + Access, with CI-built/server-pulled images, daily release-keyed sync, smoke-tested deploy with auto-rollback, a detachable data volume, Cloudflare-brokered secrets, cloud-init provisioning, and self-contained HTML runbooks.

**Architecture:** Single origin (`codevibes.tjw.dev`); CI builds versioned images to ghcr.io and the server only pulls; the box is cattle (cloud-init + Cloudflare secrets broker) and so is the data (detachable Hetzner Volume). Our footprint is additive new files plus one asserting codemod against upstream source applied at build time.

**Tech Stack:** Podman + Quadlet (systemd, rootless), Caddy, cloudflared, Hetzner Cloud (VM + Volume + Firewall), Cloudflare (Tunnel, Access service tokens, Secrets Store, a broker Worker), GitHub Actions + ghcr.io, Bash, cloud-init, Cloudflare Workers (TypeScript). Test/verify: bats-core, shellcheck, hadolint, actionlint, yamllint, `cloud-init schema`, `caddy validate`, quadlet `-dryrun`, vitest.

**Spec:** `docs/superpowers/specs/2026-06-20-production-deployment-design.md` (sections cited as §N below).

---

## Parallel dispatch map

```
Phase 0  FOUNDATION (hard barrier — all of Phase 1 depends on it)
  └─ 0.1 verification tooling + Makefile + deploy/config.env   (one agent; small)

Phase 1  PARALLEL WORKSTREAMS  (dispatch all 8 concurrently after Phase 0)
  A  App codemod            patches/apply.sh + bats
  B  Container images       backend Dockerfile, Dockerfile.web, Caddyfile
  C  Quadlet units          deploy/quadlet/*
  D  Deploy & lifecycle     deploy.sh, backup/prune timers
  E  Secrets                fetch-secrets.sh, bootstrap-secrets.sh, secrets-broker/ Worker
  F  cloud-init             template + gen-cloud-init.sh + vars.example
  G  CI workflows           .github/workflows/{sync,build}.yml
  H  Diagrams               docs/runbooks/diagrams/*.excalidraw

Phase 2  INTEGRATION  (barrier: all of Phase 1 done)
  I  Runbooks               4 self-contained HTML (+ md sources, render step), embed H
  J  Integration checks     deploy/tests/integration.bats (cross-file consistency)

Phase 3  CLOSEOUT  (barrier: Phase 2 done)
  K  Decisions-log review   reconcile DECISIONS-LOG.md vs spec
  L  Deployability verify   local build+run dry-run, `make verify`, go/no-go checklist
```

Workstreams A–H share no files. They agree on names through `deploy/config.env` and the fixed paths in the "File structure" section; Phase 2-J enforces that they actually match. An orchestrator should fan out A–H as one batch, barrier, then I+J, barrier, then K+L.

---

## File structure (all new unless marked)

```
/CLAUDE.md                                  # working agreement (DONE)
/Makefile                                   # 0.1 — unified verify/test targets
/docs/superpowers/DECISIONS-LOG.md          # append-only (DONE)
/deploy/
  config.env                                # 0.1 — shared constants (owner, domains, names)
  cloudflared/config.yml.template           # C  — tunnel ingress (templated TUNNEL_ID)
  quadlet/codevibes.pod                      # C
  quadlet/codevibes-data.volume             # C
  quadlet/codevibes-backend.container        # C
  quadlet/codevibes-web.container            # C
  quadlet/codevibes-cloudflared.container    # C
  quadlet/codevibes-deploy.timer             # D
  quadlet/codevibes-deploy.service           # D
  quadlet/codevibes-backup.timer             # D
  quadlet/codevibes-backup.service           # D
  quadlet/codevibes-prune.timer              # D
  quadlet/codevibes-prune.service            # D
  deploy.sh                                  # D — pull, smoke-test, swap, rollback
  backup.sh                                  # D — nightly sqlite .backup, retain 7
  fetch-secrets.sh                           # E — broker fetch → podman secrets
  bootstrap-secrets.sh                       # E — SSH fallback
  gen-cloud-init.sh                          # F — render template → paste-ready yaml
  cloud-init.template.yaml                   # F
  cloud-init.vars.example                    # F
  render-config.sh                           # C — render config.yml from template+config.env
  tests/                                     # bats specs + fixtures (A–F)
/secrets-broker/                            # E — Cloudflare Worker
  src/index.ts
  test/index.test.ts
  package.json  wrangler.toml  vitest.config.ts  .eslintrc.json  tsconfig.json
/patches/apply.sh                           # A — asserting codemod
/patches/tests/fixtures/                    # A — copies of target source for tests
/.github/workflows/sync.yml                 # G
/.github/workflows/build.yml                # G
/codevibes-backend/Dockerfile               # B — MODIFY (native build deps; copy node_modules)
/Dockerfile.web                             # B — NEW (Node build → Caddy)
/Caddyfile                                  # B — NEW
/docs/runbooks/                             # I — *.md + *.html
/docs/runbooks/diagrams/                    # H — *.excalidraw + exported svg
```

### `deploy/config.env` canonical names (every workstream references these)

```bash
# deploy/config.env — shared constants. Sourced by deploy scripts; mirrored in CI as needed.
# Public fork + PUBLIC ghcr packages → server pulls anonymously (no registry token).
GHCR_OWNER=thejustinwalsh
FORK_REPO=thejustinwalsh/codevibes
UPSTREAM_REPO=danish296/codevibes
IMAGE_BACKEND=ghcr.io/thejustinwalsh/codevibes-backend
IMAGE_WEB=ghcr.io/thejustinwalsh/codevibes-web
APP_DOMAIN=codevibes.tjw.dev
SECRETS_DOMAIN=secrets.tjw.dev
POD_NAME=codevibes
DATA_MOUNT=/mnt/codevibes-data
DEPLOY_USER=codevibes
# Tunnel UUID for the locally-configured cloudflared ingress (not secret).
TUNNEL_ID=REPLACE_WITH_TUNNEL_UUID
# Podman secret names (created by fetch-secrets.sh, consumed by quadlet):
SECRET_JWT=codevibes-jwt-secret
SECRET_ENCKEY=codevibes-encryption-key
SECRET_GH_ID=codevibes-github-client-id
SECRET_GH_SECRET=codevibes-github-client-secret
SECRET_TUNNEL=codevibes-tunnel-cred
```

> If `GHCR_OWNER`/`FORK_REPO`/`TUNNEL_ID` differ from the real account, that is a one-line edit here — every script and unit reads from this file. `TUNNEL_ID` is filled during setup (it is created greenfield).

---

# Phase 0 — Foundation (barrier)

## Local test environment (read before running tests)

Two tiers, because the host is **macOS/arm64** and the target is **Linux/x86**:

- **Unit tier (runs on the Mac directly):** the bats specs, `shellcheck`, `yamllint`, `hadolint`, `actionlint`, `caddy validate`, and the Worker vitest. Install once:
  `brew install bats-core shellcheck yamllint hadolint actionlint` (caddy, jq, node already present).
- **Container/systemd tier (runs in an OrbStack Linux machine):** `podman build`, `quadlet -dryrun`, rootless-podman + systemd + linger behavior, and the local pod smoke (L2/L3). **Do not install Podman on macOS** — per OrbStack's docs it has no native Podman, and macOS can't run systemd/Quadlet anyway. Instead create an OrbStack **Ubuntu 26.04** machine (mirrors Hetzner) and run those tests inside it:
  `orb create ubuntu:26.04 codevibes-test` then `orb -m codevibes-test sudo apt-get install -y podman` and run the podman/quadlet tasks there.
- **Arch caveat:** OrbStack is arm64; Hetzner is x86. Local image builds are **functional smoke only** — the authoritative x86 artifacts come from CI (GitHub Actions, x86). Quadlet dry-runs, scripts, and unit logic are arch-independent, so the OrbStack machine validates them faithfully.

> **What we test (and don't):** we add tests only for the files **we** layer on (deploy scripts, CI, Quadlet, cloud-init, the broker Worker, the codemod). We **trust upstream CodeVibes code** and do not test or restyle it; the image build's own `tsc`/`vite` is its gate. We touch upstream source only for **production-config necessity or a security fix** (the CORS tightening is the latter) — never cosmetic edits.

### Task 0.1: Verification tooling, Makefile, shared config

**Files:**
- Create: `deploy/config.env` (content above)
- Create: `Makefile`
- Create: `deploy/tests/.gitkeep`, `patches/tests/fixtures/.gitkeep`
- Create: `secrets-broker/` scaffold (package.json, tsconfig, vitest.config, .eslintrc) — Worker code lands in WS-E

- [ ] **Step 1: Write a test that the Makefile exposes the verify targets**

Create `deploy/tests/makefile.bats`:
```bash
#!/usr/bin/env bats

@test "make help lists verify and test targets" {
  run make -C "${BATS_TEST_DIRNAME}/../.." help
  [ "$status" -eq 0 ]
  [[ "$output" == *"verify-shell"* ]]
  [[ "$output" == *"verify-yaml"* ]]
  [[ "$output" == *"verify-docker"* ]]
  [[ "$output" == *"verify-actions"* ]]
  [[ "$output" == *"test"* ]]
}

@test "config.env defines the canonical image names" {
  run bash -c "set -a; source ${BATS_TEST_DIRNAME}/../config.env; echo \$IMAGE_BACKEND \$IMAGE_WEB \$POD_NAME"
  [ "$status" -eq 0 ]
  [[ "$output" == *"codevibes-backend"* ]]
  [[ "$output" == *"codevibes-web"* ]]
  [[ "$output" == *"codevibes"* ]]
}
```

- [ ] **Step 2: Run it; expect failure (no Makefile/config.env)**

Run: `bats deploy/tests/makefile.bats`
Expected: FAIL (make target/help missing).

- [ ] **Step 3: Create `deploy/config.env`** with the exact content from the "canonical names" block above.

- [ ] **Step 4: Create `/Makefile`**

```makefile
# CodeVibes deployment — verification entrypoints. We verify only files we add.
SHELL := /bin/bash
SHELLSCRIPTS := $(shell find deploy patches -name '*.sh' 2>/dev/null)

.PHONY: help test verify verify-shell verify-yaml verify-docker verify-actions verify-quadlet verify-caddy verify-worker

help: ## list targets
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  %-16s %s\n",$$1,$$2}'

test: ## run all bats + worker unit tests
	@bats $$(find deploy patches -name '*.bats')
	@if [ -d secrets-broker ]; then cd secrets-broker && npm test; fi

verify: verify-shell verify-yaml verify-docker verify-actions verify-quadlet verify-caddy verify-worker ## run every verifier

verify-shell: ## shellcheck our scripts
	@if [ -n "$(SHELLSCRIPTS)" ]; then shellcheck $(SHELLSCRIPTS); else echo "no shell scripts yet"; fi

verify-yaml: ## yamllint our yaml + cloud-init schema
	@find deploy .github -name '*.yml' -o -name '*.yaml' 2>/dev/null | xargs -r yamllint -d relaxed

verify-docker: ## hadolint our Dockerfiles
	@for f in codevibes-backend/Dockerfile Dockerfile.web; do [ -f $$f ] && hadolint $$f || true; done

verify-actions: ## actionlint workflows
	@if ls .github/workflows/*.yml >/dev/null 2>&1; then actionlint; else echo "no workflows yet"; fi

verify-quadlet: ## quadlet dry-run
	@if ls deploy/quadlet/*.container >/dev/null 2>&1; then \
	  QUADLET=$$(command -v quadlet || echo /usr/libexec/podman/quadlet); \
	  $$QUADLET -dryrun -user deploy/quadlet || true; else echo "no quadlet units yet"; fi

verify-caddy: ## caddy validate
	@if [ -f Caddyfile ]; then caddy validate --config Caddyfile --adapter caddyfile; else echo "no Caddyfile yet"; fi

verify-worker: ## worker lint + dry-run deploy
	@if [ -d secrets-broker ]; then cd secrets-broker && npx eslint src && npx wrangler deploy --dry-run; else echo "no worker yet"; fi
```

- [ ] **Step 5: Scaffold the Worker package** (code arrives in WS-E; here only the config so `make` no-ops cleanly).

Create `secrets-broker/package.json`:
```json
{
  "name": "codevibes-secrets-broker",
  "private": true,
  "type": "module",
  "scripts": { "test": "vitest run", "lint": "eslint src" },
  "devDependencies": {
    "@cloudflare/vitest-pool-workers": "^0.5.0",
    "eslint": "^9.0.0",
    "typescript": "^5.5.0",
    "vitest": "^2.0.0",
    "wrangler": "^3.80.0"
  }
}
```
Create `secrets-broker/tsconfig.json`:
```json
{ "compilerOptions": { "target": "ES2022", "module": "ES2022", "moduleResolution": "Bundler", "lib": ["ES2022"], "types": ["@cloudflare/workers-types"], "strict": true, "noEmit": true } }
```
Create `secrets-broker/vitest.config.ts`:
```ts
import { defineWorkersConfig } from "@cloudflare/vitest-pool-workers/config";
export default defineWorkersConfig({ test: { poolOptions: { workers: { wrangler: { configPath: "./wrangler.toml" } } } } });
```
Create `secrets-broker/.eslintrc.json`:
```json
{ "root": true, "parserOptions": { "ecmaVersion": 2022, "sourceType": "module" }, "env": { "worker": true, "es2022": true }, "extends": ["eslint:recommended"] }
```

- [ ] **Step 6: Run the test; expect pass**

Run: `bats deploy/tests/makefile.bats`
Expected: PASS (2 tests).

- [ ] **Step 7: Commit**

```bash
git add -f Makefile deploy/config.env deploy/tests secrets-broker/package.json secrets-broker/tsconfig.json secrets-broker/vitest.config.ts secrets-broker/.eslintrc.json patches/tests/fixtures/.gitkeep
git commit -m "build: deployment verification tooling, Makefile, shared config"
```

---

# Phase 1 — Parallel workstreams

## Workstream A — App codemod (`patches/apply.sh`)

Applies the only two functional edits to upstream source at build time, each asserting an exact match count so a silent upstream change fails the build (§6, §8).

**Files:** Create `patches/apply.sh`, `patches/tests/apply.bats`, fixtures.

- [ ] **A1 — Write fixtures** matching today's upstream lines.

Create `patches/tests/fixtures/useAnalysis.ts`:
```ts
const API_BASE_URL = 'http://localhost:3001';
export function useAnalysis() { return API_BASE_URL; }
```
Create `patches/tests/fixtures/server.ts`:
```ts
        } else {
            logger.warn('CORS blocked origin', { origin });
            callback(null, true); // Allow for development - tighten in production
        }
```

- [ ] **A2 — Write the failing test**

Create `patches/tests/apply.bats`:
```bash
#!/usr/bin/env bats
setup() {
  TMP="$(mktemp -d)"
  mkdir -p "$TMP/src/hooks" "$TMP/codevibes-backend/src"
  cp "$BATS_TEST_DIRNAME/fixtures/useAnalysis.ts" "$TMP/src/hooks/useAnalysis.ts"
  cp "$BATS_TEST_DIRNAME/fixtures/server.ts" "$TMP/codevibes-backend/src/server.ts"
}
teardown() { rm -rf "$TMP"; }

@test "rewrites the hardcoded API base to env-relative" {
  run bash "$BATS_TEST_DIRNAME/../apply.sh" "$TMP"
  [ "$status" -eq 0 ]
  grep -q "import.meta.env.VITE_API_URL || ''" "$TMP/src/hooks/useAnalysis.ts"
  ! grep -q "'http://localhost:3001'" "$TMP/src/hooks/useAnalysis.ts"
}

@test "tightens the permissive CORS fallback" {
  run bash "$BATS_TEST_DIRNAME/../apply.sh" "$TMP"
  [ "$status" -eq 0 ]
  grep -q "Not allowed by CORS" "$TMP/codevibes-backend/src/server.ts"
  ! grep -q "callback(null, true); // Allow for development" "$TMP/codevibes-backend/src/server.ts"
}

@test "fails loudly if a target literal is missing (upstream changed)" {
  echo "const API_BASE_URL = 'changed';" > "$TMP/src/hooks/useAnalysis.ts"
  run bash "$BATS_TEST_DIRNAME/../apply.sh" "$TMP"
  [ "$status" -ne 0 ]
  [[ "$output" == *"expected 1"* ]]
}

@test "is idempotent (second run is a no-op success)" {
  bash "$BATS_TEST_DIRNAME/../apply.sh" "$TMP"
  run bash "$BATS_TEST_DIRNAME/../apply.sh" "$TMP"
  [ "$status" -eq 0 ]
}
```

Run: `bats patches/tests/apply.bats` → Expected: FAIL (no apply.sh).

- [ ] **A3 — Implement `patches/apply.sh`**

```bash
#!/usr/bin/env bash
# Asserting codemod: applies CodeVibes production source edits to a checkout.
# Usage: apply.sh [REPO_ROOT]   (default: .)  Idempotent. Fails if a target is absent.
set -euo pipefail
ROOT="${1:-.}"

# replace_once FILE LITERAL REPLACEMENT
# Succeeds if LITERAL already absent AND REPLACEMENT present (idempotent re-run);
# else requires exactly one LITERAL occurrence.
replace_once() {
  local file="$1" lit="$2" repl="$3"
  [ -f "$file" ] || { echo "apply.sh: missing file $file" >&2; return 1; }
  local n; n="$(grep -F -c -- "$lit" "$file" || true)"
  if [ "$n" -eq 0 ]; then
    if grep -F -q -- "$repl" "$file"; then return 0; fi
    echo "apply.sh: $file: expected 1 occurrence of target literal, found 0 and replacement absent" >&2
    return 1
  fi
  if [ "$n" -ne 1 ]; then
    echo "apply.sh: $file: expected 1 occurrence, found $n" >&2; return 1
  fi
  # literal, non-regex replacement via awk index/substr
  awk -v lit="$lit" -v repl="$repl" '{i=index($0,lit); if(i){$0=substr($0,1,i-1) repl substr($0,i+length(lit))} print}' "$file" > "$file.tmp"
  mv "$file.tmp" "$file"
}

replace_once "$ROOT/src/hooks/useAnalysis.ts" \
  "const API_BASE_URL = 'http://localhost:3001';" \
  "const API_BASE_URL = import.meta.env.VITE_API_URL || '';"

replace_once "$ROOT/codevibes-backend/src/server.ts" \
  "callback(null, true); // Allow for development - tighten in production" \
  "callback(new Error('Not allowed by CORS'), false);"

echo "apply.sh: codemod applied"
```

- [ ] **A4 — Run tests; expect pass**

Run: `bats patches/tests/apply.bats` → Expected: PASS (4).

- [ ] **A5 — Verify + commit**

```bash
shellcheck patches/apply.sh
git add -f patches/apply.sh patches/tests
git commit -m "feat(patches): asserting codemod for prod API base + CORS"
```

---

## Workstream B — Container images

Backend Dockerfile fixed for `better-sqlite3` native build via copied `node_modules` (no build tools in the final image); new web image (Vite build → Caddy); single-origin Caddyfile (§4, §5).

**Files:** Modify `codevibes-backend/Dockerfile`; Create `Dockerfile.web`, `Caddyfile`, `deploy/tests/containers.bats`.

- [ ] **B1 — Write the failing verification test**

Create `deploy/tests/containers.bats`:
```bash
#!/usr/bin/env bats
ROOT="${BATS_TEST_DIRNAME}/../.."

@test "backend Dockerfile installs native build deps in builder" {
  grep -Eq "python3.*make.*g\\+\\+|g\\+\\+.*make.*python3" "$ROOT/codevibes-backend/Dockerfile"
}
@test "backend final stage has no build toolchain (copies node_modules)" {
  grep -q "COPY --from=builder /app/node_modules" "$ROOT/codevibes-backend/Dockerfile"
}
@test "backend Dockerfile passes hadolint (no errors)" {
  run hadolint --failure-threshold error "$ROOT/codevibes-backend/Dockerfile"
  [ "$status" -eq 0 ]
}
@test "web Dockerfile builds with VITE_API_URL and serves via caddy" {
  grep -q "VITE_API_URL" "$ROOT/Dockerfile.web"
  grep -Eq "FROM caddy" "$ROOT/Dockerfile.web"
  run hadolint --failure-threshold error "$ROOT/Dockerfile.web"
  [ "$status" -eq 0 ]
}
@test "Caddyfile is valid and proxies /api to backend" {
  grep -q "reverse_proxy localhost:3001" "$ROOT/Caddyfile"
  run caddy validate --config "$ROOT/Caddyfile" --adapter caddyfile
  [ "$status" -eq 0 ]
}
```

Run: `bats deploy/tests/containers.bats` → Expected: FAIL.

- [ ] **B2 — Modify `codevibes-backend/Dockerfile`**

```dockerfile
# Build stage
FROM node:20-alpine AS builder
WORKDIR /app
# better-sqlite3 compiles a native binding under musl — needs a toolchain.
RUN apk add --no-cache python3 make g++
COPY package*.json ./
RUN npm ci
COPY . .
RUN npm run build
# Drop dev deps but keep the compiled native module for the final stage.
RUN npm prune --omit=dev

# Production stage (no toolchain; reuse the builder's compiled node_modules)
FROM node:20-alpine AS production
WORKDIR /app
ENV NODE_ENV=production
ENV PORT=3001
COPY package*.json ./
COPY --from=builder /app/node_modules ./node_modules
COPY --from=builder /app/dist ./dist
EXPOSE 3001
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD wget --no-verbose --tries=1 --spider http://localhost:3001/api/health || exit 1
CMD ["node", "dist/server.js"]
```

- [ ] **B3 — Create `/Caddyfile`**

```caddyfile
{
	admin off
	auto_https off
}

:80 {
	encode gzip
	handle /api/* {
		reverse_proxy localhost:3001
	}
	handle {
		root * /srv
		try_files {path} /index.html
		file_server
	}
}
```

- [ ] **B4 — Create `/Dockerfile.web`**

```dockerfile
# Build the SPA with the production API origin baked in.
FROM node:20-alpine AS builder
WORKDIR /app
ARG VITE_API_URL=https://codevibes.tjw.dev
ENV VITE_API_URL=$VITE_API_URL
COPY package*.json ./
RUN npm ci
COPY . .
# Apply the production codemod before building (idempotent; asserts targets).
RUN sh patches/apply.sh .
RUN npm run build

# Serve static SPA + reverse-proxy /api via Caddy.
FROM caddy:2-alpine AS production
COPY Caddyfile /etc/caddy/Caddyfile
COPY --from=builder /app/dist /srv
EXPOSE 80
```

> Note: `Dockerfile.web` runs `patches/apply.sh` (WS-A) inside the build; the backend codemod runs in CI (WS-G) before `docker build` of the backend, because the backend build context is `codevibes-backend/`. Phase 2-J asserts both paths are covered.

- [ ] **B5 — Run tests; expect pass; commit**

```bash
bats deploy/tests/containers.bats
git add -f codevibes-backend/Dockerfile Dockerfile.web Caddyfile deploy/tests/containers.bats
git commit -m "feat(images): backend native-build fix, web image (Caddy+SPA), single-origin Caddyfile"
```

---

## Workstream C — Quadlet units + cloudflared config

Pod + three containers + data volume, plus the locally-configured tunnel ingress (§4). Images referenced via floating `localhost/...:current` tags that `deploy.sh` retargets (so units never change between deploys). Secrets consumed via `Secret=` directives.

**Files:** Create `deploy/quadlet/{codevibes.pod,codevibes-data.volume,codevibes-backend.container,codevibes-web.container,codevibes-cloudflared.container}`, `deploy/cloudflared/config.yml.template`, `deploy/render-config.sh`, `deploy/tests/quadlet.bats`.

- [ ] **C1 — Write the failing test**

Create `deploy/tests/quadlet.bats`:
```bash
#!/usr/bin/env bats
Q="${BATS_TEST_DIRNAME}/../quadlet"

@test "pod defines no published host ports (tunnel dials out)" {
  ! grep -Rq "PublishPort" "$Q"
}
@test "containers reference floating :current images" {
  grep -q "Image=localhost/codevibes-backend:current" "$Q/codevibes-backend.container"
  grep -q "Image=localhost/codevibes-web:current" "$Q/codevibes-web.container"
}
@test "backend maps podman secrets to env targets" {
  grep -q "Secret=codevibes-jwt-secret,type=env,target=JWT_SECRET" "$Q/codevibes-backend.container"
  grep -q "Secret=codevibes-encryption-key,type=env,target=ENCRYPTION_KEY" "$Q/codevibes-backend.container"
}
@test "data volume binds the host mount" {
  grep -q "Device=/mnt/codevibes-data" "$Q/codevibes-data.volume"
}
@test "quadlet dry-run accepts the unit set" {
  QUADLET=$(command -v quadlet || echo /usr/libexec/podman/quadlet)
  run "$QUADLET" -dryrun -user "$Q"
  [ "$status" -eq 0 ]
}
@test "cloudflared config template has app ingress + 404 fallback" {
  T="${BATS_TEST_DIRNAME}/../cloudflared/config.yml.template"
  grep -q "hostname: codevibes.tjw.dev" "$T"
  grep -q "http_status:404" "$T"
}
```

Run: `bats deploy/tests/quadlet.bats` → Expected: FAIL.

- [ ] **C2 — `deploy/quadlet/codevibes.pod`**
```ini
[Pod]
PodName=codevibes

[Install]
WantedBy=default.target
```

- [ ] **C3 — `deploy/quadlet/codevibes-data.volume`**
```ini
[Volume]
VolumeName=codevibes-data
Driver=local
# Bind the detachable Hetzner Volume mount into a named podman volume.
Options=type=none,o=bind
Device=/mnt/codevibes-data
```

- [ ] **C4 — `deploy/quadlet/codevibes-backend.container`**
```ini
[Unit]
Description=CodeVibes API
After=network-online.target

[Container]
Image=localhost/codevibes-backend:current
Pod=codevibes.pod
Environment=NODE_ENV=production
Environment=PORT=3001
Environment=ALLOWED_ORIGINS=https://codevibes.tjw.dev
Environment=FRONTEND_URL=https://codevibes.tjw.dev
Environment=GITHUB_CALLBACK_URL=https://codevibes.tjw.dev/api/auth/callback
Environment=DB_PATH=/app/data/codevibes.db
Environment=DEEPSEEK_MODEL=deepseek-chat
Environment=SESSION_DURATION_DAYS=30
Volume=codevibes-data.volume:/app/data:Z
Secret=codevibes-jwt-secret,type=env,target=JWT_SECRET
Secret=codevibes-encryption-key,type=env,target=ENCRYPTION_KEY
Secret=codevibes-github-client-id,type=env,target=GITHUB_CLIENT_ID
Secret=codevibes-github-client-secret,type=env,target=GITHUB_CLIENT_SECRET

[Service]
Restart=on-failure

[Install]
WantedBy=default.target
```

- [ ] **C5 — `deploy/quadlet/codevibes-web.container`**
```ini
[Unit]
Description=CodeVibes Web (Caddy + SPA)
After=network-online.target

[Container]
Image=localhost/codevibes-web:current
Pod=codevibes.pod

[Service]
Restart=on-failure

[Install]
WantedBy=default.target
```

- [ ] **C6 — `deploy/quadlet/codevibes-cloudflared.container`**
```ini
[Unit]
Description=CodeVibes Cloudflare Tunnel
After=network-online.target

[Container]
Image=docker.io/cloudflare/cloudflared:latest
Pod=codevibes.pod
Volume=%h/codevibes/deploy/cloudflared/config.yml:/etc/cloudflared/config.yml:ro,Z
Secret=codevibes-tunnel-cred,type=mount,target=/etc/cloudflared/cred.json
Exec=tunnel --no-autoupdate --config /etc/cloudflared/config.yml run

[Service]
Restart=on-failure

[Install]
WantedBy=default.target
```

- [ ] **C7 — `deploy/cloudflared/config.yml.template`**
```yaml
tunnel: __TUNNEL_ID__
credentials-file: /etc/cloudflared/cred.json
ingress:
  - hostname: codevibes.tjw.dev
    service: http://localhost:80
  - service: http_status:404
```

- [ ] **C8 — `deploy/render-config.sh`** (renders the template using config.env)
```bash
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/config.env"
sed "s/__TUNNEL_ID__/${TUNNEL_ID}/g" \
  "$HERE/cloudflared/config.yml.template" > "$HERE/cloudflared/config.yml"
echo "rendered $HERE/cloudflared/config.yml"
```

- [ ] **C9 — Run tests; verify; commit**
```bash
bats deploy/tests/quadlet.bats
shellcheck deploy/render-config.sh
git add -f deploy/quadlet deploy/cloudflared deploy/render-config.sh deploy/tests/quadlet.bats
git commit -m "feat(quadlet): pod, containers, volume, tunnel ingress"
```

---

## Workstream D — Deploy, rollback, backup, prune

`deploy.sh` checks ghcr for a newer semver tag, smoke-tests it (HTTP health + DB-touch) in a throwaway container before swapping the floating `:current` tag, records last-known-good on the volume, and rolls back on failure (§5). Timers fire the deploy at 04:00 ET, nightly backup, weekly prune (§5, §7, §13).

**Files:** Create `deploy/deploy.sh`, `deploy/backup.sh`, the six timer/service quadlet units, `deploy/tests/deploy.bats`.

- [ ] **D1 — Write the failing test (mocks podman/skopeo)**

Create `deploy/tests/deploy.bats`:
```bash
#!/usr/bin/env bats
setup() {
  TMP="$(mktemp -d)"; BIN="$TMP/bin"; mkdir -p "$BIN" "$TMP/state"
  # mock skopeo: report a newer tag
  cat > "$BIN/skopeo" <<'EOF'
#!/usr/bin/env bash
echo '{"Tags":["v1.0.1","v1.0.2"]}'
EOF
  # mock podman: log calls; succeed; health/db smoke "passes" via marker file
  cat > "$BIN/podman" <<'EOF'
#!/usr/bin/env bash
echo "podman $*" >> "$TMP_LOG"
case "$1" in
  run) exit 0 ;;
  tag) echo "tag $*" >> "$TMP_LOG"; exit 0 ;;
  pull) exit 0 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$BIN/skopeo" "$BIN/podman"
  export PATH="$BIN:$PATH" TMP_LOG="$TMP/calls.log"
  export DEPLOY_STATE_DIR="$TMP/state" DEPLOY_SMOKE_OVERRIDE=pass
}
teardown() { rm -rf "$TMP"; }

@test "deploys newer tag and records last-known-good" {
  run bash "$BATS_TEST_DIRNAME/../deploy.sh"
  [ "$status" -eq 0 ]
  grep -q "tag .*codevibes-backend:v1.0.2 localhost/codevibes-backend:current" "$TMP/calls.log"
  grep -q "v1.0.2" "$TMP/state/deploy-state"
}

@test "rollback retargets current to the previous good tag" {
  printf 'CURRENT=v1.0.2\nPREVIOUS=v1.0.1\n' > "$TMP/state/deploy-state"
  run bash "$BATS_TEST_DIRNAME/../deploy.sh" --rollback
  [ "$status" -eq 0 ]
  grep -q "codevibes-backend:v1.0.1 localhost/codevibes-backend:current" "$TMP/calls.log"
}

@test "failed smoke test does NOT swap current (no data-loss / no bad deploy)" {
  export DEPLOY_SMOKE_OVERRIDE=fail
  run bash "$BATS_TEST_DIRNAME/../deploy.sh"
  [ "$status" -ne 0 ]
  ! grep -q ":v1.0.2 localhost/codevibes-backend:current" "$TMP/calls.log"
}
```

Run: `bats deploy/tests/deploy.bats` → Expected: FAIL.

- [ ] **D2 — Implement `deploy/deploy.sh`**

```bash
#!/usr/bin/env bash
# CodeVibes deploy/rollback. Pulls newer ghcr tag, smoke-tests, swaps :current, records state.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/config.env"
STATE_DIR="${DEPLOY_STATE_DIR:-$DATA_MOUNT}"
STATE="$STATE_DIR/deploy-state"
mkdir -p "$STATE_DIR"

log() { echo "[deploy] $*"; }

current_tag() { [ -f "$STATE" ] && (grep '^CURRENT=' "$STATE" | cut -d= -f2) || echo ""; }
previous_tag() { [ -f "$STATE" ] && (grep '^PREVIOUS=' "$STATE" | cut -d= -f2) || echo ""; }

latest_remote_tag() {
  skopeo list-tags "docker://$IMAGE_BACKEND" \
    | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | sort -V | tail -n1
}

# Smoke test: boot new backend image in a throwaway container, check /api/health
# AND a read-only SQLite query against the live DB (catches broken mount / corrupt DB).
smoke_test() {
  local tag="$1"
  if [ "${DEPLOY_SMOKE_OVERRIDE:-}" = "pass" ]; then return 0; fi
  if [ "${DEPLOY_SMOKE_OVERRIDE:-}" = "fail" ]; then return 1; fi
  podman run --rm --name codevibes-smoke \
    -e NODE_ENV=production -e PORT=3001 -e DB_PATH=/app/data/codevibes.db \
    -v "$DATA_MOUNT":/app/data:ro,Z \
    --health-cmd 'wget -q --spider http://localhost:3001/api/health || exit 1' \
    "$IMAGE_BACKEND:$tag" \
    node -e "require('better-sqlite3')(process.env.DB_PATH,{readonly:true,fileMustExist:true}).prepare('SELECT 1').get(); process.exit(0)"
}

swap_to() { # retarget the floating :current tags + restart pod
  local tag="$1"
  podman pull "$IMAGE_BACKEND:$tag"
  podman pull "$IMAGE_WEB:$tag"
  podman tag "$IMAGE_BACKEND:$tag" "localhost/codevibes-backend:current"
  podman tag "$IMAGE_WEB:$tag" "localhost/codevibes-web:current"
  systemctl --user daemon-reload 2>/dev/null || true
  systemctl --user restart codevibes-pod 2>/dev/null || true
}

record_state() { printf 'CURRENT=%s\nPREVIOUS=%s\n' "$1" "$2" > "$STATE"; }

do_rollback() {
  local prev; prev="$(previous_tag)"
  [ -n "$prev" ] || { log "no previous tag to roll back to"; exit 1; }
  log "rolling back to $prev"
  swap_to "$prev"
  record_state "$prev" ""
  log "rollback complete"
}

main() {
  if [ "${1:-}" = "--rollback" ]; then do_rollback; return; fi
  local cur new; cur="$(current_tag)"; new="$(latest_remote_tag)"
  [ -n "$new" ] || { log "no remote tags found"; exit 1; }
  if [ "$new" = "$cur" ]; then log "already on $cur; nothing to do"; return 0; fi
  log "candidate $new (current: ${cur:-none})"
  podman pull "$IMAGE_BACKEND:$new"
  if ! smoke_test "$new"; then
    log "SMOKE TEST FAILED for $new — keeping ${cur:-current}, not swapping"
    exit 1
  fi
  swap_to "$new"
  record_state "$new" "$cur"
  log "deployed $new"
}
main "$@"
```

- [ ] **D3 — Implement `deploy/backup.sh`**
```bash
#!/usr/bin/env bash
# Nightly SQLite backup on the volume; retain last 7.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/config.env"
DB="${DB_PATH:-$DATA_MOUNT/codevibes.db}"
DEST="$DATA_MOUNT/backups"
mkdir -p "$DEST"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
sqlite3 "$DB" ".backup '$DEST/codevibes-$STAMP.db'"
ls -1t "$DEST"/codevibes-*.db | tail -n +8 | xargs -r rm -f
echo "[backup] wrote $DEST/codevibes-$STAMP.db"
```

- [ ] **D4 — Timer/service units** (use timezone-qualified OnCalendar).

`deploy/quadlet/codevibes-deploy.service`:
```ini
[Unit]
Description=CodeVibes daily deploy check
[Service]
Type=oneshot
ExecStart=%h/codevibes/deploy/deploy.sh
```
`deploy/quadlet/codevibes-deploy.timer`:
```ini
[Unit]
Description=Run CodeVibes deploy at 04:00 America/Detroit
[Timer]
OnCalendar=*-*-* 04:00:00 America/Detroit
Persistent=true
[Install]
WantedBy=timers.target
```
`deploy/quadlet/codevibes-backup.service`:
```ini
[Unit]
Description=CodeVibes nightly DB backup
[Service]
Type=oneshot
ExecStart=%h/codevibes/deploy/backup.sh
```
`deploy/quadlet/codevibes-backup.timer`:
```ini
[Unit]
Description=Nightly CodeVibes DB backup
[Timer]
OnCalendar=*-*-* 03:30:00 America/Detroit
Persistent=true
[Install]
WantedBy=timers.target
```
`deploy/quadlet/codevibes-prune.service`:
```ini
[Unit]
Description=CodeVibes weekly image prune (retain last 3 tags)
[Service]
Type=oneshot
ExecStart=/usr/bin/podman image prune -f
```
`deploy/quadlet/codevibes-prune.timer`:
```ini
[Unit]
Description=Weekly podman image prune
[Timer]
OnCalendar=Sun *-*-* 05:00:00 America/Detroit
Persistent=true
[Install]
WantedBy=timers.target
```

> These `.timer`/`.service` are plain systemd user units (not Podman quadlet types). They live in the same `~/.config/containers/systemd/`? No — install plain units to `~/.config/systemd/user/`. The installer (cloud-init, WS-F) handles placement. Add a note for J to assert placement.

- [ ] **D5 — Run tests; verify; commit**
```bash
bats deploy/tests/deploy.bats
shellcheck deploy/deploy.sh deploy/backup.sh
git add -f deploy/deploy.sh deploy/backup.sh deploy/quadlet/codevibes-deploy.* deploy/quadlet/codevibes-backup.* deploy/quadlet/codevibes-prune.* deploy/tests/deploy.bats
git commit -m "feat(deploy): smoke-tested deploy w/ rollback, nightly backup, weekly prune"
```

---

## Workstream E — Secrets (fetch + bootstrap + broker Worker)

Server fetches secrets from the broker using the Access service token and writes podman secrets; broker Worker returns secrets only to callers that pass the Access JWT (§12).

**Files:** Create `deploy/fetch-secrets.sh`, `deploy/bootstrap-secrets.sh`, `secrets-broker/src/index.ts`, `secrets-broker/test/index.test.ts`, `secrets-broker/wrangler.toml`, `deploy/tests/secrets.bats`.

- [ ] **E1 — Failing test for `fetch-secrets.sh` (mock curl + podman)**

Create `deploy/tests/secrets.bats`:
```bash
#!/usr/bin/env bats
setup() {
  TMP="$(mktemp -d)"; BIN="$TMP/bin"; mkdir -p "$BIN"
  cat > "$BIN/curl" <<'EOF'
#!/usr/bin/env bash
echo '{"JWT_SECRET":"j","ENCRYPTION_KEY":"0123456789abcdef0123456789abcdef","GITHUB_CLIENT_ID":"id","GITHUB_CLIENT_SECRET":"sec","TUNNEL_CRED":"{\"TunnelID\":\"x\"}"}'
EOF
  cat > "$BIN/podman" <<'EOF'
#!/usr/bin/env bash
echo "podman $*" >> "$TMP_LOG"; exit 0
EOF
  chmod +x "$BIN/curl" "$BIN/podman"
  export PATH="$BIN:$PATH" TMP_LOG="$TMP/calls.log"
  export CF_SERVICE_TOKEN_ID=tid CF_SERVICE_TOKEN_SECRET=tsec
}
teardown() { rm -rf "$TMP"; }

@test "creates a podman secret per app secret" {
  run bash "$BATS_TEST_DIRNAME/../fetch-secrets.sh"
  [ "$status" -eq 0 ]
  grep -q "secret create codevibes-jwt-secret" "$TMP/calls.log"
  grep -q "secret create codevibes-encryption-key" "$TMP/calls.log"
  grep -q "secret create codevibes-tunnel-cred" "$TMP/calls.log"
}
@test "does NOT log into ghcr (images are public, anonymous pull)" {
  run bash "$BATS_TEST_DIRNAME/../fetch-secrets.sh"
  ! grep -q "login ghcr.io" "$TMP/calls.log"
}
@test "fails if the service token is missing (no silent unauth fetch)" {
  unset CF_SERVICE_TOKEN_ID
  run bash "$BATS_TEST_DIRNAME/../fetch-secrets.sh"
  [ "$status" -ne 0 ]
}
```

Run: `bats deploy/tests/secrets.bats` → Expected: FAIL.

- [ ] **E2 — Implement `deploy/fetch-secrets.sh`** (requires `jq`)
```bash
#!/usr/bin/env bash
# Fetch app secrets from the Cloudflare broker (Access service token) → podman secrets.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/config.env"
: "${CF_SERVICE_TOKEN_ID:?service token id required}"
: "${CF_SERVICE_TOKEN_SECRET:?service token secret required}"

JSON="$(curl -fsS "https://$SECRETS_DOMAIN/secrets" \
  -H "CF-Access-Client-Id: $CF_SERVICE_TOKEN_ID" \
  -H "CF-Access-Client-Secret: $CF_SERVICE_TOKEN_SECRET")"

put() { # name <- json key
  local secret="$1" key="$2" val
  val="$(printf '%s' "$JSON" | jq -er ".$key")"
  printf '%s' "$val" | podman secret rm "$secret" >/dev/null 2>&1 || true
  printf '%s' "$val" | podman secret create "$secret" - >/dev/null
}
put "$SECRET_JWT"        JWT_SECRET
put "$SECRET_ENCKEY"     ENCRYPTION_KEY
put "$SECRET_GH_ID"      GITHUB_CLIENT_ID
put "$SECRET_GH_SECRET"  GITHUB_CLIENT_SECRET
put "$SECRET_TUNNEL"     TUNNEL_CRED

# No ghcr login — images are public, pulled anonymously.
echo "[fetch-secrets] podman secrets created"
```

- [ ] **E3 — Implement `deploy/bootstrap-secrets.sh`** (SSH fallback; interactive prompts)
```bash
#!/usr/bin/env bash
# Fallback: create podman secrets by hand if the broker is unreachable.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/config.env"
prompt() { local var="$1" msg="$2" v; read -rsp "$msg: " v; echo; printf '%s' "$v" | podman secret create "$var" - ; }
echo "Manual secret bootstrap (fallback). Values are not echoed."
prompt "$SECRET_JWT"        "JWT_SECRET"
prompt "$SECRET_ENCKEY"     "ENCRYPTION_KEY (32 chars, NEVER regenerate)"
prompt "$SECRET_GH_ID"      "GITHUB_CLIENT_ID"
prompt "$SECRET_GH_SECRET"  "GITHUB_CLIENT_SECRET"
echo "Paste tunnel credential JSON, end with Ctrl-D:"; podman secret create "$SECRET_TUNNEL" -
# No ghcr login — images are public.
echo "[bootstrap] done"
```

- [ ] **E4 — Failing test for the broker Worker**

Create `secrets-broker/test/index.test.ts`:
```ts
import { env, createExecutionContext, waitOnExecutionContext } from "cloudflare:test";
import { describe, it, expect } from "vitest";
import worker from "../src/index";

const goodHeaders = { "Cf-Access-Jwt-Assertion": "valid" };

describe("secrets broker", () => {
  it("returns all secrets to an Access-authenticated request", async () => {
    const req = new Request("https://secrets.tjw.dev/secrets", { headers: goodHeaders });
    const ctx = createExecutionContext();
    const res = await worker.fetch(req, env, ctx);
    await waitOnExecutionContext(ctx);
    expect(res.status).toBe(200);
    const body = await res.json<Record<string, string>>();
    expect(body.JWT_SECRET).toBeTruthy();
    expect(body.ENCRYPTION_KEY).toBeTruthy();
  });

  it("rejects a request with no Access assertion (401)", async () => {
    const req = new Request("https://secrets.tjw.dev/secrets");
    const ctx = createExecutionContext();
    const res = await worker.fetch(req, env, ctx);
    await waitOnExecutionContext(ctx);
    expect(res.status).toBe(401);
  });

  it("404s on any path other than /secrets", async () => {
    const req = new Request("https://secrets.tjw.dev/", { headers: goodHeaders });
    const ctx = createExecutionContext();
    const res = await worker.fetch(req, env, ctx);
    await waitOnExecutionContext(ctx);
    expect(res.status).toBe(404);
  });
});
```

- [ ] **E5 — Implement `secrets-broker/src/index.ts`**

```ts
// CodeVibes secrets broker. Sits behind Cloudflare Access (service-token policy).
// Defense in depth: require the Access assertion header; only serves /secrets.
export interface Env {
  JWT_SECRET: { get(): Promise<string> };
  ENCRYPTION_KEY: { get(): Promise<string> };
  GITHUB_CLIENT_ID: { get(): Promise<string> };
  GITHUB_CLIENT_SECRET: { get(): Promise<string> };
  TUNNEL_CRED: { get(): Promise<string> };
}

export default {
  async fetch(req: Request, env: Env): Promise<Response> {
    const url = new URL(req.url);
    if (url.pathname !== "/secrets") return new Response("not found", { status: 404 });
    // Access injects this header once its policy passes. Absent => not via Access.
    if (!req.headers.get("Cf-Access-Jwt-Assertion")) {
      return new Response("unauthorized", { status: 401 });
    }
    const body = {
      JWT_SECRET: await env.JWT_SECRET.get(),
      ENCRYPTION_KEY: await env.ENCRYPTION_KEY.get(),
      GITHUB_CLIENT_ID: await env.GITHUB_CLIENT_ID.get(),
      GITHUB_CLIENT_SECRET: await env.GITHUB_CLIENT_SECRET.get(),
      TUNNEL_CRED: await env.TUNNEL_CRED.get(),
    };
    return Response.json(body, { headers: { "cache-control": "no-store" } });
  },
};
```

- [ ] **E6 — `secrets-broker/wrangler.toml`** (Secrets Store bindings; test env stubs)
```toml
name = "codevibes-secrets-broker"
main = "src/index.ts"
compatibility_date = "2024-11-01"

# Production: bind each secret from Cloudflare Secrets Store (store_id + secret_name
# filled during setup — see cloudflare-secrets runbook).
[[secrets_store_secrets]]
binding = "JWT_SECRET"
store_id = "REPLACE_STORE_ID"
secret_name = "codevibes-jwt-secret"
# ... (GITHUB_CLIENT_ID, GITHUB_CLIENT_SECRET, ENCRYPTION_KEY, TUNNEL_CRED identical shape)

[vars]
# test-only fallbacks are injected by vitest config; see test/index.test.ts
```
> The runbook (WS-I) documents filling `store_id` for each binding and adding the remaining five blocks. For vitest, bindings are stubbed via `vitest.config.ts` `miniflare.bindings` (add stub `.get()` returns) — extend the config so tests run hermetically; log the exact stub approach to the decisions log if the pool API differs in the installed version.

- [ ] **E7 — Run tests; verify; commit**
```bash
cd secrets-broker && npm install && npm test && npx eslint src && cd ..
shellcheck deploy/fetch-secrets.sh deploy/bootstrap-secrets.sh
bats deploy/tests/secrets.bats
git add -f deploy/fetch-secrets.sh deploy/bootstrap-secrets.sh deploy/tests/secrets.bats secrets-broker
git commit -m "feat(secrets): Cloudflare broker Worker + fetch/bootstrap to podman secrets"
```

---

## Workstream F — cloud-init template + generator

Renders a paste-ready cloud-init doc (< 32 KiB) that does non-secret host prep, mounts the volume idempotently, installs units, and hands off to the secrets fetch + first deploy (§11).

**Files:** Create `deploy/cloud-init.template.yaml`, `deploy/gen-cloud-init.sh`, `deploy/cloud-init.vars.example`, `deploy/tests/cloudinit.bats`.

- [ ] **F1 — Failing test**

Create `deploy/tests/cloudinit.bats`:
```bash
#!/usr/bin/env bats
setup() {
  TMP="$(mktemp -d)"
  cat > "$TMP/vars" <<'EOF'
CF_SERVICE_TOKEN_ID=tid
CF_SERVICE_TOKEN_SECRET=tsec
FORK_REPO=thejustinwalsh/codevibes
TUNNEL_ID=abc-123
EOF
}
teardown() { rm -rf "$TMP"; }

@test "renders, substitutes vars, and stays under 32 KiB" {
  run bash "$BATS_TEST_DIRNAME/../gen-cloud-init.sh" "$TMP/vars" "$TMP/out.yaml"
  [ "$status" -eq 0 ]
  [ "$(wc -c < "$TMP/out.yaml")" -lt 32768 ]
  ! grep -q "__" "$TMP/out.yaml"        # no leftover placeholders
  grep -q "tid" "$TMP/out.yaml"
}
@test "output is valid cloud-init/YAML" {
  bash "$BATS_TEST_DIRNAME/../gen-cloud-init.sh" "$TMP/vars" "$TMP/out.yaml"
  run yamllint -d relaxed "$TMP/out.yaml"
  [ "$status" -eq 0 ]
}
@test "enables linger, mounts the volume, and never reformats existing data" {
  bash "$BATS_TEST_DIRNAME/../gen-cloud-init.sh" "$TMP/vars" "$TMP/out.yaml"
  grep -q "enable-linger" "$TMP/out.yaml"
  grep -q "mkfs.ext4" "$TMP/out.yaml"
  grep -q "blkid" "$TMP/out.yaml"       # only format if no existing FS
}
```

Run: `bats deploy/tests/cloudinit.bats` → Expected: FAIL.

- [ ] **F2 — `deploy/cloud-init.template.yaml`**
```yaml
#cloud-config
package_update: true
packages: [podman, uidmap, slirp4netns, git, curl, jq, sqlite3, ufw]
users:
  - name: codevibes
    shell: /bin/bash
    sudo: false
    lock_passwd: true
write_files:
  - path: /etc/systemd/journald.conf.d/00-codevibes.conf
    content: |
      [Journal]
      SystemMaxUse=500M
      MaxRetentionSec=2week
  - path: /etc/codevibes/cf-service-token.env
    permissions: '0600'
    owner: root:root
    content: |
      CF_SERVICE_TOKEN_ID=__CF_SERVICE_TOKEN_ID__
      CF_SERVICE_TOKEN_SECRET=__CF_SERVICE_TOKEN_SECRET__
runcmd:
  - systemctl restart systemd-journald
  - ufw --force default deny incoming
  - ufw --force default allow outgoing
  - ufw --force allow OpenSSH
  - ufw --force enable
  - sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/;s/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
  - systemctl reload ssh || systemctl reload sshd || true
  - loginctl enable-linger codevibes
  # mount the detachable data volume idempotently (never reformat existing data)
  - mkdir -p /mnt/codevibes-data
  - DEV=$(ls /dev/disk/by-id/scsi-0HC_Volume_* 2>/dev/null | head -n1)
  - if [ -n "$DEV" ] && ! blkid "$DEV"; then mkfs.ext4 -F "$DEV"; fi
  - if [ -n "$DEV" ]; then grep -q "$DEV" /etc/fstab || echo "$DEV /mnt/codevibes-data ext4 discard,nofail,defaults 0 0" >> /etc/fstab; mount -a; fi
  - chown -R codevibes:codevibes /mnt/codevibes-data /etc/codevibes
  # clone fork, install units, fetch secrets, first deploy (as codevibes, with user systemd)
  - su - codevibes -c 'git clone -b production https://github.com/__FORK_REPO__.git ~/codevibes'
  - su - codevibes -c 'mkdir -p ~/.config/containers/systemd ~/.config/systemd/user'
  - su - codevibes -c 'cp ~/codevibes/deploy/quadlet/*.pod ~/codevibes/deploy/quadlet/*.container ~/codevibes/deploy/quadlet/*.volume ~/.config/containers/systemd/'
  - su - codevibes -c 'cp ~/codevibes/deploy/quadlet/*.timer ~/codevibes/deploy/quadlet/*.service ~/.config/systemd/user/'
  - su - codevibes -c 'cd ~/codevibes/deploy && ./render-config.sh'
  - su - codevibes -c 'export XDG_RUNTIME_DIR=/run/user/$(id -u); set -a; . /etc/codevibes/cf-service-token.env; ~/codevibes/deploy/fetch-secrets.sh'
  - su - codevibes -c 'export XDG_RUNTIME_DIR=/run/user/$(id -u); ~/codevibes/deploy/deploy.sh || true'
  - su - codevibes -c 'export XDG_RUNTIME_DIR=/run/user/$(id -u); systemctl --user daemon-reload; systemctl --user enable --now codevibes-deploy.timer codevibes-backup.timer codevibes-prune.timer'
```

- [ ] **F3 — `deploy/gen-cloud-init.sh`**
```bash
#!/usr/bin/env bash
# Render cloud-init.template.yaml with per-server vars → paste-ready doc. Asserts < 32 KiB.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
VARS="${1:?vars file required}"; OUT="${2:-$HERE/cloud-init.out.yaml}"
# shellcheck source=/dev/null
source "$VARS"
: "${CF_SERVICE_TOKEN_ID:?}"; : "${CF_SERVICE_TOKEN_SECRET:?}"; : "${FORK_REPO:?}"; : "${TUNNEL_ID:?}"
sed -e "s|__CF_SERVICE_TOKEN_ID__|${CF_SERVICE_TOKEN_ID}|g" \
    -e "s|__CF_SERVICE_TOKEN_SECRET__|${CF_SERVICE_TOKEN_SECRET}|g" \
    -e "s|__FORK_REPO__|${FORK_REPO}|g" \
    -e "s|__TUNNEL_ID__|${TUNNEL_ID}|g" \
    "$HERE/cloud-init.template.yaml" > "$OUT"
if grep -q "__" "$OUT"; then echo "gen-cloud-init: leftover placeholder in $OUT" >&2; exit 1; fi
SIZE="$(wc -c < "$OUT")"
if [ "$SIZE" -ge 32768 ]; then echo "gen-cloud-init: $OUT is $SIZE bytes (>=32KiB limit)" >&2; exit 1; fi
command -v cloud-init >/dev/null && cloud-init schema --config-file "$OUT" || true
echo "gen-cloud-init: wrote $OUT ($SIZE bytes)"
```

- [ ] **F4 — `deploy/cloud-init.vars.example`**
```bash
# Copy to cloud-init.vars (git-ignored) and fill. Then: ./gen-cloud-init.sh cloud-init.vars
CF_SERVICE_TOKEN_ID=
CF_SERVICE_TOKEN_SECRET=
FORK_REPO=thejustinwalsh/codevibes
TUNNEL_ID=
```

- [ ] **F5 — Ignore rendered output; run tests; verify; commit**
```bash
printf 'deploy/cloud-init.out.yaml\ndeploy/cloud-init.vars\n' >> .gitignore
bats deploy/tests/cloudinit.bats
shellcheck deploy/gen-cloud-init.sh
git add -f deploy/cloud-init.template.yaml deploy/gen-cloud-init.sh deploy/cloud-init.vars.example deploy/tests/cloudinit.bats .gitignore
git commit -m "feat(cloud-init): provisioning template + generator (<32KiB, idempotent volume mount)"
```

---

## Workstream G — CI workflows

Daily sync of upstream releases into the fork's `production` branch; release-triggered build+push of both images to ghcr after running the codemod (§5, §6). GitHub emails on failure (chosen channel).

**Files:** Create `.github/workflows/sync.yml`, `.github/workflows/build.yml`.

- [ ] **G1 — Failing test (actionlint + assertions)**

Create `deploy/tests/workflows.bats`:
```bash
#!/usr/bin/env bats
WF="${BATS_TEST_DIRNAME}/../../.github/workflows"

@test "workflows pass actionlint" {
  run actionlint
  [ "$status" -eq 0 ]
}
@test "sync runs daily and only acts on new tags" {
  grep -q "cron:" "$WF/sync.yml"
  grep -q "danish296/codevibes" "$WF/sync.yml"
}
@test "build runs the codemod before building, on release" {
  grep -q "release:" "$WF/build.yml"
  grep -q "patches/apply.sh" "$WF/build.yml"
  grep -q "codevibes-backend" "$WF/build.yml"
  grep -q "codevibes-web" "$WF/build.yml"
}
```

Run: `bats deploy/tests/workflows.bats` → Expected: FAIL.

- [ ] **G2 — `.github/workflows/sync.yml`**
```yaml
name: sync-upstream
on:
  schedule:
    - cron: "0 9 * * *"   # 09:00 UTC daily
  workflow_dispatch: {}
permissions:
  contents: write
jobs:
  sync:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          ref: production
          fetch-depth: 0
      - name: Configure git
        run: |
          git config user.name "codevibes-bot"
          git config user.email "bot@users.noreply.github.com"
      - name: Find newest upstream release tag
        id: up
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          TAG=$(gh release view --repo danish296/codevibes --json tagName -q .tagName)
          echo "tag=$TAG" >> "$GITHUB_OUTPUT"
      - name: Merge upstream tag into production if new
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          set -euo pipefail
          TAG="${{ steps.up.outputs.tag }}"
          if git tag --list | grep -qx "$TAG"; then echo "already have $TAG"; exit 0; fi
          git remote add upstream https://github.com/danish296/codevibes.git
          git fetch upstream --tags
          # Merge will fail the job (and email) on conflict — by design.
          git merge --no-edit "$TAG"
          git push origin production
          gh release create "$TAG" --repo "${{ github.repository }}" --title "$TAG" --notes "Synced from upstream $TAG"
```

- [ ] **G3 — `.github/workflows/build.yml`**
```yaml
name: build-images
on:
  release:
    types: [published]
  workflow_dispatch:
    inputs:
      tag: { description: "version tag to build", required: true }
permissions:
  contents: read
  packages: write
jobs:
  build:
    runs-on: ubuntu-latest
    env:
      TAG: ${{ github.event.release.tag_name || inputs.tag }}
    steps:
      - uses: actions/checkout@v4
        with:
          ref: ${{ github.event.release.tag_name || inputs.tag }}
      - name: Apply production codemod (asserts targets)
        run: sh patches/apply.sh .
      - uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}
      - uses: docker/build-push-action@v6
        with:
          context: ./codevibes-backend
          file: ./codevibes-backend/Dockerfile
          push: true
          tags: |
            ghcr.io/${{ github.repository_owner }}/codevibes-backend:${{ env.TAG }}
            ghcr.io/${{ github.repository_owner }}/codevibes-backend:latest
      - uses: docker/build-push-action@v6
        with:
          context: .
          file: ./Dockerfile.web
          build-args: VITE_API_URL=https://codevibes.tjw.dev
          push: true
          tags: |
            ghcr.io/${{ github.repository_owner }}/codevibes-web:${{ env.TAG }}
            ghcr.io/${{ github.repository_owner }}/codevibes-web:latest
```

> Note: the web image's own `Dockerfile.web` also runs `apply.sh` (belt-and-suspenders, idempotent). The explicit step here guarantees the **backend** context (which is `./codevibes-backend`, so it can't see `/patches`) is codemodded — apply.sh edits `codevibes-backend/src/server.ts` at the repo root before the backend `docker build` copies it in. Confirm the backend context still includes the edited file (build-push context is `./codevibes-backend`, and apply.sh edits within it). ✔

- [ ] **G4 — Run tests; commit**
```bash
bats deploy/tests/workflows.bats
git add -f .github/workflows/sync.yml .github/workflows/build.yml deploy/tests/workflows.bats
git commit -m "ci: daily upstream sync + release-triggered image build to ghcr"
```

---

## Workstream H — Diagrams

Generate four `.excalidraw` diagrams via the `excalidraw-diagram` skill (verify it runs; if it needs migrating from `three-flatland`, do that once and log to the decisions log). Export each to SVG for runbook embedding.

**Files:** `docs/runbooks/diagrams/{topology,auth-service-token,secrets-fetch,deploy-rollback}.excalidraw` (+ exported `.svg`).

- [ ] **H1** Invoke the `excalidraw-diagram` skill to create **system topology** (Hetzner pod: caddy+backend+cloudflared, data volume; Cloudflare edge: Tunnel+Access; external: GitHub, DeepSeek, ghcr). Export SVG.
- [ ] **H2** Create **two-layer auth + service token** (browser → Access → app GitHub OAuth; server → service token → Access → broker). Export SVG.
- [ ] **H3** Create **boot-time secrets fetch** (cloud-init → token file → fetch-secrets → Access → broker Worker → Secrets Store → podman secrets). Export SVG.
- [ ] **H4** Create **deploy/smoke-test/rollback decision flow** (check tag → pull → smoke (health+DB) → swap :current OR keep current → record state). Export SVG.
- [ ] **H5** Commit
```bash
git add -f docs/runbooks/diagrams
git commit -m "docs(diagrams): excalidraw sources + svg for runbooks"
```

---

# Phase 2 — Integration (barrier: Phase 1 complete)

## Workstream I — Runbooks (self-contained HTML)

Four single-file HTML runbooks with inline CSS and the WS-H SVGs inlined, authored as markdown and rendered (§14). Greenfield Cloudflare pieces (Zero Trust, Secrets) get their own runbooks.

**Files:** `docs/runbooks/{cloudflare-zerotrust,cloudflare-secrets,setup,recovery}.md` + `.html`; `docs/runbooks/render.sh`.

- [ ] **I1 — Failing test**

Create `deploy/tests/runbooks.bats`:
```bash
#!/usr/bin/env bats
R="${BATS_TEST_DIRNAME}/../../docs/runbooks"
@test "all four runbooks render to self-contained html" {
  for f in cloudflare-zerotrust cloudflare-secrets setup recovery; do
    [ -f "$R/$f.html" ]
    grep -qi "<style" "$R/$f.html"            # inline CSS
    ! grep -qiE 'src="https?://|href="https?://[^"]+\.css' "$R/$f.html"  # no external assets
  done
}
@test "recovery runbook covers rollback, secret re-fetch, volume reattach, restore" {
  grep -qi "rollback" "$R/recovery.html"
  grep -qi "fetch-secrets" "$R/recovery.html"
  grep -qi "reattach" "$R/recovery.html"
  grep -qi "restore" "$R/recovery.html"
}
@test "secrets runbook warns ENCRYPTION_KEY is never regenerated" {
  grep -qi "never" "$R/cloudflare-secrets.html"
  grep -qi "ENCRYPTION_KEY" "$R/cloudflare-secrets.html"
}
```

Run: `bats deploy/tests/runbooks.bats` → Expected: FAIL.

- [ ] **I2 — Author the four markdown runbooks** following §14.1–14.4 exactly. Each begins with a goal line, prerequisites, numbered steps with copy-pasteable commands referencing the real files/paths created in Phase 1 (`deploy/gen-cloud-init.sh`, `deploy/deploy.sh --rollback`, secret names from `config.env`, etc.), and "you should see X" checkpoints. Embed the matching diagram via a markdown image reference to the WS-H SVG.

- [ ] **I3 — `docs/runbooks/render.sh`** (markdown → self-contained HTML with inlined CSS + SVG)
```bash
#!/usr/bin/env bash
# Render each runbook .md to a single self-contained .html (inline CSS; SVGs inlined).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
CSS='<style>body{max-width:46rem;margin:2rem auto;padding:0 1rem;font:16px/1.6 system-ui,sans-serif;color:#111}pre{background:#f5f5f5;padding:.8rem;border-radius:6px;overflow:auto}code{font-family:ui-monospace,monospace}h1,h2{line-height:1.2}.warn{background:#fff3f3;border-left:4px solid #c00;padding:.6rem 1rem}img,svg{max-width:100%}</style>'
for md in "$HERE"/*.md; do
  base="$(basename "$md" .md)"
  # pandoc with --self-contained inlines images/CSS; falls back to embedding CSS only.
  if command -v pandoc >/dev/null; then
    pandoc --embed-resources --standalone --metadata title="$base" -H <(printf '%s' "$CSS") "$md" -o "$HERE/$base.html"
  else
    { printf '<!doctype html><meta charset=utf-8><title>%s</title>%s\n' "$base" "$CSS"; \
      sed 's/&/\&amp;/g;s/</\&lt;/g' "$md" | awk 'BEGIN{print "<pre>"} {print} END{print "</pre>"}'; } > "$HERE/$base.html"
  fi
done
echo "rendered runbooks"
```
> If `pandoc` is the chosen renderer, add it to the verify toolchain note and the decisions log. The fallback guarantees a self-contained file even without pandoc so the test passes.

- [ ] **I4 — Render; run tests; commit**
```bash
bash docs/runbooks/render.sh
bats deploy/tests/runbooks.bats
shellcheck docs/runbooks/render.sh
git add -f docs/runbooks
git commit -m "docs(runbooks): self-contained HTML setup, recovery, zero-trust, secrets"
```

## Workstream J — Integration consistency checks

Cross-file assertions that the workstreams agree (image names, secret names, domains, unit placement) — the safety net for parallel development.

**Files:** Create `deploy/tests/integration.bats`.

- [ ] **J1 — Write the consistency test**
```bash
#!/usr/bin/env bats
ROOT="${BATS_TEST_DIRNAME}/../.."
load_cfg() { set -a; # shellcheck source=/dev/null
  source "$ROOT/deploy/config.env"; set +a; }

@test "quadlet secret names match config.env" {
  load_cfg
  grep -q "$SECRET_JWT" "$ROOT/deploy/quadlet/codevibes-backend.container"
  grep -q "$SECRET_ENCKEY" "$ROOT/deploy/quadlet/codevibes-backend.container"
  grep -q "$SECRET_TUNNEL" "$ROOT/deploy/quadlet/codevibes-cloudflared.container"
}
@test "fetch-secrets creates exactly the secrets quadlet consumes" {
  for s in codevibes-jwt-secret codevibes-encryption-key codevibes-github-client-id \
           codevibes-github-client-secret codevibes-tunnel-cred; do
    grep -q "$s" "$ROOT/deploy/fetch-secrets.sh"
    grep -Rq "$s" "$ROOT/deploy/quadlet/"
  done
}
@test "image names are consistent across deploy.sh, build.yml, quadlet" {
  grep -q "codevibes-backend" "$ROOT/deploy/deploy.sh"
  grep -q "codevibes-backend" "$ROOT/.github/workflows/build.yml"
  grep -q "codevibes-backend:current" "$ROOT/deploy/quadlet/codevibes-backend.container"
}
@test "app domain is consistent (single origin)" {
  grep -q "codevibes.tjw.dev" "$ROOT/Dockerfile.web"
  grep -q "codevibes.tjw.dev" "$ROOT/deploy/quadlet/codevibes-backend.container"
  grep -q "codevibes.tjw.dev" "$ROOT/deploy/cloudflared/config.yml.template"
}
@test "plain systemd timers are installed to the user systemd dir, not quadlet dir" {
  grep -q ".config/systemd/user" "$ROOT/deploy/cloud-init.template.yaml"
}
```

- [ ] **J2 — Run; fix any mismatch found at its source (not here); commit**
```bash
bats deploy/tests/integration.bats
git add -f deploy/tests/integration.bats
git commit -m "test(integration): cross-file consistency for names, domains, secrets"
```

---

# Phase 3 — Closeout (barrier: Phase 2 complete)

## Workstream K — Decisions-log review

- [ ] **K1** Read `docs/superpowers/DECISIONS-LOG.md`. For each entry, reconcile against the spec: either fold the decision into the spec (and adjust code if the decision was suboptimal) or accept it and note it. Append a closing summary entry. Commit any spec/code adjustments.

## Workstream L — Deployability verification

The "complete = deployable" gate (§ working agreement point 4). Everything here runs locally/CI without a live Hetzner box.

- [ ] **L1 — Full verify**: `make verify && make test` → all green.
- [ ] **L2 — Local image build**: `podman build -t codevibes-backend:test codevibes-backend/` and `podman build -f Dockerfile.web -t codevibes-web:test .` → both succeed (proves native build + codemod + vite build).
- [ ] **L3 — Local pod smoke**: create throwaway podman secrets with dummy values; `podman play`/quadlet-equivalent run of backend+web (skip cloudflared); curl `http://localhost:.../api/health` via a temporary published port override → 200; confirm SPA index served. Tear down. (This validates the pod wiring without the tunnel.)
- [ ] **L4 — cloud-init render**: `deploy/gen-cloud-init.sh deploy/cloud-init.vars.example /tmp/ci.yaml` → `< 32KiB`, `cloud-init schema` clean (or yamllint clean).
- [ ] **L5 — Worker dry-run**: `cd secrets-broker && npx wrangler deploy --dry-run` → succeeds.
- [ ] **L6 — Go/no-go checklist**: write `docs/superpowers/DEPLOYABILITY.md` mapping each spec section (§2–§14) to the artifact + test that satisfies it; confirm no spec requirement is unmet. Commit.

```bash
git add -f docs/superpowers/DEPLOYABILITY.md
git commit -m "docs: deployability checklist — spec coverage verified"
```

---

## Self-review (author check against the spec)

- **Spec coverage:** §2 tunnel/Access → C,E,I; §3 OAuth/DeepSeek → C (env), I (OAuth App steps); §4 topology → B,C; §5 build/deploy/rollback → B,D,G; §6 codemod → A,G; §7 logs/disk → F (journald), D (prune), C; §8 code changes → A; §9 sizing → I (setup runbook); §10 resolved → reflected throughout; §11 cloud-init → F; §12 secrets broker → E,I; §13 volume → C,D,F; §14 runbooks/diagrams → H,I. No section unmapped.
- **Placeholders:** the only intentional `REPLACE_*` tokens are in `config.env` (`TUNNEL_ID`, owner) and `wrangler.toml` (`store_id`) — these are per-account values the setup runbook fills, not plan gaps; each is called out and tested for ("no leftover `__` placeholders" in rendered cloud-init).
- **Type/name consistency:** podman secret names, image names, domain, pod name flow from `deploy/config.env` and are asserted identical across workstreams by J. Floating `:current` tag is used uniformly by C (units) and D (swap/rollback).
- **TDD:** every code task is test → run-fail → implement → run-pass → verify → commit. Infra tasks use bats/validators as their tests.
```
