# CodeVibes production deployment — design

**Date:** 2026-06-20
**Status:** Approved (ready for implementation plan)
**Target:** Self-hosted, single-user CodeVibes at `https://codevibes.tjw.dev` on a Hetzner Cloud VM, fronted by Cloudflare Tunnel + Access, with automated upstream tracking, deploy, smoke-test, and rollback.

---

## 1. Goals and constraints

- Run CodeVibes (Vite/React SPA + Express/SQLite API) in production for **one user (Justin) only**. No randoms may reach the dashboard or use the server against their own repos.
- **Zero open inbound ports** on the server.
- Survive server reboots and process crashes without manual intervention.
- **Auto-track upstream** `danish296/codevibes`, but only deploy on **version tags/releases**, never arbitrary commits.
- Automated **deploy → smoke test → rollback-on-failure**.
- **Log rotation** and disk-growth guards so the box never fills.
- Prefer **Podman** over Docker. Ubuntu x86 Hetzner server.
- Keep our modifications **patchable** across upstream updates with minimal manual work; auto-apply the small required edits.

### Non-goals
- Multi-user / public SaaS operation.
- A Cloudflare Workers script in the request path (clarified: "Zero Trust worker" here means Cloudflare **Tunnel + Access**, not a Workers script).
- Building images on the server (CI builds them; see §5).
- High availability / multi-node. Single VM is sufficient.

---

## 2. Terminology clarification

"Cloudflare Zero Trust" in this design = two products, both used:

- **Cloudflare Tunnel (`cloudflared`)** — a container in the pod that dials *out* to Cloudflare and serves `codevibes.tjw.dev`. The server needs no public inbound ports; the firewall can deny all inbound.
- **Cloudflare Access** — the Zero Trust identity gate. An Access application policy restricts `codevibes.tjw.dev` to Justin's identity (email / GitHub login via Cloudflare's IdP). This is the *outer* auth layer; the app's own GitHub OAuth is the *inner* layer.

No Workers script is involved.

---

## 3. Authentication model

### GitHub auth — full GitHub OAuth App (no code change to auth)

The application is OAuth-first by construction:
- `src/controllers/authController.ts` runs the OAuth code exchange with `scope=user:email repo` (the `repo` scope is what enables private-repo analysis).
- The resulting per-user `github_token` is stored **AES-encrypted** in SQLite (`src/utils/database.ts`, `src/utils/encryption.ts`).
- Analysis routes use `optionalAuth` and read the logged-in user's `github_token` for private repos.

A PAT-only mode would require backend changes (env-token fallback, bypassing login). Because Cloudflare Access already guarantees Justin is the only human who can reach the app, we use the app as built:

- Register a **GitHub OAuth App** with callback `https://codevibes.tjw.dev/api/auth/callback`.
- Set `GITHUB_CLIENT_ID`, `GITHUB_CLIENT_SECRET`, `GITHUB_CALLBACK_URL=https://codevibes.tjw.dev/api/auth/callback`, `FRONTEND_URL=https://codevibes.tjw.dev`.

### DeepSeek key

Per-user and client-supplied: stored encrypted via `PUT /api/auth/deepseek-key`, entered once in the UI. Nothing to bake into the server. (`DEEPSEEK_MODEL` is an env var; the key is not.)

### Two-layer auth summary

1. **Cloudflare Access** — only Justin's identity can load `codevibes.tjw.dev` at all.
2. **App GitHub OAuth** — establishes the GitHub session and the encrypted `github_token` used for private-repo reads.

The GitHub OAuth callback (`/api/auth/callback`) is reached by Justin's already-Access-authenticated browser, so it passes the Access gate normally; no bypass rule is required.

---

## 4. Runtime topology — single origin, one Podman pod, three containers

Serving the SPA and the API on **one origin** (`codevibes.tjw.dev`) avoids cross-site cookie and CORS complexity inherent in the cookie-based auth. The browser calls the API at the same origin under `/api`.

