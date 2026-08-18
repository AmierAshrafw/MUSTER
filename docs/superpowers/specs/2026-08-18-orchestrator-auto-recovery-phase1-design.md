# Orchestrator auto-recovery — Phase 1 design

**Date:** 2026-08-18
**Status:** approved (design), ready for implementation planning
**Scope:** the `muster` CLI completion path + the `muster:auto-codex` orchestrator skill.

## Problem

The `muster:auto` / `muster:auto-codex` loops are meant to run hands-off until the
board settles, halting only for a human on genuine trouble. In practice they halt on a
broad, deliberately-blanket set of conditions (decision **D12**), including cases that
are deterministic, safe, and non-destructive — so the human is pulled in for blockers
that never needed one.

Triggering incident: a task stuck in `doing` after a clean `VERIFY PASS`. `muster done`
stages its own artifact `.muster/cards/<id>.verify.log` with a plain `git add --`
(no `-f`); a containing repo's `.gitignore` carried a blanket `*.log`; git refused the
ignored path; `done` refused; the orchestrator halted. Root cause is a tool invariant
violation, not a task error.

## Constraint that stays intact — D12 / D18 / D20 / D21 / D28

`docs/decisions.md:80` (D12): *"auto-reclaim's failure mode is two executors
interleaving work on a dirty tree — corrupting. Manual recovery's failure mode is
delay — boring. Choose the design whose failure is boring."*

The corrupting failure modes stay human-only: blind reclaim, orchestrator-authored
`git checkout` / `restore` / `clean` / `reset`, DB writes by a sandboxed executor,
auto-`redo` (erases the attempt cap), and finalizing a task under a possibly-live
executor without an exclusive-ownership lease. Phase 1 does **not** weaken D12, D18
(one executor per checkout), D20 (verify/protected-path integrity), D21 (explicit
paths, one completion commit), or D28 (attempt burns before a command runs). It fixes
two confirmed latent bugs whose fixes sit entirely inside those boundaries.

## Design decision: prevention + one bug correction, not a recovery engine

Three independent reviews (a solution-auditor pass, a Codex `gpt-5.6-sol` xhigh pass,
and a Codex `gpt-5.6-sol` high adversarial pass) converged: **fix the tool at source
and correct the fingerprint bug**; do not build a general MAPE-K / reason-code recovery
subsystem for what is presently a one-flag root cause. The adversarial pass further
showed that the two originally-proposed recovery features (an auto-invoked `muster heal`
and a spawn→`install-required` reclassification) cannot be made safe within Phase 1's
constraints; both are deferred to Phase 2 with named prerequisites.

Safety axis for any auto action: **narrowly scoped · idempotent · non-lossy · backed by
authoritative evidence · under exclusive ownership · mechanically post-checked.** The two
Phase 1 items satisfy it; the deferred items do not, without new machinery.

## Phase 1 work items

### 1. `done` force-adds MUSTER-owned artifacts only (exact paths)

`completePass` (`internal/cli/done.go:74-95`) builds one path list mixing MUSTER's own
sidecars (`<id>.result.md`, `<id>.notes.md`, `<id>.verify.log`, and any gen-history /
tool-generated fix card) with the task's `commit_paths`, then passes the whole list to
`Repo.Add` (`internal/gitx/gitx.go:117`), which runs plain `git add --` (no `-f`). A
containing repo's `.gitignore` can therefore make a mandatory MUSTER artifact
uncommittable and refuse `done`.

Change:
- Add a force variant to `gitx` (e.g. `AddForce(paths)` → `git -c core.autocrlf=false
  add -f --`).
- In `completePass`, split staging: **force-add the exact, internally-constructed list
  of MUSTER-owned `.muster/cards/*` artifact paths**; **plain-add `commit_paths`
  unchanged**. Force only the exact paths the command already assembles — never a glob,
  prefix, or `-A` (D21: explicit paths only). An ignored *application* path in
  `commit_paths` may be deliberate repo policy; the tool must not override the user's
  intent for their own files.
- Apply the same split to the other completion paths that stage MUSTER artifacts:
  terminal-fail and review-reject (`internal/cli/donefail.go`). `probe()`'s auto-file
  routes through the same `completePass`, so it is covered by this one change.

