# MUSTER

Multi-harness Unified System for Task Execution & Review.

MUSTER is a delegate-and-forget task board for AI coding sessions. An orchestrator
session (strong model) shards an approved plan into small, self-contained, verifiable
task cards. Fresh executor sessions (cheap model, any harness) each claim one card,
do it, verify it, and report back. All coordination happens through files and git
inside the target repo: no servers, no daemons, no copy-paste ferrying between
sessions. It exists because executing a whole plan in one long session rots its own
context ([docs/problem.md](docs/problem.md)); a fresh session per task is the only
reliable fix, and MUSTER makes that dispatch loop cheap and durable.

MUSTER is a single static Go binary (`muster`). It owns the board in `.muster/`:
task cards and plan snapshots live in git, mutable board state lives in a SQLite
database, and the binary makes every board commit itself. Executors never run git
and never touch the database.

## How it works

`muster init` installs the board under `.muster/` in the target repo:

```
cards/    -- task cards (<plan>-<seq>-<slug>.md) + result / verify / notes sidecars, in git
plans/    -- verbatim plan snapshot per shard, in git
staging/  -- one reviewer-authored fix card awaiting validation (transient)
RUNNER.md -- the executor contract (five verbs)
muster.db -- board state in SQLite (WAL); gitignored, the cards in git are the durable record
```

A task moves `backlog -> inbox -> doing -> done | failed`. Status lives in
`muster.db`; every transition is a git commit the binary makes, never a model.
The core verbs:

- `ingest <cards...>` lints a freshly authored batch of card files and, if clean,
  loads them into the board as `backlog`. The lint is the shard gate: frontmatter
  schema, network-free verify commands, no shell metacharacters, size caps,
  `protected`/`commit_paths` coverage, placeholder and judgment-language scans, and
  exactly one seq-99 integration task per plan. Nothing unlinted lands.
- `promote` moves any `backlog` task whose dependencies are all `done` into `inbox`.
  Idempotent; run after ingest and after every completion.
- `claim -harness <claude|codex> -tier <any|strong>` picks the lowest eligible
  `inbox` task matching the session's identity, records the claim, and prints the
  card. It first reconciles a crashed predecessor's completion and re-promotes
  (self-heal), prints a board status block, and refuses if `doing` is already
  occupied - one executor per checkout.
- `verify` runs the claimed card's verify block - sourced from the git-committed
  card (`git show HEAD:<card>`), so working-tree edits to the card are inert - with
  no shell (commands are spawned directly), appends the transcript to
  `<id>.verify.log`, and owns the attempt counter. The third failed attempt moves
  the task to `failed`.
- `done` re-runs verify as a confirmation check, refuses if the diff touches a
  `protected` file or strays outside `commit_paths`, assembles the result sidecar
  from git and the log, and makes the single completion commit (code + sidecars +
  state change). On a review or integration task it takes an explicit `done pass` /
  `done fail --reason "..."`.

Inspection and recovery verbs round it out: `board` (the status block on demand),
`show <id>` (one card's full state), `doctor` (event-chain, db-vs-git, orphan and
stale-claim checks), `fingerprint` (a digest of board state, used to detect
out-of-band DB writes), and the human-only `redo <id>` / `fail <id>` /
`reimport <id>`.

The card is the prompt, pre-written by the orchestrator and read-only to
executors. Executors follow [`.muster/RUNNER.md`](internal/cli/templates/RUNNER.md):
claim, do, verify, report, done. They never run git and never interpret board
state; any command line ending `Session over.` ends the session.

Review tasks (`tier: strong`) gate downstream work on judgment the tests cannot
give. A failing review stages one fix card; `done fail` validates it, stamps its
generation, and re-blocks the review on it. Two fix generations are the cap; the
third failure goes to a human. A terminal integration task (seq 99) always closes
the plan: full build and suite plus a combined-diff review.

## Install

The product is the binary; the `/muster:*` skills are thin wrappers around it, so
building it once is the real install.

```bash
git clone https://github.com/AmierAshrafw/MUSTER MUSTER
cd MUSTER
go build -o muster.exe ./cmd/muster
```

Put `muster.exe` on PATH, then confirm it resolves - outside a git repo it must
refuse:

```bash
muster version    # muster 2.1.0
muster board      # MUSTER refuse: not inside a git repository.   (outside a repo)
```

Install the board in a target repo:

```bash
muster init
```

Requirements: git >= 2.40, Go >= 1.25 (build-time only; the binary is static, no
cgo). The target must be a git repo with `user.name` and `user.email` set (the
binary commits). On Windows, a Defender exclusion for the repo cuts done-commit
latency. Full walkthrough: [docs/INSTALL.md](docs/INSTALL.md).

The Claude Code plugin ships the slash commands. In Claude Code:

```
/plugin marketplace add AmierAshrafw/MUSTER
```

Install the `muster` plugin from that marketplace. The skills root-sense the board
and wrap the raw verbs; without them the verbs still work.

## Usage

Orchestrator (strong model):

- `/muster:init` (once per repo) - runs `muster init`: preflights (git repo, git
  identity, sync-root guard, refuses a live v1 board), creates `.muster/` and
  `muster.db`, writes `RUNNER.md` and the git ignore/attributes files from
  templates embedded in the binary, appends the board pointer to `CLAUDE.md`, and
  makes the `muster: init` commit.
