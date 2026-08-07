# MUSTER verify - spec 4.2.
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_lib.ps1')

$root = Get-RepoRoot
$tasks = Get-TasksRoot
$file = Get-SoleOccupant $tasks
$task = Read-CommittedTask -RepoRoot $root -Name $file.Name
if ($task.Errors.Count -gt 0) { Write-Refuse "$($task.Id) frontmatter invalid: $($task.Errors[0])." }
$id = $task.Id
$plan = $task.Fields['plan']
$log = Join-Path $tasks "doing/$id.verify.log"

$count = Get-AttemptCount $log
if ($count -ge 3) {
    Move-TaskToFailed -RepoRoot $root -TasksRoot $tasks -Id $id -Plan $plan
    Write-Output 'VERIFY FAIL terminal. Task moved to failed/ for human review. Session over.'
    exit 3
}
$n = $count + 1
$res = Invoke-VerifyBlock -Entries $task.Fields['verify'] -LogPath $log -Label "attempt $n" -TaskId $id -RepoRoot $root
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
