# Phase 4 baseline: 2026-08-14

Machine: RPS-MV-L-1007, Windows PowerShell 5.1.26100.9168. No NGen or machine tuning applied.
Micro rows measured with the ps1 engine (MUSTER_ENGINE cleared at script start).
MicroRuns=5, SuiteRuns=3. Cold = run 1. p95 over N<=5 runs approximates the max - noted per spec.

## Micro benchmarks (seconds)

| Operation | Runs | Cold | p50 | p95 | All samples |
|---|---:|---:|---:|---:|---|
| powershell.exe spawn (-NoProfile, exit 0) | 5 | 1.903 | 1.914 | 2.276 | 1.903, 1.83, 1.914, 1.961, 2.276 |
| fixture create+destroy (New-MusterFixture) | 5 | 4.382 | 0.986 | 4.382 | 4.382, 0.986, 1.273, 0.953, 0.643 |
| git status in fixture | 5 | 0.696 | 0.192 | 0.696 | 0.696, 0.111, 0.115, 0.192, 0.332 |
| status verb via child process (Invoke-Muster) | 5 | 5.085 | 5.029 | 5.883 | 5.085, 4.521, 5.029, 5.883, 4.132 |

## Dev-loop candidate set (pre-change)

Machine: RPS-MV-L-1007. Timer: `tests/bench/Measure-DevLoop.ps1` (default command
`Import-Module Pester -MinimumVersion 6.0.0; Invoke-Pester -Path tests/fast, tests/Lib.Tests.ps1`).
Protocol (spec D6): 5 cold (fresh host each) + 5 warm (one host, run 0 discarded).
Gate statistic = worst of 5 warm <= 30 s.

Files timed (76 tests): `tests/fast/CommandCore.Fast.Tests.ps1`,
`tests/fast/Claim.Fast.Tests.ps1`, `tests/fast/Done.Fast.Tests.ps1`,
`tests/fast/Lint.Fast.Tests.ps1`, `tests/fast/Status.Fast.Tests.ps1`,
`tests/fast/Verify.Fast.Tests.ps1`, `tests/Lib.Tests.ps1`.

| Metric | p50 | p95 (=worst of 5) | All samples |
|---|---:|---:|---|
| cold | 167.748 | 176.081 | 167.8, 167.7, 157.7, 166.7, 176.1 |
| warm | 145.746 | 153.521 | 145.7, 139.8, 153.5, 149.2, 131.0 |

Pre-change warm p95 = 153.5 s = 5.1x the 30 s gate. This is the number Tasks
1-4 (harness/fixture waste removal) and Task 12 (parallel lever) must beat.

Measurement-quality note: the micro rows above were captured under transient
machine load (status-verb-child p50 5.03 s vs 0.66 s in the committed
`baseline-2026-08-13.md`); the dev-loop rows ran later under lighter load.
All Phase 4 runs are on the same box, so relative before/after ratios stay
valid; D7's absolute thresholds (F > 30 s, the 30 s gate) are load-sensitive
and re-flagged at Task 12 if the measured floor is implausible.

