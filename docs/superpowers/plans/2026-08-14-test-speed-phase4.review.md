# Plan review sidecar: 2026-08-14-test-speed-phase4.md

Reviewer: plan-reviewer subagent (opus), 2026-08-14. All findings verified
empirically by the reviewer on this box (PS 5.1.26100.9168, Pester 6.0.1).
Verdicts by the main thread; every ACCEPT is applied in the plan.

## Blockers

- B1 ACCEPT. `Invoke-Muster`'s `2>&1` capture under `$ErrorActionPreference='Stop'`
  throws `RemoteException` when a verb child writes stderr - kills 4 of 5 new
  matrix gap tests (reviewer ran them). Fix: Task 1 Step 5 wraps the capture
  with a local `Continue`; gap tests note the dependency.
- B2 ACCEPT. `Done.Fast.Tests.ps1:117` claims a `-Tier strong` review task;
  the plan had it in the `-Tier any` group. Moved to the strong group.
- B3 ACCEPT. LintOverlap twin samples used `-Lite` (check 15 is skipped under
  `-Lite`) and asserted exit 0 (check 11 makes minimal batches exit 1).
  Samples rewritten: no `-Lite`, absence-style assertions, constraints noted.
- B4 ACCEPT. Task 12 Step 4's double-quoted `-Command "..."` let the outer
  shell expand `$env:`/`$_` (verified broken). Both commands single-quoted.
- B5 ACCEPT. Meta-test's eligible-twin It is red at Task 8 (twins land in
  Task 9) - would commit a red suite. `-Skip` at Task 8, un-skip in Task 9
  Step 4.
- B6 ACCEPT. Verify-entry child time was missing from F, biasing the D7 rule
  toward the C# branch. Added: guarded stopwatch in `Invoke-VerifyEntry`
  (no-op when the global sink is absent), `verify-children` in the
  decomposition line, and a pre-registered F_low/F_high bracket with
  conservative rule application (rule 1 needs F_low > 30; rule 2 needs A_low).

## Warnings

- W1 ACCEPT. `Lib.Tests.ps1:8` is an in-It fixture with try/finally, not a
  BeforeAll. Dropped from the Task 4 swap list; stays per-test copy.
- W2 ACCEPT. Measure-DevLoop pipes runner stdout to Out-Null, discarding the
  decomposition line Task 12 needs. Runner now appends it to
  `$env:TEMP\muster-devloop.log`; Task 12 reads it back.
- W3 ACCEPT. SuiteMeta discovery measured 4.7-5.8 s (not ~0.13 s x files) -
  ~16-20% of the gate. Moved to checkpoint tier (out of run-dev's file list,
  runs via run-full). Spec updated to match (tier model + D4).
- W4 ACCEPT. Task 6 fold rule now also greps `tests/fast/*.Fast.Tests.ps1` -
  the fast tier is `Invoke-MusterInProc`'s actual consumer and holds eight
  `$r.Output[-1]` position-sensitive assertions.
- W5 ACCEPT. Task 12's conditional `Lib.Tests.ps1` split added to the plan's
  standing-invariants carve-out list.

## Suggestions

- S1 ACCEPT. `Measure-Baseline.ps1` heading hard-coded the old date; added
  `-Title` param, Task 0 passes a Phase 4 title.
- S2 ACCEPT. Template build warmed outside both timed loops in Task 3 so the
  copy arm's first sample is not asymmetrically loaded.
- S3 ACCEPT. `Contract.Tests.ps1` renamed `ProcessContract.Tests.ps1` to
  avoid colliding with the in-process "Contract tier" vocabulary.
- S4 ACCEPT. D1's template-family fallback and D2's pool candidate added to
  the plan's Out of scope with their rationales.

Tally: 6 Blockers, 5 Warnings, 4 Suggestions - 15 ACCEPT, 0 DISMISS, 0 DEFER.
