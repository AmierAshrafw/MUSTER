# Test Speed Phase 4 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the dev loop (fast + contract tiers, ps1 only) meet the 30-second warm-p95 gate, or produce a decomposed measured miss that feeds the pre-registered C#-decision rule.

**Architecture:** Remove harness waste (verb-child spawns in fast-tier setups, per-test fixture copies), extract the missing `Invoke-PromoteCommand`, classify the suite and pin a contract matrix as tagged black-box tests plus a data file enforced by a discovery-only meta-test, migrate untwinned eligible behaviors in-process, then measure with a serial decomposition and a designed `Start-Job` parallel lever.

**Tech Stack:** Windows PowerShell 5.1, Pester 6.0.1 (`Import-Module Pester -MinimumVersion 6.0.0` always - a Pester 3.4.0 is also installed), git CLI.

**Spec:** `docs/superpowers/specs/2026-08-14-test-speed-phase4-design.md` (rev 2).
Machine for all measurements: the current dev box (record `$env:COMPUTERNAME`).
All commands run from repo root under Windows PowerShell 5.1 unless stated.

**Standing invariants (check at every task):**
- Black-box test files under `tests/*.Tests.ps1` change only by adding `-Tag`.
  Three sanctioned exceptions, all parity-gated: the new
  `ProcessContract.Tests.ps1`; the `Lib.Tests.ps1` fixture-call swaps in
  Task 4; the conditional `Lib.Tests.ps1` Describe split in Task 12 Step 3
  (spec D6's sanctioned rebalance).
- Full both-engine parity run required before merging; this plan runs it inside
  Task 5 (covers Tasks 1-5 harness/runtime changes) and Task 13 (final).
  A parity run is ~30 min (825 s ps1 + 993 s sh).

## File structure

| File | Role |
|---|---|
| `tests/bench/Measure-Baseline.ps1` | modify: `-OutFile` param |
| `tests/bench/Measure-DevLoop.ps1` | create: cold/warm protocol timer for any command |
| `tests/bench/Measure-Phase4Fixture.ps1` | create: copy vs reset-reuse benchmark + reuse contract |
| `tests/bench/Probe-InfoStream.ps1` | create: promote-warning stream probe |
| `tests/MusterFixture.ps1` | modify: DEVLOOP guard, shared reset-reuse fixture, stopwatch accumulators |
| `tests/fast/{Done,Claim}.Fast.Tests.ps1` | modify: in-process claim setups, probe cmd swap |
| `tests/fast/Promote.Fast.Tests.ps1` | create: promote twins |
| `tests/fast/LintOverlap.Fast.Tests.ps1` | create: overlap-lint twins |
| `tests/fast/Lint.Fast.Tests.ps1` | modify: expand twins |
| `tests/fast/SuiteMeta.Fast.Tests.ps1` | create: matrix/inventory meta-test (discovery-only; checkpoint tier - ~5-6 s discovery cost, too fat for the 30 s gate) |
| `tests/ProcessContract.Tests.ps1` | create: black-box matrix-gap tests (frozen-suite exception: matrix gaps; named to avoid colliding with the in-process "Contract tier") |
| `tests/ContractMatrix.psd1` | create: matrix data file |
| `tests/BlackBoxInventory.psd1` | create: growth-freeze inventory |
| `tests/Harness.Tests.ps1` | modify: guard test + shared-fixture contract test |
| `runtime/bin/_lib.ps1` | modify: add `Invoke-PromoteCommand` |
| `runtime/bin/promote.ps1` | modify: become an `Invoke-CommandBoundary` shim |
| `tests/run-dev.ps1` | create: dev-loop runner (serial + `-Parallel`) |
| `tests/run-full.ps1` | create: both-engine full-suite runner |
| `docs/runtime-consolidation/phase4-*.md` | create: baseline, fixture, classification, comparison docs |

---

### Task 0: Current-box baseline

**Files:**
- Modify: `tests/bench/Measure-Baseline.ps1:6,14`
- Create: `tests/bench/Measure-DevLoop.ps1`
- Create: `docs/runtime-consolidation/phase4-baseline-2026-08-14.md`

- [ ] **Step 1: Parameterize the baseline script's output path**

In `tests/bench/Measure-Baseline.ps1` replace:

```powershell
param([switch]$SkipSuite)
```

with:

```powershell
param(
    [switch]$SkipSuite,
    [string]$OutFile = 'docs/runtime-consolidation/baseline-2026-08-13.md',
    [string]$Title = 'Baseline: 2026-08-13'
)
```

delete the line `$OutFile   = 'docs/runtime-consolidation/baseline-2026-08-13.md'` from the fixed-config block (keep `$MicroRuns`, `$SuiteRuns`, `$Engines`), and change the hard-coded heading line `$md += '# Baseline: 2026-08-13'` to `$md += "# $Title"`.

- [ ] **Step 2: Run micro rows to a new file**

```bash
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/bench/Measure-Baseline.ps1 -SkipSuite -OutFile docs/runtime-consolidation/phase4-baseline-2026-08-14.md -Title "Phase 4 baseline: 2026-08-14"
```

Expected: `Baseline written: docs/runtime-consolidation/phase4-baseline-2026-08-14.md`; four micro rows (spawn, fixture create+destroy, git status, child status verb). Note: sample 1 of the fixture row includes the one-time template build (script header documents this).

- [ ] **Step 3: Create the protocol timer**

Create `tests/bench/Measure-DevLoop.ps1`:

```powershell
# Cold/warm wall-clock protocol for the 30 s gate (spec D6). Times any command:
#   powershell -File tests/bench/Measure-DevLoop.ps1 -Command "& 'tests/run-dev.ps1'"
# Cold = fresh powershell.exe host per run (only run 1 is OS-cache cold - recorded as such).
# Warm = one host, repeated runs. n=5 p95 is the max; the gate reads worst-of-5-warm.
param(
    [string]$Command = "Import-Module Pester -MinimumVersion 6.0.0; Invoke-Pester -Path tests/fast, tests/Lib.Tests.ps1",
    [int]$ColdRuns = 5,
    [int]$WarmRuns = 5
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Get-Percentile {
    param([double[]]$Samples, [double]$P)
    $s = @($Samples | Sort-Object)
    $idx = [math]::Ceiling($P * $s.Count) - 1
    if ($idx -lt 0) { $idx = 0 }
    return [math]::Round($s[$idx], 3)
}

$cold = @()
for ($i = 1; $i -le $ColdRuns; $i++) {
    $cold += (Measure-Command {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -Command $Command | Out-Null
    }).TotalSeconds
    Write-Output ("cold run {0}: {1:N1} s" -f $i, $cold[-1])
}

# Warm: one child host runs the command WarmRuns+1 times (run 0 warms, discarded),
# printing one duration line per timed run.
$warmScript = "`$ErrorActionPreference='Stop'; & { $Command } | Out-Null; " +
    "1..$WarmRuns | ForEach-Object { ((Measure-Command { & { $Command } | Out-Null }).TotalSeconds).ToString('N3') }"
$warmOut = & powershell.exe -NoProfile -ExecutionPolicy Bypass -Command $warmScript
$warm = @($warmOut | Where-Object { $_ -match '^\d' } | ForEach-Object { [double]$_ })
$warm | ForEach-Object { Write-Output ("warm run: {0:N1} s" -f $_) }

Write-Output ("cold p50 {0} p95 {1} | warm p50 {2} p95 {3} (n={4}, p95=max)" -f `
    (Get-Percentile $cold 0.5), (Get-Percentile $cold 0.95),
    (Get-Percentile $warm 0.5), (Get-Percentile $warm 0.95), $warm.Count)
```

- [ ] **Step 4: Measure the pre-change dev-loop candidate set**

```bash
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/bench/Measure-DevLoop.ps1
```

Expected: ~200-240 s per run based on review measurements (10 runs total: budget ~40 min unattended). Append a `## Dev-loop candidate set (pre-change)` section with the output to `docs/runtime-consolidation/phase4-baseline-2026-08-14.md`, including machine name and the file list timed.

- [ ] **Step 5: Commit**

```bash
git add tests/bench/Measure-Baseline.ps1 tests/bench/Measure-DevLoop.ps1 docs/runtime-consolidation/phase4-baseline-2026-08-14.md
git commit -m "test(phase4): current-box baseline and cold/warm protocol timer"
```

---

### Task 1: MUSTER_DEVLOOP guard + stderr-tolerant capture (TDD)

**Files:**
- Modify: `tests/MusterFixture.ps1:107-129` (`Invoke-Muster`)
- Test: `tests/Harness.Tests.ps1`

- [ ] **Step 1: Write the failing test**

Append inside `Describe 'fixture harness'` in `tests/Harness.Tests.ps1`:

```powershell
    It 'Invoke-Muster refuses to spawn under MUSTER_DEVLOOP' {
        $fx = New-MusterFixture
        try {
            $env:MUSTER_DEVLOOP = '1'
            { Invoke-Muster $fx 'status' } | Should -Throw '*MUSTER_DEVLOOP*'
        }
        finally {
            Remove-Item Env:MUSTER_DEVLOOP -ErrorAction SilentlyContinue
            Remove-MusterFixture $fx
        }
    }
```

- [ ] **Step 2: Run it, verify it fails**

Run: `powershell.exe -NoProfile -Command "Import-Module Pester -MinimumVersion 6.0.0; Invoke-Pester -Path tests/Harness.Tests.ps1"`
Expected: 1 failure - `Invoke-Muster` runs the child instead of throwing.

- [ ] **Step 3: Implement the guard**

In `tests/MusterFixture.ps1`, first lines of `Invoke-Muster`'s body (before `Push-Location $Fixture`):

```powershell
    if ($env:MUSTER_DEVLOOP) {
        throw "Invoke-Muster is forbidden in the dev loop (MUSTER_DEVLOOP set): tried verb '$Verb'"
    }
```

- [ ] **Step 4: Re-run, verify green**

Same command. Expected: all Harness tests pass.

- [ ] **Step 5: Make the capture stderr-tolerant**

`Invoke-Muster` captures the child with `2>&1` while the file-level
`$ErrorActionPreference = 'Stop'` is in force, so a verb child that writes to
stderr (e.g. `claim` outside a git repo - git's `fatal:` line passes through)
raises a terminating `RemoteException` in the harness instead of returning a
result (verified empirically during plan review). Task 8's matrix gap tests
need those children captured. Wrap both engine branches:

```powershell
        $prevEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            if ($env:MUSTER_ENGINE -eq 'sh') {
                # ...existing sh branch unchanged...
                $out = & $sh "tasks/bin/$Verb.sh" @ScriptArgs 2>&1
            }
            else {
                $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "tasks/bin/$Verb.ps1" @ScriptArgs 2>&1
            }
            $code = $LASTEXITCODE
        }
        finally { $ErrorActionPreference = $prevEap }
```

(Keep the existing `Push-Location`/`Pop-Location` frame around it. Stderr
lines arrive as ErrorRecords; the existing `"$_"` stringification already
normalizes them into `Out`/`Text`.) No existing test produces verb-child
stderr, so the suite stays green; this harness change is covered by Task 5's
parity run.

- [ ] **Step 6: Run the black-box suite (ps1) to confirm no behavior change**

Run: `powershell.exe -NoProfile -Command "Import-Module Pester -MinimumVersion 6.0.0; Invoke-Pester -Path tests"`
Expected: 0 failures.

- [ ] **Step 7: Commit**

```bash
git add tests/MusterFixture.ps1 tests/Harness.Tests.ps1
git commit -m "test(phase4): DEVLOOP spawn guard and stderr-tolerant child capture"
```

---

### Task 2: Fast-tier setups go in-process (spec D1)

**Files:**
- Modify: `tests/fast/Done.Fast.Tests.ps1:14,44,68,78,117`
- Modify: `tests/fast/Claim.Fast.Tests.ps1:68-80`

- [ ] **Step 1: Replace the five `Invoke-MusterClaim` sites in Done.Fast.Tests.ps1**

Line 14 (in `Add-ClaimedImpl`) and line 44 (direct), which claim `-Tier any`:

```powershell
            Invoke-MusterInProc $script:fx 'Invoke-ClaimCommand -Harness claude -Tier any' | Out-Null
```

Line 68 (in `Add-ClaimedReview`), line 78 (in `Add-ClaimedIntegration`), and
line 117 (direct - it claims the strong review task `p-02-review-a`), which
all pass `-Tier strong`:

```powershell
            Invoke-MusterInProc $script:fx 'Invoke-ClaimCommand -Harness claude -Tier strong' | Out-Null
```

- [ ] **Step 2: Replace the claim + probe command in Claim.Fast.Tests.ps1**

In `Add-RecoveredTask` (lines 68-80), change the `New-TaskFile` call and the rewrite so the probe verify no longer spawns `powershell.exe`, and the claim runs in-process:

```powershell
        function Add-RecoveredTask {
            New-TaskFile -Fixture $script:fx -Folder inbox -Id 'p-01-a' -CommitPaths @('src/out.txt') `
                -VerifyCmd 'cmd /c type src\out.txt' -ExpectExit '0' -Commit | Out-Null
            $p = Join-Path $script:fx 'tasks/inbox/p-01-a.md'
            $t = [IO.File]::ReadAllText($p) -replace '    expect_exit: 0', "    expect_contains: ""predecessor work"""
            [IO.File]::WriteAllText($p, $t)
            git -c core.autocrlf=false -C $script:fx add 'tasks/inbox/p-01-a.md'
            git -C $script:fx commit -qm 'fixture: tighten verify'
            Invoke-MusterInProc $script:fx 'Invoke-ClaimCommand -Harness claude -Tier any' | Out-Null
            git -C $script:fx mv 'tasks/doing/p-01-a.md' 'tasks/inbox/p-01-a.md'
            git -C $script:fx commit -qm 'human: recover p-01-a'
            Remove-Item (Join-Path $script:fx 'tasks/doing/p-01-a.verify.log') -ErrorAction SilentlyContinue
        }
```

The green probe test writes `'predecessor work'` into `src/out.txt`, so `cmd /c type src\out.txt` output contains it (probe green); with the file absent, `type` exits 1 (probe red). Both existing Its keep their assertions unchanged.

- [ ] **Step 3: Run the fast tier, verify green, record the wall time**

Run: `powershell.exe -NoProfile -Command "Import-Module Pester -MinimumVersion 6.0.0; Invoke-Pester -Path tests/fast"`
Expected: 37 passed, 0 failed. Wall time should drop by roughly 50 s versus Task 0's per-run numbers (11 child claims at ~5.4 s replaced by ~0.9 s in-process claims). Note the number for the comparison doc.

- [ ] **Step 4: Commit**

```bash
git add tests/fast/Done.Fast.Tests.ps1 tests/fast/Claim.Fast.Tests.ps1
git commit -m "test(phase4): fast-tier setups claim in-process, git-free probe cmd"
```

---

### Task 3: Fixture strategy benchmark (spec D2)

**Files:**
- Create: `tests/bench/Measure-Phase4Fixture.ps1`
- Create: `docs/runtime-consolidation/phase4-fixture-2026-08-14.md`

- [ ] **Step 1: Write the benchmark + reuse contract**

Create `tests/bench/Measure-Phase4Fixture.ps1`:

```powershell
# Phase 4 fixture benchmark: per-test cost of the current template-copy strategy vs
# baseline-SHA reset-reuse (one shared dir, git reset --hard <base> + git clean -xfd
# between tests). Pool is excluded by reasoning, not measurement: a pre-built pool
# pays the same per-copy cost as 'copy', only earlier; it can win only by overlapping
# build with execution (async machinery out of scope). Adoption rule (pre-registered,
# Phase 2 precedent): adopt reset-reuse iff its p50 cycle <= 0.70 x copy p50 in both
# passes AND Assert-ReuseFixtureContract passes.
param([int]$Cycles = 20, [int]$Passes = 2)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. (Join-Path $repoRoot 'tests/MusterFixture.ps1')

function Get-P50 { param([double[]]$S) $x = @($S | Sort-Object); $x[[math]::Ceiling(0.5 * $x.Count) - 1] }

function Assert-ReuseFixtureContract {
    # Sequential isolation: everything a test can leave behind (commits - including
    # attempt markers, the Get-AttemptCount hazard - staged changes, untracked files)
    # must vanish on reset. Throws on first violation.
    param([string]$Fixture, [string]$BaseSha)
    New-TaskFile -Fixture $Fixture -Id 'p2-01-a' -Commit | Out-Null
    git -C $Fixture commit -q --allow-empty -m 'muster(p): attempt 1 p2-01-a'
    [IO.File]::WriteAllText((Join-Path $Fixture 'stray.txt'), 'x')
    git -C $Fixture reset --hard -q $BaseSha
    git -C $Fixture clean -xfdq
    $log = @(Get-FixtureCommits $Fixture)
    if ($log.Count -ne 1 -or $log[0] -ne 'fixture: init') {
        throw "reuse contract: history not reset: $($log -join '; ')"
    }
    if (@(git -C $Fixture status --porcelain).Count -ne 0) { throw 'reuse contract: dirty after reset' }
    if (Test-Path (Join-Path $Fixture 'tasks/inbox/p2-01-a.md')) { throw 'reuse contract: task file survived reset' }
    if (Test-Path (Join-Path $Fixture 'stray.txt')) { throw 'reuse contract: untracked file survived clean' }
}

$warm = New-MusterFixture; Remove-MusterFixture $warm   # pay the one-time template build outside both timed loops

foreach ($pass in 1..$Passes) {
    $copy = @()
    foreach ($i in 1..$Cycles) {
        $copy += (Measure-Command { $fx = New-MusterFixture; Remove-MusterFixture $fx }).TotalSeconds
    }
    $shared = New-MusterFixture
    $base = (git -C $shared rev-parse HEAD).Trim()
    $reset = @()
    foreach ($i in 1..$Cycles) {
        # representative dirt: one commit + one untracked file, created outside the timer
        New-TaskFile -Fixture $shared -Id 'p-90-x' -Commit | Out-Null
        [IO.File]::WriteAllText((Join-Path $shared 'stray.txt'), 'x')
        $reset += (Measure-Command {
            git -C $shared reset --hard -q $base
            git -C $shared clean -xfdq
        }).TotalSeconds
    }
    Assert-ReuseFixtureContract -Fixture $shared -BaseSha $base
    Remove-MusterFixture $shared
    $c50 = Get-P50 $copy; $r50 = Get-P50 $reset
    Write-Output ("pass {0}: copy p50 {1:N3} s, reset-reuse p50 {2:N3} s, ratio {3:N2} (adopt if <= 0.70), contract PASS" -f `
        $pass, $c50, $r50, ($r50 / $c50))
}
```

- [ ] **Step 2: Run it**

```bash
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/bench/Measure-Phase4Fixture.ps1
```

Expected: two pass lines with ratios. A `reset+clean` pair of git ops should land well under the ~0.8 s copy cost; contract must print PASS.

- [ ] **Step 3: Write the verdict doc**

Create `docs/runtime-consolidation/phase4-fixture-2026-08-14.md` recording: machine, both pass lines verbatim, the pre-registered rule, the verdict (adopt / keep copy), and the pool-exclusion reasoning from the script header. The verdict decides whether Task 4 executes.

- [ ] **Step 4: Commit**

```bash
git add tests/bench/Measure-Phase4Fixture.ps1 docs/runtime-consolidation/phase4-fixture-2026-08-14.md
git commit -m "test(phase4): fixture reset-reuse benchmark and verdict"
```

---

### Task 4: Adopt shared reset-reuse fixtures in the dev loop (conditional on Task 3 verdict; skip entirely if verdict = keep copy)

**Files:**
- Modify: `tests/MusterFixture.ps1` (new functions)
- Modify: `tests/fast/{Status,Lint,Claim,Done,Verify}.Fast.Tests.ps1` (BeforeEach/AfterEach swap)
- Modify: `tests/Lib.Tests.ps1` (fixture-call swaps only - assertions untouched)
- Test: `tests/Harness.Tests.ps1`

- [ ] **Step 1: Write the failing shared-fixture contract test**

Append to `Describe 'fixture harness'` in `tests/Harness.Tests.ps1`:

```powershell
    It 'New-SharedMusterFixture resets to baseline between tests' {
        $a = New-SharedMusterFixture
        New-TaskFile -Fixture $a -Id 'p2-09-x' -Commit | Out-Null
        git -C $a commit -q --allow-empty -m 'muster(p): attempt 1 p2-09-x'
        [IO.File]::WriteAllText((Join-Path $a 'stray.txt'), 'x')
        $b = New-SharedMusterFixture
        $b | Should -Be $a
        @(Get-FixtureCommits $b).Count | Should -Be 1
        (git -C $b status --porcelain) | Should -BeNullOrEmpty
        Test-Path (Join-Path $b 'stray.txt') | Should -BeFalse
        Remove-SharedMusterFixture
    }
```

- [ ] **Step 2: Run it, verify it fails** (`New-SharedMusterFixture` not defined).

- [ ] **Step 3: Implement in `tests/MusterFixture.ps1`** (after `Remove-MusterFixture`):

```powershell
# Shared reset-reuse fixture (Phase 4, spec D2): one copied fixture per test file,
# reset to its baseline SHA + cleaned between tests. Adopted on the measured verdict
# in docs/runtime-consolidation/phase4-fixture-2026-08-14.md. Leaks one TEMP dir per
# file like the template does (documented, acceptable).
$script:SharedFixture = $null
$script:SharedFixtureBase = $null

function New-SharedMusterFixture {
    if (-not $script:SharedFixture -or -not (Test-Path $script:SharedFixture)) {
        $script:SharedFixture = New-MusterFixture
        $script:SharedFixtureBase = (git -C $script:SharedFixture rev-parse HEAD).Trim()
        return $script:SharedFixture
    }
    git -C $script:SharedFixture reset --hard -q $script:SharedFixtureBase
    git -C $script:SharedFixture clean -xfdq
    return $script:SharedFixture
}

function Remove-SharedMusterFixture {
    if ($script:SharedFixture) {
        Remove-MusterFixture $script:SharedFixture
        $script:SharedFixture = $null
    }
}
```

- [ ] **Step 4: Re-run Harness tests, verify green.**

- [ ] **Step 5: Swap the dev-loop files' per-test fixtures**

In each of `tests/fast/Status.Fast.Tests.ps1`, `Lint.Fast.Tests.ps1`, `Claim.Fast.Tests.ps1`, `Done.Fast.Tests.ps1`, `Verify.Fast.Tests.ps1`, and every fixture-building `BeforeEach` Describe in `tests/Lib.Tests.ps1` (the `BeforeEach { $script:fx = New-MusterFixture }` blocks at lines 201, 246, 273, 340, 369):

replace `$script:fx = New-MusterFixture` with `$script:fx = New-SharedMusterFixture`
and change `AfterEach { Remove-MusterFixture $script:fx }` to `AfterEach { }` (or delete the block). Do NOT touch any `It` body or assertion in `Lib.Tests.ps1` - in particular the `Get-TaskFiles` It builds its own fixture *inside the It body* (line 8) with a `try/finally`; leave it on per-test copy, one copy is negligible.

- [ ] **Step 6: Run the dev-loop candidate set, verify green**

Run: `powershell.exe -NoProfile -Command "Import-Module Pester -MinimumVersion 6.0.0; Invoke-Pester -Path tests/fast, tests/Lib.Tests.ps1"`
Expected: 76 passed, 0 failed. If any test fails on shared state, the reset contract missed a hazard: fix by adding the hazard to `Assert-ReuseFixtureContract` first (TDD), then to the reset. Record wall time.

- [ ] **Step 7: Commit**

```bash
git add tests/MusterFixture.ps1 tests/Harness.Tests.ps1 tests/fast tests/Lib.Tests.ps1
git commit -m "test(phase4): shared reset-reuse fixtures for the dev loop"
```

---

### Task 5: Extract Invoke-PromoteCommand (TDD) + parity run

**Files:**
- Create: `tests/fast/Promote.Fast.Tests.ps1`
- Modify: `runtime/bin/_lib.ps1` (after `Invoke-LintCommand`)
- Modify: `runtime/bin/promote.ps1`

- [ ] **Step 1: Write the failing twin tests**

Create `tests/fast/Promote.Fast.Tests.ps1` (fixture pattern per Task 4 verdict; shown with the shared fixture - use `New-MusterFixture`/`Remove-MusterFixture` in BeforeEach/AfterEach if Task 4 was skipped):

```powershell
BeforeAll {
    . (Join-Path $PSScriptRoot '../MusterFixture.ps1')
    . (Join-Path $PSScriptRoot 'InProcHarness.ps1')
}

Describe 'Invoke-PromoteCommand (in-process)' {
    BeforeEach { $script:fx = New-SharedMusterFixture }

    It 'moves a backlog task whose deps are all in done/ and commits (exit 0, silent)' {
        New-TaskFile -Fixture $script:fx -Folder done -Id 'p-01-a' -Commit | Out-Null
        New-TaskFile -Fixture $script:fx -Folder backlog -Id 'p-02-b' -DependsOn @('p-01-a') -Commit | Out-Null
        $r = Invoke-MusterInProc $script:fx 'Invoke-PromoteCommand'
        $r.ExitCode | Should -Be 0
        Test-Path (Join-Path $script:fx 'tasks/inbox/p-02-b.md') | Should -BeTrue
        (Get-FixtureCommits $script:fx)[0] | Should -Be 'muster: promote 1'
    }
    It 'counts archived deps as satisfied' {
        New-TaskFile -Fixture $script:fx -Folder archive -Id 'p-01-a' -Commit | Out-Null
        New-TaskFile -Fixture $script:fx -Folder backlog -Id 'p-02-b' -DependsOn @('p-01-a') -Commit | Out-Null
        $r = Invoke-MusterInProc $script:fx 'Invoke-PromoteCommand'
        $r.ExitCode | Should -Be 0
        Test-Path (Join-Path $script:fx 'tasks/inbox/p-02-b.md') | Should -BeTrue
    }
    It 'leaves unsatisfied tasks in backlog, exits 0 silently' {
        New-TaskFile -Fixture $script:fx -Folder backlog -Id 'p-02-b' -DependsOn @('p-01-a') -Commit | Out-Null
        $r = Invoke-MusterInProc $script:fx 'Invoke-PromoteCommand'
        $r.ExitCode | Should -Be 0
        Test-Path (Join-Path $script:fx 'tasks/backlog/p-02-b.md') | Should -BeTrue
    }
    It 'with -NoCommit stages the rename without committing' {
        New-TaskFile -Fixture $script:fx -Folder done -Id 'p-01-a' -Commit | Out-Null
        New-TaskFile -Fixture $script:fx -Folder backlog -Id 'p-02-b' -DependsOn @('p-01-a') -Commit | Out-Null
        $r = Invoke-MusterInProc $script:fx 'Invoke-PromoteCommand -NoCommit'
        $r.ExitCode | Should -Be 0
        (git -C $script:fx status --porcelain) | Should -Match 'R  tasks/backlog/p-02-b\.md -> tasks/inbox/p-02-b\.md'
        (Get-FixtureCommits $script:fx)[0] | Should -Not -Match 'promote'
    }
}
```

Note: the silent-success and skip-warning semantics mirror `tests/Promote.Tests.ps1`. The malformed-backlog *warning* twin is deliberately absent here - it is Information-stream divergent until Task 6 decides fold vs child-only.

- [ ] **Step 2: Run, verify all 4 fail** with "Invoke-PromoteCommand is not recognized".

- [ ] **Step 3: Implement the command function**

In `runtime/bin/_lib.ps1`, directly after `Invoke-LintCommand`:

```powershell
function Invoke-PromoteCommand {
    # promote verb (spec 4.4). Returns CommandResult; never writes or exits. Promote
    # is silent on success; warnings stay on Write-Host inside Invoke-Promote so
    # claim/done callers keep a clean return value.
    param([switch]$NoCommit)
    [void](Invoke-Promote -NoCommit:$NoCommit)
    New-CommandResult
}
```

Replace the body of `runtime/bin/promote.ps1` with:

```powershell
# MUSTER promote - spec 4.4. Thin wrapper; logic in _lib.ps1.
param([switch]$NoCommit)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_lib.ps1')

$r = Invoke-CommandBoundary { Invoke-PromoteCommand -NoCommit:$NoCommit }
$r.Output | Write-Output
exit $r.ExitCode
```

- [ ] **Step 4: Run twins + black-box promote, verify green**

Run: `powershell.exe -NoProfile -Command "Import-Module Pester -MinimumVersion 6.0.0; Invoke-Pester -Path tests/fast/Promote.Fast.Tests.ps1, tests/Promote.Tests.ps1"`
Expected: 9 passed (4 twins + 5 black-box).

- [ ] **Step 5: Control-flow verdict + full parity run (covers Tasks 1-5)**

Record the Phase 1/3-style verdict (simpler / equal / worse) for promote in the commit message; `worse` is a stop-and-report condition per the governing plan.

```bash
powershell.exe -NoProfile -Command "Import-Module Pester -MinimumVersion 6.0.0; Invoke-Pester -Path tests; $env:MUSTER_ENGINE='sh'; Invoke-Pester -Path tests; Remove-Item Env:MUSTER_ENGINE"
```

Expected: 0 failures on both arms (~30 min). Counts rise above 161 by the tests added since Phase 3.

- [ ] **Step 6: Commit**

```bash
git add runtime/bin/_lib.ps1 runtime/bin/promote.ps1 tests/fast/Promote.Fast.Tests.ps1
git commit -m "refactor(runtime): extract Invoke-PromoteCommand, promote.ps1 becomes shim"
```

---

### Task 6: Information-stream probe (fold vs child-only)

**Files:**
- Create: `tests/bench/Probe-InfoStream.ps1`
- Possibly modify: `tests/fast/InProcHarness.ps1`

- [ ] **Step 1: Write the probe**

Create `tests/bench/Probe-InfoStream.ps1`:

```powershell
# Phase 4 spec D3: promote's malformed-backlog warning goes through Write-Host
# (Information stream), which the runspace harness drops. Probe: does the warning
# land in $ps.Streams.Information, and do any black-box assertions require its
# ORDER relative to stdout lines (fold-by-append would lose interleaving)?
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. (Join-Path $repoRoot 'tests/MusterFixture.ps1')

$fx = New-MusterFixture
try {
    [IO.File]::WriteAllText((Join-Path $fx 'tasks/backlog/p-03-bad.md'), "---`nid: p-03-bad`n---`nbody")
    git -c core.autocrlf=false -C $fx add 'tasks/backlog/p-03-bad.md'
    git -C $fx commit -qm 'fixture: bad backlog'

    $lib = Join-Path $repoRoot 'runtime/bin/_lib.ps1'
    $ps = [powershell]::Create()
    try {
        [void]$ps.AddScript("Set-Location -LiteralPath '$fx'`n. '$lib'`nInvoke-CommandBoundary { Invoke-PromoteCommand }")
        $out = @($ps.Invoke())
        Write-Output "result output lines: $($out[-1].Output.Count)"
        Write-Output "information records: $($ps.Streams.Information.Count)"
        $ps.Streams.Information | ForEach-Object { Write-Output "  info: $_" }
    }
    finally { $ps.Dispose() }

    $child = Invoke-Muster $fx 'promote'
    Write-Output "child stdout: $($child.Text)"
}
finally { Remove-MusterFixture $fx }
```

- [ ] **Step 2: Run it and decide by the pre-set rule**

```bash
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/bench/Probe-InfoStream.ps1
```

Decision rule: **fold** (append `$ps.Streams.Information` message lines after `Output` in `Invoke-MusterInProc`'s returned result) iff (a) the warning appears in the Information stream, AND (b) `grep` of BOTH `tests/*.Tests.ps1` AND `tests/fast/*.Fast.Tests.ps1` shows no assertion on the warning's position relative to other lines - the fast tier is the actual consumer of `Invoke-MusterInProc` and holds eight position-sensitive `$r.Output[-1]` assertions; folding appends AFTER the terminal line, so verify none of those tests can emit an Information record (today only `Invoke-Promote`'s malformed-backlog warning uses Write-Host, and none of those tests create a malformed backlog file - re-verify at execution time). Otherwise **child-only**: promote-warning rows stay process-tier.

- [ ] **Step 3: If fold: modify `Invoke-MusterInProc`**

In `tests/fast/InProcHarness.ps1` replace `return $out[$out.Count - 1]` with:

```powershell
        $result = $out[$out.Count - 1]
        if ($ps.Streams.Information.Count -gt 0) {
            # Fold Write-Host lines (child stdout shows them; runspace routes them to
            # the Information stream). Order vs Output lines is NOT preserved - folding
            # is valid only while no assertion depends on it (probe, 2026-08-14).
            $folded = @($result.Output) + @($ps.Streams.Information | ForEach-Object { "$_" })
            $result = New-Object psobject -Property @{ Output = $folded; ExitCode = $result.ExitCode }
        }
        return $result
```

Then add the warning twin to `tests/fast/Promote.Fast.Tests.ps1`:

```powershell
    It 'skips malformed backlog files with a warning' {
        [IO.File]::WriteAllText((Join-Path $script:fx 'tasks/backlog/p-03-bad.md'), "---`nid: p-03-bad`n---`nbody")
        git -c core.autocrlf=false -C $script:fx add 'tasks/backlog/p-03-bad.md'
        git -C $script:fx commit -qm 'fixture: bad backlog'
        $r = Invoke-MusterInProc $script:fx 'Invoke-PromoteCommand'
        ($r.Output -join "`n") | Should -Match 'MUSTER warn: backlog/p-03-bad\.md frontmatter invalid - skipped by promote\.'
    }
```

Run `Invoke-Pester -Path tests/fast`, expect green.

- [ ] **Step 4: Record the decision** in `docs/runtime-consolidation/phase4-classification.md` (created properly in Task 7; start the file with a `## Information-stream probe` section holding the probe output and the decision).

- [ ] **Step 5: Commit**

```bash
git add tests/bench/Probe-InfoStream.ps1 tests/fast/InProcHarness.ps1 tests/fast/Promote.Fast.Tests.ps1 docs/runtime-consolidation/phase4-classification.md
git commit -m "test(phase4): information-stream probe and fold decision"
```

---

### Task 7: Classification document

**Files:**
- Modify: `docs/runtime-consolidation/phase4-classification.md`

- [ ] **Step 1: Build the table**

For each of the 23 Describes in `tests/{Claim,Done,Harness,Lib,Lint,LintOverlap,Promote,Status,Verify}.Tests.ps1`, read every It and record:

```markdown
| Describe (file) | Its | Boundary | Twinned | Divergence |
|---|---:|---|---|---|
| bin/claim (Claim.Tests.ps1) | 14 | session-state | 6 of 14 | none |
| ... | | logic / session-state / child-contract | N of M | none / native-stderr / info-stream / failing-native-cmd |
```

Boundary test: what change breaks it - a pure function (logic), a git-state flow (session-state), or child-process semantics such as exit propagation, param binding, merged-stream output (child-contract).

- [ ] **Step 2: Enumerate the failing-native-command class**

For every refusal-path It, trace whether the refusal follows a *failing* native command (the Phase 1 divergence: such refusals throw in a hosted runspace instead of returning a refusal CommandResult - `tests/fast/InProcHarness.ps1:5-10`). Known member: any outside-a-git-repo refusal (`Get-RepoRoot`). Grep aid: `git -C` calls followed by `Write-Refuse` in the same function, plus `2>$null`-masked git calls whose failure feeds a refusal. List members in a dedicated section; each is `Divergence = failing-native-cmd`, twin status `child-only`.

- [ ] **Step 3: Derive the twin worklist**

Under `## Twin worklist`, list every eligible (non-divergent) black-box It with no fast twin, grouped by target fast file. This is Task 9's input. Expected volume per current gaps: Lint ~15, LintOverlap 9, Claim ~8, Done ~9, Verify ~1, Status 0, Promote 0-1.

- [ ] **Step 4: Commit**

```bash
git add docs/runtime-consolidation/phase4-classification.md
git commit -m "docs(phase4): describe-level classification with twin worklist"
```

---

### Task 8: Contract matrix data file, tags, gap tests, inventory, meta-test

**Files:**
- Create: `tests/ContractMatrix.psd1`
- Create: `tests/ProcessContract.Tests.ps1`
- Create: `tests/BlackBoxInventory.psd1`
- Create: `tests/fast/SuiteMeta.Fast.Tests.ps1`
- Modify: tags on `tests/*.Tests.ps1` Its named in the matrix, and on their fast twins

- [ ] **Step 1: Write the matrix data file**

Create `tests/ContractMatrix.psd1`. Draft rows below; Task 7's classification may adjust It choices - the *coverage list* (success + refusal per verb, arg binding x4, ordering + terminal lines, layout, git-failure, carve-outs) is fixed by the spec. `Eligible` means "must have a same-tag fast twin".

```powershell
@{
    Rows = @(
        @{ Id = 'CM-STATUS-OK';    File = 'tests/Status.Tests.ps1';  It = 'prints the status block with the dispatch split and exits 0'; Eligible = $true }
        @{ Id = 'CM-STATUS-FAIL';  File = 'tests/ProcessContract.Tests.ps1'; It = 'status refuses outside a git repository with exit 1';        Eligible = $false }
        @{ Id = 'CM-LINT-OK';      File = 'tests/Lint.Tests.ps1';    It = 'passes a well-formed batch';                                  Eligible = $true }
        @{ Id = 'CM-LINT-FAIL';    File = 'tests/Lint.Tests.ps1';    It = 'check 2: flags id not matching filename and filename collisions'; Eligible = $true }
        @{ Id = 'CM-CLAIM-OK';     File = 'tests/Claim.Tests.ps1';   It = 'claims the lowest eligible filename, stamps claimed_at, commits'; Eligible = $true }
        @{ Id = 'CM-CLAIM-FAIL';   File = 'tests/Claim.Tests.ps1';   It = 'refuses without identity flags';                              Eligible = $false }
        @{ Id = 'CM-DONE-OK';      File = 'tests/Done.Tests.ps1';    It = 'completes an impl task: sidecars in done/, single completion commit, session-over line'; Eligible = $true }
        @{ Id = 'CM-DONE-FAIL';    File = 'tests/Done.Tests.ps1';    It = 'refuses when doing/ is empty';                                Eligible = $true }
        @{ Id = 'CM-VERIFY-OK';    File = 'tests/Verify.Tests.ps1';  It = 'passes a green task and logs attempt 1';                      Eligible = $true }
        @{ Id = 'CM-VERIFY-FAIL';  File = 'tests/Verify.Tests.ps1';  It = 'refuses when doing/ is empty';                                Eligible = $true }
        @{ Id = 'CM-PROMOTE-OK';   File = 'tests/Promote.Tests.ps1'; It = 'moves a backlog task whose deps are all in done/ and commits'; Eligible = $true }
        @{ Id = 'CM-PROMOTE-FAIL'; File = 'tests/ProcessContract.Tests.ps1'; It = 'promote refuses outside a git repository with exit 1';       Eligible = $false }
        @{ Id = 'CM-ARG-CLAIM';    File = 'tests/Claim.Tests.ps1';   It = 'enforces tier pinning both directions';                       Eligible = $true }
        @{ Id = 'CM-ARG-DONE';     File = 'tests/Done.Tests.ps1';    It = 'refuses a verdict on impl tasks and requires one on review tasks'; Eligible = $true }
        @{ Id = 'CM-ARG-LINT';     File = 'tests/Lint.Tests.ps1';    It = 'lite mode: skips 11/12, exempts self-collision, rejects generation'; Eligible = $true }
        @{ Id = 'CM-ARG-PROMOTE';  File = 'tests/Promote.Tests.ps1'; It = 'with -NoCommit stages the rename without committing';         Eligible = $true }
        @{ Id = 'CM-ORDER';        File = 'tests/Claim.Tests.ps1';   It = 'prints the status block before any refusal';                  Eligible = $true }
        @{ Id = 'CM-TERMINAL';     File = 'tests/Done.Tests.ps1';    It = 'prints the counts-only board line directly before the terminal line'; Eligible = $true }
        @{ Id = 'CM-LAYOUT';       File = 'tests/Harness.Tests.ps1'; It = 'New-MusterFixture satisfies the fixture contract';            Eligible = $false }
        @{ Id = 'CM-GITFAIL';      File = 'tests/ProcessContract.Tests.ps1'; It = 'claim refuses outside a git repository with exit 1';         Eligible = $false }
        # forced carve-outs (child-only by measured divergence):
        @{ Id = 'CM-CO-UNCOMMITTED'; File = 'tests/ProcessContract.Tests.ps1'; It = 'done refuses an uncommitted doing task';                   Eligible = $false }
        @{ Id = 'CM-CO-CRLF';        File = 'tests/Done.Tests.ps1';  It = 'commits an executor CRLF commit_path as an LF blob when the repo pins eol=lf'; Eligible = $false }
        @{ Id = 'CM-CO-PROMOTE-WARN'; File = 'tests/Promote.Tests.ps1'; It = 'skips malformed backlog files with a warning';             Eligible = $false }
        @{ Id = 'CM-PROMOTE-WARN-CLAIM'; File = 'tests/ProcessContract.Tests.ps1'; It = 'claim surfaces the promote skip warning for malformed backlog files'; Eligible = $false }
    )
}
```

(If Task 6 decided fold, flip `CM-CO-PROMOTE-WARN` and `CM-PROMOTE-WARN-CLAIM` to `Eligible = $true` and twin them.)

- [ ] **Step 2: Write the gap tests**

Create `tests/ProcessContract.Tests.ps1` (child-process tier; the name avoids
colliding with the in-process "Contract tier" vocabulary). These tests depend
on Task 1 Step 5's stderr-tolerant capture - without it the no-git children
throw `RemoteException` in the harness:

```powershell
BeforeAll { . (Join-Path $PSScriptRoot 'MusterFixture.ps1') }

Describe 'child-process contract gaps (Phase 4 matrix)' {
    BeforeAll {
        function New-NoGitRuntimeDir {
            # Installed tasks/bin layout WITHOUT a git repo - exercises the
            # failing-native-command refusal class (Get-RepoRoot) end to end.
            $dir = Join-Path ([IO.Path]::GetTempPath()) ('muster-nogit-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
            New-Item -ItemType Directory -Path (Join-Path $dir 'tasks/bin') -Force | Out-Null
            Copy-Item (Join-Path $script:RepoRoot 'runtime/bin/*') (Join-Path $dir 'tasks/bin')
            return $dir
        }
    }

    It 'claim refuses outside a git repository with exit 1' -Tag 'CM-GITFAIL' {
        $dir = New-NoGitRuntimeDir
        try {
            $r = Invoke-Muster $dir 'claim' @('-Harness', 'claude', '-Tier', 'any')
            $r.Exit | Should -Be 1
            $r.Text | Should -Match 'MUSTER refuse'
        }
        finally { Remove-Item -Recurse -Force $dir }
    }
    It 'status refuses outside a git repository with exit 1' -Tag 'CM-STATUS-FAIL' {
        $dir = New-NoGitRuntimeDir
        try {
            $r = Invoke-Muster $dir 'status'
            $r.Exit | Should -Be 1
            $r.Text | Should -Match 'MUSTER refuse'
        }
        finally { Remove-Item -Recurse -Force $dir }
    }
    It 'promote refuses outside a git repository with exit 1' -Tag 'CM-PROMOTE-FAIL' {
        $dir = New-NoGitRuntimeDir
        try {
            $r = Invoke-Muster $dir 'promote'
            $r.Exit | Should -Be 1
            $r.Text | Should -Match 'MUSTER refuse'
        }
        finally { Remove-Item -Recurse -Force $dir }
    }
    It 'done refuses an uncommitted doing task' -Tag 'CM-CO-UNCOMMITTED' {
        $fx = New-MusterFixture
        try {
            New-TaskFile -Fixture $fx -Folder doing -Id 'p-01-a' `
                -ExtraFront @('claimed_at: 2026-08-01T00:00:00Z') | Out-Null   # deliberately NOT committed
            $r = Invoke-Muster $fx 'done'
            $r.Exit | Should -Be 1
            $r.Text | Should -Match 'MUSTER refuse'
        }
        finally { Remove-MusterFixture $fx }
    }
    It 'claim surfaces the promote skip warning for malformed backlog files' -Tag 'CM-PROMOTE-WARN-CLAIM' {
        $fx = New-MusterFixture
        try {
            [IO.File]::WriteAllText((Join-Path $fx 'tasks/backlog/p-03-bad.md'), "---`nid: p-03-bad`n---`nbody")
            git -c core.autocrlf=false -C $fx add 'tasks/backlog/p-03-bad.md'
            git -C $fx commit -qm 'fixture: bad backlog'
            New-TaskFile -Fixture $fx -Folder inbox -Id 'p-01-a' -Commit | Out-Null
            $r = Invoke-Muster $fx 'claim' @('-Harness', 'claude', '-Tier', 'any')
            $r.Text | Should -Match 'MUSTER warn: backlog/p-03-bad\.md frontmatter invalid - skipped by promote\.'
        }
        finally { Remove-MusterFixture $fx }
    }
}
```

Run each new It once; where a `-Match 'MUSTER refuse'` is looser than the actual line, tighten it to the observed refusal text.

- [ ] **Step 3: Tag the existing black-box Its and their twins**

For every matrix row pointing at an existing file, add `-Tag '<Id>'` to that It's declaration (e.g. `It 'passes a well-formed batch' -Tag 'CM-LINT-OK' {`). For every `Eligible = $true` row, add the same tag to its fast twin It (create the twin in Task 9 if missing - tag then).

- [ ] **Step 4: Generate the inventory**

Run this snippet and paste its output into `tests/BlackBoxInventory.psd1`:

```powershell
Import-Module Pester -MinimumVersion 6.0.0
$conf = New-PesterConfiguration
$conf.Run.Path = @(Get-ChildItem tests -Filter '*.Tests.ps1' | ForEach-Object FullName)
$conf.Run.SkipRun = $true
$conf.Run.PassThru = $true
$res = Invoke-Pester -Configuration $conf
function Measure-Block { param($B) $n = $B.Tests.Count; foreach ($x in $B.Blocks) { $n += Measure-Block $x }; $n }
"@{"
foreach ($c in $res.Containers) {
    $its = 0; foreach ($b in $c.Blocks) { $its += Measure-Block $b }
    "    '$(Split-Path $c.Item -Leaf)' = @{ Describes = $($c.Blocks.Count); Its = $its }"
}
"}"
```

- [ ] **Step 5: Write the meta-test**

Create `tests/fast/SuiteMeta.Fast.Tests.ps1`:

```powershell
# Growth-freeze + matrix enforcement (spec D4). Discovery-only: SkipRun executes no
# test bodies and no fixture setup. The nested discovery pass over ~20 files costs
# ~5-6 s wall (plan-review measurement), so this file is CHECKPOINT tier: run by
# run-full.ps1 and standalone, deliberately excluded from run-dev.ps1's file list.
BeforeAll {
    $script:RepoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $script:Matrix = (Import-PowerShellDataFile (Join-Path $script:RepoRoot 'tests/ContractMatrix.psd1')).Rows
    $script:Inventory = Import-PowerShellDataFile (Join-Path $script:RepoRoot 'tests/BlackBoxInventory.psd1')

    function Get-BlockTests {
        param($Block, [string]$File, [System.Collections.ArrayList]$Acc)
        foreach ($t in $Block.Tests) {
            [void]$Acc.Add([pscustomobject]@{ File = $File; Name = $t.Name; Tags = @($t.Tag) })
        }
        foreach ($nb in $Block.Blocks) { Get-BlockTests $nb $File $Acc }
    }
    $paths = @(Get-ChildItem (Join-Path $script:RepoRoot 'tests') -Filter '*.Tests.ps1' | ForEach-Object FullName)
    $paths += @(Get-ChildItem (Join-Path $script:RepoRoot 'tests/fast') -Filter '*.Fast.Tests.ps1' | ForEach-Object FullName)
    $conf = New-PesterConfiguration
    $conf.Run.Path = $paths
    $conf.Run.SkipRun = $true
    $conf.Run.PassThru = $true
    $res = Invoke-Pester -Configuration $conf
    $acc = New-Object System.Collections.ArrayList
    foreach ($c in $res.Containers) {
        $leaf = Split-Path $c.Item -Leaf
        foreach ($b in $c.Blocks) { Get-BlockTests $b $leaf $acc }
    }
    $script:BlackBox = @($acc | Where-Object { $_.File -notlike '*.Fast.Tests.ps1' })
    $script:Fast = @($acc | Where-Object { $_.File -like '*.Fast.Tests.ps1' })
}

Describe 'suite meta: contract matrix and growth freeze' {
    It 'every matrix row tags exactly one black-box It in the declared file' {
        foreach ($row in $script:Matrix) {
            $hits = @($script:BlackBox | Where-Object { $_.Tags -contains $row.Id })
            $hits.Count | Should -Be 1 -Because "row $($row.Id)"
            $hits[0].File | Should -Be (Split-Path $row.File -Leaf) -Because "row $($row.Id)"
        }
    }
    # -Skip until Task 9 lands the missing twins (CM-LINT-FAIL, CM-ARG-LINT,
    # CM-TERMINAL have no twin yet at Task 8); Task 9 Step 4 removes the -Skip.
    # Keeps every intermediate commit green (spec exit criterion 4).
    It 'every eligible matrix row has a same-tag fast twin' -Skip {
        foreach ($row in @($script:Matrix | Where-Object { $_.Eligible })) {
            @($script:Fast | Where-Object { $_.Tags -contains $row.Id }).Count |
                Should -BeGreaterOrEqual 1 -Because "row $($row.Id)"
        }
    }
    It 'the black-box inventory matches discovery (growth freeze)' {
        $byFile = $script:BlackBox | Group-Object File
        foreach ($file in $script:Inventory.Keys) {
            $found = @($byFile | Where-Object Name -eq $file)
            $found.Count | Should -Be 1 -Because $file
            $found[0].Count | Should -Be $script:Inventory[$file].Its -Because "$file It count - new black-box tests require a deliberate inventory update"
        }
        @($byFile).Count | Should -Be @($script:Inventory.Keys).Count -Because 'no untracked black-box files'
    }
}
```

- [ ] **Step 6: Run the meta-test and the tagged files, verify green**

Run: `powershell.exe -NoProfile -Command "Import-Module Pester -MinimumVersion 6.0.0; Invoke-Pester -Path tests/fast/SuiteMeta.Fast.Tests.ps1, tests/ProcessContract.Tests.ps1"`
Expected: all pass, 1 skipped (the eligible-twin It - un-skipped in Task 9). Also verify tag filtering runs: `Invoke-Pester -Path tests -TagFilter 'CM-GITFAIL'` runs exactly 1 test (Pester 6 takes `-TagFilter`, not `-Tag`).

- [ ] **Step 7: Commit**

```bash
git add tests/ContractMatrix.psd1 tests/ProcessContract.Tests.ps1 tests/BlackBoxInventory.psd1 tests/fast/SuiteMeta.Fast.Tests.ps1 tests
git commit -m "test(phase4): contract matrix, gap tests, inventory, suite meta-test"
```

---

### Task 9: Twin migration

**Files:**
- Create: `tests/fast/LintOverlap.Fast.Tests.ps1`
- Modify: `tests/fast/Lint.Fast.Tests.ps1`, `Claim.Fast.Tests.ps1`, `Done.Fast.Tests.ps1`, `Verify.Fast.Tests.ps1`

Work from Task 7's twin worklist. Translation rules (mechanical, per twin):

| Black-box form | Twin form |
|---|---|
| `Invoke-Muster $fx '<verb>' @(args)` | `Invoke-MusterInProc $fx 'Invoke-<Verb>Command <params>'` |
| `Invoke-MusterLint $fx @(paths) [-Lite]` | `Invoke-MusterInProc $fx "Invoke-LintCommand [-Lite] -Paths @('...')"` |
| `$r.Exit` | `$r.ExitCode` |
| `$r.Out` (line array) | `$r.Output` |
| `$r.Text` | `($r.Output -join "`n")` |
| assertions | identical text, unchanged |

Same tag as the black-box It where the matrix names it. Fixture pattern follows Task 4's verdict.

- [ ] **Step 1: Create `tests/fast/LintOverlap.Fast.Tests.ps1`** - all 9 overlap Its are pure lint logic (eligible). Header and first two twins, remaining 7 translate identically from `tests/LintOverlap.Tests.ps1`:

```powershell
BeforeAll {
    . (Join-Path $PSScriptRoot '../MusterFixture.ps1')
    . (Join-Path $PSScriptRoot 'InProcHarness.ps1')
}

Describe 'Invoke-LintCommand - commit_paths overlap (in-process, D32)' {
    BeforeEach { $script:fx = New-SharedMusterFixture }

    It 'FAILs two impl tasks sharing a commit_path with no ordering' {
        $a = New-TaskFile -Fixture $script:fx -Folder backlog -Id 'p-01-a' -CommitPaths @('src/shared.txt')
        $b = New-TaskFile -Fixture $script:fx -Folder backlog -Id 'p-02-b' -CommitPaths @('src/shared.txt')
        $r = Invoke-MusterInProc $script:fx "Invoke-LintCommand -Paths @('tasks/backlog/p-01-a.md','tasks/backlog/p-02-b.md')"
        $r.ExitCode | Should -Be 1
        ($r.Output -join "`n") | Should -Match 'overlap'
    }
    It 'passes disjoint commit_paths with no ordering' {
        $a = New-TaskFile -Fixture $script:fx -Folder backlog -Id 'p-01-a' -CommitPaths @('src/a.txt')
        $b = New-TaskFile -Fixture $script:fx -Folder backlog -Id 'p-02-b' -CommitPaths @('src/b.txt')
        $r = Invoke-MusterInProc $script:fx "Invoke-LintCommand -Paths @('tasks/backlog/p-01-a.md','tasks/backlog/p-02-b.md')"
        ($r.Output -join "`n") | Should -Not -Match 'overlap'
    }
}
```

Two constraints the originals encode (plan-review finding B3 - do not deviate):
check 15 (overlap) is **skipped under `-Lite`** (`_lib.ps1`, `if (-not $Lite)`),
so overlap twins must NOT pass `-Lite`; and a minimal 2-task batch always exits
1 via check 11 (one seq-99 integration task required - documented at
`tests/LintOverlap.Tests.ps1:7-10`), so pass-cases assert *absence of the
overlap finding*, never `ExitCode 0`. Before writing the remaining 7, open
`tests/LintOverlap.Tests.ps1` and mirror each It's exact setup (task shapes,
ordering edges) and assertion text verbatim - the originals are the source of
truth, including their exact `Should -Match` regexes.

- [ ] **Step 2: Expand `tests/fast/Lint.Fast.Tests.ps1`** with the untwinned eligible Lint Its from the worklist (~15: checks 2-5, 5b, 7-10, 13, 14 variants, B1 schema). Mirror `tests/Lint.Tests.ps1` setups the same way. Note Lint black-box builds batches with `New-TaskFile`; reuse those calls verbatim, swap only the invoke + result properties.

- [ ] **Step 3: Fill the remaining worklist files** (`Claim.Fast`, `Done.Fast`, `Verify.Fast`) the same way. Divergent Its (worklist marks them child-only) are skipped, not approximated.

- [ ] **Step 4: Un-skip the meta-test's eligible-twin It, run the full fast tier, verify green**

Remove the `-Skip` (and its comment) from `'every eligible matrix row has a same-tag fast twin'` in `tests/fast/SuiteMeta.Fast.Tests.ps1`, then:

Run: `powershell.exe -NoProfile -Command "Import-Module Pester -MinimumVersion 6.0.0; Invoke-Pester -Path tests/fast"`
Expected: 0 failures, 0 skipped; the eligible-twin assertion now passes for every eligible row.

- [ ] **Step 5: Commit** (one commit per file is fine; final state)

```bash
git add tests/fast
git commit -m "test(phase4): twin migration per classification worklist"
```

---

### Task 10: Dev-loop runner + instrumentation

**Files:**
- Modify: `tests/MusterFixture.ps1` (stopwatch accumulators)
- Modify: `runtime/bin/_lib.ps1` (`Invoke-VerifyEntry` guarded accumulator)
- Create: `tests/run-dev.ps1`

- [ ] **Step 1: Add stopwatch accumulators**

In `tests/MusterFixture.ps1`, near the top (after `$script:RepoRoot`):

```powershell
# Phase 4 decomposition (spec D6): process-global accumulators - each test file
# dot-sources its own copy of this script, so $script: scope would be per-file.
if (-not (Get-Variable -Name MusterFixtureSeconds -Scope Global -ErrorAction SilentlyContinue)) {
    $global:MusterFixtureSeconds = 0.0
    $global:MusterTemplateSeconds = 0.0
}
```

Wrap the template build inside `New-MusterFixture`:

```powershell
    if (-not $script:FixtureTemplate) {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $script:FixtureTemplate = New-MusterFixtureFromScratch
        $global:MusterTemplateSeconds += $sw.Elapsed.TotalSeconds
    }
```

Wrap the copy in `New-MusterFixture`, the delete in `Remove-MusterFixture`, and the reset in `New-SharedMusterFixture` (if Task 4 ran) the same way, accumulating into `$global:MusterFixtureSeconds`:

```powershell
    $sw = [Diagnostics.Stopwatch]::StartNew()
    # ...existing body...
    $global:MusterFixtureSeconds += $sw.Elapsed.TotalSeconds
```

- [ ] **Step 1b: Count verify-entry child time (spec D6/D7 - F must include it)**

In `runtime/bin/_lib.ps1`, wrap the process-run section of `Invoke-VerifyEntry`
with a stopwatch and accumulate ONLY when the sink variable exists (zero
behavior or dependency change when it does not - plain runs never define it):

```powershell
    $vsw = [Diagnostics.Stopwatch]::StartNew()
    # ...existing [System.Diagnostics.Process] start/wait/kill body...
    if (Get-Variable -Name MusterVerifySeconds -Scope Global -ErrorAction SilentlyContinue) {
        $global:MusterVerifySeconds += $vsw.Elapsed.TotalSeconds
    }
```

This touches `runtime/bin/` - covered by the Task 13 final parity run.

- [ ] **Step 2: Create `tests/run-dev.ps1`**

```powershell
# Phase 4 dev-loop runner (spec D6). Serial by default with cost decomposition;
# -Parallel runs file-level Start-Job workers (wall + per-job walls only).
param([switch]$Parallel, [int]$Workers = 5)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module Pester -MinimumVersion 6.0.0
$repoRoot = Split-Path $PSScriptRoot -Parent

# Explicit dev-loop membership (spec: tier model). Directory globs cannot express
# this set - Lib.Tests.ps1 lives beside the black-box files.
$devFiles = @(
    'tests/fast/CommandCore.Fast.Tests.ps1'
    'tests/fast/Status.Fast.Tests.ps1'
    'tests/fast/Lint.Fast.Tests.ps1'
    'tests/fast/LintOverlap.Fast.Tests.ps1'
    'tests/fast/Claim.Fast.Tests.ps1'
    'tests/fast/Done.Fast.Tests.ps1'
    'tests/fast/Verify.Fast.Tests.ps1'
    'tests/fast/Promote.Fast.Tests.ps1'
    # SuiteMeta.Fast.Tests.ps1 deliberately EXCLUDED: its nested discovery pass
    # costs ~5-6 s (plan-review measurement) - checkpoint tier via run-full.ps1.
    'tests/Lib.Tests.ps1'
) | ForEach-Object { Join-Path $repoRoot $_ }

$env:MUSTER_DEVLOOP = '1'
try {
    $wall = [Diagnostics.Stopwatch]::StartNew()
    if (-not $Parallel) {
        $global:MusterFixtureSeconds = 0.0
        $global:MusterTemplateSeconds = 0.0
        $global:MusterVerifySeconds = 0.0
        $conf = New-PesterConfiguration
        $conf.Run.Path = $devFiles
        $conf.Run.PassThru = $true
        $res = Invoke-Pester -Configuration $conf
        $wall.Stop()
        $exec = ($res.Tests | ForEach-Object { $_.Duration.TotalSeconds } | Measure-Object -Sum).Sum
        $line = ("dev-loop serial: wall {0:N1} s | fixture {1:N1} s | template {2:N1} s | verify-children {3:N1} s | It-exec {4:N1} s | passed {5} failed {6}" -f `
            $wall.Elapsed.TotalSeconds, $global:MusterFixtureSeconds, $global:MusterTemplateSeconds, $global:MusterVerifySeconds, $exec, $res.PassedCount, $res.FailedCount)
        Write-Output $line
        # Measure-DevLoop pipes this process's stdout to Out-Null - persist the
        # decomposition where Task 12 can read it back.
        Add-Content -Path (Join-Path ([IO.Path]::GetTempPath()) 'muster-devloop.log') -Value ("{0}  {1}" -f (Get-Date -Format s), $line)
        if ($res.FailedCount -gt 0) { exit 1 }
    }
    else {
        $pending = [System.Collections.Queue]::new($devFiles)
        $running = @()
        $results = @()
        while ($pending.Count -gt 0 -or $running.Count -gt 0) {
            while ($pending.Count -gt 0 -and $running.Count -lt $Workers) {
                $file = $pending.Dequeue()
                $jobTemp = Join-Path ([IO.Path]::GetTempPath()) ('muster-job-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
                New-Item -ItemType Directory -Path $jobTemp | Out-Null
                $running += Start-Job -ScriptBlock {
                    param($File, $JobTemp)
                    $env:MUSTER_DEVLOOP = '1'
                    $env:TEMP = $JobTemp
                    $env:TMP = $JobTemp
                    Import-Module Pester -MinimumVersion 6.0.0
                    $sw = [Diagnostics.Stopwatch]::StartNew()
                    $conf = New-PesterConfiguration
                    $conf.Run.Path = $File
                    $conf.Run.PassThru = $true
                    $res = Invoke-Pester -Configuration $conf
                    [pscustomobject]@{
                        File    = Split-Path $File -Leaf
                        Seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1)
                        Passed  = $res.PassedCount
                        Failed  = $res.FailedCount
                        Temp    = $JobTemp
                    }
                } -ArgumentList $file, $jobTemp
            }
            $done = Wait-Job -Job $running -Any
            $results += Receive-Job -Job $done
            Remove-Job -Job $done
            $running = @($running | Where-Object { $_.Id -ne $done.Id })
        }
        $wall.Stop()
        $results | Sort-Object Seconds -Descending | ForEach-Object {
            Write-Output ("  {0}: {1} s (passed {2}, failed {3})" -f $_.File, $_.Seconds, $_.Passed, $_.Failed)
            Remove-Item -Recurse -Force $_.Temp -ErrorAction SilentlyContinue
        }
        $failed = ($results | Measure-Object Failed -Sum).Sum
        Write-Output ("dev-loop parallel ({0} workers): wall {1:N1} s | passed {2} failed {3}" -f `
            $Workers, $wall.Elapsed.TotalSeconds, ($results | Measure-Object Passed -Sum).Sum, $failed)
        if ($failed -gt 0) { exit 1 }
    }
}
finally { Remove-Item Env:MUSTER_DEVLOOP -ErrorAction SilentlyContinue }
exit 0
```

- [ ] **Step 3: Run serially, verify**

```bash
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/run-dev.ps1
```

Expected: one `dev-loop serial:` line, 0 failed, fixture/template/exec components printed, and no `Invoke-Muster` throw (proving the dev loop is verb-child free).

- [ ] **Step 4: Run parallel once, verify it completes green** (numbers come in Task 12).

- [ ] **Step 5: Commit**

```bash
git add tests/MusterFixture.ps1 runtime/bin/_lib.ps1 tests/run-dev.ps1
git commit -m "test(phase4): dev-loop runner with decomposition and parallel lever"
```

---

### Task 11: Full-suite runner

**Files:**
- Create: `tests/run-full.ps1`

- [ ] **Step 1: Create it**

```powershell
# Both-engine full-suite runner (spec: checkpoint enforcement). Required before
# merging any branch touching runtime/bin/; also the verify entry on this plan's
# own integration task. The fast tier runs on both arms (engine-independent) to
# keep totals comparable with the recorded parity numbers.
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module Pester -MinimumVersion 6.0.0
$repoRoot = Split-Path $PSScriptRoot -Parent
$rows = @()
foreach ($engine in @('ps1', 'sh')) {
    if ($engine -eq 'sh') { $env:MUSTER_ENGINE = 'sh' }
    else { Remove-Item Env:MUSTER_ENGINE -ErrorAction SilentlyContinue }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $conf = New-PesterConfiguration
    $conf.Run.Path = (Join-Path $repoRoot 'tests')
    $conf.Run.PassThru = $true
    $res = Invoke-Pester -Configuration $conf
    $rows += [pscustomobject]@{ Engine = $engine; Passed = $res.PassedCount; Failed = $res.FailedCount; Seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1) }
}
Remove-Item Env:MUSTER_ENGINE -ErrorAction SilentlyContinue
$rows | ForEach-Object { Write-Output ("{0}: passed {1} failed {2} in {3} s" -f $_.Engine, $_.Passed, $_.Failed, $_.Seconds) }
if (($rows | Measure-Object Failed -Sum).Sum -gt 0) { exit 1 }
exit 0
```

- [ ] **Step 2: Run it once end to end** (~30 min). Expected: `failed 0` on both lines.

- [ ] **Step 3: Commit**

```bash
git add tests/run-full.ps1
git commit -m "test(phase4): both-engine full-suite checkpoint runner"
```

---

### Task 12: Gate measurement (serial, then parallel if needed)

**Files:**
- Modify: `docs/runtime-consolidation/phase4-comparison-2026-08-14.md` (create)
- Conditional: split `tests/Lib.Tests.ps1`

- [ ] **Step 1: Serial protocol run**

```bash
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/bench/Measure-DevLoop.ps1 -Command "& 'tests/run-dev.ps1'"
```

Record cold/warm populations into the comparison doc, and copy the serial decomposition lines from `$env:TEMP\muster-devloop.log` (Measure-DevLoop swallows the runner's stdout; the runner appends each decomposition line there). Gate check: warm p95 (= worst of 5) <= 30 s.

- [ ] **Step 2: If serial misses - parallel protocol run**

```bash
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/bench/Measure-DevLoop.ps1 -Command "& 'tests/run-dev.ps1' -Parallel"
```

Gate metric = end-to-end runner wall (job-host spawn and per-job warm-up included, per spec Decision 7 rationale). Record per-job walls: they show the slowest-file bound.

- [ ] **Step 3: If parallel misses AND the slowest job is `Lib.Tests.ps1` by a margin that covers the gap** - split it:

Move the three git-heavy Describes (`Invoke-VerifyBlock`, `Get-AttemptCount`, `completion machinery`) verbatim - assertions unchanged - into a new `tests/LibGit.Tests.ps1` with the same `BeforeAll` dot-source header as `Lib.Tests.ps1`; add the new file to `$devFiles` in `tests/run-dev.ps1` and to the inventory in `tests/BlackBoxInventory.psd1`; re-run `tests/run-full.ps1` (harness-level change - parity gate). Then re-measure Step 2. At most one more rebalance iteration; then stop and record.

- [ ] **Step 4: One instrumented serial pass for the D7 split**

Single-quoted outer strings - a double-quoted `-Command "..."` would let the
*invoking* shell expand `$env:...` and `$_` before powershell.exe ever sees
them (plan-review finding B4, verified broken):

```bash
powershell.exe -NoProfile -Command '$env:GIT_TRACE_PERFORMANCE = Join-Path ([IO.Path]::GetTempPath()) "muster-git-perf.log"; & tests/run-dev.ps1; Remove-Item Env:GIT_TRACE_PERFORMANCE'
```

Then sum git wall time:

```bash
powershell.exe -NoProfile -Command '(Select-String -Path (Join-Path ([IO.Path]::GetTempPath()) "muster-git-perf.log") -Pattern "performance: ([\d\.]+) s" | ForEach-Object { [double]$_.Matches[0].Groups[1].Value } | Measure-Object -Sum).Sum'
```

**F/A with the double-count bracket** (git children spawned BY verify entries
appear in both `git seconds` and `verify-children seconds`, and the two cannot
be cleanly separated):

- `F_low`  = git seconds + fixture seconds + template seconds
- `F_high` = F_low + verify-children seconds
- `A_low`  = serial warm wall - F_high; `A_high` = serial warm wall - F_low

Pre-registered conservative application (fixed here, before measurement):
D7 rule 1 (floor exceeds gate, renegotiate) fires only if **F_low** > 30 s;
D7 rule 2 (speed case for C# established) fires only if it holds with
**A_low** (i.e. even the smallest C#-addressable estimate closes the gap).
Both directions resist over-claiming. Record all four numbers.

- [ ] **Step 5: Commit**

```bash
git add docs/runtime-consolidation/phase4-comparison-2026-08-14.md
git commit -m "docs(phase4): gate measurement with cost decomposition"
```

---

### Task 13: Verdict, plan Result block, final parity

**Files:**
- Modify: `docs/runtime-consolidation/phase4-comparison-2026-08-14.md`
- Modify: `docs/test-speed-consolidation-plan.md` (Phase 4 Result block)

- [ ] **Step 1: Apply the pre-registered D7 rule** to the measured F/A bracket (Task 12 Step 4's F_low/F_high, A_low/A_high and its conservative application), in the comparison doc, quoting the rule verbatim from the spec and showing the arithmetic. Outcome is one of: gate met / floor exceeds gate (renegotiate, C# not revived on speed) / speed case for C# established.

- [ ] **Step 2: Final parity run**

```bash
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/run-full.ps1
```

Expected: `failed 0` both engines. Paste both lines into the comparison doc.

- [ ] **Step 3: Write the Phase 4 Result block** in `docs/test-speed-consolidation-plan.md` after the Phase 4 exit line, following the Phase 1-3 Result format: what shipped, the gate numbers (cold/warm p50/p95, serial and parallel), the D7 outcome, and pointers to the four phase4-*.md docs.

- [ ] **Step 4: Commit**

```bash
git add docs/test-speed-consolidation-plan.md docs/runtime-consolidation/phase4-comparison-2026-08-14.md
git commit -m "docs(phase4): record Phase 4 result and gate verdict"
```

---

## Not yet specified

- Parallel-runner ergonomics beyond pass/fail counts and per-job walls
  (interleaved output, failure attribution UX). Refine only if `-Parallel`
  becomes the daily driver.
- Which additional refusal paths join the failing-native-command class -
  Task 7 Step 2's output, not guessable here.
- The exact twin worklist volume - Task 7 Step 3's output; Task 9 sizes to it.

## Out of scope

- Shell-support ADR and Git hardening (Phase 5, per the governing plan).
- Single-source parameterized test rewrite (post-gate option, spec D5).
- Spec D1's fallback (pre-claimed template family, six shapes): implemented
  only if the in-process claim setups show divergence in practice - that
  would be a plan amendment, not a silent step.
- Spec D2's pool candidate: excluded by reasoning (same per-copy cost as
  'copy', only paid earlier; wins only via async overlap machinery), recorded
  in the Task 3 script header and verdict doc instead of benchmarked.
- PS7 / Pester 6 native parallel orchestration (only if `Start-Job` proves insufficient).
- CI infrastructure (none exists; `run-full.ps1` + the parity-before-merge rule are the mechanism).
- Upgrading the repo's own pinned `tasks/bin` install (board self-hosting, not test speed).
- NGen or machine tuning.
