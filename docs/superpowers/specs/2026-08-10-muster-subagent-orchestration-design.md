# Subagent-Orchestrated Dispatch Design

**Date:** 2026-08-10
**Status:** approved (brainstorm session)
**Amends:** docs/architecture.md ("Discovery and dispatch", "Plugin" sections),
docs/superpowers/specs/2026-08-07-muster-v1.md section 8 (dispatch UX)

## Problem

v1 dispatch is entirely manual: a human opens a fresh Claude Code session per task,
types `/muster:run` or `/muster:review`, waits for the session to finish, reads its
final output, closes it, opens another fresh session, repeats — all the way to
`/muster:close`. For a plan with a dozen-plus tasks this is a lot of human
window-management for zero judgment content; the human isn't deciding anything
between dispatches, just re-typing the same two commands based on what the status
block already told them (board-visibility design, 2026-08-08).

Confirmed via a full manual run on a real repo (graticule / geometry-ops-mini,
muster-test branch, 2026-08-09 dogfooding session): the pipeline itself is sound,
but hand-dispatching every task is the friction actually felt.

## Decision

One new orchestrator-side skill, `muster:auto`, invoked as the first message of a
fresh Claude Code session (same convention as `run`/`review`/`close`). It plays the
ORCHESTRATOR role from architecture.md's own diagram continuously instead of a human
gluing orchestrator and executor together by hand across window launches: it loops,
dispatching one Agent-tool subagent per task, until the board is settled.

### Why subagent dispatch, not in-session draining

An earlier version of this idea considered having the orchestrating session execute
tasks directly in its own context, one after another ("drain mode" — already flagged
as an undecided KIV in decisions.md). That was rejected: it dilutes the fresh-context
guarantee that is D1's core driver (context rot is the exact failure MUSTER exists to
kill), and it makes review self-review if the same context that wrote a diff then
grades it.

Dispatching a Claude Code Agent-tool subagent per task avoids both problems:

- Each subagent starts with **zero parent history** — the same fresh-context
  guarantee as a human-opened session, not a capped/diluted version of it.
- A review or integration task is **always its own separate subagent call**, never a
  resumption of the impl subagent's conversation. Self-review is structurally
  impossible, not merely discouraged.
- No bin/ script changes. `claim`/`verify`/`done` have no concept of "session" —
  they only check tier pinning and git state (`claim.ps1` line ~48). Subagent
  dispatch is a pure orchestration layer on top of D17's existing mechanics.
- Does not touch D16. D16's "manual dispatch is the ceiling until a CLI harness
  exists" is about headless dispatch of new **app processes**. Agent-tool subagents
  are an intra-session primitive native to Claude Code today — a different
  mechanism, not the one D16 gates.

### Loop algorithm

1. Run `bin/status` (or `promote` then read the board) to find the next claimable
   task. When both a `tier: any` and a `tier: strong` task are claimable at once,
   either may be dispatched — the loop is strictly sequential and drains to a
   settled board regardless of order, so no ordering preference changes the
   total dispatch count or the final state. (An earlier draft of this design
   preferred `tier: strong` first, reasoning that review/integration gates the
   DAG (D19) and clearing it sooner "unblocks the most downstream work per
   dispatch" — cut during planning as an unearned complexity: D19 governs
   shard-time DAG wiring, not dispatch order, and a sequential drain-to-settled
   loop gets no throughput benefit from either ordering. Source: YAGNI audit,
   finding Y5, 2026-08-10.)
2. Nothing claimable, board empty except `done/`: run `muster:close <plan-id>`
   inline (same steps as the existing close skill), report the archived count, stop.
3. Nothing claimable, board NOT empty (something sits in `backlog/` behind a
   `failed/` dependency, or `failed/` itself is non-empty): stop and report what's
   stuck. This requires no new logic — `promote` already refuses to release a task
   whose dependency is in `failed/` (D12), so the loop naturally stalls at exactly
   the point a human needs to look. Never attempt automatic recovery.
4. Otherwise, dispatch exactly ONE `Agent()` call for the next claimable task:
   - `tier: any` task (impl/fix) → subagent instructed to run `/muster:run`'s
     command (`claim.ps1 -Harness claude -Tier any`) then follow
     `tasks/RUNNER.md`.
   - `tier: strong` task (review/integration) → subagent instructed to run
     `/muster:review`'s command (`-Tier strong`) then follow `tasks/RUNNER.md`.
   - `run_in_background: false` — the orchestrator waits for full completion
     before touching the board again.
