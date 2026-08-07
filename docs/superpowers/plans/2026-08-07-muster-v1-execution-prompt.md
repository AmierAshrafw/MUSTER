# MUSTER v1 execution prompt

Session prompt for executing the MUSTER v1 implementation plan.
Paste this into a fresh Claude Code session in this repo.

---

Execute docs/superpowers/plans/2026-08-07-muster-v1-implementation.md (MUSTER v1,
25 tasks). The plan file on disk is authoritative - it already includes the D27
protocol-surface amendments (commit 2f3e1ff): scope checks whitelist only
tasks/doing/*.notes.md, tasks/doing/*.verify.log, tasks/staging/*.md under tasks/.
Spec docs/superpowers/specs/2026-08-07-muster-v1.md wins any conflict, EXCEPT the
5 deviations listed in the plan's Authority section.

Use superpowers:subagent-driven-development. Fresh general-purpose subagent per
task, model sonnet; review each task's diff in the main thread before dispatching
the next. Run Task 22 (eval dispatch) from the main thread directly - it spawns
its own Sonnet eval subagent. Tasks run in plan order; each task commits per its
own steps (conventional subject, NO Co-Authored-By trailer, no agent name).

Environment facts: Windows 11, PowerShell 5.1 (scripts must be 5.1-compatible),
stock Pester is 3.4 - Task 2 installs Pester 5 CurrentUser. Git Bash sh.exe at
C:\Program Files\Git\bin\sh.exe for the sh-engine tests (Tasks 23-24).

Stop and ask me only at: Task 19 Step 3 if the /muster:* slash-command form does
not register (spec 8.1/8.2 wording is affected), or any plan-vs-spec conflict not
covered by the Authority deviations. Everything else: proceed.
