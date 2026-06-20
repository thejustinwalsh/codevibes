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
- **Cloudflare Access** — the Zero Trust identity gate. An Access application policy restricts `codevibes.tjw.dev` to Justin's identity (email / GitHub login via Cloudflare's IdP). This is the *outer* auth layer; the app's own GitHub OAuth is the *inner* layer. The Access **session duration is 30 days** to minimize re-login friction; the kill switch for a lost/stolen device is revoking the Access session (and, if needed, the service token) from the Zero Trust dashboard.

No Workers script sits **in the request path** of the app. A small **out-of-band** secrets-broker Worker is used only for boot-time secret delivery (see §12); it never fronts `codevibes.tjw.dev`.

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
- Podman volume `codevibes-data` → backend `/app/data` (SQLite DB + nothing else durable). The podman volume is **backed by a detachable Hetzner Volume** mounted on the host (see §13), so the DB survives VM replacement.
- Tunnel credentials and the Access/tunnel config provided to `cloudflared` via mounted secret.

### Supervision — Quadlet + systemd

The pod and containers are defined as **Quadlet** units (`*.pod`, `*.container`, `*.volume`) installed under the deploy user's `~/.config/containers/systemd/` (rootless Podman). systemd:
- starts the whole pod on boot (`WantedBy` + `podman generate`-style Quadlet `[Install]`),
- restarts containers on crash (`Restart=on-failure`),
- requires lingering enabled for the deploy user (`loginctl enable-linger`) so rootless services run without an active login session.

This is the "resilient to restarts" requirement.

### Caddy routing (single origin)

```
:80 {
    encode gzip
    handle /api/* {
        reverse_proxy localhost:3001
    }
    handle {
        root * /srv
        try_files {path} /index.html   # SPA fallback
        file_server
    }
}
```