Effect: prevention at source — the reported class cannot recur in any containing repo.

Non-goals / notes:
- Do **not** teach any orchestrator to edit `.gitignore` as recovery — that is a
  workaround against the repository and can change file visibility beyond the task.
- Not urgent for *this* repo: its `.gitignore` no longer contains `*.log` at all
  (`git check-ignore` on a `.muster/cards/*.verify.log` returns "not ignored"). This is
  a latent robustness fix for the tool, valid for every other repo.

### 2. Fingerprint: tight per-dispatch bracket (corrected)

Confirmed latent bug. `Fingerprint()` (`internal/store/fingerprint.go:49-60`) hashes the
event chain (`E|count|max|hash`). `muster verify` appends an `attempt` event **before
every run** (`internal/cli/verify.go:68`). The `auto-codex` triad captures `FP_CLAIM`
once at claim and re-checks each retry against it; after the first failed verify, the
orchestrator's own legit attempt event makes the fingerprint differ from `FP_CLAIM`,
which the loop reads as a Codex board-integrity breach and halts falsely.

The naive fix (re-snapshot the baseline after each verify) is **unsafe**: re-snapshotting
after verify would absorb a genuine tampering write — including one from a delayed Codex
descendant that writes *during* verify — into the new baseline, converting a false
positive into a false negative.

Correct change (skill prose only, no Go change):
- Bracket **each Codex dispatch tightly**: capture the fingerprint baseline immediately
  **before** the `codex exec` dispatch and check it immediately **after** Codex returns,
  **before** running `muster verify`. Compare against *that bracket's* baseline, not a
  long-lived `FP_CLAIM`. The legitimate `attempt` event then always lands *outside* every
  bracket (it is written by the orchestrator's own `verify`, after the post-dispatch
  check).
- Keep the guard strict: any mismatch *inside* a bracket is still a hard breach, never
  "explained away".
- **Load-bearing assumption to enforce:** the Codex process **tree** is dead when the
  post-dispatch fingerprint is captured. Foreground wait guarantees the direct child has
  exited but not orphaned grandchildren; the implementation must ensure no live Codex
  descendant can write between the post-dispatch check and it. If the runner cannot
  guarantee process-tree death, fall back to validating the *exact expected delta* (zero
  DB change across the bracket) rather than a plain snapshot compare.

Pre-existing weakness (noted, out of scope for this change): `Fingerprint()` omits many
task columns and hashes only event/verdict *counts* + the event tip, so some tampering
classes are already invisible to it. Not relied upon by this change; a candidate for a
separate hardening task.

## Deferred to Phase 2 (with prerequisites) — not built now

### D1. Auto-invoked healer before the `doing` halt

Rejected for Phase 1 by the adversarial review, verified against source. The claim-time
`reconcile()` (`internal/cli/claim.go:50-70`) is unsafe to auto-invoke:
- No ancestry check: it greps `head_at_claim..HEAD` (reachable-from-HEAD, not a
  descendant range); real `done` enforces `IsAncestor` (`done.go:176-185`). A commit on
  rewritten history can heal a row.
- Message-grammar match is not authoritative evidence: `MarkDone` validates no claimant,
  no result sidecar, no verify transcript, no protected-path (D20), no commit scope
  (D21). Any `muster(<plan>): done <id>` commit false-heals.
- Live-executor race: `completePass` commits at `done.go:98`, then runs
  hook-restage/amend (`done.go:101-121`), then marks done at `done.go:123`. A second
  orchestrator healing on the visible commit while the original executor is still alive
  violates D18/D12; if the original then refuses at `done.go:116`, the row is already
  falsely done.
- `reconcile()` cannot fail-closed (silently ignores query/LogGrep/MarkDone/promote
  errors and iterates all `doing` rows).
- (Note: `internal/store/reconcile.go` is a *different*, destructive abandoned-ingest
  tombstone verb — not this healer. Do not conflate them.)

**Prerequisite before Phase 2 can ship this:** an exclusive-ownership lease/fence tied to
executor lifecycle (Phase 3 material), plus a hardened evidence-checked reconcile
(single-`doing` guard, `IsAncestor` ancestry, candidate-commit tree/diff validation
against expected sidecars + `commit_paths`, protected/scope re-check, structured
fail-closed errors). Until then, an occupied `doing` remains a human stop — age is not
proof of death (D12).

