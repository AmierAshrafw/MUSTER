# Board visibility execution prompt

Session prompt for executing the board-visibility implementation plan.
Paste this into a fresh Claude Code session in this repo.

---

Execute docs/superpowers/plans/2026-08-08-board-visibility.md (board visibility,
5 tasks). The plan file on disk is authoritative - it already includes all 11
applied plan-reviewer fixes (see the .review.md sidecar). The design spec
docs/superpowers/specs/2026-08-08-board-visibility-design.md wins any intent
conflict; the v1 spec amendments the plan makes in Task 5 are intended edits,
not conflicts.

Use superpowers:subagent-driven-development. Fresh general-purpose subagent per
task, model sonnet; review each task's diff in the main thread before
dispatching the next. Tasks run in plan order; each task commits per its own
steps (conventional subject, NO Co-Authored-By trailer, no agent name).

Non-negotiables from the plan:

- The "Pinned output formats" section is byte-law: status-block inbox line,
  Board: line, bucket rule. Tests and spec amendments must match it verbatim.
- Run Pester as plain cmdlet lines in the session's PowerShell, never nested
  powershell -Command "..." (double-quoted nesting mangles $env:MUSTER_ENGINE -
  the plan's conventions section shows the exact commands).
- Task 4's done test: p-02-b MUST be committed before Add-ClaimedImpl (D27
  scope guard - the plan explains).
- Task 5 README test counts: copy the totals from the actual Pester output of
  that step, never guess.

Environment facts: Windows, PowerShell 5.1 (scripts must be 5.1-compatible),
Pester 5 installed CurrentUser (Invoke-Pester works). Git Bash sh.exe at
C:\Program Files\Git\bin\sh.exe for the sh-engine passes. Both engines must be
green per task where the plan says so - sh is not optional.

Stop and ask me only on: a plan-vs-spec conflict the Authority line above does
not cover, or a test failure that survives one honest fix attempt (no
test-weakening to get green). Everything else: proceed.
