# MUSTER claim - spec 4.1.
param([string]$Harness = '', [string]$Tier = '')
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_lib.ps1')

if (@('claude', 'codex') -notcontains $Harness -or @('any', 'strong') -notcontains $Tier) {
    Write-Refuse 'claim requires -Harness <claude|codex> and -Tier <any|strong> (the wrapper skill supplies them).'
}
$root = Get-RepoRoot
$tasks = Get-TasksRoot

# 1. self-heal promotions dropped by a crashed predecessor (D7)
[void](Invoke-Promote)

# 2. status print - fires before any refusal (D12)
Write-Output (Get-StatusBlock -RepoRoot $root -TasksRoot $tasks)

# 3. one executor per checkout (D18)
$doing = @(Get-TaskFiles (Join-Path $tasks 'doing'))
if ($doing.Count -gt 0) {
    $occ = Read-TaskFile $doing[0].FullName
    $age = 'unknown'
    if ($occ.Fields.ContainsKey('claimed_at')) { $age = Get-AgeString $occ.Fields['claimed_at'] }
    Write-Refuse "doing/ occupied by $($occ.Id) (claimed $age ago). One executor per checkout. RECOVERY in RUNNER.md."
}
# 4. stale staged fix from a crashed done-fail
$staging = @(Get-TaskFiles (Join-Path $tasks 'staging'))
if ($staging.Count -gt 0) {
    Write-Refuse "stale fix task in tasks/staging/: $($staging[0].Name). Human clears it - RECOVERY in RUNNER.md."
}

while ($true) {
    # 5. lowest eligible filename in inbox/; dependency order is the only order
    $selected = $null
    foreach ($f in Get-TaskFiles (Join-Path $tasks 'inbox')) {
        $t = Read-TaskFile $f.FullName
        # 6. malformed = loud refusal, file stays for a human
        if ($t.Errors.Count -gt 0) {
            Write-Refuse "$($t.Id) frontmatter invalid: $($t.Errors[0]). Task left in inbox/ for a human."
        }
        # NOTE: Test-TaskSchema returns via 'return , $e' (PS 5.1 array-return convention);
        # wrapping the call in @() here would double-wrap and make Count always 1 - assign directly.
        $schemaErr = Test-TaskSchema $t.Fields
        if ($schemaErr.Count -gt 0) {
            Write-Refuse "$($t.Id) frontmatter invalid: $($schemaErr[0]). Task left in inbox/ for a human."
        }
        # pinning (D25): strong tasks need a strong session; strong sessions take ONLY strong tasks
        if ($t.Fields['tier'] -eq 'strong' -and $Tier -ne 'strong') { continue }
        if ($Tier -eq 'strong' -and $t.Fields['tier'] -ne 'strong') { continue }
        if ($t.Fields.ContainsKey('harness') -and $t.Fields['harness'] -ne $Harness) { continue }
        $selected = $t
        break
    }
    if (-not $selected) { Write-Refuse "nothing to claim for $Harness/$Tier." }
    $id = $selected.Id
    $name = "$id.md"

    # 7. dirty-tree scope check, scoped to the selected task (spec decision in 4.1)
    $cp = @()
    if ($selected.Fields.ContainsKey('commit_paths')) { $cp = @($selected.Fields['commit_paths']) }
    # NOTE: Get-DirtyPaths returns via 'return , @(...)' (PS 5.1 array-return convention);
    # piping its call directly into Where-Object binds the whole array to $_ once. Capture
    # into a plain variable first so the pipe enumerates individual paths.
    $dirty = Get-DirtyPaths $root
    $outOfScope = @($dirty | Where-Object { -not (Test-PathInScope -Path $_ -CommitPaths $cp) })
    if ($outOfScope.Count -gt 0) {
        Write-Refuse "working tree dirty outside $id's commit_paths: $($outOfScope -join ', '). Likely leftovers from a failed or crashed task - see RECOVERY (RUNNER.md), 'leftover dirt'."
    }

    # 8. rename, stamp, claim commit (D21) - probe evidence gathered before the rename
    $priorClaims = @(git -C $root log --oneline -- "tasks/doing/$name")
    git -c core.autocrlf=false -C $root mv "tasks/inbox/$name" "tasks/doing/$name" 2>$null
    $sidecarPaths = Move-TaskSidecars -RepoRoot $root -TasksRoot $tasks -Id $id -From 'inbox' -To 'doing'
    $doingPath = Join-Path $tasks "doing/$name"
    Set-ClaimedAt -Path $doingPath -Iso (Get-IsoNow)
    $commitPaths = @("tasks/inbox/$name", "tasks/doing/$name") + $sidecarPaths
    git -c core.autocrlf=false -C $root commit -q -m "muster($($selected.Fields['plan'])): claim $id" -- @commitPaths 2>$null
    $selected = Read-TaskFile $doingPath   # re-read: claimed_at now present

    # 9. recovery probe (D12) - only impl/fix, only with prior-claim evidence.
    #    An ungated probe would auto-file every review/integration task (spec 4.1.9).
    $probeType = $selected.Fields['type']
    if ($priorClaims.Count -gt 0 -and ($probeType -eq 'impl' -or $probeType -eq 'fix')) {
        $probeLog = Join-Path $tasks "doing/$id.verify.log"
        $probe = Invoke-VerifyBlock -Entries $selected.Fields['verify'] -LogPath $probeLog `
            -Label 'claim-probe' -TaskId $id -RepoRoot $root
        if ($probe.Pass) {
            $claimCommit = Get-ClaimCommit -RepoRoot $root -Name $name
            $pre = Test-DonePreconditions -RepoRoot $root -Fields $selected.Fields -ClaimCommit $claimCommit
            if ($pre) { Write-Refuse $pre }
            [void](Complete-Task -RepoRoot $root -TasksRoot $tasks -Fields $selected.Fields -Id $id `
                -ClaimCommit $claimCommit -SurprisesOverride 'auto-filed at claim: verify green before execution' -Probe)
            Write-Output "Auto-filed $id - a crashed predecessor already finished it (claim-probe green)."
            continue
        }
    }

    # 10. print the task and hand over to RUNNER.md
    # Strip the file's own trailing newline: Write-Output supplies one, so keeping it
    # would print a blank line before the Claimed line - the sh mirror uses bare `cat`
    # and does not. Only ONE terminator comes off, so a file ending in a real blank
    # line still renders like cat.
    $body = [IO.File]::ReadAllText($doingPath)
    if ($body.EndsWith("`r`n")) { $body = $body.Substring(0, $body.Length - 2) }
    elseif ($body.EndsWith("`n")) { $body = $body.Substring(0, $body.Length - 1) }
    Write-Output $body
    Write-Output "Claimed $id. Follow tasks/RUNNER.md."
    exit 0
}
