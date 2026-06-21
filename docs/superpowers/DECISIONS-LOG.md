# Implementation decisions log (append-only)

Decisions made *during* implementation that were not settled in the design spec. **Append only** — never edit or delete prior entries. A review agent reconciles this log against the spec after the initial plan is complete.

Format per entry:

```
## YYYY-MM-DD — <short title>
- **Context:** what was ambiguous / unforeseen
- **Decision:** the call made to keep moving
- **Affected:** files / tasks / workstreams
- **Revisit:** what the reviewer should check
```

---

<!-- Append entries below this line. -->

## 2026-06-20 — Move worker test stubs out of wrangler.toml [vars] (security hardening)
- **Context:** WS-E put vitest stub values in `wrangler.toml` `[vars]`. `wrangler.toml` is committed (correctly — it's deploy config, not secrets), but `[vars]` is deployed to the Worker as **plaintext env vars** and lives in git. With only fake stubs it was harmless, but it's a leak trap (a real value pasted there leaks twice) and would collide with the same-named production Secrets Store bindings.
- **Decision:** Removed the `[vars]` block from `secrets-broker/wrangler.toml` (now zero secret-shaped fields). Moved the test stubs to `secrets-broker/vitest.config.ts` (`poolOptions.workers.miniflare.bindings`). Worker vitest still 3/3. Real secret values never live in any committed file — only in Cloudflare Secrets Store, referenced by `store_id`/`secret_name`.
- **Affected:** `secrets-broker/wrangler.toml`, `secrets-broker/vitest.config.ts`, spec §12.
- **Revisit:** none — verified; this is the correct steady-state.

## 2026-06-20 — Single default Secrets Store (account limit)
- **Context:** Cloudflare accounts get one default Workers-scoped Secrets Store (max 100 secrets); additional stores can't be created.
- **Decision:** Use the default store (5 secrets « 100). Runbook/spec/wrangler updated to "record the default store's ID" rather than "create a store"; all five bindings share that store_id. The broker is retained (user choice): a VM cannot read Secrets Store values directly (management API is write-only for values), so the broker Worker is the required bridge.
- **Affected:** `docs/runbooks/cloudflare-secrets.{md,html}`, spec §14.2, `secrets-broker/wrangler.toml` comments.
- **Revisit:** none.

## 2026-06-20 — Web build needs a .dockerignore; codevibes-backend kept in context (WS-L)
- **Context:** `Dockerfile.web`'s context is the repo root. On a dev host the root carries the frontend's `node_modules` (macOS-native), which `COPY . .` would copy over the image's Linux modules — and the large context bloats builds. First fix over-corrected by excluding `codevibes-backend/`, which broke `patches/apply.sh` (it asserts BOTH `src/hooks/useAnalysis.ts` and `codevibes-backend/src/server.ts` exist).
- **Decision:** Added root `.dockerignore` excluding `node_modules`/`**/node_modules`, `.git`, `.github/`, `dist*`, `docs/`, `deploy/`, `secrets-broker/`, `codevibes-backend/data/` — but **keeping `codevibes-backend/` source** in context so apply.sh's assertion passes. The backend source never reaches the final web image (only `dist/` is copied to the caddy stage). Verified: web image builds clean in OrbStack.
- **Affected:** `.dockerignore` (new).
- **Revisit:** none — verified.

## 2026-06-20 — OrbStack test-machine env setup (WS-L)
- **Context:** Rootless `podman build` in the OrbStack Ubuntu machine failed twice on environment, not on our deliverables: (1) no subuid/subgid ranges for the user → couldn't unpack base image; (2) `caddy:2-alpine` short name didn't resolve (no unqualified-search registry; `node` worked only via an existing alias).
- **Decision:** Configured the OrbStack machine to mirror what Hetzner cloud-init does: added subuid/subgid ranges + `podman system migrate`, and added `unqualified-search-registries = ["docker.io"]`. These are **test-host** fixes; the Dockerfiles are unchanged and correct for CI (GitHub Actions buildx, docker.io default). The subuid step confirms §11's cloud-init subuid configuration is load-bearing.
- **Affected:** OrbStack `codevibes-test` machine only (no repo files).
- **Revisit:** none for the repo; the Hetzner cloud-init already sets up subuids.

## 2026-06-20 — Image HEALTHCHECK ignored by podman OCI builds (WS-L, observation)
- **Context:** The backend Dockerfile's `HEALTHCHECK` is ignored when podman builds OCI-format images ("HEALTHCHECK is not supported for OCI image format").
- **Decision:** Acceptable — runtime health is enforced by `deploy/deploy.sh`'s smoke test (HTTP `/api/health` + DB-touch) at deploy time, which is the actual rollback gate. The Dockerfile HEALTHCHECK is informational (and works under docker-format/CI builds).
- **Affected:** none (observation).
- **Revisit (optional):** consider adding `HealthCmd=` to `codevibes-backend.container` for continuous runtime health → systemd restart, as a future enhancement.

## 2026-06-20 — Deployability gate passed (WS-L closeout)
- All Phase 0–3 workstreams complete and committed. `make test` (37 bats + 3 worker) and `make verify` green. Both images build in OrbStack; backend pod smoke serves `/api/health` and creates the SQLite DB+WAL on the mounted volume; quadlet dry-run clean (19 units); cloud-init renders <32 KiB valid YAML; wrangler dry-run OK. See `docs/superpowers/DEPLOYABILITY.md` for the full spec-coverage map and the residual human punch-list. Implementation is ready for runbook-driven Cloudflare + Hetzner deploy.
- **Note:** WS-K punch-list item "audit `setAuthCookie`" is already satisfied (verified prod-safe cookie flags in `src/utils/auth.ts`).

## 2026-06-20 — Parallel orchestration model for Phase 1
- **Context:** The plan is designed for parallel "horde" execution, but all workstreams share one git working tree. Concurrent `git commit` races corrupt the index, and concurrent edits to shared files (`.gitignore`, `DECISIONS-LOG.md`) conflict.
- **Decision:** Phase 1 subagents are **write-only** — they create their disjoint files and run their own tests/verifications, but do NOT run git, and do NOT edit `.gitignore` or `DECISIONS-LOG.md`. They return a summary plus any decisions in their final message. The orchestrator (main loop) commits each workstream sequentially as agents complete, appends their decisions here, and owns `.gitignore`. Parallelism is preserved for the expensive work (implementation); only the cheap, contention-prone step (commits) is serialized.
- **Affected:** all Phase 1 workstreams A–H; orchestration only — deliverable contents unchanged.
- **Revisit:** if a later phase needs agents to branch independently, switch to git worktree isolation.

## 2026-06-20 — Local verification environment
- **Context:** Host is macOS/arm64; unit-tier tools were absent; podman/quadlet verification needs Linux.
- **Decision:** Installed unit-tier tools via Homebrew (bats-core, shellcheck, yamllint, hadolint, actionlint). Provision an OrbStack Ubuntu machine for podman/quadlet verification (`quadlet -dryrun`, WS-C). arm64 vs x86 means local builds are functional smoke only; CI (x86) is authoritative.
- **Affected:** WS-C verification; Phase 3 L2/L3.
- **Revisit:** confirm the exact Ubuntu version available in OrbStack (26.04, else 24.04 fallback) when WS-C verification runs.

## 2026-06-20 — Quadlet dry-run invocation (WS-C, Makefile)
- **Context:** The plan's `quadlet -dryrun -user <dir>` invocation is wrong — `-user` is a boolean and quadlet does not accept a directory argument, so it scanned default dirs and parsed nothing. Verified in the OrbStack Ubuntu machine.
- **Decision:** Use `QUADLET_UNIT_DIRS=<dir> quadlet -dryrun -user`. Updated `deploy/tests/quadlet.bats` (test 5 now also `skip`s when the quadlet binary is absent, so it passes on macOS and truly runs on Linux) and the `Makefile` `verify-quadlet` target. Verified: dry-run exits 0 and generates 19 units with no warnings in OrbStack.
- **Affected:** `deploy/tests/quadlet.bats`, `Makefile`.
- **Revisit:** none — verified on Linux.

## 2026-06-20 — Bind-volume unit options bug (WS-C)
- **Context:** The dry-run revealed `codevibes-data.volume` produced a malformed `podman volume create` (`--opt o=type=none,o=bind`) because `type=none` was crammed into `Options=`.
- **Decision:** Use the proper quadlet keys `Type=none` + `Options=bind` (+ `Device=`). Re-verified: ExecStart is now `--opt device=/mnt/codevibes-data --opt type=none --opt o=bind`, dry-run exit 0.
- **Affected:** `deploy/quadlet/codevibes-data.volume`.
- **Revisit:** confirm the bind volume actually mounts at runtime during Phase 3 L3 (live pod smoke).

## 2026-06-20 — backup.sh prune uses find, not ls (WS-D)
- **Context:** The plan's `backup.sh` pruned with `ls -1t … | tail | xargs`, which shellcheck flags (SC2012).
- **Decision:** WS-D agent replaced it with a `find -printf '%T@ %p' | sort -rn | tail -n +8 | cut | xargs` pipeline — identical semantics, shellcheck-clean.
- **Affected:** `deploy/backup.sh`.
- **Revisit:** none — behavior equivalent, retains last 7.

## 2026-06-20 — Secrets-broker Worker test/lint plumbing (WS-E)
- **Context:** Getting the broker Worker to test + lint hermetically under the installed toolchain (wrangler 3.114, eslint 9, @cloudflare/vitest-pool-workers 0.5) required several config adjustments not anticipated in the plan.
- **Decisions (all confined to `secrets-broker/`):**
  1. `wrangler.toml`: `[[secrets_store_secrets]]` blocks are **commented out** (not recognized by wrangler 3.x) with correct shape preserved for wrangler 4 / Secrets Store GA; tests use `[vars]` string stubs injected by vitest-pool-workers.
  2. `wrangler.toml`: added `compatibility_flags = ["nodejs_compat"]` (required by vitest-pool-workers 0.5).
  3. `src/index.ts`: `Env` binding type is `string | { get(): Promise<string> }` with a `resolve()` helper, so the same code runs against Secrets Store (`.get()`) in prod and `[vars]` strings in tests — no mock patching.
  4. `vitest.config.ts`: override `css.postcss` with empty plugins so the parent project's tailwind `postcss.config.js` isn't loaded (it hung the runner).
  5. Created `secrets-broker/eslint.config.js` (eslint 9 flat config) + added `@typescript-eslint/parser`/`-plugin` devDeps; removed the superseded `.eslintrc.json`. Needed because eslint 9 ignores legacy `.eslintrc.json` and the parent flat config pulls deps absent from the parent's node_modules.
- **Affected:** `secrets-broker/{wrangler.toml,src/index.ts,vitest.config.ts,eslint.config.js,package.json}`.
- **Revisit (IMPORTANT):** before production deploy, **uncomment and complete the `[[secrets_store_secrets]]` bindings** (fill `store_id` per the cloudflare-secrets runbook) and confirm the binding shape against the wrangler version in CI. The Worker won't serve real secrets until then.

## 2026-06-20 — Integration test asserts config.env indirection, not literals (WS-J)
- **Context:** The plan's J2 sample grepped `fetch-secrets.sh` for literal secret names (`codevibes-jwt-secret`). The implemented script correctly uses `$SECRET_*` variable references from `config.env` (single source of truth), so a literal grep would false-fail correct code.
- **Decision:** `deploy/tests/integration.bats` test 2 instead asserts (a) `fetch-secrets.sh` references each `SECRET_*` variable, and (b) each variable's expanded value appears in the quadlet dir — a true consistency check across the config.env boundary.
- **Affected:** `deploy/tests/integration.bats`.
- **Revisit:** none.

## 2026-06-20 — Decisions-log review (WS-K closeout)

### Entries folded into the spec (with section)

| Entry | Spec section updated | Change |
|---|---|---|
| Secrets-broker Worker test/lint plumbing (WS-E) | §12 (Components paragraph + new warning block) | Added `Env` type description (`string \| { get() }` + `resolve()` helper); added explicit ⚠️ warning that `[[secrets_store_secrets]]` bindings are commented out in `wrangler.toml`, will not serve real secrets until uncommented + `store_id` filled, and requires wrangler ≥4. |
| Secrets-broker Worker test/lint plumbing (WS-E) | §14.2 (`cloudflare-secrets.html` runbook) | Added companion ⚠️ block with the exact pre-deploy steps: install wrangler ≥4, create Secrets Store, fill `store_id`, uncomment the five `[[secrets_store_secrets]]` blocks, run `wrangler deploy`. |
| Caddy routing (implicit — Caddyfile uses `localhost:3001` not `backend:3001`) | §4 (Caddy routing block) | Corrected the code snippet from a named-vhost `backend:3001` form to the actual `:80 { ... reverse_proxy localhost:3001 }` form, and added an explanatory note that containers in a Podman pod share the pod's network namespace (localhost-only, no container-name DNS). |

### Entries accepted as-is (benign implementation details, spec unchanged)

- **Parallel orchestration model** — agent coordination only; no deliverable content changed.
- **Local verification environment** — toolchain setup detail; no design divergence.
- **Quadlet dry-run invocation** — corrected `QUADLET_UNIT_DIRS=<dir> quadlet -dryrun -user` invocation; Makefile/test only, not a spec concern.
- **Bind-volume unit options bug** — corrected quadlet keys (`Type=none` + `Options=bind`); spec §4/§13 describe semantics, not key syntax.
- **backup.sh prune uses find** — shellcheck-required `find`-based pipeline replacing `ls | tail | xargs`; identical semantics, spec §13 only specifies "retain last 7."
- **Integration test asserts config.env indirection** — test implementation detail; spec unaffected.

### Residual human punch-list (must complete before/at production deploy)

1. **`[[secrets_store_secrets]]` bindings** (`secrets-broker/wrangler.toml`): install wrangler ≥4 in CI and locally; create the Cloudflare Secrets Store; note the store ID; uncomment all five `[[secrets_store_secrets]]` blocks; replace every `REPLACE_STORE_ID` with the real ID; run `wrangler deploy`. **The Worker serves test stubs only until this is done.**
2. **`ENCRYPTION_KEY` — generate exactly once, never regenerate**: use `openssl rand -hex 16` (32 hex chars), store in Secrets Store under `codevibes-encryption-key`, never rotate (changing it bricks all encrypted DB rows).
3. **Bind-volume runtime verification** (noted in WS-C entry): confirm `codevibes-data` actually mounts at runtime during the first live pod smoke (L3). The quadlet dry-run passed but the live bind has not been exercised against the Hetzner Volume.
4. **`TUNNEL_ID` placeholder** (`deploy/config.env`): replace `REPLACE_WITH_TUNNEL_UUID` with the real tunnel UUID after creating the Cloudflare Tunnel during first-deploy setup (§14.3 step 2).
5. **ghcr package visibility**: after the first CI build push, set both `codevibes-backend` and `codevibes-web` ghcr packages to **public** in package settings (one-time, required for anonymous pull — §5, §14.3 step 1).
6. **wrangler version in CI**: confirm `.github/workflows/build.yml` pins or installs wrangler ≥4 so `[[secrets_store_secrets]]` is recognized during `wrangler deploy --dry-run` and the live deploy step.
7. **`setAuthCookie` audit** (§8/§10 open confirmation): verify `src/utils/auth.ts` sets `Secure` + `SameSite=Lax` (or stricter) in production before first user login.

## 2026-06-20 — First-deploy fixes (CI dash, no skopeo on box, first-deploy smoke)
- **Context:** The first real build/deploy surfaced three breakages unit tests didn't catch: (1) `build.yml` and `Dockerfile.web` run `sh patches/apply.sh`, but `sh` is dash (CI) / busybox ash (Alpine), which reject `set -o pipefail`; (2) `deploy.sh` listed tags via `skopeo`, which cloud-init never installs; (3) the smoke test required a pre-existing DB (read-only mount, `fileMustExist`), impossible on first deploy → chicken-and-egg.
- **Decision:** (1) `apply.sh` → `set -eu` (POSIX; verified under dash). (2) `deploy.sh` lists tags via the ghcr REST API with curl+jq (already installed; works for public images, no skopeo). (3) smoke test boots the candidate backend against the real RW volume with the real podman secrets and polls `/api/health` — first-deploy-safe, still catches broken mount/corrupt DB. `deploy.bats` updated to mock curl/jq.
- **Affected:** `patches/apply.sh`, `deploy/deploy.sh`, `deploy/tests/deploy.bats`.
- **Revisit:** none — verified via bats + dash run; CI build confirms the Alpine path.

## 2026-06-20 — SSH posture: key-only + fail2ban, no IP allow-list (+ PermitRootLogin fix)
- **Context:** (1) cloud-init set `PermitRootLogin no` with no other key-bearing SSH user → would lock the box out once past the firewall. (2) The planned "Cloud Firewall → static home IP" SSH gate is fragile: the operator's egress IP is unstable behind iCloud Private Relay → lockout risk / mismatched-source drops (observed as a port-22 timeout).
- **Decision:** Port 22 open, **key-only** (`PasswordAuthentication no`, `PermitRootLogin prohibit-password`), brute force throttled by **fail2ban** (sshd jail, maxretry 4, bantime 1h). No source-IP allow-list. Added `fail2ban` to packages + `/etc/fail2ban/jail.local` + `systemctl enable --now fail2ban`. Also documented that the server MUST have an IPv4 (GitHub/ghcr are IPv4-only).
- **Affected:** `deploy/cloud-init.template.yaml`, spec §10/§11/§14.3, `docs/runbooks/setup.{md,html}`.
- **Revisit:** optionally move SSH behind Cloudflare Access (cloudflared) later for true zero-open-ports.

## 2026-06-20 — SSH-timeout root cause: `ufw --force allow` is invalid (added no rule)
- **Context:** Every box timed out on SSH despite sshd listening and the Hetzner Cloud Firewall open. Web console showed ufw **enabled, default-deny, with NO allow rules**. Verified in OrbStack: `ufw --force allow 22/tcp` just prints usage and adds nothing (`--force` is valid only for `enable`/`reset`), while `ufw --force enable` succeeds → ufw deny-all + no SSH allow → SYN silently dropped → connection timeout. The `--force default …` lines failed the same way but happened to match ufw's built-in defaults, so only the missing `allow 22` bit.
- **Decision:** Drop `--force` from every ufw line except `enable`. Also fixed bug B — the `users:` block omitted `- default`, which suppresses injection of the operator's SSH key (would cause permission-denied even once reachable) — by adding `- default`; and cleared the `sudo: false` cloud-init deprecation by omitting the key.
- **Affected:** `deploy/cloud-init.template.yaml`.
- **Revisit:** none — root cause verified empirically; live box unblocked via `sudo ufw allow 22/tcp` on the console.

## 2026-06-21 — Pod bring-up validated in OrbStack; fixed container-service restart + container names
- **Context:** Before another from-scratch deploy, validated the full pod start in OrbStack (rootless, real Quadlet + `systemctl --user`). Found two more bugs: (1) `deploy.sh` `swap_to` restarted only `codevibes-pod`, leaving the per-container Quadlet services down → nothing actually starts; (2) Quadlet names containers `systemd-<unit>` by default, so `podman logs/exec codevibes-*` (and the runbook commands) failed.
- **Decision:** `swap_to` now restarts the container services (`codevibes-backend/web/cloudflared.service`), which pull in the pod + volume. Added `ContainerName=` to each `.container` for clean names. **Re-validated:** pod Up; backend `/api/health` OK directly AND through Caddy (single-origin proxy); Caddy serves the SPA. (cloudflared not exercised — needs a live tunnel.)
- **Affected:** `deploy/deploy.sh`, `deploy/quadlet/codevibes-{backend,web,cloudflared}.container`.
- **Revisit:** confirm cloudflared registers on the real box.

## 2026-06-21 — Cloud-init INTEGRATION test added (the missing verification) + sshd/openssh fixes
- **Context:** We lint/render/schema-checked cloud-init but never EXECUTED it, so runcmd bugs reached prod one at a time. Added `deploy/tests/cloud-init-integration.sh`: boots a fresh OrbStack Ubuntu 26.04 machine with the rendered cloud-init as real user-data and asserts host state. It immediately caught: (1) the sshd `sed` on `/etc/ssh/sshd_config` is a no-op on Ubuntu 24.04+/26.04 (settings live in `sshd_config.d/*.conf` drop-ins; the main file may not even exist); (2) the OrbStack image ships no `openssh-server` (it accesses machines out-of-band).
- **Decision:** Harden sshd via a `write_files` drop-in `/etc/ssh/sshd_config.d/00-codevibes.conf` (`PermitRootLogin prohibit-password`, `PasswordAuthentication no`, `PubkeyAuthentication yes`); add `openssh-server` to packages (no-op on Hetzner, essential on minimal images); add a runcmd mirroring the platform-injected key from root → codevibes. Test asserts effective config via `sshd -T`. Wired into `make verify-cloudinit` and documented as a REQUIRED tier in CLAUDE.md. All checks pass on a fresh boot.
- **Affected:** `deploy/cloud-init.template.yaml`, `deploy/tests/cloud-init-integration.sh` (new), `Makefile`, `CLAUDE.md`.
- **Revisit:** confirm on the real Hetzner box that root gets the injected key (then codevibes gets the copy).
