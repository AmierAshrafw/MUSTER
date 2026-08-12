# MUSTER lint - shard-lint (spec 2.6) and lint-lite. Not part of the RUNNER contract.
param([switch]$Lite, [Parameter(ValueFromRemainingArguments = $true)][string[]]$Paths)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_lib.ps1')

if (-not $Paths -or $Paths.Count -eq 0) { Write-Refuse 'lint needs at least one task file path.' }
$findings = Test-LintChecks -RepoRoot (Get-RepoRoot) -Paths $Paths -Lite:$Lite
if ($findings.Count -gt 0) {
    foreach ($f in $findings) { Write-Output "LINT FAIL $f" }
    exit 1
}
Write-Output "LINT OK $($Paths.Count) file(s)"
exit 0
