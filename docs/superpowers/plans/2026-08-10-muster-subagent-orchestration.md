# Subagent-Orchestrated Dispatch (muster:auto) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. **Task 6 is human-only** — do not dispatch a subagent for it; it requires opening real Claude Code sessions with the model picker, which no file-editing subagent can do.

**Goal:** Add a `muster:auto` skill that loops dispatching one Claude-Code Agent-tool
subagent per claimable task (run or review) until a plan's board is settled, then
closes it — removing the human from between-task dispatch while keeping every
fresh-context and review-independence guarantee v1 already relies on.

**Architecture:** One new prose skill file (`skills/auto/SKILL.md`) that an
orchestrator session follows: read `bin/status`, dispatch exactly one subagent
(either claimable tier — ordering doesn't affect final state in a strictly
sequential drain-to-settled loop), wait for it to finish, repeat; halt on a
stuck board or run `/muster:close` when done. No `bin/` script changes —
this is a pure orchestration layer on top of existing D17 mechanics. Remaining
tasks are documentation updates (manifest, architecture.md, spec section 8,
README) so the new skill is discoverable and the docs stop describing v1 as
manual-dispatch-only.

**Tech Stack:** Claude Code plugin skill (Markdown + YAML frontmatter), no new
code. Verified by a live dogfooding run, not a unit test suite (see design doc
Testing section — no `bin/` script changed, nothing new to unit-test).

**Spec:** [docs/superpowers/specs/2026-08-10-muster-subagent-orchestration-design.md](../specs/2026-08-10-muster-subagent-orchestration-design.md)

---

## Task 1: Write the `muster:auto` skill

**Files:**
- Create: `skills/auto/SKILL.md`

- [ ] **Step 1: Write the skill file**

`````markdown
---
name: auto
description: MUSTER orchestrator-loop entry point. Invoked ONLY by the explicit /muster:auto slash command typed as the first message of a fresh orchestrator session. Dispatches one Agent-tool subagent per task (run or review) until the board is settled, then closes the plan. Never auto-trigger from conversational mention of dispatch, automation, or running tasks.
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
`````

- [ ] **Step 2: Verify the file parses as valid frontmatter + Markdown**

Run: `powershell -Command "(Get-Content skills/auto/SKILL.md -Raw) -match '(?s)^---\r?\n(.*?)\r?\n---'"`
Expected: `True`

- [ ] **Step 3: Commit**

```bash
git add skills/auto/SKILL.md
git commit -m "feat: add muster:auto orchestrator-loop skill"
```

---

## Task 2: Register the skill in both manifests

**Files:**
- Modify: `.claude-plugin/plugin.json:4`
- Modify: `.claude-plugin/marketplace.json:12`

- [ ] **Step 1: Update `plugin.json`'s description**

Change line 4 from:
```json
  "description": "Delegate-and-forget task board: shard approved plans into small verified tasks executed by fresh sessions. Skills: init, shard, run, review, close."
```
to:
```json
  "description": "Delegate-and-forget task board: shard approved plans into small verified tasks executed by fresh sessions. Skills: init, shard, run, review, close, auto."
```

- [ ] **Step 2: Update `marketplace.json`'s plugin description**

Change line 12 from:
```json
      "description": "Delegate-and-forget task board: shard approved plans into small verified tasks executed by fresh sessions. Skills: init, shard, run, review, close.",
```
to:
```json
      "description": "Delegate-and-forget task board: shard approved plans into small verified tasks executed by fresh sessions. Skills: init, shard, run, review, close, auto.",
```

- [ ] **Step 3: Verify both files still parse as valid JSON**

Run: `powershell -Command "Get-Content .claude-plugin/plugin.json -Raw | ConvertFrom-Json | Out-Null; Get-Content .claude-plugin/marketplace.json -Raw | ConvertFrom-Json | Out-Null; 'OK'"`
Expected: `OK`

- [ ] **Step 4: Commit**

```bash
git add .claude-plugin/plugin.json .claude-plugin/marketplace.json
git commit -m "docs: list muster:auto in plugin manifests"
```

---

## Task 3: Document the skill in architecture.md and decisions.md

**Files:**
- Modify: `docs/architecture.md` (Plugin section, currently lines 91-101; Open
  items section, currently lines 113-124)