Little is lost by deferring: item 1 *prevents* the reported stuck-`doing`; the residual
"completion commit landed but the DB flip crashed" case is exactly D12's careful zone.

### D2. Spawn-failure classified as `install-required`

Rejected for Phase 1, verified against source. The verify runner spawns argv directly,
no shell (`internal/verify/verify.go:1-5,83-97`): a missing *bare top-level* executable is
a clean non-`ExitError` (`SpawnErr`), but shell-wrapped commands (`cmd /c missing-tool`),
package-manager failures (inside a spawned `go`/`dotnet`/`npm`), and task-built *relative*
executables all spawn successfully and fail via exit code — so "spawn error =
install-required" only cleanly covers the bare-exe case. Also, the attempt event burns at
`verify.go:68` **before** the runner, so the classification arrives too late to spare the
attempt without a pre-burn preflight (D28 conflict).

**Prerequisite before Phase 2 can ship this:** a pre-burn `exec.LookPath` preflight scoped
to bare-name top-level tools (path-separator tokens and shell wrappers excluded, to avoid
letting a task dodge its verify by not producing a relative artifact); a stable
machine-readable exit signal (a minimal reason-code contract); and coordinated updates to
**both** orchestrator skills, the `internal/cli/templates/RUNNER.md` template, and a
migration note for already-installed `.muster/RUNNER.md` files (whose fix-and-retry
instructions would otherwise loop on a terminal environment error). Windows + POSIX runner
tests (the current suite skips non-Windows: `internal/verify/verify_test.go:23-27`).

## Delivery + bootstrap

- **Binary bootstrap trap:** item 1 edits `done.go`, but the *installed* `muster` binary
  is what runs `done`. The fix is inert until the binary is rebuilt and installed
  (`go build -o muster.exe ./cmd/muster`). Item 1 therefore cannot be validated by routing
  it through the MUSTER board — the board would complete the item-1 task with the *old*
  plain-`git add` binary. Build+install the new binary first (off-board), then verify.
- Item 2 is skill-prose only — no rebuild.
- A short dev branch for the code change is fine: `architecture.md`'s "all board
  transitions on main; feature-branch workflows out of scope" governs **board
  transitions**, not ordinary tool-source development. No board routing for Phase 1.

## Testing intent

- **Item 1:** unit tests that `done` (and terminal-fail / review-reject) commit **each**
  MUSTER artifact type separately — result, notes, live verify.log, a generated fix card,
  and each gen-history file — even when the repo `.gitignore` ignores them (e.g. a `*.log`
  rule); AND that a gitignored `commit_paths` entry is still refused (user-file intent
  preserved). A process-level smoke reproducing the original stuck-`doing` scenario and
  showing `done` now lands. The force list must be asserted to be the exact artifact set,
  not a glob.
- **Item 2:** a claim → dispatch → failed verify → retry sequence does **not** read the
  orchestrator's own attempt event as a fingerprint breach; a genuine DB write *inside* a
  dispatch bracket still trips the guard; and (if the delta-validation fallback is used) a
  mutation to any DB state across a bracket other than the expected zero-change trips it.
  Because item 2 is skill prose, the test is an orchestration-sequence harness, not a Go
  unit test.

## Deliberately excluded

- **General MAPE-K recovery engine / new recovery module** — over-engineered for a
  one-flag root cause; adds more privileged state and failure modes than it removes.
- **Recovery logic as freeform LLM commands in skill prose** — parsing mutable English
  error text is not deterministic and duplicates across Claude + Codex; orchestrator-
  authored git mutations are exactly what D12 forbids.
- **Orchestrator editing `.gitignore` / any `git checkout`/`restore`/`clean`/`reset`** —
  workaround against the repo; can alter file visibility beyond the task.
- **Auto-`redo` of a failed/terminal task** — erases the attempt cap's meaning.
- **Stable CLI reason codes + skill-side policy table + circuit breakers + orchestrator-
  owned-verb convergence + claim fencing/lease** — Phase 2/3, only when a deferred item's
  prerequisites are designed.
