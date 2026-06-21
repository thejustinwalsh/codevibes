# CodeVibes — project working agreement

CodeVibes is a Vite/React SPA (`src/`) plus an Express + better-sqlite3 API (`codevibes-backend/`). Active work: the **production deployment subsystem** (Hetzner + Podman/Quadlet + Cloudflare Tunnel/Access). The authoritative design is `docs/superpowers/specs/2026-06-20-production-deployment-design.md`; the implementation plan is in `docs/superpowers/plans/`.

## How we work

This is binding for every agent working in this repo.

1. **Per task, in this order: tests → feature → verifications.**
   - Write the tests first (they must fail for the right reason).
   - Implement the feature until the tests pass.
   - Run the **verifications** — linters, formatters, type-checkers, compilers, and any artifact validators for the file type (see "Verification commands"). Verifications prove the *edits are valid outputs*; tests prove *the work is correct*. Both must be green before the task is done.

2. **We do not stop between steps or phases — we loop until done.**
   - Loop *within* a task/phase until its tests and verifications all pass.
   - Loop *across* the whole plan until every task is complete. Do not pause for approval between tasks or phases; the plan was agreed up front.

3. **The plan is agreed up front. Decisions found mid-implementation get logged, not negotiated.**
   - If an ambiguity, conflict, or unforeseen choice arises during implementation, make the most reasonable call to keep moving, and **append an entry to `docs/superpowers/DECISIONS-LOG.md`** (append-only — never edit or delete prior entries). A review agent reconciles the log after the initial plan is complete.

4. **"Complete" means deployable.**
   - The work is done when it can be deployed to the Hetzner image (per the spec) and functions as specified — not when the code merely compiles. The final phase verifies the end-to-end deploy path as far as is possible without live cloud resources.

5. **Test strategy: mocks, happy path, catastrophic edges.**
   - Tests rely on **mocks** for external systems (GitHub, DeepSeek, ghcr, podman, Cloudflare, the filesystem/network where practical). Cover the **happy path** thoroughly, plus any **catastrophic edge cases** (data-loss, security-bypass, failed-rollback, secret-leak, disk-fill). Do not chase exhaustive coverage of trivial branches; do guarantee the dangerous ones can't regress.

## Verification commands

**We lint and test only the files this project adds** — infra, containers, YAML, scripts, the Worker, and the codemod. We do **not** lint, format, restyle, or write tests for the upstream CodeVibes app code (`src/`, `codevibes-backend/src/`). We **trust upstream's code**; its correctness is exercised by the **image build's own compiler** (tsc/vite), which gates CI; if our codemod breaks the app, that build fails. That's the safety net for their code.

We touch upstream source **only** for production-config necessity or a **security fix** (e.g. the CORS tightening) — applied via the asserting codemod (`patches/apply.sh`), never as cosmetic edits.

**Local test tiers** (host is macOS/arm64; target is Linux/x86):
- Unit tier on the Mac: bats, shellcheck, yamllint, hadolint, actionlint, caddy validate, Worker vitest.
- Container/systemd tier in an **OrbStack Ubuntu 26.04 Linux machine** (mirrors Hetzner): `podman build`, `quadlet -dryrun`, rootless podman + systemd + linger, local pod smoke. Do **not** install Podman on macOS. CI (x86) builds the authoritative images; local arm64 builds are functional smoke only.
- **Integration tier (REQUIRED after any cloud-init change):** `make verify-cloudinit` boots a fresh OrbStack machine with the rendered cloud-init as real user-data and asserts the host ends up correctly provisioned (ufw, sshd hardening via `sshd -T`, fail2ban, user/linger, clone, units). Lint/render checks do **not** catch runcmd execution bugs — this tier does. Don't ship a cloud-init edit without it green.

Run the relevant verifications for whatever **we** touched:

| Area (ours) | Test | Verify |
|------|------|--------|
| Shell scripts (`deploy/`, `patches/`) | `bats deploy/tests` | `shellcheck <script>` |
| Codemod (`patches/apply.sh`) | `bats` against fixtures | `shellcheck` |
| Dockerfiles (ours) | build smoke (`podman build`) | `hadolint <Dockerfile>` |
| Caddyfile | — | `caddy validate --config Caddyfile` |
| Quadlet units (`deploy/quadlet/`) | — | `/usr/libexec/podman/quadlet -dryrun` |
| cloud-init / YAML (ours) | render + `<32KiB` assert | `yamllint` + `cloud-init schema --config-file` |
| GitHub Actions (`.github/workflows/`) | — | `actionlint` |
| Secrets-broker Worker (`secrets-broker/`) | `npm test` (vitest) | `eslint` + `npx wrangler deploy --dry-run` |

App code (not ours): verified transitively by the image build — `tsc` (backend) and `vite build` (frontend) must succeed for an image to be produced.

## Git

- Commit per task (tests + feature + verification together), small and frequent.
- Identity and commit-message rules are governed by the user's global `~/.claude/CLAUDE.md` (configured repo identity; **no AI co-author trailer**).
- `*.md` is gitignored in this repo; tracked docs (this file, `docs/`) are force-added.