(Caddy listens on `:80` — not a named vhost — because `cloudflared` terminates TLS at Cloudflare and forwards plain HTTP into the pod. Containers in a Podman pod share the pod's network namespace, so `localhost:3001` is how Caddy reaches the backend; container-name DNS is not available within the pod.)

---

## 5. Build and deploy pipeline — CI builds, server pulls

The server **never builds**. CI builds versioned images and pushes them to **GitHub Container Registry (ghcr.io)** as **public** packages. The server pulls a tag **anonymously** (no registry credential needed) and runs it. Rollback = point back at the previous tag. This is what makes rollback trivial and the server "dumb and reliable." Public images are safe here precisely because nothing secret is ever baked in — all secrets arrive at runtime via podman secrets (§12).

### Repositories and branches

- **Public fork** owned by Justin (e.g. `thejustinwalsh/codevibes`). Public by design: it forces good hygiene — nothing secret may be hardcoded or shipped in an image, since anyone can read the repo and pull the images. Privacy-as-a-crutch is exactly the laziness we want to preclude. (See the no-secrets-in-image guarantees in §4/§12.)
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
   - A **daily systemd timer** on the server runs `deploy.sh` at **04:00 America/Detroit** (ET; the timer uses a timezone-qualified `OnCalendar` so DST is handled — Ubuntu 26.04's systemd supports this). A bad deploy therefore lands during off-hours. The timer:
     1. Checks ghcr.io for a newer version tag than the running one.
     2. If newer: pulls the new images, starts the new pod/containers **alongside** (or staged), and runs a **smoke test** = `/api/health` **plus a DB-touch read** (open the SQLite file on the volume and run one query). The DB-touch catches a broken volume mount or corrupt DB before it goes live, not just a dead HTTP port.
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
1b. **CORS tightening** (codemod, asserted): `src/server.ts` currently falls back to `callback(null, true)` for unknown origins ("tighten in production" per its own comment). In production, reject origins not in `ALLOWED_ORIGINS`. Safe for GitHub: CORS is browser-only; GitHub Actions (server-to-server to ghcr), the OAuth token exchange (backend→github.com), and the OAuth callback (top-level browser redirect) are none of them CORS-checked.
2. Build-time env: `VITE_API_URL=https://codevibes.tjw.dev` (frontend build).
2b. `DEEPSEEK_MODEL=deepseek-chat` — the project's own recommended/default model ("faster, more reliable"; `deepseek-reasoner` is "slower, may timeout"). Per-user overridable in the UI.
3. Backend env (via **podman secrets**, not committed env files):
   - `NODE_ENV=production`, `PORT=3001`
   - `ALLOWED_ORIGINS=https://codevibes.tjw.dev`
   - `FRONTEND_URL=https://codevibes.tjw.dev`
   - `GITHUB_CLIENT_ID`, `GITHUB_CLIENT_SECRET`, `GITHUB_CALLBACK_URL=https://codevibes.tjw.dev/api/auth/callback`
   - `JWT_SECRET` (`openssl rand -base64 32`), `ENCRYPTION_KEY` (exactly 32 chars; `openssl rand -hex 16`), `SESSION_DURATION_DAYS`
   - `DEEPSEEK_MODEL` (optional)
4. `codevibes-backend/Dockerfile` builder stage: add `python3 make g++` for `better-sqlite3`.
5. New files: `Dockerfile.web`, `Caddyfile`, Quadlet units, `deploy/deploy.sh`, systemd timer units, `.github/workflows/sync.yml`, `.github/workflows/build.yml`, `patches/apply.sh`.

Secrets are delivered at boot/deploy via the Cloudflare secrets-broker flow (§12) and materialized as **podman secrets** — never committed env files.

Cookie auth requires `Secure`/`SameSite` behavior consistent with HTTPS single-origin; verify `setAuthCookie` in `src/utils/auth.ts` sets `Secure` + `SameSite=Lax` (or stricter) in production. (To confirm during implementation.)

---

## 9. Hetzner sizing — CX22

**Recommendation: Hetzner Cloud CX22** — 2 vCPU (shared, Intel/AMD x86), 4 GB RAM, 40 GB NVMe, ~€4.59/mo. Image: **Ubuntu 26.04 (x86)**. Location: **Falkenstein (fsn1)** — chosen as the cheapest; latency is irrelevant for this app (DeepSeek/GitHub are remote regardless).

Rationale:
- The heavy compute (DeepSeek inference) is a **remote API call**; the server is I/O-bound (fetch GitHub files, count tokens with tiktoken, stream SSE). Light.
- CI builds the images, so the server needs **no build headroom**.
- 4 GB comfortably holds the pod, journald buffers, and page cache; 40 GB NVMe is ample with log rotation + image pruning.

Alternatives:
- **CPX11** (2 GB) — would run it, but thin margin; not recommended.
- **CX32** (4 vCPU / 8 GB / 80 GB) — only if on-box builds or additional services are later wanted.

---

## 10. Resolved decisions

All prior open items are now decided:

- **`ENCRYPTION_KEY` / `JWT_SECRET`:** fetch-only, never regenerated; `ENCRYPTION_KEY` is permanent/immutable (data-loss risk — see §12 warning).
- **SSH exposure:** Hetzner **Cloud Firewall** restricts port 22 to Justin's static home IP; key-only, no root, no passwords (§11).
- **CORS:** tighten the backend to reject origins outside `ALLOWED_ORIGINS` in production (§8 item 1b). Safe for GitHub (CORS is browser-only).
- **Tunnel:** **locally-configured** (`config.yml` + credential in repo/secret), ingress in version control.
- **Secrets storage:** Cloudflare **Secrets Store** (§12).
- **Access session:** **30 days**; kill switch is session/token revocation (§2).
- **Hetzner location:** **Falkenstein (fsn1)**, cheapest; latency irrelevant (§9).
- **Deploy cadence:** daily timer at **04:00 America/Detroit**; smoke test = `/api/health` + DB-touch read (§5).
- **Backups:** trust the Volume; nightly **on-volume** `.backup` (retain 7); no offsite for now (§13).
- **ghcr packages:** **public**, pulled anonymously (no registry token). Public-by-design enforces no-secrets-in-image hygiene (§5).
- **Image retention:** last **3** tags for rollback (§5).
- **DeepSeek model:** default `deepseek-chat` (the project's own recommendation); per-user overridable (§8 item 2b).

Remaining to verify **in code during implementation** (not decisions, just confirmations):
- `setAuthCookie` (`src/utils/auth.ts`) sets `Secure` + `SameSite=Lax` (or stricter) in production for the single-origin HTTPS setup.
- Exact ghcr.io image names/paths.

**Prerequisite (confirmed):** `tjw.dev` is an active Cloudflare zone with live deployments and tunnels; Zero Trust (Access) and Secrets Store are **greenfield** on the account — hence the dedicated runbooks in §14.

---

## 11. Cloud-init provisioning

A single cloud-init `user-data` document (well under Hetzner's 32 KiB limit) turns a bare **Ubuntu 26.04 x86** VM into a host ready to run the pod on first boot, with no manual host setup. It performs **non-secret host prep only**; secrets arrive via §12.

Responsibilities:

1. **Packages** — `apt` install `podman`, `uidmap`, `slirp4netns` (rootless networking), `git`, `curl`, `ufw`. No host `cloudflared` (it runs as a pod container).
2. **Deploy user** — create unprivileged `codevibes` user; ensure `/etc/subuid` and `/etc/subgid` ranges exist for rootless Podman; `loginctl enable-linger codevibes` so its systemd user units start at boot without a login session.
3. **Firewall / SSH hardening** — `ufw` default deny incoming / allow outgoing. SSH (port 22) is restricted at the **network layer by a Hetzner Cloud Firewall** to Justin's static home IP only (he pays for a fixed public IP that will not change); `ufw` allows `OpenSSH` but the Cloud Firewall is the real gate. `sshd`: disable root login, disable password auth, key-only. No other inbound ports (the tunnel dials out).
4. **Log caps** — write `/etc/systemd/journald.conf.d/00-codevibes.conf` with `SystemMaxUse=500M` (and a sane `MaxRetentionSec`).
5. **Mount the data volume** — detect the attached Hetzner Volume by its stable `/dev/disk/by-id/scsi-0HC_Volume_<id>` path; if unformatted, `mkfs.ext4`; mount at `/mnt/codevibes-data` via an `/etc/fstab` entry (idempotent — existing data on a reattached volume is preserved, never reformatted). The podman `codevibes-data` volume binds here (see §13).
6. **Bootstrap the repo + units** — as `codevibes`: clone the fork's `production` branch into `~/codevibes`, install the Quadlet units into `~/.config/containers/systemd/`, install the deploy timer + service and the weekly image-prune timer, `systemctl --user daemon-reload`.
7. **Service-token handoff** — write the Cloudflare Access **service token** (the single bootstrap credential, supplied via cloud-init variables) to a root-owned `0600` file at `/etc/codevibes/cf-service-token.env`, then invoke the secrets fetch (§12) and the first deploy.

What cloud-init deliberately does **not** contain: any app secret beyond the single Access service token. Everything else is fetched at boot from Cloudflare.

### Generation workflow

The committed file is a **template**, not the final document. You generate the paste-ready output locally:

1. `deploy/cloud-init.template.yaml` is checked into the repo (no secrets).
2. `deploy/gen-cloud-init.sh` reads the template plus per-server values — the Access **service-token** ID/secret and any host vars (hostname, fork repo URL, branch) — from a local untracked `deploy/cloud-init.vars` (or env vars) and renders the final document to stdout / `cloud-init.out.yaml`. The script also asserts the output is **< 32 KiB** (Hetzner's limit) and validates basic YAML.
3. You **paste the rendered output into Hetzner's "Cloud config" / user-data box** in the server creation flow. First boot does the rest.

The rendered `cloud-init.out.yaml` is **git-ignored** (it carries the service token); only the template and generator are committed.

Deliverables: `deploy/cloud-init.template.yaml`, `deploy/gen-cloud-init.sh`, `deploy/cloud-init.vars.example`.

---

## 12. Secrets management — Cloudflare service token + broker Worker

**Chosen approach.** Secrets live in Cloudflare and are fetched at boot/deploy by the server; the server holds only a single, scoped, revocable bootstrap credential. The one-time SSH script (`bootstrap-secrets.sh`) is retained as a documented **fallback** for when the broker is unreachable at boot.

### Components

- **Secrets-broker Worker** (out-of-band; not in the app request path). A small Worker that, on an authenticated request, returns the app secrets as JSON. Secret *values* are held outside the Worker code — via a **Secrets Store** binding (preferred) or Worker secrets — and read at request time via `env.JWT_SECRET.get()` (Secrets Store) or plain string (test stubs). The `Env` type uses `string | { get(): Promise<string> }` with a `resolve()` helper so the same code runs against Secrets Store in production and `[vars]` plain strings in vitest.
- **Cloudflare Access service token** — a machine credential (client-ID / client-secret pair). An Access policy on the broker route (`secrets.tjw.dev`) accepts **only** this service token. The server authenticates with `CF-Access-Client-Id` / `CF-Access-Client-Secret` headers.

> ⚠️ **`[[secrets_store_secrets]]` bindings are commented out in `secrets-broker/wrangler.toml`.** They were authored with the correct shape but commented out because wrangler 3.x does not recognize the stanza (it is a wrangler 4 / Secrets Store GA feature). The `[vars]` stubs below them are test-only. **Before production deploy:** upgrade to wrangler ≥4 (or confirm Secrets Store GA support in the installed wrangler version), uncomment all five `[[secrets_store_secrets]]` blocks, fill each `store_id` with the real Secrets Store ID from the Cloudflare dashboard (see §14.2 runbook), and run `wrangler deploy` to push the live Worker. The Worker will not serve real secrets until this step is complete.

### Secrets delivered

`JWT_SECRET`, `ENCRYPTION_KEY` (32 chars), `GITHUB_CLIENT_ID`, `GITHUB_CLIENT_SECRET`, and the **Cloudflare Tunnel credential** for `cloudflared`. (No ghcr pull token — images are public, §5.) Storage is **Cloudflare Secrets Store** (account-level, binding-consumed), chosen over plain Worker secrets for central rotation and a single source of truth.

> ⚠️ **`ENCRYPTION_KEY` is permanent and immutable.** It AES-encrypts every stored `github_token` and `deepseek_key` in the SQLite DB. If it ever changes, **all encrypted rows become permanently undecryptable** — silent data loss, made worse by the portable DB (a rebuilt box fetching a different key would brick the existing data). Generate it **exactly once**, store it immutably in Secrets Store, and treat any rotation as a deliberate decrypt-all → re-encrypt migration, never a casual regenerate. The secrets-broker and fetch script must never regenerate it. (`JWT_SECRET` carries the same "fetch, never regenerate" discipline but lower stakes — changing it only force-logs-out.)

### Flow

1. cloud-init places the service token at `/etc/codevibes/cf-service-token.env` (`0600`).
2. `deploy/fetch-secrets.sh` calls `https://secrets.tjw.dev/...` with the two `CF-Access-Client-*` headers; Access validates the service token and passes the request to the broker Worker.
3. The script writes each returned value directly into a **podman secret** (`podman secret create`). (No `podman login` — ghcr images are public.) No secret is persisted to disk in plaintext beyond the transient fetch; the service-token file is the only at-rest credential.
4. The Quadlet `backend` and `cloudflared` units reference podman secrets (`Secret=` directives) rather than env files.

### Why this shape

- **Reprovision** = re-run from just the service token; the box re-fetches everything. Cattle, not pets.
- **Rotate** a secret once in Cloudflare; the next reboot/deploy picks it up.
- **Revoke** the one service token to instantly cut off a suspected-compromised box.
- Blast radius of the plaintext cloud-init credential drops from "every app secret" to "one narrow, revocable token."

### Tradeoff (accepted)

Introduces and requires maintaining a small broker Worker plus a second Access policy (service-token rule). Accepted because resilience was an explicit goal and the stack is already all-in on Cloudflare (tunnel + Access), so no new vendor is added.

Deliverables: `secrets-broker/` (Worker source + `wrangler.toml`), `deploy/fetch-secrets.sh`, `deploy/bootstrap-secrets.sh` (SSH fallback).

---

## 13. Data resilience — detachable Hetzner Volume

The SQLite DB is the only **non-reconstructible** state in the system (users, analysis history, AES-encrypted GitHub/DeepSeek tokens). Images, secrets, and config are all rebuildable from CI + Cloudflare; the DB is not. So it lives on storage decoupled from the VM lifecycle.

- A **Hetzner Cloud Volume** (minimum 10 GB, ~€0.44/mo; the DB is megabytes, so size is a non-issue) is attached to the server and mounted at `/mnt/codevibes-data`. The podman `codevibes-data` volume binds there; the backend writes `data/codevibes.db` onto it.
- **Move/resize/rebuild a box:** detach the volume from the old VM, attach to the new one; cloud-init detects the existing filesystem and mounts it **without reformatting**, so the DB is intact. Combined with the secrets-broker flow, both compute and data are now cattle.
- **SQLite safety on a Volume:** a Hetzner Volume is block storage formatted ext4 and mounted on a single host, so SQLite file locking behaves exactly as on local disk. (The known SQLite hazard is network *filesystems* like NFS, which this is not.) WAL mode is fine.
- **Backup (defense in depth):** a Volume survives VM loss but not DB corruption or accidental deletion. A nightly systemd timer runs `sqlite3 codevibes.db ".backup"` to a timestamped file **on the volume**, retaining the last 7. This is kept because it's near-zero cost and guards against corruption (the more likely failure than volume loss). **Decision: trust the Hetzner Volume; no offsite backup for now** — data loss here is annoying, not catastrophic. Offsite (Cloudflare R2) remains a noted future enhancement if the data's value grows.

Deliverable: volume mount handled in `deploy/cloud-init.template.yaml` (§11 step 5); nightly backup timer in `deploy/`.

---

## 14. Runbooks (single-file HTML) and diagrams

**Account starting state.** `tjw.dev` is already an active Cloudflare zone with live deployments and tunnels. **Cloudflare Zero Trust (Access) and Secrets Store are not yet set up** on the account — so those two get their own standalone runbooks rather than a few lines buried in the main setup.

All runbooks are **self-contained single-file HTML** (inline CSS, no external dependencies) so they render offline and print cleanly — important because the recovery and Zero Trust runbooks may be read precisely when something is down or half-configured. Authored in markdown under `docs/runbooks/` and rendered to standalone HTML by a small build step. Each embeds the relevant **Excalidraw-generated diagram** (exported to inline SVG/PNG) so the visual travels with the single file.

### 14.1 `cloudflare-zerotrust.html` — Zero Trust / Access setup (greenfield)
Enabling Zero Trust on the account for the first time: create the Access team/org; the **human application + policy** gating `codevibes.tjw.dev` to Justin (30-day session); the **service-token application + policy** gating the broker route `secrets.tjw.dev`; how to generate, record, and later revoke the service token. Diagram: the two-layer auth flow (Access → app GitHub OAuth) and where the service token fits.

### 14.2 `cloudflare-secrets.html` — Secrets Store + broker Worker setup (greenfield)
Enabling Secrets Store for the first time: use the account's **single default Workers store** (one store / 100 secrets per account — you cannot create more, nor need to; record its store ID); add each secret (`ENCRYPTION_KEY` with its **generate-once, never-rotate** warning called out in red); deploy the `secrets-broker/` Worker with its Secrets Store bindings; bind it behind the §14.1 service-token Access policy; test a fetch with the service-token headers. Diagram: the boot-time secrets fetch path (cloud-init → service token → Access → broker Worker → Secrets Store → podman secrets).

> ⚠️ **Manual step required before deploying the Worker.** In `secrets-broker/wrangler.toml`, the five `[[secrets_store_secrets]]` blocks are currently **commented out** (wrangler 3.x does not support this stanza). Before running `wrangler deploy`: (1) ensure wrangler ≥4 is installed in CI and locally; (2) create the Secrets Store in the Cloudflare dashboard and note its store ID; (3) uncomment all five blocks and replace each `REPLACE_STORE_ID` placeholder with the real store ID; (4) run `wrangler deploy` to push the live Worker. Until this is done the Worker falls back to the `[vars]` test stubs and will not return production secret values.

### 14.3 `setup.html` — end-to-end first deploy
Full first-time setup in dependency order, with copy-pasteable commands and explicit "you should see X" checkpoints. References §14.1 and §14.2 for the two Cloudflare pieces rather than duplicating them:
1. **GitHub** — create the public fork; register the GitHub **OAuth App** (callback `https://codevibes.tjw.dev/api/auth/callback`); after the first build, set the two ghcr packages' visibility to **public** (one-time, in package settings). No pull token needed.
2. **Cloudflare** — complete §14.1 (Zero Trust) and §14.2 (Secrets) ; create the **Tunnel** (locally-configured `config.yml`), store its credential in Secrets Store, point ingress at the app; DNS for `codevibes.tjw.dev` and `secrets.tjw.dev`.
3. **Hetzner** — create the **Volume**; render cloud-init via `deploy/gen-cloud-init.sh`; create the **CX22 / Ubuntu 26.04 / Falkenstein** server, attach the volume, set the **Cloud Firewall** (SSH → your static IP only), paste the rendered cloud-init.
4. **First deploy + verification** — watch cloud-init complete; confirm the pod is up (`systemctl --user status`), the smoke test (`/api/health` + DB-touch) passes, the site loads through Access, and GitHub OAuth login + a private-repo analysis succeed end to end. Diagram: full system topology (Hetzner pod + volume, Cloudflare edge, GitHub/DeepSeek/ghcr).

### 14.4 `recovery.html` — manual re-deploy / recovery
For when automated smoke-test + rollback did **not** save you:
1. **Triage** — SSH in; `systemctl --user status`, `podman ps -a`, `journalctl --user -u` for the failing unit; check the smoke test manually.
2. **Manual rollback to a known-good tag** — find the last-known-good tag (state file on the volume / ghcr tag list); point the Quadlet unit at it; `daemon-reload` + restart; re-verify.
3. **Re-fetch secrets** — if failure is secret-related, re-run `deploy/fetch-secrets.sh`; verify podman secrets exist.
4. **Volume reattach / box replacement** — detach the Hetzner Volume, spin a fresh VM from cloud-init, attach the volume; verify the DB mounted intact and unreformatted.
5. **Restore from backup** — if the DB is corrupt, stop the backend, restore the latest `.backup` file from the volume, restart, verify.
6. **Escalation** — full teardown and rebuild from the setup runbook, with the volume preserving data. Diagram: the deploy → smoke-test → swap/rollback decision flow.

### Diagrams (Excalidraw)
Generated with the `excalidraw-diagram` skill (available as a user/plugin skill; if it needs migrating out of the `three-flatland` repo, that's a one-time prerequisite). Source `.excalidraw` files committed under `docs/runbooks/diagrams/`, exported to inline SVG for embedding:
- **System topology** (setup.html)
- **Two-layer auth + service token** (cloudflare-zerotrust.html)
- **Boot-time secrets fetch path** (cloudflare-secrets.html)
- **Deploy/smoke-test/rollback decision flow** (recovery.html)

Deliverables: `docs/runbooks/{cloudflare-zerotrust,cloudflare-secrets,setup,recovery}.md` + their rendered `.html`, the markdown→HTML render step, and `docs/runbooks/diagrams/*.excalidraw`.
