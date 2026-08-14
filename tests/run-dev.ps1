# Phase 4 dev-loop runner (spec D6). Serial by default with cost decomposition;
# -Parallel runs file-level Start-Job workers (wall + per-job walls only).
#
# MEASURED 2026-08-14 (damai-new, Windows PowerShell 5.1): -Parallel is NON-VIABLE.
# Start-Job workers deadlock on verify-entry children - a Process.Start with redirected
# stdout/stderr (Invoke-VerifyEntry) hangs inside a background job; the git verify child
# is never observed to exit and hits the 300 s timeout. Reproduced with a SINGLE job, so
# it is a Start-Job/redirected-I/O platform limitation, not contention. Even absent the
# deadlock, per-job host-spawn + Pester-import overhead alone exceeds the 30 s gate, so
# parallelism cannot reach it. The lever is retained as the spec's designed contingency
# for the measurement record; the gate is measured on the SERIAL path (which is itself
# far above the gate - the fixture-I/O floor already exceeds 30 s). See the Phase 4
# comparison doc under docs/runtime-consolidation/.
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
