# Phase 4 fixture benchmark: per-test cost of the current template-copy strategy vs
# baseline-SHA reset-reuse (one shared dir, git reset --hard <base> + git clean -xfd
# between tests). Pool is excluded by reasoning, not measurement: a pre-built pool
# pays the same per-copy cost as 'copy', only earlier; it can win only by overlapping
# build with execution (async machinery out of scope). Adoption rule (pre-registered,
# Phase 2 precedent): adopt reset-reuse iff its p50 cycle <= 0.70 x copy p50 in both
# passes AND Assert-ReuseFixtureContract passes.
#
# Deliberately NOT built on tests/bench/FixtureStrategies.ps1's strategy map:
# Assert-FixtureContract holds TWO fixtures live simultaneously to prove
# independent mutation - a single shared reset-reuse dir fails that shape by
# construction. The reuse contract is sequential (Assert-ReuseFixtureContract
# below); same justified-duplicate convention as Measure-Fixture.ps1's header.
param([int]$Cycles = 20, [int]$Passes = 2)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. (Join-Path $repoRoot 'tests/MusterFixture.ps1')
. (Join-Path $PSScriptRoot 'BenchCommon.ps1')

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
    $c50 = Get-Percentile -Samples $copy -P 0.5; $r50 = Get-Percentile -Samples $reset -P 0.5
    Write-Output ("pass {0}: copy p50 {1:N3} s, reset-reuse p50 {2:N3} s, ratio {3:N2} (adopt if <= 0.70), contract PASS" -f `
        $pass, $c50, $r50, ($r50 / $c50))
}
