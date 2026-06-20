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
