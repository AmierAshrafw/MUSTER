# Architecture (high level)

Two planes. Agents touch the board only through the `muster` binary and their own
sidecar files; they never run git and never open the database. The binary owns
every state transition and every commit.

MUSTER v2 is a single static Go binary. The board lives in `.muster/` inside the
target repo: task cards and the plan snapshot are committed markdown; mutable state
(status, claims, the event log, verdicts) lives in a SQLite database the binary
manages. A read-side control plane can mirror the board later; it never sits in the
agent critical path.

```
ORCHESTRATOR (strong model, Claude Code)     EXECUTOR (Claude Code, or Codex via /muster:auto-codex)
  superpowers: brainstorm -> plan              fresh session IN target repo
  muster:shard  plan -> cards + ingest-lint    one line: /muster:run  (muster claim ...)
        |                                             |
        v                                             v
  ==================== DATA PLANE (target repo) ====================
  .muster/cards/ (git)   .muster/plans/ (git)   .muster/muster.db (SQLite, gitignored)
  =================================================================
        ^
        | read-only mirror (later)
  CONTROL PLANE (later): read-side viewer / dashboard, never in the agent path
```

## Harness scope

Executors run in Claude Code, or in Codex driven by the orchestrator through
`/muster:auto-codex` (Codex runs the edits via `codex exec`; the orchestrator runs
every `muster` verb and all git). Claim identity is
`-harness <claude|codex> -tier <any|strong>`.

- Capability floor is high, but the binary still owns mechanics, so even strong
  models cannot shed protocol tail-steps.
- "Cheap execution" = quota arbitrage: Codex absorbs run-tier edits, Claude quota is
  reserved for judgment (shard, review).
- The Codex sandbox denies network by default. Verify commands must be network-free
  (ingest-lint enforces it); a task needing package restore (dotnet/nuget, npm
  install) is pinned `harness: claude`.
- No headless app dispatch exists, so cross-app automation stays manual per task.
  `/muster:auto` and `/muster:auto-codex` automate the dispatch loop within one
  orchestrator session - strictly sequential, one executor per checkout.

## Data plane

The board lives in `.muster/` in the target repo:

- `cards/` - one markdown card per task (`<plan>-<seq>-<slug>.md`), plus per-task
  sidecars (`.result.md`, `.verify.log`, `.notes.md`). Committed.
- `plans/` - the verbatim plan snapshot per shard. Committed. Cards quote the
  snapshot, never the live plan.
- `staging/` - at most one reviewer-authored fix card awaiting validation.
  Transient; claim refuses while it is occupied.
- `muster.db` - SQLite (WAL): the `tasks` board rows, `deps` edges, an append-only
  hash-chained `events` log, and review `verdicts`. Gitignored - the committed cards
  are the durable record and the database is a rebuildable index.

Status is a column in `muster.db`, not a folder. A task moves
`backlog -> inbox -> doing -> done | failed`. Every transition is a commit the
binary makes (`muster: init`, `muster(<plan>): shard <n> tasks`, the claim commit,
`muster(<plan>): done <id>`), never a model. `promote` lifts a backlog task to inbox
once its dependencies are all done; it runs at claim time AND completion time, so a
crashed session's dropped promotion self-heals on the next dispatch.

**One active executor per checkout.** Claim atomicity protects the task row; nothing
protects a shared working tree. Concurrent sessions in one checkout produce chimera
commits. Concurrency requires a git worktree per executor - KIV.

**Plan closeout is report-only.** Dependencies resolve in the database and no verb
scans folders, so done cards stay in `.muster/cards/` as permanent history and keep
satisfying dependencies. `/muster:close` only confirms the plan's board is empty
except `done`.

## Task cards

The card is the prompt, pre-written by the orchestrator, and READ-ONLY to executors.
All executor output goes to sidecars.

**Weak-executor principle:** the orchestrator does all thinking at shard time. Cards
carry explicit steps, exact file paths, acceptance criteria, and network-free verify
commands. The executor gets zero judgment calls. Cross-task context is INLINED as
excerpts, never pointed at - a pointer invites the executor to eat the whole plan
into context, recreating the rot this system exists to kill.

Card frontmatter is schema-checked at ingest (`id, plan, type, tier, verify,
depends_on` always; `protected` + `commit_paths` on impl/fix, and omitted on
review/integration; `reviews` on review; `fixes` on fix). Filenames embed the plan
id, so ids are unique across concurrent plans. Steps are phrased as target-state
("ensure file contains"), so recovery re-dispatch is idempotent.

## Verification: two tiers

Reliability order: code > engineers > agents. Applied to the checks AND to who runs
the protocol.