5. Read the subagent's final report, go to step 1.

### Sequential dispatch is a hard rule (D18)

The orchestrator MUST NOT dispatch a second subagent before the first fully
completes, in the same checkout. Claim atomicity protects the task file, not the
working tree (D18) — two subagents running concurrently in one checkout produce
chimera commits, same failure mode D18 already names. This rule lives in the
`muster:auto` skill's own instructions; nothing in the scripts enforces it (same as
today — D18 is a protocol rule, not a lock file).

### What `muster:auto` does NOT do

- Never claims or edits task files itself — it only dispatches subagents that do,
  identical to what a human-run `/muster:run` session does.
- Never resumes a completed subagent's conversation (no `SendMessage` back into a
  finished agent) — this is the mechanism that keeps review structurally isolated.
- Never overrides `-Tier`/`-Harness` — pinning stays exactly as declared by the two
  existing wrapper skills' commands.

## Deliberately excluded

- **Worktree-per-subagent concurrency.** Would let independent claimable tasks
  dispatch in parallel, resolving the D18 KIV ("git worktree per executor for true
  concurrency"). Rejected for this round:
  - Needs a merge-back step MUSTER has never designed for. D21 scopes all
    task-state transitions to one branch (main) in v1; feature-branch/merge flows
    are explicitly out of scope until v2.
  - D28's attempt-marker counting (`git rev-list --count claimCommit..HEAD`
    grepping an exact commit message) and D20's protected-file diffing both assume
    linear single-branch history. Non-linear history from a merged worktree would
    need both re-verified, at minimum, under the same adversarial-review bar D28
    itself went through.
  - A merge conflict between two worktrees is a judgment call, not a mechanical
    one — contradicts D9 (all judgment happens at shard time, execution stays
    mechanical).
  - No measured need yet: nobody has run subagent dispatch even once. Building
    concurrent+merge machinery for an unmeasured workload is the premature
    optimization YAGNI exists to catch.
  Left as a named future item, same status as the existing D18 KIV line — not
  designed away, just not this round.
- **Any change to `bin/` scripts, RUNNER.md, or task templates.** This design is
  purely a new orchestration skill; D17's mechanics are reused unmodified.
- **Context-budget cap on the orchestrator loop.** The orchestrator's own context
  grows only from subagent result summaries and status checks (not from each
  subagent's tool calls or exploration), and the harness already auto-compacts a
  session's context as it approaches the limit. No manual cap is load-bearing for
  a first cut; revisit only if a real long plan shows it's a problem.

## Costs (accepted)

- One new plugin skill (`muster:auto`) alongside init/shard/run/review/close —
  manifest entry, anti-trigger prose (same pattern as the other four).
- Spec section 8 (dispatch UX) gains a fourth dispatch mode description.
- architecture.md's "Plugin" section gains one bullet.
- No test suite changes to `bin/` scripts (none are touched). The new skill's
  correctness is behavioral (does it dispatch in the right order, does it stop at
  the right points) rather than unit-testable the way script logic is — verified
  by a real dogfooding run, not a Pester suite.

## Error handling

- Subagent crashes or is killed mid-task: identical to a human-closed session
  today — the task sits in `doing/`, next `bin/status`-driven check (whether from
  a re-run of `muster:auto` or a human) shows it STALE, recovery stays manual
  (D12). `muster:auto` does not attempt reclaim.
- Subagent's verify exhausts 3 attempts → task moves to `failed/` by the verify
  script itself (existing behavior). The loop's step 3 catches this on the next
  iteration and halts, reporting the failed id(s).
- Review generation 3 → `failed/` for the human (existing D11 cap). Same halt
  path as above.
- `muster:close` eligibility check fails (something unexpectedly present outside
  `done/`) → report and stop rather than force, matching the existing close
  skill's own refusal behavior.

## Testing

- No new unit tests (no script code changes). Verification is a live dogfooding
  run: shard a small multi-task plan, invoke `muster:auto` in a fresh session,
  confirm it dispatches impl → review → integration in the right order, one
  subagent at a time, and stops cleanly at `muster:close`.
- Deliberately inject one failing verify (bad task) in a follow-up dogfood run to
  confirm the loop halts at step 3 instead of spinning or skipping past it.
