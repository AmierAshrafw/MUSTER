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
