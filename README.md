# MUSTER

Multi-harness Unified System for Task Execution & Review.

MUSTER is a delegate-and-forget task board for AI coding sessions. An orchestrator
session (strong model) shards an approved plan into small, self-contained, verifiable
task files. Fresh executor sessions (cheap model, any harness) each claim one task,
do it, verify it, and report back. All coordination happens through files and git
inside the target repo: no servers, no daemons, no copy-paste ferrying between
sessions. It exists because executing a whole plan in one long session rots its own
context ([docs/problem.md](docs/problem.md)); a fresh session per task is the only
reliable fix, and MUSTER makes that dispatch loop cheap and durable.

## How it works

The board lives in `tasks/` inside the target repo, in maildir-style status folders:

```
backlog/ -- dependency-blocked          done/    -- completed + result sidecars
inbox/   -- ready to claim              failed/  -- terminal failures
doing/   -- claimed, max one occupant   archive/ -- archive/<plan-id>/ per closed plan
staging/ -- reviewer-authored fix awaiting validation
bin/     -- claim / verify / done / promote / lint / status (.ps1 + .sh each)
```

A task moves: `backlog -> inbox -> doing -> done | failed -> archive/<plan>/`.
Every transition is a git-committed rename performed by a script in `tasks/bin/`,
never by a model:

- `claim` picks the lowest eligible inbox task matching the session's harness/tier
  flags, stamps `claimed_at`, commits the claim. It first runs `promote` (self-heal)
  and prints a status block that flags stale claims and dead-blocked backlog tasks.
  On re-dispatch of a crashed task it probes verify first: already green means a
  crashed predecessor finished the work, so it is filed as done without re-execution.
- `verify` reads the task's verify block from the git-committed claim-time copy
  (working-tree edits to the task file are inert), runs the commands, appends the
  transcript to `<id>.verify.log`, and owns the attempt counter (each attempt is a
  script-authored marker commit, so executors cannot reset the count): third
  failure moves the task to `failed/`.
- `done` re-runs verify, refuses if the diff touches `protected` files or strays
  outside `commit_paths` (except a `fail` verdict on a review/integration task,
  which records a red done-check instead of refusing - D29), assembles the
  result sidecar from git and the log, and makes the single completion commit
  (code + sidecars + task move + promotions). Its last output is a counts-only
  board summary plus the session-over line, so the human reading the session
  tail knows what to dispatch next.
- `promote` moves any backlog task whose dependencies are all in `done/` or
  `archive/` into `inbox/`. Idempotent; runs at claim and completion time.
- `lint` gates shard output: schema, network-free verify commands, size caps,
  placeholder and judgment-language scans. Nothing unlinted lands on the board.
- `status` prints the same board block on demand -- from a bare terminal or any
  session, no claim required. Not part of the RUNNER contract; executors never
  run it.

The task file is the prompt, pre-written by the orchestrator and read-only to
executors. Executors follow [runtime/RUNNER.md](runtime/RUNNER.md) (installed as
`tasks/RUNNER.md`): claim, do, verify, report, done. They never run git and never
interpret board state; any script line ending `Session over.` ends the session.

Review tasks (strong tier) gate downstream work on judgment the tests cannot give.
A failing review stages one fix task; the `done fail` script validates it, stamps
its generation, and re-blocks the review on it. Two fix generations are the cap;
the third failure goes to a human. A terminal integration task (seq 99) always
closes the plan: full build and suite plus a combined-diff review.

## Install

In Claude Code:

```
/plugin marketplace add AmierAshrafw/MUSTER
```

Install the `muster` plugin from that marketplace, then in the target repo run
`/muster:init`.

Requirements: the target is a git repo with `user.name` and `user.email` set
(scripts commit). Windows PowerShell 5.1+ or POSIX `sh`; dual-engine scripts ship
in `tasks/bin/` and behave identically.

## Usage

