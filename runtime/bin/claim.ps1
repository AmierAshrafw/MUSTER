# MUSTER claim - spec 4.1. Thin wrapper; logic in _lib.ps1.
param([string]$Harness = '', [string]$Tier = '')
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_lib.ps1')

$r = Invoke-CommandBoundary { Invoke-ClaimCommand -Harness $Harness -Tier $Tier }
$r.Output | Write-Output
exit $r.ExitCode
