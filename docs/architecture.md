# Architecture (high level)

Two planes. Agents touch files only. Protocol mechanics live in scripts, not prompts.
The app watches; it never gates.

```
ORCHESTRATOR (strong model, Claude Code app)      EXECUTOR (Claude Code app or Codex app)
  superpowers: brainstorm -> plan                   open session IN target repo
  muster:shard  plan -> task files + shard-lint     one line: /muster:run or $muster-run
        |                                                 |
        v                                                 v
  ======================= DATA PLANE (target repo, files) =======================
  tasks/backlog/  inbox/  doing/  done/  failed/  archive/<plan>/  staging/  bin/
  ===============================================================================
        ^
        | ingest (read-side, later)
  CONTROL PLANE (v2+): ASP.NET + SQL Server viewer/registry/review dashboard
```

## Harness scope (v1 constraint)

Executors run ONLY in the two desktop apps: Claude Code and Codex. No CLI harnesses.
**PoC: Codex not installed yet - everything runs on Claude Code desktop. Fable 5 orchestrates + reviews, Sonnet 5 executes. Codex joins after install + smoke test (D16).**
Consequences:
- Capability floor is high (GPT-5-Codex-class / Claude-class). Scripts still own mechanics - even strong models shed protocol tail-steps.
- "Cheap execution" = quota arbitrage: Codex subscription absorbs execution load, Claude quota is reserved for judgment (shard, review).
- No headless mode exists in the apps, so programmatic cross-app dispatch is dead until a CLI is ever installed - that ceiling stands. `muster:auto` automates the dispatch loop within one session (D31); it does not lift it.
- Codex app sandbox denies network (config override has a known ignored-bug). Verify commands must be network-free; tasks needing package restore (dotnet/nuget, npm install) are pinned `harness: claude`.

## Data plane

Task files live inside the target project's repo under `tasks/`, in maildir-style status folders:
`backlog/` (dependency-blocked), `inbox/` (ready to claim), `doing/`, `done/`, `failed/`, `staging/` (one reviewer-authored fix task awaiting validation by `done fail` - transient, at most one file, claim refuses while it is non-empty), plus `archive/<plan-id>/` for shipped plans.

Every state transition is performed by a script under `tasks/bin/` (installed by muster:init, ps1 + sh):

