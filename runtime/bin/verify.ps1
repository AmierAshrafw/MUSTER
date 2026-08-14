# MUSTER verify - spec 4.2. Thin wrapper; logic in _lib.ps1.
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_lib.ps1')

$r = Invoke-CommandBoundary { Invoke-VerifyCommand }
$r.Output | Write-Output
exit $r.ExitCode
