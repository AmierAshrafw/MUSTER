# MUSTER verify - spec 4.2.
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_lib.ps1')
try {

$root = Get-RepoRoot
$tasks = Get-TasksRoot
$file = Get-SoleOccupant $tasks
$task = Read-CommittedTask -RepoRoot $root -Name $file.Name
if ($task.Errors.Count -gt 0) { Write-Refuse "$($task.Id) frontmatter invalid: $($task.Errors[0])." }
$id = $task.Id
$plan = $task.Fields['plan']
$log = Join-Path $tasks "doing/$id.verify.log"

$claimCommit = Get-ClaimCommit -RepoRoot $root -Name "$id.md"
$count = Get-AttemptCount -RepoRoot $root -Plan $plan -Id $id -ClaimCommit $claimCommit
if ($count -ge 3) {
    Move-TaskToFailed -RepoRoot $root -TasksRoot $tasks -Id $id -Plan $plan
    Write-Output 'VERIFY FAIL terminal. Task moved to failed/ for human review. Session over.'
    exit 3
}
$n = $count + 1
# D28: the attempt burns BEFORE any command runs - killing verify mid-run
# still counts. The marker commit message is the counter; the log content is
# just transcript (the NEXT marker or the terminal move commits the output).
# No stderr redirect and a hard exit-code check: if this commit fails, running
# the verify would be an unaccounted attempt - the exact hole D28 closes.
$head = git -C $root rev-parse HEAD
Add-Utf8 $log ("=== attempt $n | $(Get-IsoNow) | task $id | HEAD $head`n")
git -c core.autocrlf=false -C $root add "tasks/doing/$id.verify.log"
git -c core.autocrlf=false -C $root commit -q -m "muster($plan): attempt $n $id" -- "tasks/doing/$id.verify.log"
if ($LASTEXITCODE -ne 0) {
    Write-Refuse 'attempt marker commit failed - cannot account the attempt. Inspect git state by hand.'
}
$res = Invoke-VerifyBlock -Entries $task.Fields['verify'] -LogPath $log -Label "attempt $n" -TaskId $id -RepoRoot $root -SkipHeader
if ($res.Pass) {
    Write-Output "VERIFY PASS (attempt $n)"
    exit 0
}
if ($n -lt 3) {
    Write-Output "VERIFY FAIL (attempt $n of 3): $($res.FirstFail). Fix and rerun."
    exit 2
}
Move-TaskToFailed -RepoRoot $root -TasksRoot $tasks -Id $id -Plan $plan
Write-Output 'VERIFY FAIL terminal. Task moved to failed/ for human review. Session over.'
exit 3
}
catch { Exit-OnRefusal $_ }