- Modify: `docs/decisions.md` (add D31; KIV section, currently lines 262-269;
  Rejected section, currently lines 250-260)

- [ ] **Step 1: Add one bullet after the existing `muster:close` bullet**

In the `## Plugin (orchestrator side, Claude Code)` section, after the line:
```
- `muster:close` - archive a finished plan.
```
add:
```
- `muster:auto` - orchestrator loop: dispatches one Agent-tool subagent per
  claimable task until the board settles, then performs `muster:close`'s own
  steps. Strictly sequential (D18) - no worktree
  isolation, so never two subagents at once in one checkout. Review/integration
  subagents are always a fresh, separate dispatch - never a resumed conversation
  - keeping review structurally independent of the diff it grades. See D31 and
  the [subagent-orchestration design](superpowers/specs/2026-08-10-muster-subagent-orchestration-design.md).
```

- [ ] **Step 2: Resolve the stale "Drain mode" open item**

In the `## Open items (undesigned, on purpose)` section, remove this bullet:
```
- Drain mode: may an executor claim another task in the same session while context is low? (Dilutes fresh-context guarantee - undecided.)
```
and add it to the "Settled since this list was first written, and where"
list at the bottom of the same section:
```
- Drain mode (in-session task draining) - rejected in favor of subagent-per-task
  dispatch; D31, [subagent-orchestration design](superpowers/specs/2026-08-10-muster-subagent-orchestration-design.md).
```

- [ ] **Step 3: Add D31 to decisions.md**

After D30, before the `## Rejected` heading, add:
```
## D31. Subagent-orchestrated dispatch (muster:auto)

A new orchestrator-side skill, `muster:auto`, loops dispatching one Claude-Code
Agent-tool subagent per claimable task (strictly sequential, one checkout,
D18) until a plan's board settles, then performs `muster:close`'s steps
itself. Each dispatch is a genuinely fresh subagent - zero parent context - so
the fresh-context guarantee (D1) holds exactly as it does for a human-opened
session; review/integration tasks are always their own separate subagent
call, never a resumed conversation, keeping review structurally independent
of the diff it grades. Run-tier subagents are dispatched on Sonnet 5,
review-tier on Fable 5 - preserving the quota-arbitrage economics (D16)
rather than burning strong-tier quota on execution.
Why: manual per-task dispatch (D1's v1 baseline) was pure human
window-management with zero judgment content once a status block already
says what to type next (board-visibility feature, 2026-08-08). Draining
multiple tasks into one orchestrating session's own context ("drain mode")
was considered and rejected: it dilutes D1's fresh-context guarantee and
makes review self-review if the same context that wrote a diff also grades
it. Subagent dispatch avoids both, because the subagent - not the
orchestrator's own context - does the work, and needs none of D16's
CLI-harness gate, since it is an intra-session primitive, not headless app
dispatch.
Source: brainstorm session 2026-08-10 (subagent-orchestration design +
plan-reviewer pass).
```

- [ ] **Step 4: Remove the now-resolved "Drain mode" KIV line and record it as rejected**

In the `## KIV (revisit later, do not delete)` section, remove:
```
- Drain mode: executor claims another task in the same session while context is low - dilutes fresh-context guarantee, undecided.
```

In the `## Rejected (do not reopen without new facts)` section, add:
```
- **Drain mode (in-session task draining)** - dilutes the fresh-context
  guarantee and makes review self-review; superseded by subagent-per-task
  dispatch (D31).
```

- [ ] **Step 5: Commit**

```bash
git add docs/architecture.md docs/decisions.md
git commit -m "docs: describe muster:auto in architecture.md, add D31, resolve drain-mode KIV"
```

---

## Task 4: Amend spec section 8 (dispatch UX)

**Files:**
- Modify: `docs/superpowers/specs/2026-08-07-muster-v1.md` (section 8, currently lines 714-753)

- [ ] **Step 1: Add a third dispatch line to 8.1**

After:
```
- Review session - model picker: **Fable 5**, then type `/muster:review`
```
add:
```
- Orchestrator loop - model picker: **Fable 5**, then type `/muster:auto`. Give
  it a plan id; it dispatches one Agent-tool subagent per task until the board
  settles, then closes the plan itself. See
  [subagent-orchestration design](2026-08-10-muster-subagent-orchestration-design.md)
  for the full loop and halt conditions.
```

