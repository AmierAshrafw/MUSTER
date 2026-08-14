# Phase 3 divergence probe (throwaway, spec 2026-08-14-test-speed-phase3-design).
# Maps which stateful git paths round-trip in a hosted runspace vs throw a terminating
# NativeCommandError under $ErrorActionPreference='Stop'. Calls EXISTING _lib helpers
# (extraction has not happened yet). Run from repo root, Windows PowerShell 5.1:
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/bench/Probe-Phase3Divergence.ps1
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. tests/MusterFixture.ps1

$lib = Join-Path $script:RepoRoot 'runtime/bin/_lib.ps1'

function Test-RunspacePath {
    # Runs $Body in a fresh runspace cd'd into $Fixture; reports PASS (returned) or THROW.
    param([string]$Name, [string]$Fixture, [string]$Body, [string]$Expect)
    $ps = [powershell]::Create()
    try {
        [void]$ps.AddScript("Set-Location -LiteralPath '$Fixture'`n. '$lib'`n$Body")
        try {
            [void]@($ps.Invoke())
            "PASS  (expected $Expect)  $Name"
        }
        catch {
            "THROW (expected $Expect)  $Name  ::  $($_.Exception.Message -replace '\s+', ' ')"
        }
    }
    finally { $ps.Dispose() }
}

$results = @()

# Case 1 — default fixture, Complete-Task (git mv/add/renormalize/commit chain). Expect PASS.
$fx = New-MusterFixture
try {
    New-TaskFile -Fixture $fx -Folder inbox -Id 'p-01-a' -CommitPaths @('src/out.txt') -VerifyCmd 'git --version' -Commit | Out-Null
    Invoke-MusterClaim $fx | Out-Null
    New-Item -ItemType Directory (Join-Path $fx 'src') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $fx 'src/out.txt'), 'payload')
    $results += Test-RunspacePath -Name 'Complete-Task (default fixture)' -Fixture $fx -Expect 'PASS' -Body @'
$root = Get-RepoRoot; $tasks = Get-TasksRoot
$task = Read-CommittedTask -RepoRoot $root -Name 'p-01-a.md'
$claim = Get-ClaimCommit -RepoRoot $root -Name 'p-01-a.md'
[void](Complete-Task -RepoRoot $root -TasksRoot $tasks -Fields $task.Fields -Id 'p-01-a' -ClaimCommit $claim)
'@
}
finally { Remove-MusterFixture $fx }

# Case 2 — default fixture, Invoke-DoneFailReview (review-cycling git chain). Expect PASS.
$fx = New-MusterFixture
try {
    New-TaskFile -Fixture $fx -Folder done -Id 'p-01-a' -Commit | Out-Null
    New-TaskFile -Fixture $fx -Folder inbox -Id 'p-02-review-a' -Type review -Tier strong -DependsOn @('p-01-a') -ExtraFront @('reviews: p-01-a') -Commit | Out-Null
    Invoke-MusterClaim $fx -Tier strong | Out-Null
    [IO.File]::WriteAllText((Join-Path $fx 'tasks/doing/p-02-review-a.notes.md'), 'finding: bad naming')
    New-TaskFile -Fixture $fx -Folder staging -Id 'p-01-fix-naming' -Type fix -CommitPaths @('src/out.txt') -ExtraFront @('fixes: p-01-a') | Out-Null
    $results += Test-RunspacePath -Name 'Invoke-DoneFailReview cycle (default fixture)' -Fixture $fx -Expect 'PASS' -Body @'
$root = Get-RepoRoot; $tasks = Get-TasksRoot
$task = Read-CommittedTask -RepoRoot $root -Name 'p-02-review-a.md'
$claim = Get-ClaimCommit -RepoRoot $root -Name 'p-02-review-a.md'
[void](Invoke-DoneFailReview -RepoRoot $root -TasksRoot $tasks -Fields $task.Fields -Id 'p-02-review-a' -ClaimCommit $claim -DoneCheckPass $true)
'@
}
finally { Remove-MusterFixture $fx }

# Case 3 — eol=lf pin + CRLF commit_path, Complete-Task renormalize. Expect THROW (carve-out b).
# safecrlf left at its default so the "CRLF will be replaced by LF" stderr notice fires.
$fx = New-MusterFixture
try {
    [IO.File]::WriteAllText((Join-Path $fx '.gitattributes'), "* text=auto eol=lf`n", $script:Utf8NoBom)
    git -c core.autocrlf=false -C $fx add .gitattributes
    git -C $fx commit -qm 'fixture: pin LF' | Out-Null
    New-TaskFile -Fixture $fx -Folder inbox -Id 'p-01-a' -CommitPaths @('src/out.txt') -VerifyCmd 'git --version' -Commit | Out-Null
    Invoke-MusterClaim $fx | Out-Null
    New-Item -ItemType Directory (Join-Path $fx 'src') -Force | Out-Null
    [IO.File]::WriteAllBytes((Join-Path $fx 'src/out.txt'), [byte[]](97, 13, 10, 98, 13, 10))  # "a\r\nb\r\n"
    $results += Test-RunspacePath -Name 'Complete-Task (eol=lf + CRLF commit_path)' -Fixture $fx -Expect 'THROW' -Body @'
$root = Get-RepoRoot; $tasks = Get-TasksRoot
$task = Read-CommittedTask -RepoRoot $root -Name 'p-01-a.md'
$claim = Get-ClaimCommit -RepoRoot $root -Name 'p-01-a.md'
[void](Complete-Task -RepoRoot $root -TasksRoot $tasks -Fields $task.Fields -Id 'p-01-a' -ClaimCommit $claim)
'@
}
finally { Remove-MusterFixture $fx }

# Case 4 — task in doing/ but NOT committed; Read-CommittedTask git show fails+stderr. Expect THROW (carve-out a, D20).
$fx = New-MusterFixture
try {
    New-TaskFile -Fixture $fx -Folder doing -Id 'p-01-a' -ExtraFront @('claimed_at: 2026-08-01T00:00:00Z') | Out-Null
    $results += Test-RunspacePath -Name 'Read-CommittedTask (uncommitted doing task)' -Fixture $fx -Expect 'THROW' -Body @'
$root = Get-RepoRoot
[void](Read-CommittedTask -RepoRoot $root -Name 'p-01-a.md')
'@
}
finally { Remove-MusterFixture $fx }

Write-Output '=== Phase 3 divergence probe ==='
$results | ForEach-Object { Write-Output $_ }
