# MUSTER done - spec 4.3. Fail branches live in _lib.ps1 (later commits in this plan).
param([string]$Verdict = '')
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_lib.ps1')

$root = Get-RepoRoot
$tasks = Get-TasksRoot
$file = Get-SoleOccupant $tasks
$task = Read-CommittedTask -RepoRoot $root -Name $file.Name
if ($task.Errors.Count -gt 0) { Write-Refuse "$($task.Id) frontmatter invalid: $($task.Errors[0])." }
$id = $task.Id
$type = $task.Fields['type']

# verdict argument rules (spec 4.3)
$isJudgment = ($type -eq 'review' -or $type -eq 'integration')
if (-not $isJudgment -and $Verdict) { Write-Refuse 'done takes no verdict on impl/fix tasks.' }
if ($isJudgment -and @('pass', 'fail') -notcontains $Verdict) {
    Write-Refuse 'done needs a pass or fail verdict on review/integration tasks.'
}

# 1. claim commit is derived, not stored
$claimCommit = Get-ClaimCommit -RepoRoot $root -Name $file.Name

# 2. confirmation verify - kills stale-pass; logged as done-check, never counts.
#    A fail verdict on a judgment task records a red done-check instead of gating
#    on it: a broken build IS the finding, and the verdict must stay fileable (D29).
$log = Join-Path $tasks "doing/$id.verify.log"
$check = Invoke-VerifyBlock -Entries $task.Fields['verify'] -LogPath $log -Label 'done-check' -TaskId $id -RepoRoot $root
if (-not $check.Pass -and -not ($isJudgment -and $Verdict -eq 'fail')) {
    Write-Refuse "done-check verify failed: $($check.FirstFail). Run the verify script, fix, and retry."
}

# 3-4. protected + scope
$pre = Test-DonePreconditions -RepoRoot $root -Fields $task.Fields -ClaimCommit $claimCommit
if ($pre) { Write-Refuse $pre }

# 5. judgment tasks must carry findings
if ($isJudgment -and -not (Test-Path (Join-Path $tasks "doing/$id.notes.md"))) {
    Write-Refuse "verdict needs tasks/doing/$id.notes.md with findings."
}

if ($Verdict -eq 'fail') {
    if ($type -eq 'review') {
        Invoke-DoneFailReview -RepoRoot $root -TasksRoot $tasks -Fields $task.Fields -Id $id -ClaimCommit $claimCommit -DoneCheckPass $check.Pass
    }
    else {
        Invoke-DoneFailIntegration -RepoRoot $root -TasksRoot $tasks -Fields $task.Fields -Id $id -ClaimCommit $claimCommit -DoneCheckPass $check.Pass
    }
    exit 3   # unreachable - both branch functions exit themselves; kept as a guard
}

$promoted = Complete-Task -RepoRoot $root -TasksRoot $tasks -Fields $task.Fields -Id $id `
    -ClaimCommit $claimCommit -Verdict $Verdict
$plist = 'none'
if ($promoted.Count -gt 0) { $plist = ($promoted -join ', ') }
Write-Output (Get-BoardLine -TasksRoot $tasks)
Write-Output "Done: $id. Promoted: $plist. Do not claim another task. Session over."
exit 0