- [ ] **Step 2: Add the wrapper text to 8.2**

After the Codex wrapper paragraph (the one ending "same text with `-Harness codex`."),
add:
```

`/muster:auto` is not a thin wrapper like the three above - it is an
orchestrator loop with its own hard rules (sequential dispatch only, review
always a fresh subagent call). Full text: `skills/auto/SKILL.md`.
```

- [ ] **Step 3: Commit**

```bash
git add "docs/superpowers/specs/2026-08-07-muster-v1.md"
git commit -m "docs: amend spec section 8 for muster:auto"
```

---

## Task 5: Update README.md and docs/problem.md

**Files:**
- Modify: `README.md` (Usage section ~line 89-101, repo layout ~line 139, Status section ~line 161)
- Modify: `docs/problem.md:47`

- [ ] **Step 1: Add a `/muster:auto` bullet to Usage, after the `/muster:shard` bullet and before `/muster:run`**

Insert:
```
- `/muster:auto` (orchestrator, after shard) - loops dispatching one Agent-tool
  subagent per task (`/muster:run` or `/muster:review` under the hood) until the
  board is settled, then closes the plan. Strictly sequential; halts and reports
  if a task fails or the board reaches an unexpected state. The three commands
  below remain available for manual, one-task-at-a-time dispatch.
```

- [ ] **Step 2: Update the repo layout skill count**

Change:
```
skills/           the five slash commands (init, shard, run, review, close)
```
to:
```
skills/           the six slash commands (init, shard, run, review, close, auto)
```

- [ ] **Step 3: Replace the stale "no automated session spawning" limitation line**

Change:
```
- No automated session spawning; dispatch is one human-typed line per session.
```
to:
```
- `/muster:auto` runs the dispatch loop as Agent-tool subagents inside one
  session, strictly sequential (D18); `/muster:run`/`/muster:review` remain for
  manual, one-task-at-a-time control.
```

- [ ] **Step 4: Clarify the related non-goal in docs/problem.md**

Change (`docs/problem.md:47`):
```
- No automated session spawning (blocked by the apps-only constraint; KIV).
```
to:
```
- No automated *session* (new app-instance) spawning - still blocked by the
  apps-only, no-headless-mode constraint above. `/muster:auto` automates the
  dispatch *loop* via same-session Agent-tool subagents instead - a different
  mechanism, not blocked by this constraint (see D31).
```

- [ ] **Step 5: Commit**

```bash
git add README.md docs/problem.md
git commit -m "docs: document muster:auto in README, clarify problem.md non-goal"
```

---

## Task 6: Dogfood verification (human-only, not subagent-dispatchable)

**Files:** none (verification only)

This task requires opening real Claude Code sessions and picking a model in the
UI — no file-editing subagent can perform it. Run it yourself; do not dispatch
this task to `subagent-driven-development`.

- [ ] **Step 1: Shard a small multi-task test plan**

In any disposable git repo already `muster:init`-ed (or a scratch repo you
`git init` for this), write a tiny plan with at least: one impl task WITH an
opt-in review task, and a second, separate impl task with no review. Let shard
add its mandatory terminal integration task. Approve and `/muster:shard` it.

- [ ] **Step 2: Run `bin/status` and confirm the split**

```
powershell -ExecutionPolicy Bypass -File tasks/bin/status.ps1
```
Expected, matching the literal format in `runtime/bin/_lib.ps1` /
spec 8.3 (not a paraphrase):
```
  inbox    2 ready      (run 2, review 0) [<plan-id>-01-*, <plan-id>-02-*]
```
The review and integration tasks are still in `backlog/`, blocked on their
`depends_on`.

- [ ] **Step 3: Open a fresh Claude Code session in that repo, pick Fable 5, type `/muster:auto <plan-id>`**

Watch it dispatch subagents one at a time. Confirm:
- It never dispatches a second subagent before the first's Agent-tool call
  returns.