- `/muster:init` (orchestrator, once per repo) - installs the `tasks/` tree, the
  `bin/` scripts, `RUNNER.md`, and pointer lines in CLAUDE.md/AGENTS.md, then makes
  the init commit. Refuses on a half-usable target (no git identity, existing
  `tasks/`, cloud-sync roots).
- `/muster:shard` (orchestrator, strong model, after plan approval) - snapshots the
  plan, decomposes it into impl tasks plus opt-in review tasks and the mandatory
  integration task, lints the whole batch, commits it, and promotes the unblocked
  tasks. All thinking happens here; executors get zero judgment calls.
- `/muster:run` (fresh executor session, Sonnet per spec 8.1) - the human picks
  Sonnet in the model picker and types this one line. It claims with
  `-Harness claude -Tier any` and follows `tasks/RUNNER.md`. One task per session.
- `/muster:review` (fresh reviewer session, strong model per spec 8.1) - same, but
  claims with `-Tier strong`, so it takes only review and integration tasks.
- `/muster:close` (orchestrator, after the integration task passes) - archives a
  finished plan's cards, sidecars, and snapshot into `tasks/archive/<plan-id>/`.
  Refuses while any card sits outside `done/`.

Nothing is pasted back after a session: results live on disk as sidecars
(`<id>.result.md`, `<id>.verify.log`), and the orchestrator reads them whenever it
next runs.

## Guarantees and design highlights

- Verify commands come from the claim-time git commit (`git show HEAD:`), so an
  executor editing its own task file changes nothing.
- Scripts own every state transition and every commit; executors never run git.
  Pass/fail is script-stamped, never model-reported.
- Files named in verify commands must be listed in `protected` or `commit_paths`;
  test-looking paths and test-runner invocations must be `protected` specifically
  (lint checks 5b/14 - a heuristic over named runners and test-shaped paths, not
  proof against every executor-runnable grader), and the done script refuses any
  diff touching `protected`.
- Verify attempts are capped at 3, review fix generations at 2; both caps are
  enforced by scripts, and hitting them routes the work to a human.
- Executor compliance is measured by a deterministic eval (git + filesystem
  scoring, no judge). The rubric is now 16 checks (updated for D28 marker
  commits, which assert commit shape rather than an exact count); the
  published 15/15 baseline Sonnet run predates D28
  ([results](evals/runner-compliance/results/2026-08-07-sonnet.md)) and a
  re-run under the 16-check rubric is pending (manual dispatch - the eval
  drives a live model session and is not automated here).
- Both script engines pass the same contract test suite: 109 tests, run twice
  (the `MUSTER_ENGINE=sh` pass reruns the full suite against the `.sh`
  mirrors).

## Repo layout

```
.claude-plugin/   plugin + marketplace manifests
skills/           the five slash commands (init, shard, run, review, close)
runtime/          what init installs: bin/ scripts (ps1 + sh) and RUNNER.md
templates/        impl / review / fix / integration task templates
tests/            Pester contract suite, engine-switchable via MUSTER_ENGINE=sh
evals/            runner-compliance eval (setup, rubric, results)
docs/             problem.md, architecture.md, decisions.md, superpowers/ (spec, plans)
```

Deep dives: [docs/problem.md](docs/problem.md),
[docs/architecture.md](docs/architecture.md),
[docs/decisions.md](docs/decisions.md), and the
[v1 spec](docs/superpowers/specs/2026-08-07-muster-v1.md).

## Status

v1 is complete and working: board, scripts, plugin skills, templates, lint, tests,
and the compliance eval. Out of scope, on purpose:

- Codex wrapper is specified but dormant until the Codex app is installed and
  smoke-tested.
- No control-plane UI; the planned ASP.NET viewer is v2 and read-side only.
- One active executor per checkout by design; concurrency needs git worktrees (KIV).
- No automated session spawning; dispatch is one human-typed line per session.
