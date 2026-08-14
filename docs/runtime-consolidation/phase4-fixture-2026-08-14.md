# Phase 4 fixture strategy verdict: 2026-08-14

Machine: RPS-MV-L-1007, Windows PowerShell 5.1. Benchmark:
`tests/bench/Measure-Phase4Fixture.ps1` (Cycles=20, Passes=2).

## Strategies compared (dev-loop scope only)

1. **copy** - the current template-copy `New-MusterFixture` / `Remove-MusterFixture`
   (one fresh copied fixture per test).
2. **reset-reuse** - one shared copied fixture per test file, reset to its baseline
   SHA between tests: `git reset --hard <baseSha>` + `git clean -xfd`.

Pool (a pre-built fixture pool) is **excluded by reasoning, not measurement**: a
pre-built pool pays the same per-copy cost as `copy`, only earlier; it can win only
by overlapping build with execution (async machinery, out of scope for this phase).

## Pre-registered adoption rule (fixed before measurement, Phase 2 precedent)

Adopt reset-reuse **iff** its p50 cycle <= 0.70 x copy p50 in **both** passes
**AND** `Assert-ReuseFixtureContract` passes (sequential isolation: committed task
files, attempt-marker commits - the `Get-AttemptCount` hazard - staged changes, and
untracked files all vanish on reset).

## Measured (verbatim script output)

```
pass 1: copy p50 0.473 s, reset-reuse p50 0.177 s, ratio 0.37 (adopt if <= 0.70), contract PASS
pass 2: copy p50 0.630 s, reset-reuse p50 0.170 s, ratio 0.27 (adopt if <= 0.70), contract PASS
```

## Verdict: ADOPT reset-reuse

Both passes clear the rule with margin (ratio 0.37 and 0.27, both <= 0.70) and the
reuse contract passes in both. Reset-reuse costs ~0.17 s/cycle vs ~0.47-0.63 s/cycle
for copy - a ~63-73% per-fixture reduction, material under the pre-fixed rule.

Consequence: **Task 4 executes** - the dev-loop test files adopt
`New-SharedMusterFixture` (one reset-reused fixture per file). Template-copy
`New-MusterFixture` remains the fallback and stays in use for
`Harness.Tests.ps1`, the `Get-TaskFiles` It (builds its own fixture in-body), and
any test needing two independent live fixtures.