- `claim` - picks/validates a task, renames it into doing/, stamps claimed_at itself, commits the claim, refuses malformed frontmatter loudly. Runs `promote` first (self-healing, see below). On re-dispatch it also probes the task's verify block before execution - but only when both gates hold: `type` is `impl` or `fix`, AND git history already shows a claim commit for that id. Green probe means a crashed predecessor did the work, so file it as done without re-executing steps. Both gates are load-bearing: an ungated probe would auto-file every review and integration task, whose verify is green before the judgment work happens (spec 4.1.9).
- `verify` - reads the verify block from the GIT-COMMITTED version of the task file (executor edits to it are inert), runs the commands, writes the raw transcript to `<task-id>.verify.log` itself, owns the attempt counter, and performs the failed/ move at attempt 3. Pass/fail is script-stamped, never model-reported. Each attempt is burned as a marker commit before any command runs and the counter counts those commits since the claim (D28), so nothing an executor does to the working tree - truncating the log, deleting it, killing verify mid-run - can lower it.
- `done` - assembles the result sidecar `<task-id>.result.md` (claim commit via `git log`, files touched via `git diff --name-only`, verify status from the log; the model contributes only a surprises paragraph), moves task + sidecars to done/, makes the single completion commit, then runs `promote`.
- `promote` - scans backlog/ frontmatter, moves any task whose `depends_on` are all in done/ or archive/** into inbox/. Idempotent. Runs at claim time AND completion time, so a crashed session's dropped promotion self-heals on the next dispatch.

Single writer per transition still holds: shard writes backlog/inbox; the claiming session's scripts own inbox -> doing -> done/failed.

**One active executor per checkout.** Claim atomicity protects the task file; nothing protects a shared working tree. Concurrent sessions in one checkout produce chimera commits (`git add -A` swallows the other's half-work). Concurrency requires a git worktree per executor - KIV, out of v1 scope.

**Plan closeout.** When a plan's board is empty except done/, its cards move in one batch to `archive/<plan-id>/` (manual or `muster:close`). Keeps done/ small so promotion scans stay cheap; archived tasks count as satisfied dependencies.

## Task files

The task file is the prompt, pre-written by the orchestrator, and READ-ONLY to executors.
All executor output goes to sidecars (`<task-id>.result.md`, `<task-id>.verify.log`).

**Weak-executor principle:** the orchestrator does all thinking at shard time.
Tasks carry explicit steps, exact file paths, acceptance criteria, and verification commands. The executor gets zero judgment calls.

Cross-task context is INLINED as excerpts, not pointed at - a pointer invites the executor to eat the whole plan into context, recreating the rot this system exists to kill. The full plan is snapshotted at shard time to `tasks/plan-<id>.md`; the live plan may drift freely.

Filenames embed the plan id (`<plan-id>-<seq>-slug.md`), so ids are unique across concurrent plans and the promote scan can match on filenames safely. Shard refuses to write a filename that already exists anywhere under tasks/.

Steps are phrased as target-state ("ensure file contains"), not actions - recovery re-dispatch must be idempotent.

## Verification: two tiers

Reliability order: code > engineers > agents. Applied to the checks AND to who runs the protocol.

- **Tier 0 - deterministic verify (mandatory, every task).**
  Verify block = runnable commands with exit-code or exact-string expectations, network-free.
  The `verify` script runs the loop: fail -> executor fixes -> rerun, script-capped at 3, then script moves to failed/ with the transcript. Fixes may only touch files the task lists; files named in verify commands must be listed in `protected` or `commit_paths`, and test-looking paths and test-runner invocations must be `protected` specifically (lint checks 5b/14) - the done script refuses if `git diff` touches a protected file. Kills the delete-the-test pass. A test the task authors is dual-listed (`protected` + `commit_paths`); the protected check is tracked-diff-only, so the task creates it and it freezes for downstream consumers (D30).
- **Tier 1 - agent review (judgment, opt-in per task).**
  Review tasks are PRE-WRITTEN BY THE ORCHESTRATOR at shard time into backlog/, with `depends_on: [impl-task]` - the existing promote mechanism releases them when the implementation lands. Executors never author task files.
  Review gating is real: anything depending on a reviewed task depends on the REVIEW task's id, so downstream work cannot start on unreviewed code.
  Review tasks carry `tier: strong` (and `harness:` where needed); the claim script enforces pinning against the identity the wrapper skill declares. Reviewer checks only what code cannot test: spec adherence, design quality, side effects.
  Fail = reviewer authors a fix task (strong model writing for a weak one - allowed), generation counter increments; generation 3 refuses to spawn and drops to failed/ for the human. Cap = 2 review cycles in v1.

**Terminal integration task, mandatory per plan.** Shard always emits a final task depending on all others: run the full build + test suite, strong-model review of the combined diff against the plan snapshot. Catches cross-task integration drift no per-task check can see.

## Discovery and dispatch

- Canonical executor contract = `tasks/RUNNER.md`, now five verbs:
  run `bin/claim`, do the steps, run `bin/verify` until it says pass or stop, run `bin/done`, write one paragraph of surprises. Zero parsing, zero counting, zero self-assessment.
- Thin skill wrappers per harness point at it: Claude plugin skill (`/muster:run`), and - specified but DORMANT until the D16 Codex gate passes (spec 8.2) - a Codex repo skill in `.agents/skills/` (`$muster-run`, app invokes via `@`/`$`). No `.agents/` tree ships today and `muster:init` does not create one. Wrappers declare harness identity to the claim script.
- Executors always open INSIDE the target repo.
- Dispatch-time status print (wrapper + claim script): pending tasks, stale doing/ entries (old claimed_at), and dead-blocked backlog tasks sitting behind failed/ work. Detection automated; recovery human.

## Git protocol

- v1: all task-state transitions happen on one designated branch (main). Feature-branch workflows are out of scope until v2.
- Claim = its own small commit. Completion = ONE commit containing code + sidecars + task move + promotions. State transitions are git-atomic; `git stash`/checkout can no longer silently un-claim work.
- Never `git add -A` - explicit paths only (shard writes them into the task).

## Plugin (orchestrator side, Claude Code)

A thin layer over superpowers. Nothing in superpowers is copied or modified.

- `muster:init` - bootstrap target repo: tasks/ folders (incl. `staging/`) + .gitkeep in each, `bin/` scripts and RUNNER.md copied from the plugin's versioned `runtime/`, pointer lines in CLAUDE.md / AGENTS.md, then one init commit. Preflight refuses on a half-usable target: no git repo, no git identity, `tasks/` already present; warns loudly if the repo sits under a sync root (OneDrive/Dropbox - sync engines duplicate and resurrect task files). The Claude wrapper skills ship with the plugin and are never copied into the target repo (the dormant Codex wrapper is a repo skill by design - see above).
- `muster:shard` - approved plan -> plan snapshot + task files (+ review tasks + terminal integration task) in backlog/inbox. Last step is a deterministic **shard-lint**: frontmatter schema-valid, verify block parseable and network-free, expectations machine-diffable, size under cap, no placeholder text, no un-inlined references. Reject the shard output, not the executor's downstream mess.
- `muster:run` - thin wrapper: follow tasks/RUNNER.md. Claims `-Tier any`.
- `muster:review` - same wrapper, claims `-Tier strong`, so a strong session takes only `tier: strong` tasks (review and integration in practice; shard may also pin an impl task strong).
- `muster:close` - archive a finished plan.
- `muster:auto` - orchestrator loop: dispatches one Agent-tool subagent per
  claimable task until the board settles, then performs `muster:close`'s own
  steps. Strictly sequential (D18) - no worktree
  isolation, so never two subagents at once in one checkout. Review/integration
  subagents are always a fresh, separate dispatch - never a resumed conversation
  - keeping review structurally independent of the diff it grades. See D31 and
  the [subagent-orchestration design](superpowers/specs/2026-08-10-muster-subagent-orchestration-design.md).

The opt-in fork is unchanged: plan approved, then `superpowers:executing-plans` (small work) or `muster:shard` (big work).

## Control plane (later)

ASP.NET + SQL Server app. Read-side only: ingests done/ and archive/ (script-written sidecars are its clean data source), holds fine statuses, registry, dashboards, review queue. Data flows files -> app, never app -> agents. App down = agents keep working.

## Sequencing

- **v1** - file convention + bin/ scripts + plugin (init/shard/run/review/close/auto) + manual per-task dispatch, with `muster:auto` looping same-session subagent dispatch on top (D31). registry.json orchestrator-side only.
- **v2** - the ASP.NET viewer app, built THROUGH the pipeline (dogfood).
- **v3** - richer workflow in the app; programmatic dispatch only if a CLI harness ever becomes available.

## Open items (undesigned, on purpose)

- registry.json shape. v1 keeps it orchestrator-side only; the control plane (v2) is what gives it a consumer.
- Codex app: confirm script execution + skill invocation details on Windows. The Codex wrapper is specified but dormant until then.

Settled since this list was first written, and where:

- Task file schema, final field list - v1 spec section 2.2
  ([spec](superpowers/specs/2026-08-07-muster-v1.md)).
- bin/ script contracts - spec section 4. RUNNER.md text - `runtime/RUNNER.md`, the single source of truth; the spec deliberately keeps no copy.
- Task / review-task / fix-task / integration templates - `templates/`, mirrored in spec section 7.
- Dispatch UX wording per app - spec section 8.
- Drain mode (in-session task draining) - rejected in favor of subagent-per-task
  dispatch; D31, [subagent-orchestration design](superpowers/specs/2026-08-10-muster-subagent-orchestration-design.md).
