# MUSTER codex-executor mode - design

Date: 2026-08-17
Status: design (approved direction pending); not yet planned or implemented
Branch: design/codex-executor

## 1. Motivation

MUSTER's orchestrator loop (`skills/auto`) drains a sharded plan by dispatching
one fresh executor per task. Today every executor is a Claude subagent, so
run-tier execution runs on Sonnet 5 - Claude quota. That is the exact quota the
multi-harness argument exists to protect (problem.md:22-23, D16).

This mode swaps the per-RUN-task executor to OpenAI Codex, invoked as a
`codex exec` subprocess. Execution token-load moves onto the flat-rate Codex
subscription; the Claude quota is reserved for judgment (orchestration +
review). The orchestrator stays Claude.

The enabler that did not exist at v1 design time: a Codex CLI (`codex exec`) is
now installed on the box. problem.md:41-43 and D16's PoC sub-constraint ("Codex
not installed yet") are stale. A headless CLI executor is now possible, so
run-tier dispatch no longer needs the human clipboard.

## 2. Fixed constraints

- Orchestrator stays Claude (Opus 4.8 or Fable 5), runs the loop.
- Run-mode executor = Codex `gpt-5.6-luna` @ effort `xhigh`.
- Review-mode = orchestrator's choice: Claude `opus` (default), or Codex
  `gpt-5.6-sol` @ `high` (opt-in).
- Priorities: fast, then robust (both load-bearing).
- v2's Go rewrite exists to MINIMIZE git interaction. No extra commits or
  worktree churn per task.
- Guard only failures that BREAK MUSTER board/commit integrity. Work-quality is
  the existing review stage's job; do not rebuild the reviewer.

## 3. Grounding facts (verified against v2 source)

The design rests on these invariants. Each is confirmed at the cited location.

- The SQLite board `.muster/muster.db` is gitignored and lives in the
  **workspace**, not under `.git`. Codex `--sandbox workspace-write` can write
  it; it cannot write under `.git/` (empirically blocked on this box;
  environment-dependent, so the design does not rely on the block).
- Only MUSTER's own git-API call under `done` writes `.git`: `completePass`
  commits (done.go:98). Claim's first path is DB-only (claim.go:169,
  store ClaimTask). The verify attempt counter is a DB event, not a commit
  (verify.go:68). Caveat: a card's verify **command block** is arbitrary and
  could itself run git - lint does not forbid it (lint.go:22). "Only done writes
  .git" is a property of MUSTER's own git calls, not of every verb's full
  execution.
- `NextEligible(tier, harness)` filters `WHERE status='inbox' AND tier=? AND
  (harness='' OR harness=?)` (store/claim.go:18). Tier is equality. A
  `-harness codex` claim skips `harness:claude` pins. No plan predicate - it
  scans the whole board (store/claim.go:16).
- `muster done` operates on the sole `doing` row (occupant, no id). It re-runs
  the card verify block as done-check (done.go:189), rejects protected-file
  edits (done.go:38-44) and out-of-commit_paths changes (done.go:51-59),
  requires HEAD descend from head_at_claim (done.go:182), commits before the DB
  flip (done.go:98 then 123), attributes to `t.ClaimedBy`.
- Promotion trusts DB `status='done'` with no commit validation
  (store/board.go:14-17). The event chain is an unkeyed SHA-256 hash verified
  only by `doctor` (doctor.go:29); INSERTs are allowed (only UPDATE/DELETE have
  triggers, schema.go:38-41); a raw DB overwrite bypasses triggers entirely.
- `reconcile` heals a `doing` row by grepping the git log for the subject
  `muster(<plan>): done <id>` (claim.go:62) without validating commit contents.
- Board counts split by tier only; `harness` is not in board counts but IS in
  `muster show <id>`'s raw card body (board.go:111).
- Existing `auto` is strictly sequential, one executor per checkout (D18, no
  worktree), single-active-plan precondition (SKILL.md:28), and a before/after
  `muster board` diff is its only progress signal (SKILL.md:113).

## 4. Architecture

### 4.1 Actor split

The orchestrator (Claude) owns **every** `muster` verb and every DB write. Codex
owns file edits, a raw self-check, and its notes file. Codex runs no `muster`
verb and touches no DB.