- **Tier 0 - deterministic verify (mandatory, every task).** The verify block is
  runnable commands with exit-code or exact-string expectations, network-free.
  `muster verify` reads the block from the git-committed card
  (`git show HEAD:<card>`), spawns each command directly (no shell), and owns the
  attempt counter as append-only `events` rows - so nothing an executor does to the
  working-tree card, the log, or the tree can lower the count. Cap 3, then the task
  moves to `failed`. Files named in verify commands must be listed in `protected` or
  `commit_paths`; test-looking paths and test-runner invocations must be `protected`,
  and `done` refuses any diff that touches a protected file. A self-authored test is
  dual-listed (`protected` + `commit_paths`); the protected check is tracked-diff
  only, so the task creates it and it then freezes for downstream consumers.
- **Tier 1 - agent review (judgment, opt-in per task).** Review cards are
  pre-written by the orchestrator at shard time with `depends_on: [impl-task]`;
  promote releases them when the implementation lands. Anything downstream of a
  reviewed task depends on the REVIEW id, so downstream work cannot start on
  unreviewed code. Review cards carry `tier: strong`; claim enforces the pin against
  the session identity. A failing review stages one fix card (a strong model writing
  for a weak one); `done fail` validates it, increments the generation, and re-blocks
  the review on it. Cap = 2 fix generations; the third routes to a human.

**Terminal integration task, mandatory per plan.** Shard always emits a final seq-99
task depending on all others: full build + test suite plus a strong-model review of
the combined diff against the plan snapshot. Catches cross-task drift no per-task
check can see.

## Discovery and dispatch

- The executor contract is `.muster/RUNNER.md` (written by init), five verbs: run
  `muster claim`, do the steps, run `muster verify` until it says pass or stop, write
  the notes sidecar, run `muster done`. Zero parsing, zero counting, zero
  self-assessment.
- Thin skill wrappers carry the identity flags: `/muster:run`
  (`-harness claude -tier any`), `/muster:review` (`-tier strong`). The skills
  root-sense a v1 vs v2 board and dispatch accordingly.
- Executors always open INSIDE the target repo.
- Every claim prints a status block (pending tasks, stale `doing` claims,
  dead-blocked backlog) so a human reading the session tail knows what to dispatch.
  `muster board` prints it on demand; `muster doctor` checks the event chain,
  db-vs-git drift, orphaned files, and stale claims; `muster fingerprint` digests
  board state so an orchestrator can detect any out-of-band write to the database.

## Git protocol

- All board transitions happen on one branch (main); feature-branch workflows are
  out of scope.
- Claim is its own small commit. Completion is ONE commit (code + sidecars + state
  change). The binary stages explicit paths, never `git add -A`; it commits first,
  then updates the database, and a crash between the two heals at the next claim.

## Orchestrator side (Claude Code plugin)

A thin layer over superpowers. Nothing in superpowers is copied or modified.

- `muster:init` - runs `muster init`: preflight (git repo, git identity, sync-root
  guard, refuse a live v1 board, detect active git hooks), create `.muster/` + the
  database, write `RUNNER.md` and the git ignore/attributes from templates embedded
  in the binary, append the board pointer to `CLAUDE.md`, one init commit. (Mirror
  the pointer into `AGENTS.md` by hand if the repo keeps one - init writes only
  `CLAUDE.md`.)
- `muster:shard` - approved plan -> plan snapshot + cards (+ opt-in review cards +
  the terminal integration card) -> `muster ingest` lint gate -> commit -> `muster
  promote`.
- `muster:run` / `muster:review` - thin wrappers; claim `-tier any` / `-tier strong`.
- `muster:auto` - orchestrator loop: dispatch one Agent-tool subagent per claimable
  task until the board settles, then close. Strictly sequential; one executor per
  checkout, no worktree isolation. Review/integration is always a fresh, separate
  dispatch, keeping review structurally independent of the diff it grades.
- `muster:auto-codex` - the same loop with Codex as the run-tier executor; review
  stays a Claude subagent. The orchestrator runs every verb and fingerprints the
  database around each Codex run to catch any write Codex should not have made.
- `muster:close` - report the plan finished (nothing moves on a v2 board).

The opt-in fork is unchanged: plan approved, then `superpowers:executing-plans`
(small work) or `muster:shard` (big work).

## Control plane (later)

A read-side viewer over the committed cards and sidecars: fine statuses, a registry,
dashboards, a review queue. Data flows files -> app, never app -> agents. App down =
agents keep working.

## Legacy v1

A v1 script board still ships in-repo and is being retired
([v2-cutover.md](v2-cutover.md)): `runtime/` (PowerShell + POSIX board scripts), a
`tasks/` maildir board, and a Pester suite under `tests/`. The `/muster:*` skills
root-sense v1 vs v2 and dispatch to whichever board a repo has; `muster init`
refuses to install over a live v1 tree. The v1 mechanics live in the
[v1 spec](superpowers/specs/2026-08-07-muster-v1.md) and git history.
