# Plan review — 2026-08-14-test-speed-phase3

Reviewer: `plan-reviewer` subagent (opus, fresh context). Read the plan, the design spec, `runtime/bin/_lib.ps1` (the relevant functions), the three verb scripts, `tests/MusterFixture.ps1`, `tests/fast/InProcHarness.ps1`, the Phase 1 fast-test precedent, and the three black-box suites.

**Summary:** 0 blockers, 2 warnings, 2 suggestions. All four ACCEPTED and applied inline.

The reviewer verified independently: the three extracted command bodies reproduce the verb scripts (exit codes, refusal strings, output ordering, PS 5.1 array-return gotchas intact — `Test-TaskSchema`/`Get-DirtyPaths` still assigned directly, `Complete-Task`/`Move-TaskSidecars` returns captured); the three tail edits match source verbatim; cycle→0 / cap→3 / integration→3 map correctly; the only caller of the two converted fail functions is `done.ps1`→`Invoke-DoneCommand` (grep-confirmed); no fast test trips a documented carve-out.

## Findings and verdicts

### W1 — stale line-number hints after Step 3 insertion
Task 1 Steps 4/5 cite `_lib.ps1:1049-1054`, `1089-1091`, `1104-1106`, but Step 3 inserts `Invoke-DoneCommand` (~52 lines) earlier in the file, shifting those blocks down within the same task.

**ACCEPT** — correct: the insertion point (after `Invoke-LintCommand`, ~line 765) precedes the fail branches (1022-1107), so the cited coordinates go stale mid-task. Evidence: plan Task 1 Step 3 inserts after `_lib.ps1:765`; fail branches at `_lib.ps1:1022,1094`. Applied: added a callout at the top of Step 4 instructing the implementer to locate by the quoted before-block, not the line numbers.

### W2 — missing `## Not yet specified` fog section
Plan had `## Out of scope` but not the `## Not yet specified` section the repo's plan convention uses.

**ACCEPT** — the Phase 1 plan carries it (`docs/superpowers/plans/2026-08-13-test-speed-phase0-phase1.md:696-705`). Applied: added a `## Not yet specified` section listing the Phase 4 contract matrix, test migration, and the deferred carve-out restructure.

### S1 — stale comment on `Move-ToFailedWithResult`
`_lib.ps1:1004` header comment "Caller prints and exits 3" goes false once both fail branches convert to `return … -ExitCode 3`. The plan fixed the analogous comment at `_lib.ps1:1023` but not this one.

**ACCEPT** — correct: `Move-ToFailedWithResult` is called by both converted branches (`_lib.ps1:1051,1104`), and its callers no longer exit. Applied: added the comment fix to Task 1 Step 4.

### S2 — sh arm runs the stateful fast tests redundantly
Task 4 Step 1's sh arm runs `-Path tests`, which includes the new fast files. Their act is engine-agnostic (PS runspace) but their setup (`Invoke-MusterClaim`) is engine-dependent — new vs Phase 1, whose fast tests had no claim in setup.

**ACCEPT** — accurate and a genuinely new wrinkle. It is harmless (parity guarantees `claim.sh` produces identical board state) and matches the Phase 1 precedent of running fast tests under both arms. Applied: added a note to Task 4 Step 1 explaining the redundancy is intentional/harmless and not to scope it out.

## Context inspected (reviewer)
- Read: the plan (full), the design spec (full), `runtime/bin/_lib.ps1` (relevant functions), `runtime/bin/{claim,verify,done,status}.ps1`, `tests/MusterFixture.ps1`, `tests/fast/InProcHarness.ps1`, `tests/fast/Status.Fast.Tests.ps1`, `tests/{Done,Claim,Verify}.Tests.ps1`.
- Grep: fail-branch callers; `Invoke-{Done,Claim,Verify}Command` collisions; function inventory; plan section headers.
- Missing: none.
