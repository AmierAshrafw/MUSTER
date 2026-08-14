# Test helpers. Dot-sourced by every *.Tests.ps1. PowerShell 5.1 compatible.
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:Utf8NoBom = New-Object System.Text.UTF8Encoding $false
$script:RepoRoot  = Split-Path $PSScriptRoot -Parent

function New-MusterFixtureFromScratch {
    # Throwaway git repo with the full tasks/ tree and the runtime scripts installed.
    $dir = Join-Path ([IO.Path]::GetTempPath()) ('muster-fix-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $dir | Out-Null
    git -C $dir init -q -b main
    git -C $dir config user.email 'test@muster.local'
    git -C $dir config user.name 'muster-test'
    foreach ($f in 'backlog', 'inbox', 'doing', 'done', 'failed', 'archive', 'staging', 'bin') {
        $p = Join-Path $dir "tasks/$f"
        New-Item -ItemType Directory -Path $p | Out-Null
        [IO.File]::WriteAllText((Join-Path $p '.gitkeep'), '', $script:Utf8NoBom)
    }
    Copy-Item (Join-Path $script:RepoRoot 'runtime/bin/*') (Join-Path $dir 'tasks/bin')
    $runner = Join-Path $script:RepoRoot 'runtime/RUNNER.md'
    if (Test-Path $runner) { Copy-Item $runner (Join-Path $dir 'tasks') }
    [IO.File]::WriteAllText((Join-Path $dir 'README.md'), "fixture`n", $script:Utf8NoBom)
    # -c core.autocrlf=false, same as every runtime script: a box with the Git-for-Windows
    # system default (autocrlf=true) otherwise floods the test output with LF->CRLF warnings
    # on every fixture. Noise only - the suite is green either way - but it makes the fixture
    # deterministic and consistent with the scripts under test.
    git -c core.autocrlf=false -C $dir add -A
    git -C $dir commit -qm 'fixture: init'
    return $dir
}

# Built lazily. Each Pester test file dot-sources MusterFixture.ps1 into its own
# scope, so this rebuilds per test file (~12 builds and ~12 deliberately leaked
# TEMP dirs of ~1 MB per full suite run; aborted runs already leak fixtures the
# same way). Always fresh per file, so runtime/bin edits can never go stale in it.
$script:FixtureTemplate = $null

function New-MusterFixture {
    # Copy of a cached template: adopted in Phase 2 on measured gain over git init
    # per fixture (docs/runtime-consolidation/fixture-comparison-2026-08-13.md).
    if (-not $script:FixtureTemplate) {
        $script:FixtureTemplate = New-MusterFixtureFromScratch
    }
    $dir = Join-Path ([IO.Path]::GetTempPath()) ('muster-fix-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    Copy-Item -Recurse -Force $script:FixtureTemplate $dir
    return $dir
}

function Remove-MusterFixture([string]$Fixture) {
    if ($Fixture -and (Test-Path $Fixture)) { Remove-Item -Recurse -Force $Fixture }
}

# Shared reset-reuse fixture (Phase 4, spec D2): one copied fixture per test file,
# reset to its baseline SHA + cleaned between tests. Adopted on the measured verdict
# in docs/runtime-consolidation/phase4-fixture-2026-08-14.md. Leaks one TEMP dir per
# file like the template does (documented, acceptable).
$script:SharedFixture = $null
$script:SharedFixtureBase = $null

function Reset-TrackedFileStat([string]$Fixture) {
    # Backdate every tracked file's mtime strictly before any future .git/index write,
    # then refresh so the index records the backdated stats: stat-based diff can never
    # flag them racy-clean afterwards.
    $old = (Get-Date).AddSeconds(-30)
    foreach ($f in @(git -C $Fixture ls-files)) {
        $p = Join-Path $Fixture $f
        if (Test-Path -LiteralPath $p) { [IO.File]::SetLastWriteTime($p, $old) }
    }
    git -C $Fixture update-index -q --refresh 2>$null
}

function New-SharedMusterFixture {
    if (-not $script:SharedFixture -or -not (Test-Path $script:SharedFixture)) {
        $script:SharedFixture = New-MusterFixture
        $script:SharedFixtureBase = (git -C $script:SharedFixture rev-parse HEAD).Trim()
        return $script:SharedFixture
    }
    git -C $script:SharedFixture reset --hard -q $script:SharedFixtureBase
    git -C $script:SharedFixture clean -xfdq
    # reset --hard bumps tracked-file mtimes into the current wall-clock second; a later
    # per-test claim commit rewrites .git/index in that same second, so git flags the
    # files racy-clean and the stat-based `git diff --name-only <claimCommit>` in
    # Get-ChangedPaths (runtime) phantom-reports an unmodified tracked file (README.md)
    # as changed, tripping done's scope check. Harness artifact only - the real flow
    # never resets before done. Refreshing alone is not enough (stays racy vs the later
    # index write); backdating first is.
    Reset-TrackedFileStat $script:SharedFixture
    return $script:SharedFixture
}

function Remove-SharedMusterFixture {
    if ($script:SharedFixture) {
        Remove-MusterFixture $script:SharedFixture
        $script:SharedFixture = $null
    }
}

function New-TaskFile {
    # Writes a schema-valid task file into a fixture status folder.
    param(
        [string]$Fixture,
        [string]$Folder = 'inbox',
        [string]$Id = 'p-01-a',
        [string]$Plan = 'p',
        [string]$Type = 'impl',
        [string]$Tier = 'any',
        [string[]]$DependsOn = @(),
        [string[]]$Protected = @('README.md'),
        [string[]]$CommitPaths = @('src/out.txt'),
        [string]$VerifyCmd = 'git --version',
        [string]$ExpectExit = '0',
        [string[]]$ExtraFront = @(),   # raw extra frontmatter lines (reviews:, fixes:, harness: ...)
        [string]$Body = '',
        [switch]$Commit
    )
    $L = @('---', "id: $Id", "plan: $Plan", "type: $Type", "tier: $Tier")
    if ($DependsOn.Count -eq 0) { $L += 'depends_on: []' }
    else {
        $L += 'depends_on:'
        foreach ($d in $DependsOn) { $L += "  - $d" }
    }
    if ($Type -eq 'impl' -or $Type -eq 'fix') {
        if ($Protected.Count -eq 0) { $L += 'protected: []' }
        else {
            $L += 'protected:'
            foreach ($p in $Protected) { $L += "  - $p" }
        }
        if ($CommitPaths.Count -eq 0) { $L += 'commit_paths: []' }
        else {
            $L += 'commit_paths:'
            foreach ($p in $CommitPaths) { $L += "  - $p" }
        }
    }
    $L += $ExtraFront
    $L += 'verify:'
    $L += "  - cmd: ""$VerifyCmd"""
    $L += "    expect_exit: $ExpectExit"
    $L += '---'
    if (-not $Body) {
        $Body = "# ${Id}: sample task`n`n## Context`n`nFixture task.`n`n## Steps`n`n1. Ensure nothing changes.`n`n## Acceptance`n`n- Nothing."
    }
    $path = Join-Path $Fixture "tasks/$Folder/$Id.md"
    [IO.File]::WriteAllText($path, (($L -join "`n") + "`n" + $Body + "`n"), $script:Utf8NoBom)
    if ($Commit) {
        git -c core.autocrlf=false -C $Fixture add "tasks/$Folder/$Id.md"
        git -C $Fixture commit -qm "fixture: add $Id"
    }
    return $path
}

function Invoke-Muster {
    # Runs a verb script as a child process from the fixture root. Engine-parameterized.
    param([string]$Fixture, [string]$Verb, [string[]]$ScriptArgs = @())
    if ($env:MUSTER_DEVLOOP) {
        throw "Invoke-Muster is forbidden in the dev loop (MUSTER_DEVLOOP set): tried verb '$Verb'"
    }
    Push-Location $Fixture
    try {
        $prevEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            if ($env:MUSTER_ENGINE -eq 'sh') {
                $sh = 'C:\Program Files\Git\bin\sh.exe'
                if (-not (Test-Path $sh)) {
                    $found = Get-Command sh -ErrorAction SilentlyContinue
                    if ($found) { $sh = $found.Source }
                    else { throw 'sh engine requested but no sh.exe found - install Git for Windows' }
                }
                $out = & $sh "tasks/bin/$Verb.sh" @ScriptArgs 2>&1
            }
            else {
                $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "tasks/bin/$Verb.ps1" @ScriptArgs 2>&1
            }
            $code = $LASTEXITCODE
        }
        finally { $ErrorActionPreference = $prevEap }
    }
    finally { Pop-Location }
    $lines = @($out | ForEach-Object { "$_" })
    return [pscustomobject]@{ Out = $lines; Text = ($lines -join "`n"); Exit = $code }
}

function Invoke-MusterClaim {
    param([string]$Fixture, [string]$Harness = 'claude', [string]$Tier = 'any')
    if ($env:MUSTER_ENGINE -eq 'sh') {
        Invoke-Muster $Fixture 'claim' @('--harness', $Harness, '--tier', $Tier)
    }
    else {
        Invoke-Muster $Fixture 'claim' @('-Harness', $Harness, '-Tier', $Tier)
    }
}

function Invoke-MusterPromote {
    param([string]$Fixture, [switch]$NoCommit)
    $a = @()
    if ($NoCommit) { if ($env:MUSTER_ENGINE -eq 'sh') { $a = @('--no-commit') } else { $a = @('-NoCommit') } }
    Invoke-Muster $Fixture 'promote' $a
}

function Invoke-MusterLint {
    param([string]$Fixture, [string[]]$Paths, [switch]$Lite)
    $a = @()
    if ($Lite) { if ($env:MUSTER_ENGINE -eq 'sh') { $a += '--lite' } else { $a += '-Lite' } }
    $a += $Paths
    Invoke-Muster $Fixture 'lint' $a
}

function Get-FixtureCommits([string]$Fixture) {
    @(git -C $Fixture log --format='%s')
}
