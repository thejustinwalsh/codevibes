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
