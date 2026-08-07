# README rewrite prompt

Session prompt for rewriting the repo README now that v1 is built.
Paste this into a fresh Claude Code session in this repo.

---

Rewrite README.md. The current README says "design phase, nothing is built" - that
is stale. MUSTER v1 is fully implemented, tested, and installed as a working Claude
Code plugin. The README must let any human or agent understand, in one read: what
MUSTER is, why it exists, how it works, how to install it, and how to use it.
Professional and informational tone - no marketing fluff, no emoji.

Ground every claim in the repo before writing. Read at minimum: README.md (current),
docs/problem.md, docs/architecture.md, docs/superpowers/specs/2026-08-07-muster-v1.md
(sections 1, 4, 6, 8 - the contract), .claude-plugin/plugin.json and marketplace.json,
skills/*/SKILL.md (the five skills), runtime/RUNNER.md, and skim runtime/bin/ and
evals/runner-compliance/README.md plus results/. Do not invent behavior - if the
README states a command, message string, or flow, it must match what the scripts and
skills actually do.

Suggested structure (adapt if the content argues otherwise):

1. Title + one-paragraph pitch: delegate-and-forget task board for AI coding
   sessions - an orchestrator (strong model) shards an approved plan into small,
   self-contained, verifiable task files; fresh executor sessions (cheap model,
   any harness) each claim one task, do it, verify it, and report back, all
   through files and git. No servers, no daemons - the repo is the coordination
   medium.
2. How it works: the board (tasks/ folders and their meanings), task lifecycle
   (backlog -> inbox -> doing -> done/failed -> archive), the four executor verbs
   (claim, verify, done, promote) plus lint, RUNNER.md as the executor contract,
   review/fix generation cycling, the recovery probe. A small ASCII diagram of the
   flow is welcome; keep it accurate.
3. Install: add the marketplace and plugin
   (`/plugin marketplace add AmierAshrafw/MUSTER`, install muster), then
   `/muster:init` in a target repo. Requirements: git repo with user identity set;
   Windows PowerShell 5.1+ or POSIX sh (dual-engine scripts ship in tasks/bin/).
4. Usage: the five slash commands (/muster:init, /muster:shard, /muster:run,
   /muster:review, /muster:close) - one short paragraph each: who runs it (human
   orchestrator vs dispatched executor session), what it does, what model tier to
   pick per spec 8.1 (Sonnet + /muster:run for impl tasks, strong model +
   /muster:review for review tasks).
5. Guarantees and design highlights, briefly: verify commands re-read from the
   claim-time commit (working-tree tampering is inert), scripts own all state
   transitions and commits (executors never run git), attempt cap 3, fix
   generation cap 2, deterministic 15/15 runner-compliance eval (link the results
   file), dual ps1/sh engine with a shared contract test suite (137 tests total:
   85 ps1 + 52 sh).
6. Repo layout: short annotated tree (skills/, runtime/, templates/, tests/,
   evals/, docs/). Point deep-dive readers at docs/problem.md, docs/architecture.md,
   docs/decisions.md, and the spec.
7. Status: v1 complete and working; out-of-scope list stays honest (Codex wrapper
   dormant, no control-plane UI, single executor per checkout by design).

Keep it scannable - the whole README under ~150 lines. Verify any command you quote
against the actual skill/script text. No em dash anywhere (plain hyphen). When done,
commit as `docs: rewrite README for v1 release` (conventional subject, no
Co-Authored-By trailer, no agent name), then show me the rendered result for review
before pushing.
