# Phase 2 fixture-strategy benchmark. Contract-checks AND times every candidate
# (a contract failure disqualifies from adoption but the strategy is still timed
# for the record - the spec says benchmark all four). Two independent passes per
# strategy so the adoption decision rests on repeated evidence.
# Run from repo root, Windows PowerShell 5.1 host:
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/bench/Measure-Fixture.ps1
# Takes roughly 3-5 minutes. WARNING: overwrites its output file.
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# Fixed measurement config - vary in source if a future phase needs it.
$RunsPerPass = 20
$Passes      = 2
$OutFile     = 'docs/runtime-consolidation/fixture-comparison-2026-08-13.md'

# A leaked MUSTER_ENGINE=sh would route the contract's Invoke-Muster call to the
# sh engine; keep the doc ps1-labeled and exact.
Remove-Item Env:MUSTER_ENGINE -ErrorAction SilentlyContinue

$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. (Join-Path $repoRoot 'tests/MusterFixture.ps1')
. (Join-Path $PSScriptRoot 'FixtureStrategies.ps1')

# Intentional duplicate of Measure-Baseline.ps1's Get-Percentile: that script
# runs its whole benchmark on load, so it cannot be dot-sourced for 7 lines.
function Get-Percentile {
    param([double[]]$Samples, [double]$P)
    $s = @($Samples | Sort-Object)
    $idx = [math]::Ceiling($P * $s.Count) - 1
    if ($idx -lt 0) { $idx = 0 }
    return [math]::Round($s[$idx], 3)
}

$templateCost = (Measure-Command { $template = New-MusterFixture }).TotalSeconds
$strategies   = Get-FixtureStrategies

$rows   = @()
$failed = @()
try {
    foreach ($name in $strategies.Keys) {
        $s = $strategies[$name]
        try {
            Assert-FixtureContract -NewFixture $s.New -RemoveFixture $s.Remove -Template $template
        }
        catch {
            $failed += [pscustomobject]@{ Strategy = $name; Reason = "$_" }
        }
        foreach ($pass in 1..$Passes) {
            $samples = @()
            for ($i = 1; $i -le $RunsPerPass; $i++) {
                $samples += (Measure-Command {
                    $d = & $s.New $template
                    & $s.Remove $template $d
                }).TotalSeconds
            }
            $rows += [pscustomobject]@{
                Strategy = $name
                Pass     = $pass
                P50      = Get-Percentile -Samples $samples -P 0.50
                P95      = Get-Percentile -Samples $samples -P 0.95
                All      = ($samples | ForEach-Object { [math]::Round($_, 3) }) -join ', '
            }
        }
    }
}
finally {
    Remove-MusterFixture $template
}

# The timing loop above appends rows unconditionally for every strategy, so the
# init rows always exist here (contract failures land in $failed, not a throw).
$initBest = ($rows | Where-Object { $_.Strategy -eq 'init' } |
    Measure-Object -Property P50 -Minimum).Minimum

# Decision rule fixed in the plan: material = contract passed AND both passes
# p50 <= 0.7 * best init p50.
$verdicts = @()
foreach ($name in ($strategies.Keys | Where-Object { $_ -ne 'init' })) {
    $fail  = $failed | Where-Object { $_.Strategy -eq $name }
    $mine  = @($rows | Where-Object { $_.Strategy -eq $name })
    $worst = ($mine | Measure-Object -Property P50 -Maximum).Maximum
    $ratio = [math]::Round($worst / $initBest, 2)
    if ($fail) {
        $verdicts += "- **${name}:** DISQUALIFIED (contract: $($fail.Reason)). Timed for the record: worst-pass p50 $worst s (${ratio}x init best)."
    }
    elseif ($worst -le 0.7 * $initBest) {
        $verdicts += "- **${name}:** MATERIAL - worst-pass p50 $worst s = ${ratio}x of init best p50 $initBest s (<= 0.70 required)."
    }
    else {
        $verdicts += "- **${name}:** not material - worst-pass p50 $worst s = ${ratio}x of init best p50 $initBest s (<= 0.70 required)."
    }
}

$L = @()
$L += '# Phase 2 fixture-strategy comparison'
$L += ''
$L += "Machine: $env:COMPUTERNAME, Windows PowerShell $($PSVersionTable.PSVersion). No NGen or machine tuning."
$L += "Measured $(Get-Date -Format 'yyyy-MM-dd') with tests/bench/Measure-Fixture.ps1, BEFORE any New-MusterFixture change (the init rows are the current per-test git-init path)."
$L += "Config: $Passes independent passes x $RunsPerPass create+destroy cycles per strategy."
$L += "One-time template build (New-MusterFixture): $([math]::Round($templateCost, 3)) s - under a template-based strategy this is paid once per Pester test file (each file dot-sources its own MusterFixture.ps1 scope), i.e. ~12x per full suite run."
$L += 'Every strategy was checked against Assert-FixtureContract (tests/bench/FixtureStrategies.ps1); failures disqualify from adoption but are still timed below.'
$L += ''
$L += '## Create+destroy timings (seconds)'
$L += ''
$L += '| Strategy | Pass | p50 | p95 | All samples |'
$L += '|---|---:|---:|---:|---|'
foreach ($r in $rows) {
    $L += "| $($r.Strategy) | $($r.Pass) | $($r.P50) | $($r.P95) | $($r.All) |"
}
$L += ''
$L += '## Verdicts (rule fixed before measurement)'
$L += ''
$L += "Material = contract passed AND both passes p50 <= 0.7x the best init pass p50 ($initBest s). Ties go to the simpler strategy: copy > clone-local > worktree."
$L += ''
$L += $verdicts
$L += ''

$enc = New-Object System.Text.UTF8Encoding $false
[IO.File]::WriteAllText((Join-Path $repoRoot $OutFile), (($L -join "`n") + "`n"), $enc)
Write-Host "Wrote $OutFile"
