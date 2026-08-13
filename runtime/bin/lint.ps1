# MUSTER lint - shard-lint (spec 2.6) and lint-lite. Not part of the RUNNER contract.
param([switch]$Lite, [Parameter(ValueFromRemainingArguments = $true)][string[]]$Paths)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_lib.ps1')

$r = Invoke-CommandBoundary { Invoke-LintCommand -Lite:$Lite -Paths $Paths }
$r.Output | Write-Output
exit $r.ExitCode
