# Phase 4 test classification

**Machine:** damai-new (Windows Server 2025, Windows PowerShell 5.1, Pester 6.0.1)
**Date:** 2026-08-14

## Information-stream probe (spec D3)

Question: `Invoke-Promote`'s malformed-backlog warning goes through `Write-Host`
(the Information stream), which the in-process runspace harness dropped. Does the
warning land in `$ps.Streams.Information`, and can the harness fold it into the
returned result's `Output` without breaking any existing assertion's line order?

Probe: `tests/bench/Probe-InfoStream.ps1`.

**Fixture-content correction (found during the probe):** the malformed-backlog
warning fires only for a backlog file with *no frontmatter block at all*
(content `"no frontmatter here\n"`, per the black-box source of truth
`tests/Promote.Tests.ps1:44`). A valid-but-incomplete frontmatter such as
`---\nid: p-03-bad\n---\nbody` parses clean — `Read-TaskFile.Errors` covers
frontmatter *parse* errors, not schema completeness — so promote treats it as a
normal task and promotes it silently, emitting no warning. The first probe run
used the incomplete-frontmatter content and (correctly) saw 0 information records;
the probe fixture was corrected to the no-frontmatter content.

Probe output (corrected run):

```
result output lines: 0
information records: 1
  info: MUSTER warn: backlog/p-03-bad.md frontmatter invalid - skipped by promote.
child stdout: MUSTER warn: backlog/p-03-bad.md frontmatter invalid - skipped by promote.
```

**Decision: FOLD.** Both conditions of the pre-set rule hold:

- **(a)** The warning appears in `$ps.Streams.Information` (1 record).
- **(b)** No existing fast-tier test emits an Information record while asserting
  Output-line position. The only `Write-Host` reachable in-process is
  `Invoke-Promote`'s malformed-backlog warning (`runtime/bin/_lib.ps1:428`; the
  other two `Write-Host` hits at 418/769 are comments). No current fast test
  creates a malformed *backlog* file — `Status.Fast.Tests.ps1:25` writes a
  no-frontmatter file to `tasks/inbox/`, not `tasks/backlog/`, and status never
  promotes — so the fold appends to no existing test's Output. Verified
  empirically: the full fast tier stayed green (42 passed) after the fold.

Implementation: `tests/fast/InProcHarness.ps1` appends
`$ps.Streams.Information` message lines after `Output` in the returned result
(order vs Output is not preserved — valid only while no assertion depends on it).
The promote-warning rows (`CM-CO-PROMOTE-WARN`, `CM-PROMOTE-WARN-CLAIM`) become
**eligible** for fast twins; the `skips malformed backlog files with a warning`
twin now lives in `tests/fast/Promote.Fast.Tests.ps1` and asserts on the folded
`Output` via a substring match (not a position).

## Describe-level classification (spec D3)

23 Describes / 126 Its across `tests/{Claim,Done,Harness,Lib,Lint,LintOverlap,Promote,Status,Verify}.Tests.ps1`.
It counts recounted directly from source (do not reuse plan examples).

**Boundary** = what change breaks it: `logic` (pure function), `session-state`
(git-state flow), `child-contract` (child-process semantics - exit propagation,
param binding, merged-stream output).
**Twinned** = how many of the Describe's Its already have a fast/contract twin.
`Lib.Tests.ps1` and `Harness.Tests.ps1` dot-source `_lib.ps1`/`MusterFixture.ps1`
directly into the Pester process - no child, no runspace - so they already run at
fast-tier speed; their cells are `N/A (already in-process)`, not a coverage gap.

| # | Describe (file) | Its | Boundary | Twinned | Divergence |
|---|---|---:|---|---|---|
| 1 | bin/claim (Claim.Tests.ps1) | 14 | session-state | 6 of 14 | none |
| 2 | bin/claim - recovery probe (Claim.Tests.ps1) | 3 | session-state | 2 of 3 | none |
| 3 | bin/done - preconditions and pass path (Done.Tests.ps1) | 13 | session-state | 6 of 13 | native-stderr (1 It: eol=lf + CRLF commit_path) |
| 4 | bin/done fail - review path (Done.Tests.ps1) | 5 | session-state | 3 of 5 | none |
| 5 | bin/done fail - integration path (Done.Tests.ps1) | 4 | session-state | 1 of 4 | none |
| 6 | fixture harness (Harness.Tests.ps1) | 5 | child-contract (infra) | N/A (already in-process) | none |
| 7 | Get-TaskFiles (Lib.Tests.ps1) | 1 | logic | N/A (already in-process) | none |
| 8 | Get-IsoNow (Lib.Tests.ps1) | 1 | logic | N/A (already in-process) | none |
| 9 | Write-Utf8 / Add-Utf8 (Lib.Tests.ps1) | 2 | logic | N/A (already in-process) | none |
| 10 | Get-AgeString (Lib.Tests.ps1) | 1 | logic | N/A (already in-process) | none |
| 11 | Read-Frontmatter (Lib.Tests.ps1) | 7 | logic | N/A (already in-process) | none |
| 12 | Test-TaskSchema (Lib.Tests.ps1) | 10 | logic | N/A (already in-process) | none |
| 13 | Split-CmdLine (Lib.Tests.ps1) | 2 | logic | N/A (already in-process) | none |
| 14 | Invoke-VerifyBlock (Lib.Tests.ps1) | 4 | child-contract | N/A (already in-process) | none |
| 15 | Get-AttemptCount (Lib.Tests.ps1) | 3 | session-state | N/A (already in-process) | none |
| 16 | completion machinery (Lib.Tests.ps1) | 3 | session-state | N/A (already in-process) | none |
| 17 | Get-InboxSplit (Lib.Tests.ps1) | 3 | logic | N/A (already in-process) | none |
| 18 | Get-BoardLine (Lib.Tests.ps1) | 2 | logic | N/A (already in-process) | none |
| 19 | bin/lint (Lint.Tests.ps1) | 18 | logic | 2 of 18 | none |
| 20 | bin/lint - commit_paths overlap D32 (LintOverlap.Tests.ps1) | 9 | logic | 0 of 9 | none |
| 21 | bin/promote (Promote.Tests.ps1) | 5 | session-state | 5 of 5 | none (info-stream folded, D3) |
| 22 | bin/status (Status.Tests.ps1) | 4 | logic | 4 of 4 | none |
| 23 | bin/verify (Verify.Tests.ps1) | 7 | session-state | 6 of 7 | none |