Podman **pod** `codevibes` (containers share the pod's localhost):

| Container    | Image                              | Role |
|--------------|------------------------------------|------|
| `caddy`      | built in CI; SPA baked in          | Serves the static SPA **and** reverse-proxies `/api/*` → `backend:3001`. Single public-facing service inside the pod. |
| `backend`    | built in CI from `codevibes-backend` | Express API. Mounts a named volume for `data/codevibes.db`. Logs to stdout. |
| `cloudflared`| `cloudflare/cloudflared`           | Tunnel; ingress points at `caddy:80`. No published host ports anywhere in the pod. |

Persistence:
- Named volume `codevibes-data` → backend `/app/data` (SQLite DB + nothing else durable).
- Tunnel credentials and the Access/tunnel config provided to `cloudflared` via mounted secret.

### Supervision — Quadlet + systemd

The pod and containers are defined as **Quadlet** units (`*.pod`, `*.container`, `*.volume`) installed under the deploy user's `~/.config/containers/systemd/` (rootless Podman). systemd:
- starts the whole pod on boot (`WantedBy` + `podman generate`-style Quadlet `[Install]`),
- restarts containers on crash (`Restart=on-failure`),
- requires lingering enabled for the deploy user (`loginctl enable-linger`) so rootless services run without an active login session.

This is the "resilient to restarts" requirement.

### Caddy routing (single origin)

```
codevibes.tjw.dev {
    handle /api/* {
        reverse_proxy backend:3001
    }
    handle {
        root * /srv
        try_files {path} /index.html   # SPA fallback
        file_server
    }
}
```

(Caddy runs behind cloudflared, which terminates TLS at Cloudflare; internal hop is plain HTTP within the pod.)

---

## 5. Build and deploy pipeline — CI builds, server pulls

The server **never builds**. CI builds versioned images and pushes them to **GitHub Container Registry (ghcr.io)**. The server pulls a tag and runs it. Rollback = point back at the previous tag. This is what makes rollback trivial and the server "dumb and reliable."

### Repositories and branches

- **Private fork** owned by Justin (e.g. `thejustinwalsh/codevibes`).
- Long-lived branch **`production`** holds the additive infra files (Dockerfiles, Caddyfile, Quadlet units, workflows, deploy script, `patches/`). Upstream tags are merged into `production`.

### Jobs (all GitHub Actions in the fork)

1. **Sync job** — scheduled **daily**.
   - Queries upstream `danish296/codevibes` **releases/tags**.
   - Upstream uses clean semver with GitHub Releases (verified: `v1.0.1`, `v1.0.2`, latest marked), so releases are a reliable trigger — no commit-watching, no separate weekly poll.
   - On a **new tag not yet built**: merge the upstream tag into `production` and create a matching release/tag in the fork.
   - On merge conflict: **stop, do not build, do not deploy**; GitHub Actions emails Justin on workflow failure.

2. **Build job** — triggered by a new release/tag on the fork.
   - First step: run `patches/apply.sh` (the asserting codemod, §6). If any assertion fails, the job fails (and notifies) before building.
   - Build two images and push to ghcr.io tagged with the version (`:vX.Y.Z`) and `:latest`:
     - **backend** — multi-stage from `codevibes-backend/Dockerfile`. Fix: the Alpine builder stage installs `python3 make g++` so `better-sqlite3` compiles its native binding. Final stage runs `node dist/server.js`.
     - **caddy+SPA** — multi-stage: Node stage runs `npm ci && VITE_API_URL=https://codevibes.tjw.dev npm run build`; final stage is `caddy` with `dist/` copied to `/srv` and the Caddyfile in place.

3. **Deploy** — pulled by the **server**, not pushed by CI.
   - A **daily systemd timer** on the server runs `deploy.sh`, which:
     1. Checks ghcr.io for a newer version tag than the running one.
     2. If newer: pulls the new images, starts the new pod/containers **alongside** (or staged), and runs a **smoke test** against `/api/health` (the backend already exposes it; `Dockerfile` healthcheck hits `http://localhost:3001/api/health`).
     3. If healthy within a timeout: swaps the Quadlet units to the new tag, reloads systemd, confirms health again, and records the new tag as **last-known-good**.
     4. If unhealthy: discards the new version, leaves last-known-good running, exits non-zero. (Optional: surface failures via the same GitHub Actions path by having the timer report status, or rely on local journald + a health endpoint check.)
   - Because deploy is a **daily local timer**, there is no inbound webhook surface — consistent with zero open ports.

### Rollback

- The set of recent image tags is retained (last ~3).
- `deploy.sh` records the last-known-good tag (e.g. in a state file on the data volume).
- Manual rollback: `deploy.sh --rollback` repoints Quadlet to the previous good tag and restarts. Automatic rollback: a failed smoke test never swaps off the good version in the first place.

---

## 6. Patch / upstream-tracking flow

Two tiers, matching the two kinds of change:

### Tier 1 — additive infra (the bulk of our work)
All new files, living on `production`:
- `codevibes-backend/Dockerfile` (modified — adds native build deps; this is an *existing* file, treat as Tier 2 if upstream edits it, but currently upstream's Dockerfile is the base we extend),
- `Dockerfile.web` / `Caddyfile` (new),
- `deploy/` (Quadlet units, `deploy.sh`, systemd timer) (new),
- `.github/workflows/` (sync + build) (new),
- `patches/apply.sh` (new).

New files cannot conflict on merge → hands-off.

### Tier 2 — functional source delta (exactly one line today)
The only live functional edit to upstream source:
- `src/hooks/useAnalysis.ts:6` — `const API_BASE_URL = 'http://localhost:3001';` must become origin-relative. (This hook is live: imported by `src/pages/Index.tsx`.) `src/lib/api.ts` already reads `import.meta.env.VITE_API_URL`. The three `localhost:3001` strings in `src/pages/ApiReferencePage.tsx` are display-only curl examples — cosmetic, left as-is.

Handled by an **asserting codemod**, not a line-context git patch:
- `patches/apply.sh` performs idempotent string replacement: replace the literal `const API_BASE_URL = 'http://localhost:3001';` with `const API_BASE_URL = import.meta.env.VITE_API_URL || '';`, asserting **exactly 1 match**.
- A codemod keyed on the string literal survives reformatting/line-moves that would break a `.patch`.
- If upstream changes or removes that line, the assertion fails → build job fails → Justin notified. We never ship unpatched or broken.

`patch-package` is explicitly **not** used: it patches `node_modules` dependencies, which is not what we edit.

### Conflict guarantee
If a merge conflicts (Tier 1 surprise) **or** a codemod assertion fails (Tier 2), the workflow halts **before** build/deploy, and **GitHub Actions emails Justin** (default workflow-failure notification — chosen channel). The currently-running server version stays up. Human-in-the-loop only on the rare real conflict; fully automated otherwise.

---

## 7. Logs and disk safety

- **Container logs → journald** (Quadlet default `LogDriver=journald`). Cap journald with `SystemMaxUse` (e.g. 500M) in `journald.conf` so logs cannot fill the disk.
- **Backend logging**: switch Winston to **stdout** (so it flows to journald) rather than writing unbounded files inside the container. The container filesystem is ephemeral; only the data volume persists.
- **Image growth**: a weekly `podman image prune -f` (systemd timer) plus retaining only the last ~3 version tags caps image disk use.
- **SQLite DB**: lives on the `codevibes-data` volume; stays small (history rows + users). No special rotation needed.

---

## 8. Required code / config changes (summary)

All minor:

1. `src/hooks/useAnalysis.ts:6` → origin-relative API base via the codemod (§6).
2. Build-time env: `VITE_API_URL=https://codevibes.tjw.dev` (frontend build).
3. Backend env (via **podman secrets**, not committed env files):
   - `NODE_ENV=production`, `PORT=3001`
   - `ALLOWED_ORIGINS=https://codevibes.tjw.dev`
   - `FRONTEND_URL=https://codevibes.tjw.dev`
   - `GITHUB_CLIENT_ID`, `GITHUB_CLIENT_SECRET`, `GITHUB_CALLBACK_URL=https://codevibes.tjw.dev/api/auth/callback`
   - `JWT_SECRET` (`openssl rand -base64 32`), `ENCRYPTION_KEY` (exactly 32 chars; `openssl rand -hex 16`), `SESSION_DURATION_DAYS`
   - `DEEPSEEK_MODEL` (optional)
4. `codevibes-backend/Dockerfile` builder stage: add `python3 make g++` for `better-sqlite3`.
5. New files: `Dockerfile.web`, `Caddyfile`, Quadlet units, `deploy/deploy.sh`, systemd timer units, `.github/workflows/sync.yml`, `.github/workflows/build.yml`, `patches/apply.sh`.

Secrets handling: cookie auth requires `Secure`/`SameSite` behavior consistent with HTTPS single-origin; verify `setAuthCookie` in `src/utils/auth.ts` sets `Secure` + `SameSite=Lax` (or stricter) in production. (To confirm during implementation.)

---

## 9. Hetzner sizing — CX22

**Recommendation: Hetzner Cloud CX22** — 2 vCPU (shared, Intel/AMD x86), 4 GB RAM, 40 GB NVMe, ~€4.59/mo. Image: **Ubuntu 24.04 (x86)**.

Rationale:
- The heavy compute (DeepSeek inference) is a **remote API call**; the server is I/O-bound (fetch GitHub files, count tokens with tiktoken, stream SSE). Light.
- CI builds the images, so the server needs **no build headroom**.
- 4 GB comfortably holds the pod, journald buffers, and page cache; 40 GB NVMe is ample with log rotation + image pruning.

Alternatives:
- **CPX11** (2 GB) — would run it, but thin margin; not recommended.
- **CX32** (4 vCPU / 8 GB / 80 GB) — only if on-box builds or additional services are later wanted.

---

## 10. Open items to resolve during implementation

- Confirm `setAuthCookie` production cookie flags (`Secure`, `SameSite`) for the single-origin HTTPS setup.
- Decide exact ghcr.io image names and visibility (private packages; server pulls with a read-only token / `GITHUB_TOKEN`-scoped PAT in a podman secret).
- Tunnel provisioning method: remotely-managed tunnel (config in Cloudflare dashboard) vs locally-configured tunnel (`config.yml` + credentials file mounted into `cloudflared`). Locally-configured keeps ingress in version control; lean that way.
- Cloudflare Access application + policy definition (identity = Justin) — created in the Zero Trust dashboard; document the steps.
