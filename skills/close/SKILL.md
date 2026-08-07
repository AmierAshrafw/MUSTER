---
name: close
description: Archive a finished MUSTER plan. Invoked ONLY by the explicit /muster:close slash command. Never auto-trigger from conversational mention of closing, archiving, or finishing work.
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