Per-file It totals (grep-verified): Claim 17, Done 22, Harness 5, Lib 39, Lint 18,
LintOverlap 9, Promote 5, Status 4, Verify 7 = **126**.
`Status` calls `git rev-parse --abbrev-ref HEAD` for a branch label but never
asserts a git-state transition, so it is bucketed `logic` (read-only, cannot fail
in any fixture).

## Failing-native-command class (spec D3 Step 2)

The Phase 1 divergence: a refusal that follows a *failing* native command throws a
terminating `NativeCommandError` in a hosted runspace (under the library's
`$ErrorActionPreference='Stop'`) instead of returning a refusal CommandResult
(`tests/fast/InProcHarness.ps1:5-10`). Such behaviors are child-only.

**Finding: zero of the 126 canonical black-box Its are members of this class.**
The class is real in `runtime/bin/_lib.ps1` but no current fixture exercises it:

- `Get-RepoRoot` (`_lib.ps1:8-12`) - `git rev-parse --show-toplevel`, unguarded;
  failure outside a repo feeds `Write-Refuse 'not inside a git repository.'`. The
  canonical member per the InProcHarness header - but every fixture `git init`s,
  so no It runs outside a repo.
- `Invoke-VerifyCommand` attempt-marker commit (`_lib.ps1:~963`) and `Complete-Task`
  completion commit (`_lib.ps1:~1174`) - `$LASTEXITCODE`-gated refusals behind an
  unguaranteed `git commit`; no It forces the commit to fail.
- `Read-CommittedTask` (`_lib.ps1:~395`) - `git show HEAD:tasks/doing/<name>`,
  failure feeds the uncommitted-doing-task refusal. Measured native-stderr path
  (`phase3-spike-2026-08-14.md`), child-only - but it is NOT an existing black-box
  It (only the throwaway `tests/bench/Probe-Phase3Divergence.ps1` exercises it).

Consequence for Task 8: the matrix's `CM-GITFAIL` / `CM-STATUS-FAIL` /
`CM-PROMOTE-FAIL` (outside-a-repo refusals) and `CM-CO-UNCOMMITTED` are genuinely
**new** tests in `tests/ProcessContract.Tests.ps1`, not tags on existing Its. The
one measured native-stderr divergence with a real black-box home is the `eol=lf`
+ CRLF `Complete-Task` case (Done row 3 above), which stays child-only.

## Twin worklist (Task 9 input)

Every eligible (non-divergent) black-box It with no fast twin, grouped by target
fast file. **46 items** (Promote's 1 item was completed in Task 6). Counts compared
to the plan's rough expectations in parentheses.

### tests/fast/Lint.Fast.Tests.ps1 - 16 (plan ~15)
checks 2; 4 (metachar/network) x2; 5 (verify-path protected/committed); 5 (cmd.exe
switch not a repo path); 7-9 (placeholders/refs/judgment); 8 (review template
passes); 10 (heading order); 11 (seq-99 integration); lite mode; 13 (commit_paths
non-empty); B1 (non-kebab plan); 14 (test-runner empty protected) x2; 5b (test-path
in commit_paths only); protected-test passes both checks. All pure `Test-LintChecks`
logic.

### tests/fast/LintOverlap.Fast.Tests.ps1 - 9 (plan 9; NEW file)
All 9 D32 overlap Its (share/order/transitive/prefix both directions/disjoint/
fix-type/three-way/clean-batch). Pure `Test-Reaches`/`Test-PathListed` graph logic.

### tests/fast/Done.Fast.Tests.ps1 - 11 (plan ~9)
counts-only board line before terminal; self-authored grader D30; refuses deleted
pre-existing protected; refuses out-of-scope; refuses tasks/ protocol surface D27;
lists promoted ids in session-over; refuses staging empty fix; refuses invalid
staged fix; refuses staging-not-empty (integration); records red done-check M4;
refuses pass verdict when done-check fails.
NOTE (executor): several existing Done fast twins are PARTIAL - the fast It asserts
fewer fields than its black-box source (e.g. the review-pass twin covers only the
pass branch, not the refuse-without-notes branch). Some worklist entries are
"flesh out an existing fast It", not "add a new It".

### tests/fast/Claim.Fast.Tests.ps1 - 9 (plan ~8)
refuses without identity flags; refuses on stale staging file; skips diff-harness
tasks; tolerates in-scope dirt + live sidecars; refuses dirty protocol file D27;
promote-first-then-claim; full body before Claimed line; body flush no blank line;
recovery probe skips no-prior-history.

### tests/fast/Verify.Fast.Tests.ps1 - 1 (plan ~1)
attempt cap survives log deletion (M1).

### tests/fast/Status.Fast.Tests.ps1 - 0; tests/fast/Promote.Fast.Tests.ps1 - 0 (done in Task 6)

Excluded from the worklist (not twins of any black-box It): `CommandCore.Fast`
(infra Its for New-CommandResult/Write-Refuse/Invoke-CommandBoundary) and
`Lint.Fast`'s empty-`-Paths` refusal (fast-only, no black-box counterpart).
