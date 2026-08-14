# MUSTER done - spec 4.3. Thin wrapper; logic in _lib.ps1.
param([string]$Verdict = '')
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_lib.ps1')

$r = Invoke-CommandBoundary { Invoke-DoneCommand -Verdict $Verdict }
$r.Output | Write-Output
exit $r.ExitCode