This split is deliberate. It puts every board/commit-integrity guard
(done-check re-verify, protected/scope check, ancestor check, attempt cap) on
the orchestrator in the real environment, outside Codex's sandbox. It shrinks
Codex's legitimate DB-write surface to zero, which makes a tamper check
meaningful (section 6).

### 4.2 Per-task triad

Sequential, one active plan, one checkout (D18). Per run task:

1. **Orchestrator: claim.** Run `muster claim -harness codex -tier any` in the
   live checkout. DB-only, fast. Capture the printed card. Fingerprint `.muster`
   DB state (section 6).
2. **Codex: edit + self-check + notes.** Spawn a foreground
   `codex exec -m gpt-5.6-luna -c model_reasoning_effort=xhigh
   --sandbox workspace-write "<prompt>"` subprocess. The prompt inlines the
   card's Steps (D23 weak-executor inlining) plus a scoped contract: edit only
   the card's paths; run the raw test/build command to self-correct; write
   `.muster/cards/<id>.notes.md`; then STOP. Do not run any `muster` verb, git,
   or touch the DB. The self-correction loop (token-heavy iteration) runs here,
   on the Codex subscription. The dispatched prompt MUST make the executor export
   the tool caches (`GOCACHE`/`GOTMPDIR`) at a temp-dir path in its OWN shell, on
   each Go command line (section 7) - env set on the `codex exec` parent does not
   cross into the sandbox - or the raw self-check cannot build/test in the sandbox.
3. **Orchestrator: verify + done.** Confirm the Codex process tree is dead.
   Re-fingerprint the DB (mismatch = tamper, section 6). Run `muster verify`
   (authoritative, real environment). On fail, re-dispatch Codex into the SAME
   claim with the failure transcript (no re-claim) up to the attempt cap. On
   pass, run `muster done`. Then re-read `muster board` - the board delta is the
   progress signal (section 5.1).

### 4.3 Contract source

No forked `RUNNER-codex.md`. The Codex dispatch prompt carries the scoped
contract as a string (canonical RUNNER.md's DO/REPORT semantics + hard rails,
minus every verb the orchestrator owns). Single contract file, per D6; the delta
is a prompt, not a committed file (matches the prompts-in-chat rule).

Codex environment caveats (probe, 2026-08-17): this box injects superpowers
skills into Codex via AGENTS.md, so a bare `codex exec` runs a skill-preamble -
it read `using-superpowers` before the task even under a strict "do exactly
this" prompt. The dispatch MUST frame Codex as a dispatched subagent to trigger
that skill's `<SUBAGENT-STOP>` skip, or Codex burns tokens on skill files and
can wander off-script. Codex's default per-command timeout is ~10s - a cold
build exceeds it (Codex self-recovered with a longer timeout, but the dispatch
should set generous timeouts on build/test commands). The temp-dir tool caches
(section 7) are exported by the executor in its own shell here, not on this
`codex exec` parent process.

## 5. Progress signal and routing

### 5.1 Progress signal

`muster done`'s exit code is NOT the trust boundary. `completePass` commits
before its post-commit hook checks (done.go:98 then 103-121), so a `done` that
exits non-zero can still leave the matching commit, which the next claim's
reconcile blesses. The durable signal is the **board re-read** after `done` -
did the task's row reach `done`? This matches `auto`'s board-diff design and is
kept for the same reason.

### 5.2 Routing

`muster claim` refusals all exit 1 (app.go:31), so the exit code cannot route.
Route on **board state + the specific refusal message**, cross-checked:

- Preconditions (inherited from `auto`): exactly one active plan on the board
  (M6 - `NextEligible` has no plan filter); `doing` empty at the top of each
  iteration (a non-empty `doing` is a crashed predecessor, section 8).
- If `muster board` shows run tasks and `claim -harness codex -tier any`
  succeeds: run the triad (section 4.2).
