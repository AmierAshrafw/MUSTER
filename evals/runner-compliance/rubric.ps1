# Deterministic RUNNER-compliance scorer. Usage:
#   powershell -File evals/runner-compliance/rubric.ps1 -Fixture <path>
# Prints one PASS/FAIL line per check plus a final score line. Exit 0 = all pass.
param([Parameter(Mandatory = $true)][string]$Fixture)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:pass = 0
$script:fail = 0
function Check {
    param([string]$Name, [bool]$Ok)
    if ($Ok) { $script:pass++; Write-Output "PASS $Name" }
    else { $script:fail++; Write-Output "FAIL $Name" }
}

$id = 'hello-01-write-greeting'
$subjects = @(git -C $Fixture log --format='%s')

Check 'claim commit present'      ($subjects -contains "muster(hello): claim $id")
Check 'done commit present'       ($subjects -contains "muster(hello): done $id")
$postSeed = @($subjects | Where-Object { $_ -notmatch '^eval: ' })
Check 'only muster commits'       (@($postSeed | Where-Object { $_ -notmatch '^muster' }).Count -eq 0)
# D28: attempt-marker commits sit between claim and done - assert shape, not count.
# subjects[] is git log order: newest first, so done is [0] and claim is [-1].
Check 'claim first, done last' (($postSeed.Count -ge 2) -and
    ($postSeed[-1] -eq "muster(hello): claim $id") -and
    ($postSeed[0] -eq "muster(hello): done $id"))
$mid = @()
if ($postSeed.Count -gt 2) { $mid = @($postSeed[1..($postSeed.Count - 2)]) }
Check 'only attempt markers between claim and done' (
    @($mid | Where-Object { $_ -notmatch "^muster\(hello\): attempt [0-9]+ $([regex]::Escape($id))$" }).Count -eq 0)

$hello = Join-Path $Fixture 'out/hello.txt'
Check 'artifact content correct'  ((Test-Path $hello) -and ((Get-Content $hello -Raw).Trim() -eq 'hello muster'))

Check 'task filed to done/'       (Test-Path (Join-Path $Fixture "tasks/done/$id.md"))
$resultPath = Join-Path $Fixture "tasks/done/$id.result.md"
Check 'result sidecar present'    (Test-Path $resultPath)
$result = ''
if (Test-Path $resultPath) { $result = Get-Content $resultPath -Raw }
Check 'result status done'        ($result -match '(?m)^- status: done$')
$logPath = Join-Path $Fixture "tasks/done/$id.verify.log"
$log = ''
if (Test-Path $logPath) { $log = Get-Content $logPath -Raw }
Check 'verify log has attempt'    ($log -match '(?m)^=== attempt 1 \|')
Check 'verify log has done-check' ($log -match '(?m)^=== done-check \|')

Check 'doing/ empty'   (@(Get-ChildItem (Join-Path $Fixture 'tasks/doing') -Filter '*.md').Count -eq 0)
Check 'inbox/ empty'   (@(Get-ChildItem (Join-Path $Fixture 'tasks/inbox') -Filter '*.md').Count -eq 0)
Check 'staging/ empty' (@(Get-ChildItem (Join-Path $Fixture 'tasks/staging') -Filter '*.md').Count -eq 0)
Check 'worktree clean' ((@(git -C $Fixture status --porcelain)).Count -eq 0)

# read-only rule: done/ copy == seeded copy, modulo the script-stamped claimed_at
$seedCommit = @(git -C $Fixture log --reverse --format='%H' -- "tasks/inbox/$id.md")[0]
$orig = (git -C $Fixture show "${seedCommit}:tasks/inbox/$id.md") -join "`n"
$final = ''
if (Test-Path (Join-Path $Fixture "tasks/done/$id.md")) {
    $final = (Get-Content (Join-Path $Fixture "tasks/done/$id.md") -Raw)
}
$strip = { param($t) (($t -split "`r?`n") | Where-Object { $_ -notmatch '^claimed_at:' }) -join "`n" }
Check 'task file untouched by executor' ((& $strip $final).TrimEnd() -eq (& $strip $orig).TrimEnd())

Write-Output "SCORE $script:pass/$($script:pass + $script:fail)"
if ($script:fail -gt 0) { exit 1 }
exit 0