- `/muster:shard` (after plan approval) - snapshots the plan to `.muster/plans/`,
  authors impl cards (plus opt-in review cards and the mandatory seq-99 integration
  card) into `.muster/cards/`, gates the batch with `muster ingest`, commits the
  cards, and runs `muster promote`. All thinking happens here; executors get zero
  judgment calls.
- `/muster:auto` (after shard) - loops dispatching one Agent-tool subagent per task
  (`/muster:run` or `/muster:review` under the hood) until the board settles, then
  reports the plan closed. Strictly sequential; halts and reports on a failure or
  unexpected board state.
- `/muster:auto-codex` - the same loop with Codex (via `codex exec`) as the
  run-tier executor; review stays a Claude subagent. Requires `codex` on PATH.
- `/muster:close` (after the integration task passes) - reports the plan finished.
  On a v2 board nothing moves: done cards stay in `.muster/cards/` as permanent
  history and keep satisfying dependencies.

Executor / reviewer (fresh session, one task each):

- `/muster:run` - claims with `muster claim -harness claude -tier any` and follows
  `.muster/RUNNER.md`. Sonnet per dispatch policy.
- `/muster:review` - same with `-tier strong`, so it takes only `tier: strong`
  tasks (review and integration in practice). Opus per dispatch policy.

The raw executor loop, if you skip the skills:

```bash
muster claim -harness claude -tier any   # claims one task, prints the card
# ... do the card's Steps ...
muster verify                            # VERIFY PASS (attempt 1)  |  VERIFY FAIL ... (exit 2)
muster done                              # commits everything; prints "... Session over."
```

Nothing is pasted back after a session: results live on disk as sidecars
(`<id>.result.md`, `<id>.verify.log`, `<id>.notes.md`), and the orchestrator reads
them whenever it next runs.

Exit codes: `0` success/pass, `1` refusal (one line starting `MUSTER refuse:`),
`2` verify attempt failed (retry allowed), `3` terminal.

## Guarantees and design highlights

- Verify commands come from the git-committed card (`git show HEAD:<card>`), and
  commands are spawned directly with no shell, so an executor editing its own card -
  or smuggling shell metacharacters - changes nothing.
- The binary owns every state transition and every commit; executors never run git.
  Pass/fail is stamped from exit codes and expected strings, never model-reported.
- Files named in a verify command must be listed in `protected` or `commit_paths`;
  test-looking paths and test-runner invocations must be `protected` (lint checks
  5b/14), and `done` refuses any diff that touches a `protected` file. A test the
  task authors is dual-listed (`protected` + `commit_paths`): the protected check is
  tracked-diff-only, so the task can create it and it then freezes for downstream
  consumers.
- Verify attempts are capped at 3, review fix generations at 2; both caps are
  enforced by the binary, and hitting them routes the work to a human.
- The `events` table is an append-only hash chain (update and delete are blocked by
  triggers); `muster fingerprint` digests board state so an orchestrator can detect
  any out-of-band write to the database - for example a Codex run that should only
  touch code.
- Two test tiers, both Go: `go test ./internal/...` (unit, seconds) and
  `go test -tags process ./test/process` (a real-binary process tier that shards and
  runs a full plan with a review cycle on itself, a minute or two).

## Repo layout

```
cmd/muster/             the muster CLI (main + version)
cmd/musterbench/        musterbench, a separate performance-measurement binary
internal/               cli/ (verbs), store/ (SQLite), card/ (parse + lint), verify/, gitx/, bench/
internal/cli/templates/ RUNNER.md + git ignore/attributes embedded into the binary
test/process/           real-binary process tier (build tag: process)
skills/                 the seven slash commands (init, shard, run, review, close, auto, auto-codex)
templates/              impl / review / fix / integration card templates (used by shard)
.claude-plugin/         plugin + marketplace manifests
docs/                   problem.md, architecture.md, decisions.md, INSTALL.md, v2-cutover.md, bench.md
```

A legacy v1 tree still ships alongside the binary and is being retired
([docs/v2-cutover.md](docs/v2-cutover.md)): `runtime/` (PowerShell + POSIX board
scripts), `tasks/` (the v1 maildir board), and `tests/*.Tests.ps1` (Pester suite).
The `/muster:*` skills root-sense v1 vs v2 and dispatch to whichever board a repo
has; `muster init` refuses to install over a live v1 tree.

Deep dives: [docs/problem.md](docs/problem.md),
[docs/architecture.md](docs/architecture.md),
[docs/decisions.md](docs/decisions.md), and the
[v2 design spec](docs/superpowers/specs/2026-08-15-muster-v2-design.md).

## Status

v2 (Go + SQLite) is the shipped board: single static binary, `.muster/` layout, one
commit per task, dual-mode Claude/Codex executors, and the process-tier dogfood that
shards and runs a plan on itself. The v1 script board is decommissioned and retiring
([docs/v2-cutover.md](docs/v2-cutover.md)).

Out of scope, on purpose:

- No control-plane UI; the planned ASP.NET read-side viewer remains a later idea.
- One active executor per checkout by design; concurrency needs a git worktree per
  executor (KIV).
