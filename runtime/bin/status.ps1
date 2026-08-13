# MUSTER status - on-demand board print (spec 8.3). Not part of the RUNNER contract.
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_lib.ps1')

$r = Invoke-CommandBoundary { Invoke-StatusCommand }
$r.Output | Write-Output
exit $r.ExitCode
