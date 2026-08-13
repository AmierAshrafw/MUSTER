# MUSTER promote - spec 4.4. Thin wrapper; logic in _lib.ps1.
param([switch]$NoCommit)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_lib.ps1')
try {

[void](Invoke-Promote -NoCommit:$NoCommit)
exit 0
}
catch { Exit-OnRefusal $_ }
