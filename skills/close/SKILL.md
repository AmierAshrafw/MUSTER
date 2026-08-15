---
name: close
description: Archive a finished MUSTER plan. Slash-only (/muster:close); do not auto-trigger.
---

# muster:close - archive a finished plan

Input: a plan id. All checks read the board; refuse rather than force.

1. Eligibility (D15): the plan's board must be empty except done/ - zero task files
   with this plan id in backlog/, inbox/, doing/, staging/, or failed/. Any present =
   refuse and list them (failed/ cards mean the plan is NOT finished - the human
   decides what to do with them first).
2. Create `tasks/archive/<plan-id>/`.
3. `git mv` every `tasks/done/<plan-id>-*` file (task cards AND their sidecars:
   .result.md, .verify.log, .gen*.* history) into `tasks/archive/<plan-id>/`.
4. `git mv tasks/plan-<plan-id>.md tasks/archive/<plan-id>/plan-<plan-id>.md`
   (the snapshot retires with its cards - spec section 1).
5. One commit, explicit paths, message: `muster(<plan-id>): close`.
6. Print: card count archived, and a reminder that archived tasks still satisfy
   dependencies (D15).

## v2 boards (`.muster/` exists at the repo root)

Nothing moves at close on v2: dependencies resolve in the database and no verb
scans folders, so done cards stay in `.muster/cards/` as permanent history.

1. Run `muster board`. Eligibility: every task with this plan id is in
   `done` - the board shows backlog 0, inbox 0, doing 0, failed 0 for the
   plan (failed cards mean the plan is NOT finished; the human decides).
2. Report: done count for the plan and a reminder that done tasks keep
   satisfying dependencies forever.