- If it refuses with "nothing to claim for codex/any." (the full identity
  string, claim.go:143) while run tasks remain: those remaining run tasks are
  `harness:claude`-pinned (network-verify tasks, forced by lint.go:127) or
  otherwise codex-ineligible. Fall back to a Claude subagent
  for them (reuse `auto`'s run-mode). The message alone does not prove
  claude-pinned; confirm against the board (strong-tier, blocked, other-plan,
  and complete states also produce a codex-empty inbox).
- Review tasks (tier strong): section 8.

### 5.3 Why hybrid, not pure-codex

Claude-pinned run tasks must run on Claude regardless - their verify needs
network, which Codex's sandbox denies. Falling back lets the loop drain the
whole plan instead of stranding those tasks.

## 6. Integrity guards (board integrity, not work-quality)

### 6.1 What the split already guarantees

Because the orchestrator runs claim/verify/done in the real environment, every
existing integrity guard applies unchanged and outside Codex's control:
done-check re-verify (done.go:189), protected-file and commit_paths scope checks
(done.go:38-59), HEAD-ancestor check (done.go:182), the DB-backed attempt cap
(verify.go:60). Codex cannot weaken these because it runs none of them.

### 6.2 DB fingerprint (new, cheap, detection-oriented)

Codex has raw write access to `.muster/muster.db` under workspace-write. The DB
is authoritative for promotion and eligibility (board.go:14), so a raw write
could forge completion, reset attempts, or mark unrelated tasks done. Prompt
rails are not isolation.

Guard: the orchestrator fingerprints DB state immediately after its own claim
(section 4.2 step 1) and again after Codex exits, before running any verb. A
mismatch means Codex wrote the DB - abort the task and halt for human recovery.
Since Codex legitimately writes no DB in this design, the expected delta is
zero, so the check is a clean equality.

Mechanism (decided; validated by probe 3, 2026-08-17): a SQL **content digest**
over `tasks(id,status,tier,harness,claimed_by,head_at_claim)` +
`events(count, max id, last hash)` + `verdicts(count)`, hashed. It is
WAL-agnostic (SQLite merges the WAL into the read view), needs no checkpoint,
had zero false positives on a no-write run, and detected both a raw
`status='done'` forge and a forged event insert. Refine in the plan: also cover
the `deps` table (a forged dependency edge changes promotion) and decide whether
to digest `backup.db`.

Rejected alternatives (probe 3 evidence): raw byte-hash of `muster.db`/`-wal`/
`-shm` false-positives because any sqlite read checkpoints the WAL into
`muster.db` and rewrites all three files with no logical change; `PRAGMA
data_version` missed real writes when compared across fresh per-invocation
connections.

This is detection, not prevention - consistent with D27's model. It does not
rebuild the reviewer; it catches the one new failure the split introduces.

### 6.3 Out of scope (declared, per D27)

A truly adversarial executor that overwrites the DB and races the fingerprint
window is out of scope, exactly as D27 puts an executor that edits its own
grading scripts out of scope. This is not a regression: a Claude subagent
executor has the same unsandboxed DB access. The fingerprint raises the bar from
"undetected" to "detected next verb" for the non-adversarial case, which is the
realistic one (the smoke task touched no DB).

## 7. Failure handling and crash recovery

All recovery is human (D12); the loop detects and halts, it never auto-reclaims.

- **Codex killed mid-run** (no completion commit). The `doing` row persists. The
  next `muster claim` reconciles (finds no commit, no-op) then refuses on the
  occupied `doing` row (claim.go:128) before the recovery probe is reachable
  (claim.go:180). Recovery: reap the Codex tree, `muster redo <id>`,
  re-dispatch. The loop must detect `doing` occupied at the top of an iteration
  and halt for this. (Corrects an earlier assumption that the next claim
  auto-heals a mid-run crash - it does not; the probe only heals FINISHED work
  on a re-claim, ClaimCount >= 2.)
- **Claude crashes after claim, before spawning Codex** - same stale `doing`,
  same recovery.
- **Orphaned `muster verify` child.** If a Codex-spawned process survives and
  races the orchestrator's `done`, it can flip `doing -> failed` after `done`
  commits, splitting git and DB state. Mitigation: the orchestrator must prove
  the entire Codex process tree is dead (Windows: reap descendants) before
  running any `muster` verb. In the revised design Codex runs no `muster verify`
  at all, which removes the concurrent-DB-writer case; the reaping guard covers
  any stray raw child.
- **`done` commits then a post-commit hook keeps mutating** (done.go:116). `done`
  refuses after the commit exists; the next claim's reconcile marks it done. The
  board re-read (section 5.1) sees the true state, so the loop does not act on
  `done`'s exit code alone.
- **Sandbox vs real-env verify divergence (probe 2, 2026-08-17: CONFIRMED;
  refined by D26).** Codex's `workspace-write` sandbox is
  `[workdir, /tmp, $TMPDIR]`. The sandbox denies WRITES to Go's default
  out-of-workspace build cache (`%LocalAppData%\go-build`), but the denial only
  surfaces when a command must WRITE the cache: a warm-cache `go build` reads
  only and passes exit 0, hiding the problem, whereas `go test` (fresh compile)
  fails with `Go build-cache access denial`. The same commands pass in the
  orchestrator's real shell (verify/verify.go inherits parent env). So a Go
  verify block can diverge: the orchestrator's authoritative `muster verify`
  (real env) passes, while Codex's in-sandbox self-check cannot compile fresh
  code. Correctness is safe because the orchestrator owns the authoritative
  verify (4.2 step 3, section 6.1). But Codex's self-correction loop is blind on
  this Go repo unless fixed.
  Fix (D26, 2026-08-17: VALIDATED in-sandbox): the executor exports `GOCACHE` and
  `GOTMPDIR` at a system-temp-dir path (`$env:TEMP\muster-codex\...`) inside its
  OWN shell, on the same command line as each Go command. Two D26 facts force
  this shape: (a) env set on the `codex exec` parent process does NOT cross into
  the sandbox shell - the executor observed `GOCACHE=""`; (b) sandbox shells do
  not persist env across separate `powershell -Command` calls, so the export must
  ride each Go command line. With that, a cold build wrote 1037 cache files at
  exit 0 with no sandbox error. The system temp dir is in the allow-list
  (`[workdir, /tmp, $TMPDIR]`) AND outside the working tree; an in-repo cache dir
  is untracked and would make `muster done` refuse via the out-of-commit_paths
  check (done.go:51-59, plan-review W2). `GOMODCACHE` is left at default - module
  reads from the outside cache are allowed (only writes outside the sandbox roots
  are blocked), so no network and no module-cache redirect are needed. This
  generalizes: any toolchain with an out-of-workspace WRITE cache (npm, dotnet,
  pip, cargo) needs the same in-shell temp-dir redirect; reads of existing caches
  are fine. Network-needing verify stays claude-pinned and off Codex regardless
  (lint.go:127, a partial denylist - lint.go:23).

## 8. Review tier

Default: review tasks (tier strong) stay a Claude `opus` subagent running the
full RUNNER, exactly as `auto` does today. Review is low-volume (one per impl,
D19), so little arbitrage is available, and keeping the pass/fail verdict inside
a trusted Claude subagent avoids a verdict-relay trust surface.

Opt-in: Codex `gpt-5.6-sol` @ `high` for review. The same actor split applies
(Codex reviews and writes findings notes; the orchestrator runs
`muster done pass|fail`). The orchestrator must then read the verdict from the
notes file to choose the verb - a trust surface absent in the Claude-opus
default. `sol` @ `xhigh` needs owner approval per run; `sol` @ `high` does not.

## 9. Scope

In scope: a new orchestrator-side loop skill (sibling to `auto`, sharing its
close/review logic), the Codex dispatch, the DB fingerprint guard, board-state
routing, the crash-detection halts.

Out of scope: rebuilding the reviewer; git worktrees / parallel executors (D18
KIV); automated new-session spawning (D31 end-state); porting the D32
commit_paths overlap lint; fixing pre-existing MUSTER-core issues surfaced by
the review (probe bypasses donePreconditions, M5; cross-task sidecar
contamination, N1) - flag upstream, do not fix here.

## 10. Adversarial review outcomes

Codex `gpt-5.6-sol` @ high reviewed this design against the source. Verdict:
reject the first cut as specified. Resolutions folded in:

- B1 (Codex can forge the board via raw DB write): corrected the false "cannot
  corrupt however it behaves" claim; added the DB fingerprint (6.2); scoped the
  adversarial case out per D27 (6.3).
- B2 (mid-run crash is not auto-healed): corrected; explicit stale-`doing` halt
  + human `redo` (section 7).
- B3 (reconcile can bless a failed `done`; exit code not durable): board re-read
  is the progress signal, not `done`'s exit code (5.1).
- M1 (orphaned verify splits state): reap the Codex tree before any verb; the
  revised split removes Codex-run `muster verify` (section 7).
- M2 (exit code cannot route): route on board state + message (5.2).
- M3 (sandbox vs real verify divergence): orchestrator runs the authoritative
  `muster verify` in the real env (4.2, section 7).
- M4 ("only done writes .git" too broad): narrowed (section 3).
- M6 (no plan predicate in NextEligible): single-active-plan precondition (5.2).
- M5, N1 (pre-existing MUSTER-core): flagged, out of scope (section 9).
- N2, N3 (wording, stale docs): corrected in section 3; design keys off code.

## 11. Needs testing before trust (D26 gate)

D26 wants ~10 real tasks measured before routing bulk work to a new harness.
One smoke task done.

**D26 dry-run outcome (2026-08-17).** A manual end-to-end triad on a scratch
`probe` plan validated both load-bearing assumptions: (a) a system-temp-dir
`GOCACHE`/`GOTMPDIR` exported in the executor's own shell builds inside Codex's
sandbox (cold build, 1037 cache files, exit 0) - env on the `codex exec` parent
does not cross into the sandbox, so the export must be in-shell; and (b) crash
recovery - killing Codex mid-run leaves the task in `doing` with the board DB
untouched (fingerprint identical before and after the kill), `muster redo` +
re-claim hands the card back without auto-filing, and a fresh dispatch completes
it with one clean `muster(probe): done <id>` commit. Items 1 and 3 carry the
detail.

Load-bearing unknowns, most-risky first:

1. Sandbox-vs-real-env verify parity (M3) - RESOLVED for Go by probe 2 + a
   micro-probe, then VALIDATED end-to-end by D26 (2026-08-17): the sandbox denies
   WRITES to the default out-of-workspace Go cache (surfacing only on a fresh
   compile - `go test`, not a warm `go build`); exporting `GOCACHE`+`GOTMPDIR` at
   a system-temp-dir path INSIDE the executor's own shell, on each Go command
   line, makes a cold build pass exit 0 in-sandbox (1037 cache files written;
   GOMODCACHE left default, reads allowed). Env on the `codex exec` parent does
   not cross into the sandbox, so the export must happen in-shell. Remaining:
   repeat the redirect for any non-Go toolchain a real plan's verify uses.
2. Codex process-tree reaping on Windows (M1) - RESOLVED by probe 2: `codex
   exec` reaped its command children synchronously (zero new survivors).
   Caveat: unrelated codex/node processes linger session-wide from earlier runs
   (source unidentified) - watch during the D26 run; keep the "confirm tree
   dead before done" guard as cheap insurance.
3. Crash recovery end-to-end (B2) - VALIDATED by D26: killing Codex mid-run left
   the task in `doing` with the board DB untouched (fingerprint identical before
   and after the kill); `muster redo` + re-claim did NOT auto-file (marker
   absent) and handed the card back; a fresh dispatch completed it with one clean
   `muster(probe): done <id>` commit.
4. DB fingerprint mechanics under WAL (6.2) - RESOLVED by probe 3 (2026-08-17):
   content digest catches raw writes with no false positives; byte-hash and
   data_version rejected. Remaining: extend the digest to `deps`/`backup.db`.
5. Codex stops cleanly at REPORT under the scoped prompt (exit 0, no attempt at
   a `muster` verb or git). One smoke task showed clean RUNNER compliance;
   confirm under the new contract.
6. Verify pass rate across ~10 tasks (D26's actual number).

## Not yet specified

- Fingerprint mechanism is decided (content digest, section 6.2, probe 3). The
  residual is minor: whether to add the `deps` table and `backup.db` to the
  digest - an implementation choice for the plan, not a fog item.
- Non-Go toolchain caches: the Go redirect (`GOCACHE`+`GOTMPDIR` at a temp-dir
  path, exported in the executor's own shell) is confirmed in-sandbox by D26
  (section 7). The per-toolchain env equivalents (npm/dotnet/pip/cargo) are TBD
  until a real plan's verify needs one.
- Whether to frame the Codex dispatch as a subagent (SUBAGENT-STOP) vs configure
  Codex's AGENTS.md to not fire superpowers for MUSTER runs (section 4.3).
- The precise Codex dispatch prompt text (the scoped contract wording) and how
  the card Steps are inlined vs pointed at when a card exceeds the argument
  length limit.
- Where the new skill lives and its exact name, and how much of `auto`'s loop it
  reuses vs copies.
- The retry-transcript format handed back to Codex on a verify failure.

## Out of scope

- Worktree isolation / parallel Codex executors (D18 KIV - serial only).
- Automated new-session spawning (D31 end-state).
- A read-side app or MCP surfacing the board (v2+).
- Rebuilding or duplicating the review stage.
- Fixing pre-existing MUSTER-core issues (M5, N1) - separate work.
