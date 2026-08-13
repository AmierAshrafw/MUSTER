# Phase 2 candidate fixture strategies and the correctness contract they must all
# satisfy. Shared by tests/Harness.Tests.ps1 (permanent, current strategy only)
# and tests/bench/Measure-Fixture.ps1 (one-shot, all candidates). PowerShell 5.1.
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if (-not (Get-Command New-MusterFixture -ErrorAction SilentlyContinue)) {
    throw 'FixtureStrategies.ps1 requires tests/MusterFixture.ps1 to be dot-sourced first'
}

function New-FixtureDirName {
    Join-Path ([IO.Path]::GetTempPath()) ('muster-fix-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
}

function Get-FixtureStrategies {
    # name -> @{ New = scriptblock(Template) returning the fixture dir;
    #            Remove = scriptblock(Template, Dir) }.
    # 'init' ignores Template: it is the from-scratch git-init path. Post-Phase-2,
    # New-MusterFixture itself is the template-cached copy path (same as 'copy'
    # below), so 'init' calls New-MusterFixtureFromScratch directly to stay distinct.
    [ordered]@{
        'init' = @{
            New    = { param($Template) New-MusterFixtureFromScratch }
            Remove = { param($Template, $Dir) Remove-MusterFixture $Dir }
        }
        'copy' = @{
            New    = { param($Template)
                $d = New-FixtureDirName
                Copy-Item -Recurse -Force $Template $d
                $d }
            Remove = { param($Template, $Dir) Remove-MusterFixture $Dir }
        }
        'clone-local' = @{
            New    = { param($Template)
                $d = New-FixtureDirName
                # Same autocrlf guard as New-MusterFixture: a box with the
                # Git-for-Windows system default (autocrlf=true) would otherwise
                # check out different line endings than init/copy produce.
                git -c core.autocrlf=false clone -q --local $Template $d
                git -C $d config user.email 'test@muster.local'
                git -C $d config user.name 'muster-test'
                git -C $d remote remove origin
                $d }
            Remove = { param($Template, $Dir) Remove-MusterFixture $Dir }
        }
        'worktree' = @{
            New    = { param($Template)
                $d = New-FixtureDirName
                git -C $Template worktree add -q --detach $d
                $d }
            Remove = { param($Template, $Dir)
                git -C $Template worktree remove --force $Dir
                git -C $Template worktree prune }
        }
    }
}

function Assert-FixtureContract {
    # Encodes the Phase 2 validation checklist. Throws on the first violation.
    # Template may be '' for strategies that build from scratch.
    param([scriptblock]$NewFixture, [scriptblock]$RemoveFixture, [string]$Template)

    $a = $null
    $b = $null
    try {
        $a = & $NewFixture $Template
        $b = & $NewFixture $Template

        $dirty = @(git -C $a status --porcelain)
        if ($dirty.Count -ne 0) { throw "contract: dirty status in ${a}: $($dirty -join '; ')" }

        $log = @(Get-FixtureCommits $a)
        if ($log.Count -ne 1 -or $log[0] -ne 'fixture: init') {
            throw "contract: unexpected history in ${a}: $($log -join '; ')"
        }

        foreach ($f in 'tasks/bin/status.ps1', 'tasks/bin/_lib.ps1', 'tasks/RUNNER.md') {
            if (-not (Test-Path (Join-Path $a $f))) { throw "contract: missing $f in $a" }
        }

        # Checkout-lock compatibility (spec: exclusive lock file under .git/):
        # the fixture must OWN its git dir. A worktree's real git dir lives under
        # the template, shared with every sibling fixture - that shares locks too.
        $ownGitDir = Join-Path $a '.git'
        if (-not (Test-Path $ownGitDir -PathType Container)) {
            throw "contract: $a does not own its git dir ($ownGitDir is not a directory)"
        }
        $locks = @(Get-ChildItem -Path $ownGitDir -Recurse -Force -Filter '*.lock' -File -ErrorAction SilentlyContinue)
        if ($locks.Count -ne 0) {
            throw "contract: stale lock files: $(($locks | ForEach-Object FullName) -join '; ')"
        }

        # No stale .git content: a local clone would leave origin pointing at the
        # leaked TEMP template unless the strategy strips it.
        $remotes = @(git -C $a remote)
        if ($remotes.Count -ne 0) { throw "contract: stale remotes: $($remotes -join '; ')" }

        # Independent mutation: a commit in A must not appear in B or the template.
        New-TaskFile -Fixture $a -Id 'p2-01-a' -Commit | Out-Null
        if (@(Get-FixtureCommits $a).Count -ne 2) { throw 'contract: commit in A did not land' }
        if (@(Get-FixtureCommits $b).Count -ne 1) { throw 'contract: commit in A leaked into B' }
        if ($Template -and @(Get-FixtureCommits $Template).Count -ne 1) {
            throw 'contract: commit in A leaked into template'
        }

        # The installed runtime must actually execute from the fixture tree.
        $r = Invoke-Muster $a 'status'
        if ($r.Exit -ne 0) { throw "contract: status verb failed (exit $($r.Exit)): $($r.Text)" }
    }
    finally {
        if ($a) { & $RemoveFixture $Template $a }
        if ($b) { & $RemoveFixture $Template $b }
    }
    if ($a -and (Test-Path $a)) { throw "contract: cleanup left $a" }
    if ($b -and (Test-Path $b)) { throw "contract: cleanup left $b" }
}
