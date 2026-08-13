# MUSTER baseline benchmark. Records the numbers the 30-second p95 gate is judged against.
# Run from repo root, Windows PowerShell 5.1 host:
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/bench/Measure-Baseline.ps1
# Full-suite timing across both engines takes roughly 1.5-2 hours; use -SkipSuite for micro-only reruns.
# WARNING: overwrites its output file. Phase 1 comparison results live in a separate file for this reason.
param([switch]$SkipSuite)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# Fixed measurement config - vary in source if a future phase needs it (YAGNI: no dead knobs).
$MicroRuns = 5
$SuiteRuns = 3
$Engines   = @('ps1', 'sh')
$OutFile   = 'docs/runtime-consolidation/baseline-2026-08-13.md'

# A leaked MUSTER_ENGINE=sh would silently make the micro rows measure the sh engine
# under a ps1-implied label. Clear it up front; the suite loop sets it per engine.
Remove-Item Env:MUSTER_ENGINE -ErrorAction SilentlyContinue

$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. (Join-Path $repoRoot 'tests/MusterFixture.ps1')

function Get-Percentile {
    param([double[]]$Samples, [double]$P)
    $s = @($Samples | Sort-Object)
    $idx = [math]::Ceiling($P * $s.Count) - 1
    if ($idx -lt 0) { $idx = 0 }
    return [math]::Round($s[$idx], 3)
}

function Measure-Samples {
    param([string]$Label, [int]$Runs, [scriptblock]$Body)
    $samples = @()
    for ($i = 1; $i -le $Runs; $i++) {
        $samples += (Measure-Command { & $Body }).TotalSeconds
    }
    [pscustomobject]@{
        Label = $Label
        Runs  = $Runs
        Cold  = [math]::Round($samples[0], 3)      # run 1 = cold-ish
        P50   = Get-Percentile -Samples $samples -P 0.50
        P95   = Get-Percentile -Samples $samples -P 0.95
        All   = ($samples | ForEach-Object { [math]::Round($_, 3) }) -join ', '
    }
}

$rows = @()

# --- micro benchmarks -------------------------------------------------------
$rows += Measure-Samples -Label 'powershell.exe spawn (-NoProfile, exit 0)' -Runs $MicroRuns -Body {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -Command 'exit 0' | Out-Null
}
# Post-Phase-2 note: New-MusterFixture is now template-cached. On a rerun of this
# script, sample 1 of this row includes the one-time template build and later
# samples measure the per-fixture copy only - the row no longer means what the
# committed baseline-2026-08-13.md row meant. See fixture-comparison-2026-08-13.md.
$rows += Measure-Samples -Label 'fixture create+destroy (New-MusterFixture)' -Runs $MicroRuns -Body {
    $fx = New-MusterFixture; Remove-MusterFixture $fx
}
$fx = New-MusterFixture
try {
    $rows += Measure-Samples -Label 'git status in fixture' -Runs $MicroRuns -Body {
        git -C $fx status --porcelain | Out-Null
    }
    $rows += Measure-Samples -Label 'status verb via child process (Invoke-Muster)' -Runs $MicroRuns -Body {
        Invoke-Muster $fx 'status' | Out-Null
    }
}
finally { Remove-MusterFixture $fx }

# --- per-file suite timings -------------------------------------------------
$suiteRows = @()
if (-not $SkipSuite) {
    $testFiles = @(Get-ChildItem (Join-Path $repoRoot 'tests') -Filter '*.Tests.ps1' | Sort-Object Name)
    foreach ($engine in $Engines) {
        foreach ($tf in $testFiles) {
            $samples = @()
            for ($i = 1; $i -le $SuiteRuns; $i++) {
                $samples += (Measure-Command {
                    if ($engine -eq 'sh') { $env:MUSTER_ENGINE = 'sh' }
                    else { Remove-Item Env:MUSTER_ENGINE -ErrorAction SilentlyContinue }
                    & powershell.exe -NoProfile -ExecutionPolicy Bypass -Command `
                        "Invoke-Pester -Path '$($tf.FullName)'" | Out-Null
                }).TotalSeconds
            }
            Remove-Item Env:MUSTER_ENGINE -ErrorAction SilentlyContinue
            $suiteRows += [pscustomobject]@{
                Engine = $engine
                File   = $tf.Name
                Cold   = [math]::Round($samples[0], 3)
                P50    = Get-Percentile -Samples $samples -P 0.50
                P95    = Get-Percentile -Samples $samples -P 0.95
                All    = ($samples | ForEach-Object { [math]::Round($_, 3) }) -join ', '
            }
        }
    }
}

# --- emit markdown ----------------------------------------------------------
$md = @()
$md += '# Baseline: 2026-08-13'
$md += ''
$md += "Machine: $env:COMPUTERNAME, Windows PowerShell $($PSVersionTable.PSVersion). No NGen or machine tuning applied."
$md += "Micro rows measured with the ps1 engine (MUSTER_ENGINE cleared at script start)."
$md += "MicroRuns=$MicroRuns, SuiteRuns=$SuiteRuns. Cold = run 1. p95 over N<=5 runs approximates the max - noted per spec."
$md += ''
$md += '## Micro benchmarks (seconds)'
$md += ''
$md += '| Operation | Runs | Cold | p50 | p95 | All samples |'
$md += '|---|---:|---:|---:|---:|---|'
foreach ($r in $rows) { $md += "| $($r.Label) | $($r.Runs) | $($r.Cold) | $($r.P50) | $($r.P95) | $($r.All) |" }
$md += ''
if ($suiteRows.Count -gt 0) {
    $md += '## Per-file suite timings (seconds)'
    $md += ''
    $md += '| Engine | File | Cold | p50 | p95 | All samples |'
    $md += '|---|---|---:|---:|---:|---|'
    foreach ($r in $suiteRows) { $md += "| $($r.Engine) | $($r.File) | $($r.Cold) | $($r.P50) | $($r.P95) | $($r.All) |" }
    $md += ''
    foreach ($engine in $Engines) {
        $tot = ($suiteRows | Where-Object Engine -eq $engine | Measure-Object P50 -Sum).Sum
        $md += "Total p50, engine ${engine}: $([math]::Round($tot, 1)) s"
    }
}
$outPath = Join-Path $repoRoot $OutFile
$dir = Split-Path $outPath -Parent
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
[IO.File]::WriteAllText($outPath, (($md -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding $false))
Write-Output "Baseline written: $OutFile"
