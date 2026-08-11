---
name: auto
description: MUSTER orchestrator loop. Slash-only (/muster:auto); do not auto-trigger. Dispatches one subagent per task until board settles, then closes plan.
---

# muster:auto - orchestrator loop, one subagent per task

Input: a plan id (kebab-case). Runs from a fresh Claude Code session, cwd = target
repo. This skill dispatches subagents; it never claims or edits task files itself.

**Precondition:** exactly one plan is active on the board (every task file under
`backlog/`, `inbox/`, `doing/`, `staging/` carries this plan id, or those folders
are otherwise empty). `bin/status` counts are board-wide, not plan-scoped
(D13 - concurrent plans are architecturally allowed but this loop does not
disambiguate between them). With two plans live, this skill can dispatch the
other plan's tasks and never see its own plan reach a closeable state. Refuse to
start if the board holds any task file for a different plan id.

## Hard rules

- **Sequential only.** Never dispatch a second subagent before the first fully
  completes (`run_in_background: false`, wait for the result). Two subagents
  claiming in one checkout at once produces chimera commits (D18) - there is no
  worktree isolation here (KIV, see docs/decisions.md).
- **Review/integration always its own subagent call.** Never resume a finished
  subagent's conversation (no `SendMessage` back into it). This is what keeps
  review structurally independent of the implementer that wrote the diff - do
  not weaken it even if it seems safe for a specific task.
- **Never override `-Tier`/`-Harness`.** Each subagent runs the exact wrapper
  command below unmodified.
- **Model per dispatch mode.** Run-mode subagents use Sonnet 5, review-mode
  subagents use Fable 5 - matching spec 8.1's session-model split (D16).
  Dispatching execution work on the strong tier burns the exact quota D16's
  arbitrage exists to protect.

## Loop

1. Run `powershell -ExecutionPolicy Bypass -File tasks/bin/status.ps1`
   (POSIX: `sh tasks/bin/status.sh`). Read the
   `  inbox    <n> ready      (run <n>, review <n>) [<ids>]` and
   `  doing    <n> ...` lines.
2. If `doing <n>` > 0: STOP. A task is claimed but not completed - either a
   subagent crashed mid-task, or something else is occupying the checkout
   (D18). Report it; this is human recovery territory (D12), not something
   this loop retries.
3. If `review <n>` > 0 or `run <n>` > 0: dispatch a subagent for either
   claimable tier (review mode if `review <n>` > 0, else run mode - step 5).
   Which tier goes first when both are nonzero does not matter: this loop is
   strictly sequential and drains to a settled board regardless of order, so
   there is no throughput difference between orderings (an earlier draft
   claimed a review-first benefit citing D19; cut as unearned - D19 governs
   shard-time DAG wiring, not dispatch order. YAGNI audit finding Y5,
   2026-08-10).
4. Else (nothing claimable): check the `backlog` and `failed` lines.
   - `failed <n>` > 0, or a `DEAD` marker on any backlog line: STOP. Report the
     stuck ids exactly as printed. Do not attempt recovery (D12 - human only).
   - Both zero and `done <n>` > 0: the plan is finished. Perform the Close
     steps below directly (no subagent - closing is an orchestrator action, not
     an executor task). Report the archived count. Stop.
   - Otherwise (nothing claimable, nothing stuck, board not empty): STOP and
     report the board as printed - an unexpected state, not a known halt
     condition.

### Step 5: dispatch one subagent

Capture the current `bin/status` output before dispatching. Launch exactly one
Agent-tool call, `subagent_type: general-purpose`, foreground
(`run_in_background: false`), and wait for it to finish before continuing.

Review mode - `model: fable`, prompt:

````
Run `powershell -ExecutionPolicy Bypass -File tasks/bin/claim.ps1 -Harness claude -Tier strong`
(POSIX: sh tasks/bin/claim.sh --harness claude --tier strong), then follow
tasks/RUNNER.md to the letter.
````

Run mode - `model: sonnet`, same call with `-Tier any` / `--tier any` instead of
`-Tier strong` / `--tier strong`.

After the subagent returns, run `bin/status` again and compare it to the
captured pre-dispatch output.

- **Unchanged** (same counts, same ids): STOP. The subagent made no board
  progress - a claim refusal it couldn't recover from (malformed inbox
  frontmatter, a dirty tree outside `commit_paths`, a harness pin mismatch, a
  stale staged fix, or simply nothing eligible for this tier). Report the
  subagent's final message verbatim; this is human recovery territory, not a
  case to retry.
- **Changed:** go back to step 1. Do not otherwise parse or trust anything the
  subagent says about board state - the before/after `bin/status` comparison is
  the only signal this loop acts on.

## Close (performed directly, no subagent)

Mirrors `skills/close/SKILL.md` exactly - inlined here so this loop never
depends on a slash-command-only skill accepting a non-slash-command invocation.

1. Confirm eligibility: zero task files with this plan id in `backlog/`,
   `inbox/`, `doing/`, `staging/`, or `failed/` (check the filesystem directly -
   `bin/status` does not print `staging/`, so do not rely on it alone for this
   check).
2. Create `tasks/archive/<plan-id>/`.
3. `git mv` every `tasks/done/<plan-id>-*` file (task cards and sidecars:
   `.result.md`, `.verify.log`, `.gen*.*` history) into
   `tasks/archive/<plan-id>/`.
4. `git mv tasks/plan-<plan-id>.md tasks/archive/<plan-id>/plan-<plan-id>.md`.
5. One commit, explicit paths, message: `muster(<plan-id>): close`.
6. Report the archived card count.

## Halt conditions (exhaustive)

- Plan closed (success).
- `doing/` occupied at the top of a loop iteration - a crashed or stuck
  subagent, human recovery (D12).
- A dispatch made no board progress - a claim refusal the subagent couldn't
  clear, human recovery (D12).
- Stuck: `failed/` non-empty or a DEAD backlog task - human recovery (D12).
- Unexpected board state - reported, waiting on a human.

No other exit path. In particular, do not add a task-count cap, a turn cap, or
any other early-stop condition not listed here - see the design doc's
"Deliberately excluded" section for why none is needed (D12's promote-gating
already makes runaway-past-a-failure impossible, and the harness auto-compacts
context, so no manual budget cap is load-bearing).
