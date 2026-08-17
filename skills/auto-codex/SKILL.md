---
name: auto-codex
description: MUSTER orchestrator loop, Codex as run-tier executor. Slash-only (/muster:auto-codex); do not auto-trigger. Orchestrator owns every muster verb; Codex only edits + self-checks per task.
---

# muster:auto-codex - orchestrator loop, Codex runs the edits

Input: a plan id (kebab-case). Fresh Claude Code session, cwd = target repo.
Requires `.muster/` (v2 board) and `codex` on PATH.

## Preconditions (refuse to start otherwise)

- Exactly one active plan on the board (every backlog/inbox/doing/staging task
  carries this plan id). `NextEligible` scans board-wide, so a second plan makes
  the loop drain the wrong tasks.
- `doing` empty. A non-empty `doing` is a crashed predecessor - human recovery
  (`muster redo <id>`), not this loop's job.

## Hard rules

- **Sequential only.** One task fully finishes before the next starts. One
  executor per checkout (D18); no worktree.
- **Orchestrator runs every `muster` verb** (claim, verify, done) and the
  `codex exec` subprocess. Codex runs no verb and no git.
- **Progress = board re-read**, never `done`'s exit code and never Codex's prose.
- **Review-tier is a Claude opus subagent** (default), full RUNNER, exactly like
  `skills/auto`. Codex handles run-tier only.

## Loop

1. `muster board`. Read the run / review / doing / failed / backlog / done lines.
2. `doing > 0`: STOP - crashed predecessor. Report the id; human runs
   `muster redo`. (Recovery framing is identical to `skills/auto`.)
3. `review > 0`: dispatch a Claude opus review subagent (run
   `muster claim -harness claude -tier strong`, follow `.muster/RUNNER.md`),
   foreground, wait. Then re-read the board (step 1). Do not resume a finished
   subagent.
4. Else `run > 0`: run the Codex run-task triad (below). Then re-read (step 1).
5. Else nothing claimable:
   - `failed > 0` or a DEAD backlog marker: STOP, report ids. Human recovery.
   - `backlog` clear and `done > 0`: perform Close (below). Stop.
   - Otherwise: STOP, report the board as printed (unexpected).

## Codex run-task triad (step 4 detail)

1. **Claim + fingerprint.**
   - `muster claim -harness codex -tier any`.
   - Refusal `nothing to claim for codex/any.` (the full identity string,
     claim.go:143): run tasks remain but none are codex-eligible - they are
     `harness:claude`-pinned. Dispatch a Claude
     run-mode subagent for them (`-harness claude -tier any`), as `skills/auto`
     does. Then re-read the board. (Do not treat the exit code alone as
     "nothing to do" - confirm against the board counts.)
   - Any other refusal: STOP, report verbatim.
   - On success, capture the printed card body. Run `muster fingerprint`; save
     the digest as FP_CLAIM.
2. **Dispatch Codex.** Fill `codex-dispatch.md`'s template with the card body
   and this task id, write it to a scratch file, and run the `codex exec` line
   with the temp-dir `GOCACHE`/`GOTMPDIR` env (codex-dispatch.md). Foreground;
   wait for exit. Give build/test steps a generous timeout (Codex's default
   per-command limit is ~10s).
3. **Verify + done.** After EVERY Codex dispatch (the initial one and each
   retry):
   - Confirm the `codex exec` process returned (foreground wait).
   - Run `muster fingerprint`; if it differs from FP_CLAIM, Codex wrote the DB -
     STOP and report a board-integrity breach (human recovery). Expected: equal.
     (Re-checking each retry, not just once, closes the retry-tamper gap.)
   - `muster verify`. FAIL with attempts remaining: re-dispatch Codex into the
     SAME claim (no re-claim) with the verify transcript appended, then repeat
     this fingerprint+verify block. Terminal fail (cap reached): STOP, report.
   - PASS: `muster done`.
   - Re-read `muster board`. Task moved to `done` = progress, loop. Task still
     `doing` or a `done` refusal: STOP, report the `done` output (human runs
     `redo`/`fail`).

## Close (performed directly, no subagent)

Mirror `skills/close` (v2 arm): when the board is empty except `done`, this loop
reports the closeable state and runs the plan's close. Nothing moves in v2 beyond
what `muster` does. Report the archived/closed count. Stop.

## Halt conditions (exhaustive)

- Plan closed (success).
- `doing` occupied at top of loop - crashed predecessor (human recovery).
- A `done` refusal or a task stuck `doing` after the triad (human recovery).
- Fingerprint mismatch after a Codex run - board-integrity breach (human).
- `failed` non-empty or a DEAD backlog task (human recovery).
- Unexpected board state - reported.

No other exit path. No task/turn cap.