- Run-mode subagents run on Sonnet 5 and review-mode subagents run on Fable 5
  (the model pinning from Task 1's Hard rules).
- The review/integration subagent calls are visibly fresh dispatches (no shared
  context with the impl subagent that wrote the diff).
- It runs `muster:close`'s steps itself at the end and reports an archived
  count, without dispatching a subagent for that step.

- [ ] **Step 4: Inject a failure and confirm the halt**

Shard a second tiny plan containing one impl task whose verify command is
guaranteed to fail (e.g. `expect_exit: 1` against a command that exits 0, or
vice versa) so it exhausts 3 attempts and lands in `failed/`. Run
`/muster:auto <plan-id>` again.

Expected: after the subagent reports the task failed, the next `bin/status`
read shows `failed 1`; `muster:auto` stops on the next loop iteration and
reports the stuck id — it does not attempt recovery, retry, or continue past
it.

- [ ] **Step 5: Record the result**

Note in your own working notes (not a repo file) whether all four expectations
in Steps 3-4 held. If any did not, that is a design or skill-text bug to fix
before trusting `/muster:auto` on real work — do not silently adjust
expectations to match observed behavior.

---

## Self-review notes

- **Spec coverage:** loop algorithm (Task 1), sequential-only + review-isolation
  + model-pinning hard rules (Task 1), halt conditions incl. close and
  stuck-board (Task 1), manifest registration (Task 2), architecture/decisions/
  spec/README/problem.md doc amendments (Tasks 3-5), live-run verification in
  place of unit tests per the design doc's Testing section (Task 6). No spec
  section without a task.
- **Placeholder scan:** no TBD/TODO; every step carries literal file content or
  an exact command with expected output.
- **Type/name consistency:** skill name `auto` matches `/muster:auto` throughout
  (manifests, architecture.md, spec, README, the skill file's own frontmatter
  `name: auto`). `-Tier any`/`-Tier strong` and the `run`/`review` status-line
  labels are used identically in Task 1's skill text and Task 6's verification
  steps - no drift between what the skill says and what verification checks.
- **plan-reviewer pass (2026-08-10, opus):** 2 blockers, 7 warnings, 2
  suggestions, all ACCEPTed and applied inline (see sidecar
  `2026-08-10-muster-subagent-orchestration.md.review.md`). Highlights: added a
  no-progress halt so a claim refusal can't spin the loop forever (B1); pinned
  Sonnet/Fable per dispatch mode so execution doesn't burn strong-tier quota
  (B2); fixed a nested-fence bug in Task 1's own code block (W2); inlined
  `muster:close`'s steps instead of pointing at a slash-command-only skill
  (W3).
- **YAGNI audit (2026-08-10, opus):** SOFT tier, 1 finding, ACCEPTed (see
  sidecar `2026-08-10-muster-subagent-orchestration.md.yagni.md`). Y5: the
  review-first dispatch priority claimed a throughput benefit ("clears the DAG
  faster") that doesn't hold in a strictly sequential drain-to-settled loop -
  total dispatch count and wall-clock are order-invariant regardless. Cut from
  the loop (now "dispatch whichever tier is claimable"), from the design doc,
  and from architecture.md's Task-3 bullet. This also reverted the
  plan-reviewer's W7 fixture-ordering constraint in Task 6 - it existed only to
  test a priority rule that no longer exists, so the fixture is back to plain
  "one impl with review, one without."

## Not yet specified

None — the way is clear. (An earlier draft left "what if a subagent's Agent-tool
call itself errors out, distinct from completing and reporting a task failure"
unspecified. The plan-reviewer pass's B1 finding forced a general no-progress
halt — Task 1's before/after `bin/status` comparison — that covers this too: a
tool-use error or a mid-dispatch crash leaves the board unchanged just like a
claim refusal does, so it hits the same halt without special-casing.)

## Out of scope

- Worktree-per-subagent concurrency - named in the design doc's "Deliberately
  excluded" section; needs its own spec, merge-back protocol, and adversarial
  review before it's safe to build (D21 branch-scope wall, D28/D20 linear-
  history assumptions).
- True multi-plan-aware dispatch (filtering claimable tasks by plan id
  mid-loop) - `bin/status`/`claim` are board-wide, not plan-scoped (D13 allows
  concurrent plans architecturally, this loop doesn't disambiguate). Handled
  instead by a hard precondition in the skill: refuse to start if the board
  holds another plan's tasks. Revisit only if concurrent-plan dogfooding
  actually happens.
- Any `bin/` script change - this plan is a pure orchestration layer; D17's
  mechanics are reused unmodified.
- A context-budget cap on the orchestrator loop - the design doc's rationale
  (harness auto-compaction, lighter growth than draining) stands until a real
  long dogfooding run shows otherwise.
