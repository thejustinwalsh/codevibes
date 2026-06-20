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
