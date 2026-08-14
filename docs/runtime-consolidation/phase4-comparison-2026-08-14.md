# Phase 4 gate measurement and C#-decision (D7)

**Machine:** damai-new (Windows Server 2025 Standard, Windows PowerShell 5.1, Pester 6.0.1). NOT RPS-MV-L-1007 - all Phase 0-3 timing baselines were on the old box and do not transfer, so this doc re-measures the dev loop on the current box under the spec D6 protocol (same-box to same-box only).
**Date:** 2026-08-14
**Branch:** test-speed-consolidation

## Gate statistic (spec D6: worst of 5 warm <= 30 s)

`tests/run-dev.ps1` (serial, 129 tests: the 8 fast files + Lib.Tests.ps1; SuiteMeta excluded - checkpoint tier), measured by `tests/bench/Measure-DevLoop.ps1` (5 cold fresh hosts + 5 warm same host):

| | p50 | p95 (= worst of 5) |
|---|---:|---:|
| cold | 174.0 s | 178.0 s |
| warm | 166.5 s | **167.9 s** |

**Gate: warm p95 = 167.9 s vs 30 s -> MISS by 5.6x.** cold p95 (178.0) < 2x warm p95, so no cold-start finding. All 129 tests passed on every run; **0 verb-child spawns** in the dev loop (the MUSTER_DEVLOOP guard would throw on any).

## Serial cost decomposition (gate warm run, wall 167.9 s)

| Component | Seconds | Notes |
|---|---:|---|
| fixture (copy + reset-reuse + delete) | 39.8 | language-independent filesystem/git I/O |
| template build | 6.6 | one New-MusterFixtureFromScratch per file |
| verify-children | 2.2 | UNDERCOUNTED - see caveat |
| It-exec (sum of It durations) | 165.6 | interpreter + runspace + in-process command time |
| git wall (GIT_TRACE_PERFORMANCE) | 56.77 | separate instrumented run; sum of 5695 perf-trace lines |

**verify-children undercount caveat:** `Invoke-MusterInProc` runs each command in a fresh `[powershell]::Create()` runspace whose `$global:` scope is separate from run-dev's, so the `MusterVerifySeconds` accumulator (guarded on that global) never fires inside the nested runspace. Only Lib.Tests.ps1's direct `Invoke-VerifyEntry` calls are counted; the fast tier's verify children are not. Immaterial to the verdict: all fixture-verify children are git (`git --version`), captured in the git wall via GIT_TRACE_PERFORMANCE (inherited by every subprocess), and F_low already exceeds the gate on the fixture floor alone. (`GIT_TRACE_PERFORMANCE` also emits internal-region lines, so 56.77 is an upper bound on git wall - which only makes F_low a more conservative-high floor.)

## D7 decision (pre-registered before measurement)

F = language-independent floor (git children + verify-entry children + fixture I/O); A = C#-addressable (interpreter/runspace + in-process exec). Double-count bracket (git spawned by verify appears in both git-seconds and verify-children; git inside fixture appears in both git-seconds and fixture-seconds - so the sum over-estimates F):

- **F_low**  = git + fixture + template = 56.77 + 39.8 + 6.6 = **103.2 s**
- **F_high** = F_low + verify-children = **105.4 s**
- **A_low**  = warm wall - F_high = 167.9 - 105.4 = **62.5 s**
- **A_high** = warm wall - F_low  = 167.9 - 103.2 = **64.7 s**

Pre-registered application: rule 1 (floor exceeds gate; renegotiate; C# NOT revived on speed) fires iff **F_low > 30 s**; rule 2 (C# speed case) fires iff it holds with A_low.

**F_low = 103.2 s > 30 s -> D7 RULE 1 FIRES.**

Robustness - the conclusion does not depend on the git double-count: the tightest possible floor, fixture I/O ALONE (39.8 s) - which any language's harness pays identically (git reset/clean + filesystem copy of the fixture) - already exceeds the 30 s gate. **The 30 s dev-loop gate is unreachable in any language on this machine.**

**Outcome: gate renegotiated (scope or number); C# NOT revived on speed grounds** (governing plan, "Relationship to the C# proposal"). A (~62-65 s) is recorded as the measured upper bound on what a from-scratch-language rewrite could remove, but it cannot close the gap below the F floor.

## Parallelism lever (spec D6/D7): measured NON-VIABLE

`run-dev.ps1 -Parallel` (file-level Start-Job workers) neither reaches the gate nor completes green on this box:
- Start-Job workers DEADLOCK on verify-entry children: a `[System.Diagnostics.Process]::Start` with redirected stdout/stderr (Invoke-VerifyEntry) hangs inside a background job - the git verify child is never observed to exit and hits the 300 s timeout. Reproduced with a SINGLE job and with a bare minimal Process.Start; a Start-Job/redirected-I/O platform limitation, not contention.
- Even absent the deadlock, per-job host-spawn + Pester-import overhead alone exceeds 30 s, so parallelism cannot reach the gate regardless.

Task 12's parallel steps (parallel protocol, Lib split) are therefore moot; the gate is measured on the serial path, which is itself 5.6x over. The lever is retained in `run-dev.ps1` with an in-file non-viability note, as the spec's designed contingency for the record.

## Pre-change baseline (this box, PRE-Phase-4 candidate set at c4c5078)

`Measure-DevLoop.ps1` default command (`Invoke-Pester -Path tests/fast, tests/Lib.Tests.ps1`) at commit c4c5078 - the pre-Phase-4 candidate set (76 tests: the original 37 fast tests, whose setups spawn `powershell.exe` verb children, + 39 Lib tests):

| | p50 | p95 |
|---|---:|---:|
| cold | 107.3 s | 112.4 s |
| warm | 103.0 s | 104.1 s |

## What Phase 4 delivered (same box)

The post-change dev loop is LARGER, not the same 76 tests: Phase 4 migrated 53 black-box contract behaviors into the in-process dev loop as fast/contract twins, so run-dev is 129 tests (90 fast + 39 Lib) vs the pre-change 76.

| | tests | warm p95 | s / test |
|---|---:|---:|---:|
| pre-change (c4c5078) | 76 | 104.1 s | 1.37 |
| post-change (run-dev) | 129 | 167.9 s | 1.30 |

- Per-test cost fell (1.37 -> 1.30 s) despite the pre-change set including child-spawn claim setups this phase removed.
- The 53 migrated behaviors added 63.8 s in-process (167.9 - 104.1) = ~1.2 s each. Adding the same 53 as black-box child-spawn tests would cost ~5 s each (measured child claim 5.42 s) ~ 265 s - so the in-process migration bought the added contract coverage at ~4x lower marginal cost.
- Structural wins independent of wall: verb-child-free dev loop (D1), shared reset-reuse fixtures (D2), extracted `Invoke-PromoteCommand`, committed contract matrix + growth-freeze meta-test (D4), and a both-engine `run-full.ps1` checkpoint.

Net: Phase 4 met its structural and decision goals but not the 30 s wall gate - which the D7 analysis shows is unreachable in any language on this machine (fixture I/O floor 39.8 s > 30 s). Per the governing plan, a documented gate MISS with the D7 rule applied is a valid phase exit.

## Sources
- `phase4-baseline-2026-08-14.md` (Task 0 baseline scripts), `phase4-fixture-2026-08-14.md` (D2 verdict), `phase4-classification.md` (D3 classification + info-stream fold).
- Raw protocol output and decomposition log captured 2026-08-14 on damai-new.
