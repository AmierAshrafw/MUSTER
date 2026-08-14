# Cold/warm wall-clock protocol for the 30 s gate (spec D6). Times any command:
#   powershell -File tests/bench/Measure-DevLoop.ps1 -Command "& 'tests/run-dev.ps1'"
# Cold = fresh powershell.exe host per run (only run 1 is OS-cache cold - recorded as such).
# Warm = one host, repeated runs. n=5 p95 is the max; the gate reads worst-of-5-warm.
param(
    [string]$Command = "Import-Module Pester -MinimumVersion 6.0.0; Invoke-Pester -Path tests/fast, tests/Lib.Tests.ps1"
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'BenchCommon.ps1')

# Fixed measurement config - the gate statistic is DEFINED as worst of 5 warm
# runs (spec Decision 6); vary in source if a future phase needs it (YAGNI: no
# dead knobs - same convention as Measure-Baseline.ps1).
$ColdRuns = 5
$WarmRuns = 5

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
