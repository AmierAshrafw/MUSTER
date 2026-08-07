# MUSTER v1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development
> (recommended) or superpowers:executing-plans to implement this plan task-by-task.
> Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build MUSTER v1: the Claude Code plugin (init/shard/run/review/close skills),
the tasks/bin state-transition scripts (ps1 first, sh mirror), RUNNER.md, task templates,
and a skill-creator-style eval that measures RUNNER compliance of a fresh Sonnet executor.

**Architecture:** Repo root is the plugin root. `runtime/` holds everything `muster:init`
copies into a target repo (bin scripts + RUNNER.md). All protocol logic lives in
`runtime/bin/_lib.ps1` functions; the four verbs plus `lint` are thin scripts over it.
Tests are Pester 5 contract tests running each verb as a child process against throwaway
fixture git repos; the same suite runs against the sh mirror via an engine switch.

**Tech Stack:** PowerShell 5.1-compatible ps1, POSIX sh (Git Bash), Pester 5, git,
Claude Code plugin format (`.claude-plugin/plugin.json` + `skills/*/SKILL.md`).

---

## Authority

`docs/superpowers/specs/2026-08-07-muster-v1.md` (below: "spec") is the settled contract.
Where this plan says "verbatim from spec section N", copy that spec text exactly - it is
in-repo and authoritative. On any conflict between this plan and the spec (message
strings, exit codes, formats), **the spec wins**. Spec deviations approved for this plan:

1. `tasks/bin/` ships 6 files per engine, not 4: the verbs plus `_lib` (shared functions)
   and `lint` (shard-lint + lint-lite, used by `muster:shard` and `done fail`).
   Executors still see only the four verbs; RUNNER.md never mentions lib or lint.
2. Repo root doubles as plugin root (`.claude-plugin/plugin.json` beside `docs/`).
3. Templates ship with block-list `depends_on`. Spec section 7 shows inline flow lists
   (`depends_on: [{dep-ids}]`) but spec 2.5's strict subset - one parser - forbids
   non-empty inline lists. The spec contradicts itself; 2.5 wins. Shard fills
   `depends_on: []` when empty, a block list otherwise (Task 16).
4. `claim` validates frontmatter/schema of every inbox file it iterates BEFORE the
   pinning filters (spec 4.1 orders select-then-validate). An unparseable file cannot
   be pin-filtered; refusing loudly on first contact keeps the failure obvious. Cost:
   one malformed card halts claims for both tiers until a human clears it.
5. The lint collision scan self-exempts the candidate file in FULL mode too (spec 2.6
   describes that exemption only for lint-lite) - shard writes the batch into
   tasks/backlog/ before linting it, so every batch file already exists on disk.

## File structure

```
.claude-plugin/plugin.json        plugin manifest
skills/init/SKILL.md              /muster:init
skills/shard/SKILL.md             /muster:shard
skills/run/SKILL.md               /muster:run  (executor wrapper, Sonnet)
skills/review/SKILL.md            /muster:review (reviewer wrapper, Fable)
skills/close/SKILL.md             /muster:close
runtime/RUNNER.md                 executor contract, spec section 6 verbatim
runtime/bin/_lib.ps1              all shared logic (parser, verify runner, git helpers)
runtime/bin/claim.ps1             verb: claim   (thin wrapper over lib)
runtime/bin/verify.ps1            verb: verify
runtime/bin/done.ps1              verb: done
runtime/bin/promote.ps1           verb: promote
runtime/bin/lint.ps1              shard-lint / lint-lite
runtime/bin/*.sh                  sh mirror of the six files above
templates/impl-task.md            spec 7.1 verbatim
templates/review-task.md          spec 7.2 verbatim
templates/fix-task.md             spec 7.3 verbatim
templates/integration-task.md     spec 7.4 verbatim
tests/MusterFixture.ps1           fixture + invocation helpers (dot-sourced by tests)
tests/Lib.Tests.ps1               lib unit tests
tests/Promote.Tests.ps1           per-verb contract tests
tests/Verify.Tests.ps1
tests/Lint.Tests.ps1
tests/Claim.Tests.ps1
tests/Done.Tests.ps1
evals/runner-compliance/setup.ps1     builds the eval fixture repo
evals/runner-compliance/rubric.ps1    deterministic compliance scorer
evals/runner-compliance/README.md     procedure
evals/runner-compliance/results/      one file per eval run
```

## Conventions (all tasks)

- **PowerShell 5.1 compatible.** No `&&`, no ternary, no `??`. `Set-StrictMode -Version 2.0`
  at the top of every script. Scripts must also run unmodified on PowerShell 7.
- **UTF-8 without BOM** for every file a script writes (BOM breaks sh and pollutes diffs).
  Always use the lib helpers `Write-Utf8` / `Add-Utf8`, never `Set-Content`/`Out-File`.
  Files created by the Write tool are BOM-free already.
- **Pathspec commits only.** Scripts commit as
  `git commit -q -m "<msg>" -- <path> <path>` - never bare `git commit`, never
  `git add -A`. Pathspec commits ignore unrelated staged content and pick up worktree
  state of the named paths (this is what makes D21 explicit-paths true even when the
  executor never staged anything). New files (sidecars) need `git add <path>` first;
  pathspec commit alone does not pick up untracked files.
- **Exit codes** (spec 4.0): 0 success/pass, 1 refusal, 2 verify attempt failed
  (retry allowed), 3 terminal. Refusals print one line starting `MUSTER refuse:`.
- **Run tests:** `Invoke-Pester -Path tests -Output Detailed` from repo root.
  Engine switch: `$env:MUSTER_ENGINE` unset/`ps1` (default) or `sh`.
- **Commits:** conventional-commit subject, no co-author trailer, no agent name.
- **No em dash** in any authored file; plain hyphen.

---

### Task 1: Plugin skeleton

**Files:**
- Create: `.claude-plugin/plugin.json`
- Create: `runtime/bin/.gitkeep`, `templates/.gitkeep`, `skills/.gitkeep`,
  `tests/.gitkeep`, `evals/.gitkeep` (placeholder files so the tree commits; delete
  each `.gitkeep` in the task that populates its folder)

- [ ] **Step 1: Write the manifest**

`.claude-plugin/plugin.json`:

```json
{
  "name": "muster",
  "version": "0.1.0",
  "description": "Delegate-and-forget task board: shard approved plans into small verified tasks executed by fresh sessions. Skills: init, shard, run, review, close."
}
```

- [ ] **Step 2: Create the folder skeleton**

Create empty `.gitkeep` files at: `runtime/bin/.gitkeep`, `templates/.gitkeep`,
`skills/.gitkeep`, `tests/.gitkeep`, `evals/.gitkeep`.

- [ ] **Step 3: Verify manifest parses**

Run: `powershell -NoProfile -Command "Get-Content .claude-plugin/plugin.json -Raw | ConvertFrom-Json | Select-Object name, version"`
Expected: table showing `muster` / `0.1.0`.

- [ ] **Step 4: Commit**

```bash
git add .claude-plugin/plugin.json runtime/bin/.gitkeep templates/.gitkeep skills/.gitkeep tests/.gitkeep evals/.gitkeep
git commit -m "feat: plugin skeleton and manifest"
```

### Task 2: Test harness - Pester 5 + fixture helpers

**Files:**
- Create: `tests/MusterFixture.ps1`
- Create: `tests/Harness.Tests.ps1`
- Delete: `tests/.gitkeep`

- [ ] **Step 1: Install Pester 5 (CurrentUser)**

Run:
`powershell -NoProfile -Command "Install-Module Pester -MinimumVersion 5.5 -Scope CurrentUser -Force -SkipPublisherCheck"`
(`-SkipPublisherCheck` required because the inbox Pester 3.4 has a different signer.)
Then confirm: `powershell -NoProfile -Command "Import-Module Pester -MinimumVersion 5.5; (Get-Module Pester).Version"`
Expected: `5.x`.

- [ ] **Step 2: Write the fixture helper**

`tests/MusterFixture.ps1`:

```powershell
# Test helpers. Dot-sourced by every *.Tests.ps1. PowerShell 5.1 compatible.
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:Utf8NoBom = New-Object System.Text.UTF8Encoding $false
$script:RepoRoot  = Split-Path $PSScriptRoot -Parent

function New-MusterFixture {
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
    git -C $dir add -A
    git -C $dir commit -qm 'fixture: init'
    return $dir
}

function Remove-MusterFixture([string]$Fixture) {
    if ($Fixture -and (Test-Path $Fixture)) { Remove-Item -Recurse -Force $Fixture }
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
        $L += 'protected:'
        foreach ($p in $Protected) { $L += "  - $p" }
        $L += 'commit_paths:'
        foreach ($p in $CommitPaths) { $L += "  - $p" }
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
        git -C $Fixture add "tasks/$Folder/$Id.md"
        git -C $Fixture commit -qm "fixture: add $Id"
    }
    return $path
}

function Invoke-Muster {
    # Runs a verb script as a child process from the fixture root. Engine-parameterized.
    param([string]$Fixture, [string]$Verb, [string[]]$ScriptArgs = @())
    Push-Location $Fixture
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
```

- [ ] **Step 3: Write a harness smoke test**

`tests/Harness.Tests.ps1`:

```powershell
BeforeAll { . (Join-Path $PSScriptRoot 'MusterFixture.ps1') }

Describe 'fixture harness' {
    It 'creates a git repo with the full tasks tree' {
        $fx = New-MusterFixture
        try {
            foreach ($f in 'backlog', 'inbox', 'doing', 'done', 'failed', 'archive', 'staging', 'bin') {
                Test-Path (Join-Path $fx "tasks/$f") | Should -BeTrue
            }
            (git -C $fx log --oneline).Count | Should -Be 1
        }
        finally { Remove-MusterFixture $fx }
    }
    It 'writes a task file that starts and ends with frontmatter markers' {
        $fx = New-MusterFixture
        try {
            $p = New-TaskFile -Fixture $fx
            $lines = Get-Content $p
            $lines[0] | Should -Be '---'
            ($lines | Where-Object { $_ -eq '---' }).Count | Should -Be 2
        }
        finally { Remove-MusterFixture $fx }
    }
}
```

- [ ] **Step 4: Run the suite**

Run: `powershell -NoProfile -Command "Import-Module Pester -MinimumVersion 5.5; Invoke-Pester tests -Output Detailed"`
Expected: 2 tests PASS. (`Invoke-Muster` is untested until a verb exists - fine.)

- [ ] **Step 5: Commit**

```bash
git rm -q tests/.gitkeep
git add tests/MusterFixture.ps1 tests/Harness.Tests.ps1
git commit -m "test: pester harness with muster fixture helpers"
```

### Task 3: Lib core - paths, time, IO, listing, refusal

**Files:**
- Create: `runtime/bin/_lib.ps1`
- Create: `tests/Lib.Tests.ps1`
- Delete: `runtime/bin/.gitkeep`

All lib tests exercise functions in-process (dot-source the lib), not via child
processes - only the verb scripts get child-process contract tests.

- [ ] **Step 1: Write failing tests**

`tests/Lib.Tests.ps1`:

```powershell
BeforeAll {
    . (Join-Path $PSScriptRoot 'MusterFixture.ps1')
    . (Join-Path $PSScriptRoot '../runtime/bin/_lib.ps1')
}

Describe 'Get-TaskFiles' {
    It 'lists task md files only, sorted, excluding sidecars and gitkeep' {
        $fx = New-MusterFixture
        try {
            New-TaskFile -Fixture $fx -Folder done -Id 'p-02-b' | Out-Null
            New-TaskFile -Fixture $fx -Folder done -Id 'p-01-a' | Out-Null
            $done = Join-Path $fx 'tasks/done'
            [IO.File]::WriteAllText((Join-Path $done 'p-01-a.result.md'), 'x', $script:Utf8NoBom)
            [IO.File]::WriteAllText((Join-Path $done 'p-01-a.notes.md'), 'x', $script:Utf8NoBom)
            [IO.File]::WriteAllText((Join-Path $done 'p-01-a.verify.log'), 'x', $script:Utf8NoBom)
            $files = @(Get-TaskFiles $done)
            $files.Count | Should -Be 2
            $files[0].Name | Should -Be 'p-01-a.md'
            $files[1].Name | Should -Be 'p-02-b.md'
        }
        finally { Remove-MusterFixture $fx }
    }
}

Describe 'Get-IsoNow' {
    It 'returns UTC ISO 8601 with Z suffix' {
        Get-IsoNow | Should -Match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$'
    }
}

Describe 'Write-Utf8 / Add-Utf8' {
    It 'writes without BOM and appends' {
        $f = Join-Path ([IO.Path]::GetTempPath()) ("muster-$(New-Guid).txt")
        try {
            Write-Utf8 $f "a`n"
            Add-Utf8 $f "b`n"
            $bytes = [IO.File]::ReadAllBytes($f)
            $bytes[0] | Should -Be 97      # 'a', not 0xEF BOM
            (Get-Content $f) -join ',' | Should -Be 'a,b'
        }
        finally { Remove-Item $f -ErrorAction SilentlyContinue }
    }
}

Describe 'Get-AgeString' {
    It 'renders minutes, hours, days' {
        Get-AgeString ((Get-Date).ToUniversalTime().AddMinutes(-5).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'"))  | Should -Be '5m'
        Get-AgeString ((Get-Date).ToUniversalTime().AddHours(-3).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'"))    | Should -Be '3h'
        Get-AgeString ((Get-Date).ToUniversalTime().AddDays(-2).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'"))     | Should -Be '2d'
    }
}
```

- [ ] **Step 2: Run tests, verify they fail**

Run: `powershell -NoProfile -Command "Import-Module Pester -MinimumVersion 5.5; Invoke-Pester tests/Lib.Tests.ps1 -Output Detailed"`
Expected: FAIL - `_lib.ps1` does not exist.

- [ ] **Step 3: Write the lib core**

`runtime/bin/_lib.ps1` (initial content; later tasks append to this file):

```powershell
# MUSTER shared library. Dot-sourced by every verb script. PowerShell 5.1 compatible.
# Executors never call this file directly; it is not part of the RUNNER contract.
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:Utf8NoBom = New-Object System.Text.UTF8Encoding $false

function Get-RepoRoot {
    $root = git rev-parse --show-toplevel
    if ($LASTEXITCODE -ne 0 -or -not $root) { Write-Output 'MUSTER refuse: not inside a git repository.'; exit 1 }
    return $root
}

function Get-TasksRoot { Join-Path (Get-RepoRoot) 'tasks' }

function Get-IsoNow { (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'") }

function Write-Utf8 { param([string]$Path, [string]$Text) [IO.File]::WriteAllText($Path, $Text, $script:Utf8NoBom) }
function Add-Utf8 { param([string]$Path, [string]$Text) [IO.File]::AppendAllText($Path, $Text, $script:Utf8NoBom) }

function Write-Refuse {
    # Single-line refusal per spec 4.0; callers rely on this terminating the script.
    param([string]$Message)
    Write-Output "MUSTER refuse: $Message"
    exit 1
}

function Get-TaskFiles {
    # Task .md files only: sidecars (.result.md, .notes.md) and .gitkeep never count (spec 4.0).
    param([string]$Folder)
    @(Get-ChildItem -Path $Folder -File -Filter '*.md' |
        Where-Object { $_.Name -notlike '*.result.md' -and $_.Name -notlike '*.notes.md' } |
        Sort-Object Name)
}

function Get-AgeString {
    # Humanized age of an ISO UTC timestamp: 42m / 3h / 2d.
    param([string]$Iso)
    $then = [datetime]::Parse($Iso, [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::AdjustToUniversal)
    $delta = (Get-Date).ToUniversalTime() - $then
    if ($delta.TotalDays -ge 1) { return ('{0}d' -f [int][math]::Floor($delta.TotalDays)) }
    if ($delta.TotalHours -ge 1) { return ('{0}h' -f [int][math]::Floor($delta.TotalHours)) }
    return ('{0}m' -f [int][math]::Floor($delta.TotalMinutes))
}
```

- [ ] **Step 4: Run tests, verify pass**

Same command as Step 2. Expected: all Lib tests PASS.

- [ ] **Step 5: Commit**

```bash
git rm -q runtime/bin/.gitkeep
git add runtime/bin/_lib.ps1 tests/Lib.Tests.ps1
git commit -m "feat(lib): core helpers - paths, utf8 io, task listing, age"
```

### Task 4: Lib - strict-YAML frontmatter parser

**Files:**
- Modify: `runtime/bin/_lib.ps1` (append)
- Modify: `tests/Lib.Tests.ps1` (append)

Grammar is spec 2.5, exactly: flat scalars (unquoted or double-quoted), `[]`, block
lists of scalars, the `verify` block list of flat maps. Anything else is an error.

- [ ] **Step 1: Append failing tests**

Append to `tests/Lib.Tests.ps1`:

```powershell
Describe 'Read-Frontmatter' {
    It 'parses scalars, empty list, block list, and verify block' {
        $text = @(
            '---'
            'id: p-01-a'
            'plan: p'
            'type: impl'
            'tier: any'
            'depends_on: []'
            'protected:'
            '  - src/a.cs'
            '  - src/b.cs'
            'commit_paths:'
            '  - src/a.cs'
            'verify:'
            '  - cmd: "dotnet test X.csproj"'
            '    expect_exit: 0'
            '    timeout_seconds: 60'
            '  - cmd: "node check.js"'
            '    expect_contains: "SCHEMA OK"'
            '---'
            '# p-01-a: title'
        ) -join "`n"
        $r = Read-Frontmatter $text
        $r.Errors.Count | Should -Be 0
        $r.Fields['id'] | Should -Be 'p-01-a'
        @($r.Fields['depends_on']).Count | Should -Be 0
        @($r.Fields['protected']).Count | Should -Be 2
        @($r.Fields['verify']).Count | Should -Be 2
        $r.Fields['verify'][0]['cmd'] | Should -Be 'dotnet test X.csproj'
        $r.Fields['verify'][0]['expect_exit'] | Should -Be '0'
        $r.Fields['verify'][1]['expect_contains'] | Should -Be 'SCHEMA OK'
        $r.Body | Should -Match '^# p-01-a'
    }
    It 'errors on missing opening marker' {
        (Read-Frontmatter "id: x`n---`n").Errors.Count | Should -BeGreaterThan 0
    }
    It 'errors on missing closing marker' {
        (Read-Frontmatter "---`nid: x`n").Errors.Count | Should -BeGreaterThan 0
    }
    It 'errors on anchors and aliases' {
        (Read-Frontmatter "---`nid: &a x`n---`n").Errors.Count | Should -BeGreaterThan 0
    }
    It 'errors on a bare key with no items (must use [])' {
        (Read-Frontmatter "---`ndepends_on:`nid: x`n---`n").Errors.Count | Should -BeGreaterThan 0
    }
    It 'errors on unparseable lines' {
        (Read-Frontmatter "---`n  nested_map:`n    a: b`n---`n").Errors.Count | Should -BeGreaterThan 0
    }
    It 'strips double quotes from scalar values' {
        $r = Read-Frontmatter "---`nid: ""p-01-a""`n---`n"
        $r.Fields['id'] | Should -Be 'p-01-a'
    }
}
```

- [ ] **Step 2: Run, verify fail**

Run: `powershell -NoProfile -Command "Import-Module Pester -MinimumVersion 5.5; Invoke-Pester tests/Lib.Tests.ps1 -Output Detailed"`
Expected: new Describe FAILS (`Read-Frontmatter` not defined); earlier tests still pass.

- [ ] **Step 3: Append the parser to `_lib.ps1`**

```powershell
function Read-QuoteStripped {
    param([string]$Value)
    if ($Value -match '^"(.*)"$') { return $Matches[1] }
    return $Value
}

function Read-Frontmatter {
    # Strict YAML subset per spec 2.5. Returns @{ Fields; Errors; Body }.
    # Values stay strings; typing/enums are Test-TaskSchema's job.
    param([string]$Text)
    $r = @{ Fields = @{}; Errors = @(); Body = '' }
    $lines = $Text -split "`r?`n"
    if ($lines.Count -lt 3 -or $lines[0] -ne '---') { $r.Errors += 'missing opening --- marker'; return $r }
    $close = 0
    for ($j = 1; $j -lt $lines.Count; $j++) { if ($lines[$j] -eq '---') { $close = $j; break } }
    if ($close -eq 0) { $r.Errors += 'missing closing --- marker'; return $r }

    $i = 1
    while ($i -lt $close) {
        $line = $lines[$i]
        if ($line -match '^\s*$') { $i++; continue }
        if ($line -notmatch '^([a-z_]+):(.*)$') {
            $r.Errors += "unparseable frontmatter line: $line"
            $i++
            continue
        }
        $key = $Matches[1]
        $val = $Matches[2].Trim()

        if ($key -eq 'verify') {
            if ($val -ne '') { $r.Errors += 'verify: must be a block list'; return $r }
            $entries = @()
            $i++
            while ($i -lt $close) {
                $vline = $lines[$i]
                if ($vline -match '^  - ([a-z_]+): (.+)$') {
                    $entries += , @{ $Matches[1] = (Read-QuoteStripped $Matches[2].Trim()) }
                    $i++
                }
                elseif ($vline -match '^    ([a-z_]+): (.+)$') {
                    if ($entries.Count -eq 0) { $r.Errors += "verify: continuation before first entry: $vline"; return $r }
                    $entries[$entries.Count - 1][$Matches[1]] = (Read-QuoteStripped $Matches[2].Trim())
                    $i++
                }
                else { break }
            }
            if ($entries.Count -eq 0) { $r.Errors += 'verify: empty block' }
            $r.Fields['verify'] = $entries
            continue
        }

        if ($val -eq '[]') {
            $r.Fields[$key] = @()
            $i++
        }
        elseif ($val -eq '') {
            $items = @()
            $i++
            while ($i -lt $close -and $lines[$i] -match '^\s+- (.+)$') {
                $items += (Read-QuoteStripped $Matches[1].Trim())
                $i++
            }
            if ($items.Count -eq 0) { $r.Errors += "${key}: empty value - use [] for an empty list" }
            $r.Fields[$key] = $items
        }
        else {
            if ($val -match '^[&*]') { $r.Errors += "${key}: anchors/aliases are not allowed" }
            $r.Fields[$key] = (Read-QuoteStripped $val)
            $i++
        }
    }
    if ($close + 1 -lt $lines.Count) {
        $r.Body = ($lines[($close + 1)..($lines.Count - 1)] -join "`n")
    }
    return $r
}

function Read-TaskFile {
    # Read + parse a task file from disk. Adds Id (filename stem) and Path.
    param([string]$Path)
    $r = Read-Frontmatter ([IO.File]::ReadAllText($Path))
    $r['Id'] = [IO.Path]::GetFileNameWithoutExtension($Path)
    $r['Path'] = $Path
    return $r
}
```

- [ ] **Step 4: Run, verify pass**

Same command. Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add runtime/bin/_lib.ps1 tests/Lib.Tests.ps1
git commit -m "feat(lib): strict-yaml frontmatter parser"
```

### Task 5: Lib - schema validation per task type

**Files:**
- Modify: `runtime/bin/_lib.ps1` (append)
- Modify: `tests/Lib.Tests.ps1` (append)

Field table is spec 2.2. `-Staged` switch = lint-lite mode for reviewer-authored fix
tasks: `generation` must be ABSENT (spec 2.6 note).

- [ ] **Step 1: Append failing tests**

```powershell
Describe 'Test-TaskSchema' {
    BeforeAll {
        function New-Fields([hashtable]$Over) {
            $f = @{
                id = 'p-01-a'; plan = 'p'; type = 'impl'; tier = 'any'
                depends_on = @()
                protected = @('src/a.cs'); commit_paths = @('src/a.cs')
                verify = @(, @{ cmd = 'git --version'; expect_exit = '0' })
            }
            foreach ($k in $Over.Keys) { $f[$k] = $Over[$k] }
            return $f
        }
    }
    It 'passes a valid impl task' {
        (Test-TaskSchema (New-Fields @{})).Count | Should -Be 0
    }
    It 'flags missing required fields' {
        $f = New-Fields @{}; $f.Remove('tier')
        (Test-TaskSchema $f) -join ';' | Should -Match 'tier'
    }
    It 'flags illegal enum values' {
        (Test-TaskSchema (New-Fields @{ type = 'chore' })).Count | Should -BeGreaterThan 0
        (Test-TaskSchema (New-Fields @{ tier = 'mega' })).Count | Should -BeGreaterThan 0
        (Test-TaskSchema (New-Fields @{ harness = 'gemini' })).Count | Should -BeGreaterThan 0
    }
    It 'requires reviews on review tasks and forbids commit_paths there' {
        $f = New-Fields @{ type = 'review' }
        $f.Remove('protected'); $f.Remove('commit_paths')
        (Test-TaskSchema $f) -join ';' | Should -Match 'reviews'
        $f['reviews'] = 'p-01-a'
        (Test-TaskSchema $f).Count | Should -Be 0
        $f['commit_paths'] = @('x')
        (Test-TaskSchema $f) -join ';' | Should -Match 'commit_paths'
    }
    It 'requires fixes on fix tasks and validates generation' {
        $f = New-Fields @{ type = 'fix'; fixes = 'p-01-a'; generation = '1' }
        (Test-TaskSchema $f).Count | Should -Be 0
        $f['generation'] = '3'
        (Test-TaskSchema $f).Count | Should -BeGreaterThan 0
    }
    It 'in staged mode generation must be absent' {
        $f = New-Fields @{ type = 'fix'; fixes = 'p-01-a' }
        (Test-TaskSchema $f -Staged).Count | Should -Be 0
        $f['generation'] = '1'
        (Test-TaskSchema $f -Staged) -join ';' | Should -Match 'generation'
    }
    It 'flags verify entries without expectation or with unknown keys' {
        (Test-TaskSchema (New-Fields @{ verify = @(, @{ cmd = 'git --version' }) })).Count | Should -BeGreaterThan 0
        (Test-TaskSchema (New-Fields @{ verify = @(, @{ cmd = 'x'; expect_exit = '0'; shell = 'bash' }) })).Count | Should -BeGreaterThan 0
        (Test-TaskSchema (New-Fields @{ verify = @(, @{ expect_exit = '0' }) })).Count | Should -BeGreaterThan 0
    }
    It 'flags non-integer expect_exit and timeout_seconds' {
        (Test-TaskSchema (New-Fields @{ verify = @(, @{ cmd = 'x'; expect_exit = 'zero' }) })).Count | Should -BeGreaterThan 0
        (Test-TaskSchema (New-Fields @{ verify = @(, @{ cmd = 'x'; expect_exit = '0'; timeout_seconds = 'long' }) })).Count | Should -BeGreaterThan 0
    }
    It 'flags a non-kebab id' {
        (Test-TaskSchema (New-Fields @{ id = 'P_01' })).Count | Should -BeGreaterThan 0
    }
}
```

- [ ] **Step 2: Run, verify fail** (same Pester command; new Describe fails)

- [ ] **Step 3: Append `Test-TaskSchema` to `_lib.ps1`**

```powershell
function Test-TaskSchema {
    # Returns a string[] of schema errors (empty = valid). Field table: spec 2.2.
    # -Staged: lint-lite mode for a reviewer-authored fix in staging/ (generation must be absent).
    param([hashtable]$Fields, [switch]$Staged)
    $e = @()
    foreach ($req in 'id', 'plan', 'type', 'tier', 'depends_on', 'verify') {
        if (-not $Fields.ContainsKey($req)) { $e += "missing required field: $req" }
    }
    if ($e.Count -gt 0) { return $e }

    $type = $Fields['type']
    if (@('impl', 'review', 'fix', 'integration') -notcontains $type) { $e += "type: illegal value '$type'"; return $e }
    if (@('any', 'strong') -notcontains $Fields['tier']) { $e += "tier: illegal value '$($Fields['tier'])'" }
    if ($Fields.ContainsKey('harness') -and @('claude', 'codex') -notcontains $Fields['harness']) {
        $e += "harness: illegal value '$($Fields['harness'])'"
    }
    if ($Fields['id'] -notmatch '^[a-z0-9-]+$') { $e += 'id: must be kebab-case [a-z0-9-]+' }
    if ($Fields['depends_on'] -isnot [array]) { $e += 'depends_on: must be a list' }

    if ($type -eq 'review' -and -not $Fields.ContainsKey('reviews')) { $e += 'reviews: required on review tasks' }
    if ($type -eq 'fix' -and -not $Fields.ContainsKey('fixes')) { $e += 'fixes: required on fix tasks' }
    if ($type -eq 'impl' -or $type -eq 'fix') {
        foreach ($req in 'protected', 'commit_paths') {
            if (-not $Fields.ContainsKey($req)) { $e += "${req}: required on $type tasks" }
        }
    }
    else {
        if ($Fields.ContainsKey('commit_paths')) { $e += "commit_paths: must be omitted on $type tasks (outputs are sidecars only)" }
    }

    if ($Fields.ContainsKey('generation')) {
        if ($type -ne 'fix') { $e += 'generation: only legal on fix tasks' }
        elseif ($Staged) { $e += 'generation: must be absent on a staged fix (the done script stamps it)' }
        elseif (@('1', '2') -notcontains "$($Fields['generation'])") { $e += 'generation: must be 1 or 2' }
    }

    if ($Fields['verify'] -is [array]) {
        $allowed = @('cmd', 'expect_exit', 'expect_contains', 'timeout_seconds')
        foreach ($en in $Fields['verify']) {
            foreach ($k in $en.Keys) {
                if ($allowed -notcontains $k) { $e += "verify: unknown key '$k'" }
            }
            if (-not $en.ContainsKey('cmd')) { $e += 'verify: entry missing cmd' }
            if (-not $en.ContainsKey('expect_exit') -and -not $en.ContainsKey('expect_contains')) {
                $e += 'verify: entry needs expect_exit and/or expect_contains'
            }
            foreach ($ik in 'expect_exit', 'timeout_seconds') {
                if ($en.ContainsKey($ik)) {
                    $tmp = 0
                    if (-not [int]::TryParse("$($en[$ik])", [ref]$tmp)) { $e += "verify: $ik must be an integer" }
                }
            }
        }
    }
    return $e
}
```

- [ ] **Step 4: Run, verify pass**

- [ ] **Step 5: Commit**

```bash
git add runtime/bin/_lib.ps1 tests/Lib.Tests.ps1
git commit -m "feat(lib): per-type task schema validation"
```

### Task 6: Lib - command tokenizer + verify runner + transcript writer

**Files:**
- Modify: `runtime/bin/_lib.ps1` (append)
- Modify: `tests/Lib.Tests.ps1` (append)

Transcript format is spec 3.2. The label parameter produces the three header kinds:
`attempt <n>`, `done-check`, `claim-probe`. Only `=== attempt <n> |` headers count
toward the cap.

- [ ] **Step 1: Append failing tests**

```powershell
Describe 'Split-CmdLine' {
    It 'splits on whitespace and honors double quotes' {
        $t = Split-CmdLine 'dotnet test "My Tests/X.csproj" -v q'
        $t.Count | Should -Be 4
        $t[2] | Should -Be 'My Tests/X.csproj'
    }
    It 'throws on unbalanced quotes' {
        { Split-CmdLine 'echo "oops' } | Should -Throw
    }
}

Describe 'Invoke-VerifyBlock' {
    BeforeEach { $script:fx = New-MusterFixture }
    AfterEach { Remove-MusterFixture $script:fx }

    It 'passing block writes PASS transcript and returns Pass' {
        $log = Join-Path $script:fx 'tasks/doing/t.verify.log'
        $entries = @(, @{ cmd = 'git --version'; expect_exit = '0'; expect_contains = 'git version' })
        $r = Invoke-VerifyBlock -Entries $entries -LogPath $log -Label 'attempt 1' -TaskId 't' -RepoRoot $script:fx
        $r.Pass | Should -BeTrue
        $raw = Get-Content $log -Raw
        $raw | Should -Match '(?m)^=== attempt 1 \| \d{4}.+\| task t \| HEAD [0-9a-f]+'
        $raw | Should -Match ([regex]::Escape('$ git --version'))
        $raw | Should -Match 'expect_exit 0 -> OK'
        $raw | Should -Match 'expect_contains "git version" -> OK'
        $raw | Should -Match '(?m)^=== attempt 1 result: PASS$'
    }
    It 'failing expectation stops at first failure and reports it' {
        $log = Join-Path $script:fx 'tasks/doing/t.verify.log'
        $entries = @(
            @{ cmd = 'git frobnicate'; expect_exit = '0' },
            @{ cmd = 'git --version'; expect_exit = '0' }
        )
        $r = Invoke-VerifyBlock -Entries $entries -LogPath $log -Label 'attempt 1' -TaskId 't' -RepoRoot $script:fx
        $r.Pass | Should -BeFalse
        $r.FirstFail | Should -Match 'git frobnicate'
        (Get-Content $log -Raw) | Should -Not -Match ([regex]::Escape('$ git --version'))
    }
    It 'missing executable fails the entry, not the script' {
        $log = Join-Path $script:fx 'tasks/doing/t.verify.log'
        $entries = @(, @{ cmd = 'muster-no-such-exe'; expect_exit = '0' })
        (Invoke-VerifyBlock -Entries $entries -LogPath $log -Label 'attempt 1' -TaskId 't' -RepoRoot $script:fx).Pass |
            Should -BeFalse
    }
    It 'timeout kills the process and fails' {
        $log = Join-Path $script:fx 'tasks/doing/t.verify.log'
        $entries = @(, @{ cmd = 'powershell -NoProfile -Command Start-Sleep 30'; expect_exit = '0'; timeout_seconds = '2' })
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $r = Invoke-VerifyBlock -Entries $entries -LogPath $log -Label 'attempt 1' -TaskId 't' -RepoRoot $script:fx
        $sw.Stop()
        $r.Pass | Should -BeFalse
        $sw.Elapsed.TotalSeconds | Should -BeLessThan 20
        (Get-Content $log -Raw) | Should -Match 'timeout 2s -> FAIL'
    }
}

Describe 'Get-AttemptCount' {
    It 'counts only attempt headers, not done-check or claim-probe' {
        $f = Join-Path ([IO.Path]::GetTempPath()) ("muster-log-$(New-Guid).log")
        try {
            $body = @(
                '=== attempt 1 | x | task t | HEAD a'
                '=== attempt 1 result: FAIL'
                '=== claim-probe | x | task t | HEAD a'
                '=== done-check | x | task t | HEAD a'
                '=== attempt 2 | x | task t | HEAD a'
            ) -join "`n"
            [IO.File]::WriteAllText($f, $body)
            Get-AttemptCount $f | Should -Be 2
        }
        finally { Remove-Item $f -ErrorAction SilentlyContinue }
    }
    It 'returns 0 for a missing file' {
        Get-AttemptCount (Join-Path ([IO.Path]::GetTempPath()) 'muster-nope.log') | Should -Be 0
    }
}
```

- [ ] **Step 2: Run, verify fail**

- [ ] **Step 3: Append runner functions to `_lib.ps1`**

```powershell
function Split-CmdLine {
    # Tokenize one command line: whitespace-separated, double quotes group (spec 2.4).
    # No shell interpretation anywhere downstream - tokens go straight to Process.Start.
    param([string]$Cmd)
    $tokens = @()
    $sb = New-Object System.Text.StringBuilder
    $inQuote = $false
    foreach ($ch in $Cmd.ToCharArray()) {
        if ($ch -eq '"') { $inQuote = -not $inQuote; continue }
        if (-not $inQuote -and ($ch -eq ' ' -or $ch -eq "`t")) {
            if ($sb.Length -gt 0) { $tokens += $sb.ToString(); [void]$sb.Clear() }
            continue
        }
        [void]$sb.Append($ch)
    }
    if ($inQuote) { throw "unbalanced double quote in cmd: $Cmd" }
    if ($sb.Length -gt 0) { $tokens += $sb.ToString() }
    return , $tokens
}

function Invoke-VerifyEntry {
    # Run one verify entry: direct process invocation, merged stdout+stderr, wall timeout.
    param([hashtable]$Entry, [string]$WorkDir)
    $tokens = Split-CmdLine $Entry['cmd']
    $timeout = 300
    if ($Entry.ContainsKey('timeout_seconds')) { $timeout = [int]$Entry['timeout_seconds'] }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $tokens[0]
    $quoted = @()
    for ($k = 1; $k -lt $tokens.Count; $k++) {
        if ($tokens[$k] -match '\s') { $quoted += ('"' + $tokens[$k] + '"') } else { $quoted += $tokens[$k] }
    }
    $psi.Arguments = ($quoted -join ' ')
    $psi.WorkingDirectory = $WorkDir
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $out = ''; $code = -1; $timedOut = $false
    try {
        $p = [System.Diagnostics.Process]::Start($psi)
        $so = $p.StandardOutput.ReadToEndAsync()
        $se = $p.StandardError.ReadToEndAsync()
        if ($p.WaitForExit($timeout * 1000)) {
            $code = $p.ExitCode
            $out = $so.Result + $se.Result
        }
        else {
            $timedOut = $true
            try { $p.Kill() } catch { }
        }
    }
    catch { $out = "spawn failed: $($_.Exception.Message)" }
    return @{ Output = $out; ExitCode = $code; TimedOut = $timedOut; TimeoutSeconds = $timeout }
}

function Invoke-VerifyBlock {
    # Run all entries in order, appending a spec-3.2 transcript block to $LogPath.
    # $Label: 'attempt <n>' | 'done-check' | 'claim-probe'. Stops at first failing entry.
    param([array]$Entries, [string]$LogPath, [string]$Label, [string]$TaskId, [string]$RepoRoot)
    $head = git -C $RepoRoot rev-parse HEAD
    Add-Utf8 $LogPath ("=== $Label | $(Get-IsoNow) | task $TaskId | HEAD $head`n")
    $pass = $true
    $firstFail = $null
    foreach ($en in $Entries) {
        Add-Utf8 $LogPath ('$ ' + $en['cmd'] + "`n")
        $res = Invoke-VerifyEntry -Entry $en -WorkDir $RepoRoot
        if ($res.Output) { Add-Utf8 $LogPath ($res.Output.TrimEnd() + "`n") }
        $parts = @()
        $why = @()
        $ok = $true
        if ($res.TimedOut) {
            $parts += "timeout $($res.TimeoutSeconds)s -> FAIL"
            $why += "timed out after $($res.TimeoutSeconds)s"
            $ok = $false
        }
        else {
            $parts += "exit $($res.ExitCode)"
            if ($en.ContainsKey('expect_exit')) {
                if ([int]$en['expect_exit'] -eq $res.ExitCode) { $parts += "expect_exit $($en['expect_exit']) -> OK" }
                else { $parts += "expect_exit $($en['expect_exit']) -> FAIL"; $why += "exit $($res.ExitCode), expected $($en['expect_exit'])"; $ok = $false }
            }
            if ($en.ContainsKey('expect_contains')) {
                if ($res.Output.Contains($en['expect_contains'])) { $parts += "expect_contains ""$($en['expect_contains'])"" -> OK" }
                else { $parts += "expect_contains ""$($en['expect_contains'])"" -> MISSING"; $why += "output missing ""$($en['expect_contains'])"""; $ok = $false }
            }
        }
        Add-Utf8 $LogPath (($parts -join ' | ') + "`n")
        if (-not $ok) {
            $pass = $false
            $firstFail = "$($en['cmd']): $($why -join '; ')"
            break
        }
    }
    $verdict = 'FAIL'
    if ($pass) { $verdict = 'PASS' }
    Add-Utf8 $LogPath ("=== $Label result: $verdict`n")
    return @{ Pass = $pass; FirstFail = $firstFail }
}

function Get-AttemptCount {
    # Attempt number source of truth (spec 3.2): count of '=== attempt N |' headers.
    param([string]$LogPath)
    if (-not (Test-Path $LogPath)) { return 0 }
    return @([regex]::Matches([IO.File]::ReadAllText($LogPath), '(?m)^=== attempt \d+ \|')).Count
}
```

Note the deliberate detail in `Invoke-VerifyEntry`: a missing executable makes
`Process.Start` throw; the catch records `spawn failed`, `ExitCode` stays `-1`, and the
expectation evaluation fails the entry - the script itself never crashes.

- [ ] **Step 4: Run, verify pass** (the timeout test takes ~2s; suite still fast)

- [ ] **Step 5: Commit**

```bash
git add runtime/bin/_lib.ps1 tests/Lib.Tests.ps1
git commit -m "feat(lib): tokenizer, verify runner, transcript writer"
```

### Task 7: promote

**Files:**
- Create: `runtime/bin/promote.ps1`
- Modify: `runtime/bin/_lib.ps1` (append `Invoke-Promote`, `Test-DepSatisfied`)
- Create: `tests/Promote.Tests.ps1`

Spec 4.4. Logic lives in the lib (`claim` and `done` reuse it); `promote.ps1` is a
thin wrapper. Contract tests run the script as a child process via the fixture helper.

- [ ] **Step 1: Write failing contract tests**

`tests/Promote.Tests.ps1`:

```powershell
BeforeAll { . (Join-Path $PSScriptRoot 'MusterFixture.ps1') }

Describe 'bin/promote' {
    BeforeEach { $script:fx = New-MusterFixture }
    AfterEach { Remove-MusterFixture $script:fx }

    It 'moves a backlog task whose deps are all in done/ and commits' {
        New-TaskFile -Fixture $script:fx -Folder done -Id 'p-01-a' -Commit | Out-Null
        New-TaskFile -Fixture $script:fx -Folder backlog -Id 'p-02-b' -DependsOn @('p-01-a') -Commit | Out-Null
        $r = Invoke-MusterPromote $script:fx
        $r.Exit | Should -Be 0
        Test-Path (Join-Path $script:fx 'tasks/inbox/p-02-b.md') | Should -BeTrue
        Test-Path (Join-Path $script:fx 'tasks/backlog/p-02-b.md') | Should -BeFalse
        (Get-FixtureCommits $script:fx)[0] | Should -Be 'muster: promote 1'
    }
    It 'counts archived deps as satisfied' {
        $arch = Join-Path $script:fx 'tasks/archive/p'
        New-Item -ItemType Directory -Path $arch | Out-Null
        New-TaskFile -Fixture $script:fx -Folder 'archive/p' -Id 'p-01-a' -Commit | Out-Null
        New-TaskFile -Fixture $script:fx -Folder backlog -Id 'p-02-b' -DependsOn @('p-01-a') -Commit | Out-Null
        (Invoke-MusterPromote $script:fx).Exit | Should -Be 0
        Test-Path (Join-Path $script:fx 'tasks/inbox/p-02-b.md') | Should -BeTrue
    }
    It 'leaves unsatisfied tasks in backlog and exits 0 silently' {
        New-TaskFile -Fixture $script:fx -Folder backlog -Id 'p-02-b' -DependsOn @('p-01-a') -Commit | Out-Null
        $before = (Get-FixtureCommits $script:fx).Count
        $r = Invoke-MusterPromote $script:fx
        $r.Exit | Should -Be 0
        $r.Text | Should -Be ''
        Test-Path (Join-Path $script:fx 'tasks/backlog/p-02-b.md') | Should -BeTrue
        (Get-FixtureCommits $script:fx).Count | Should -Be $before
    }
    It 'with -NoCommit stages the rename without committing' {
        New-TaskFile -Fixture $script:fx -Folder done -Id 'p-01-a' -Commit | Out-Null
        New-TaskFile -Fixture $script:fx -Folder backlog -Id 'p-02-b' -DependsOn @('p-01-a') -Commit | Out-Null
        $before = (Get-FixtureCommits $script:fx).Count
        (Invoke-MusterPromote $script:fx -NoCommit).Exit | Should -Be 0
        Test-Path (Join-Path $script:fx 'tasks/inbox/p-02-b.md') | Should -BeTrue
        (Get-FixtureCommits $script:fx).Count | Should -Be $before
        (git -C $script:fx diff --cached --name-only) | Should -Contain 'tasks/inbox/p-02-b.md'
    }
    It 'skips malformed backlog files with a warning' {
        $bad = Join-Path $script:fx 'tasks/backlog/p-03-bad.md'
        [IO.File]::WriteAllText($bad, "no frontmatter here`n")
        $r = Invoke-MusterPromote $script:fx
        $r.Exit | Should -Be 0
        $r.Text | Should -Match 'MUSTER warn: .*p-03-bad'
        Test-Path $bad | Should -BeTrue
    }
}
```

- [ ] **Step 2: Run, verify fail** -
`powershell -NoProfile -Command "Import-Module Pester -MinimumVersion 5.5; Invoke-Pester tests/Promote.Tests.ps1 -Output Detailed"`
Expected: FAIL (promote.ps1 missing).

- [ ] **Step 3: Append to `_lib.ps1`**

```powershell
function Test-DepSatisfied {
    # Satisfied = task id present in done/ or anywhere under archive/ (spec 4.4, D15).
    param([string]$TasksRoot, [string]$DepId)
    if (Test-Path (Join-Path $TasksRoot "done/$DepId.md")) { return $true }
    $archive = Join-Path $TasksRoot 'archive'
    if (Test-Path $archive) {
        $hit = @(Get-ChildItem -Path $archive -Recurse -File -Filter "$DepId.md")
        if ($hit.Count -gt 0) { return $true }
    }
    return $false
}

function Move-TaskSidecars {
    # .gen<g>.* history sidecars move with their task file (spec 3). Returns commit paths.
    param([string]$RepoRoot, [string]$TasksRoot, [string]$Id, [string]$From, [string]$To)
    $paths = @()
    foreach ($h in @(Get-ChildItem (Join-Path $TasksRoot $From) -File | Where-Object { $_.Name -like "$Id.gen*" })) {
        git -C $RepoRoot mv "tasks/$From/$($h.Name)" "tasks/$To/$($h.Name)"
        $paths += "tasks/$From/$($h.Name)"
        $paths += "tasks/$To/$($h.Name)"
    }
    return , $paths
}

function Invoke-Promote {
    # Spec 4.4. Returns the moved ids (filename ascending). -NoCommit: stage renames only.
    # Warnings go to Write-Host so the return value stays clean for claim/done callers
    # (child-process stdout still shows them, which the contract test relies on).
    param([switch]$NoCommit)
    $root = Get-RepoRoot
    $tasks = Get-TasksRoot
    $moved = @()
    $movedPaths = @()
    foreach ($f in Get-TaskFiles (Join-Path $tasks 'backlog')) {
        $t = Read-TaskFile $f.FullName
        if ($t.Errors.Count -gt 0) {
            Write-Host "MUSTER warn: backlog/$($f.Name) frontmatter invalid - skipped by promote."
            continue
        }
        $ok = $true
        foreach ($dep in @($t.Fields['depends_on'])) {
            if (-not (Test-DepSatisfied -TasksRoot $tasks -DepId $dep)) { $ok = $false; break }
        }
        if ($ok) {
            git -C $root mv "tasks/backlog/$($f.Name)" "tasks/inbox/$($f.Name)"
            $movedPaths += "tasks/backlog/$($f.Name)"
            $movedPaths += "tasks/inbox/$($f.Name)"
            $movedPaths += Move-TaskSidecars -RepoRoot $root -TasksRoot $tasks -Id $t.Id -From 'backlog' -To 'inbox'
            $moved += $t.Id
        }
    }
    if ($moved.Count -gt 0 -and -not $NoCommit) {
        git -C $root commit -q -m "muster: promote $($moved.Count)" -- @movedPaths
    }
    return , $moved
}
```

- [ ] **Step 4: Write `runtime/bin/promote.ps1`**

```powershell
# MUSTER promote - spec 4.4. Thin wrapper; logic in _lib.ps1.
param([switch]$NoCommit)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_lib.ps1')

[void](Invoke-Promote -NoCommit:$NoCommit)
exit 0
```

Note: `Invoke-Promote`'s `MUSTER warn:` lines go through Write-Host - visible on the
child process's stdout, never mixed into the moved-ids return value (claim/done
consume that).

- [ ] **Step 5: Run, verify pass, commit**

```bash
git add runtime/bin/_lib.ps1 runtime/bin/promote.ps1 tests/Promote.Tests.ps1
git commit -m "feat(bin): promote verb"
```

### Task 8: verify

**Files:**
- Create: `runtime/bin/verify.ps1`
- Modify: `runtime/bin/_lib.ps1` (append occupant + committed-read helpers)
- Create: `tests/Verify.Tests.ps1`

Spec 4.2. Key mechanics: the verify block is read from `git show HEAD:` (working-tree
edits inert, D20); attempt counter owned by the log file; terminal move at cap.

- [ ] **Step 1: Write failing contract tests**

`tests/Verify.Tests.ps1`:

```powershell
BeforeAll { . (Join-Path $PSScriptRoot 'MusterFixture.ps1') }

Describe 'bin/verify' {
    BeforeEach { $script:fx = New-MusterFixture }
    AfterEach { Remove-MusterFixture $script:fx }

    function New-DoingTask {
        param([string]$VerifyCmd = 'git --version', [string]$ExpectExit = '0')
        New-TaskFile -Fixture $script:fx -Folder doing -Id 'p-01-a' -VerifyCmd $VerifyCmd `
            -ExpectExit $ExpectExit -ExtraFront @('claimed_at: 2026-08-07T00:00:00Z') -Commit | Out-Null
    }

    It 'refuses when doing/ is empty' {
        $r = Invoke-Muster $script:fx 'verify'
        $r.Exit | Should -Be 1
        $r.Text | Should -Match '^MUSTER refuse:'
    }
    It 'passes a green task and logs attempt 1' {
        New-DoingTask
        $r = Invoke-Muster $script:fx 'verify'
        $r.Exit | Should -Be 0
        $r.Text | Should -Match 'VERIFY PASS \(attempt 1\)'
        (Get-Content (Join-Path $script:fx 'tasks/doing/p-01-a.verify.log') -Raw) |
            Should -Match '=== attempt 1 result: PASS'
    }
    It 'fails with exit 2 and increments attempts across runs' {
        New-DoingTask -VerifyCmd 'git frobnicate'
        (Invoke-Muster $script:fx 'verify').Exit | Should -Be 2
        $r2 = Invoke-Muster $script:fx 'verify'
        $r2.Exit | Should -Be 2
        $r2.Text | Should -Match 'VERIFY FAIL \(attempt 2 of 3\)'
    }
    It 'third failure is terminal: task moved to failed/, committed, exit 3' {
        New-DoingTask -VerifyCmd 'git frobnicate'
        Invoke-Muster $script:fx 'verify' | Out-Null
        Invoke-Muster $script:fx 'verify' | Out-Null
        $r3 = Invoke-Muster $script:fx 'verify'
        $r3.Exit | Should -Be 3
        $r3.Text | Should -Match 'VERIFY FAIL terminal'
        Test-Path (Join-Path $script:fx 'tasks/failed/p-01-a.md') | Should -BeTrue
        Test-Path (Join-Path $script:fx 'tasks/failed/p-01-a.verify.log') | Should -BeTrue
        Test-Path (Join-Path $script:fx 'tasks/doing/p-01-a.md') | Should -BeFalse
        (Get-FixtureCommits $script:fx)[0] | Should -Be 'muster(p): fail p-01-a'
    }
    It 'reads the verify block from HEAD, ignoring working-tree edits' {
        New-DoingTask -VerifyCmd 'git frobnicate'
        # Executor tampers: rewrite the committed task with an always-green cmd, unstaged.
        $path = Join-Path $script:fx 'tasks/doing/p-01-a.md'
        $text = [IO.File]::ReadAllText($path) -replace 'git frobnicate', 'git --version'
        [IO.File]::WriteAllText($path, $text)
        (Invoke-Muster $script:fx 'verify').Exit | Should -Be 2
    }
}
```

- [ ] **Step 2: Run, verify fail**

- [ ] **Step 3: Append occupant helpers to `_lib.ps1`**

```powershell
function Get-SoleOccupant {
    # The one task in doing/. Refuses (exit 1) when empty or ambiguous (spec 4.2/4.3).
    param([string]$TasksRoot)
    $files = @(Get-TaskFiles (Join-Path $TasksRoot 'doing'))
    if ($files.Count -eq 0) { Write-Refuse 'doing/ is empty - nothing in progress.' }
    if ($files.Count -gt 1) { Write-Refuse "doing/ holds $($files.Count) task files - one executor per checkout broke. RECOVERY in RUNNER.md." }
    return $files[0]
}

function Read-CommittedTask {
    # Claim-time copy: parse the task from the HEAD blob, not the working tree (D20).
    param([string]$RepoRoot, [string]$Name)
    $blob = git -C $RepoRoot show "HEAD:tasks/doing/$Name"
    if ($LASTEXITCODE -ne 0) { Write-Refuse "tasks/doing/$Name is not committed - claim did not complete. RECOVERY in RUNNER.md." }
    $r = Read-Frontmatter (($blob -join "`n"))
    $r['Id'] = [IO.Path]::GetFileNameWithoutExtension($Name)
    return $r
}

function Move-TaskToFailed {
    # Terminal move: task + live sidecars -> failed/, one pathspec commit (spec 4.2 step 6).
    param([string]$RepoRoot, [string]$TasksRoot, [string]$Id, [string]$Plan)
    $paths = @("tasks/doing/$Id.md", "tasks/failed/$Id.md")
    git -C $RepoRoot mv "tasks/doing/$Id.md" "tasks/failed/$Id.md"
    foreach ($side in "$Id.verify.log", "$Id.notes.md") {
        $src = Join-Path $TasksRoot "doing/$side"
        if (Test-Path $src) {
            Move-Item $src (Join-Path $TasksRoot "failed/$side")
            git -C $RepoRoot add "tasks/failed/$side"
            $paths += "tasks/failed/$side"
        }
    }
    git -C $RepoRoot commit -q -m "muster($Plan): fail $Id" -- @paths
}
```

- [ ] **Step 4: Write `runtime/bin/verify.ps1`**

```powershell
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
```

- [ ] **Step 5: Run, verify pass, commit**

```bash
git add runtime/bin/_lib.ps1 runtime/bin/verify.ps1 tests/Verify.Tests.ps1
git commit -m "feat(bin): verify verb with attempt cap and terminal move"
```

### Task 9: lint

**Files:**
- Create: `runtime/bin/lint.ps1`
- Modify: `runtime/bin/_lib.ps1` (append `Test-LintChecks`)
- Create: `tests/Lint.Tests.ps1`

Spec 2.6, all 13 checks. `-Lite` = checks 1-10 + 13 with the modified collision rule
(exempt the candidate itself; `generation` must be absent). Batch semantics: check 3
(deps exist) and 11/12 (integration/review wiring) look at the batch AND disk.
Output: one `LINT FAIL <file>: <msg>` line per finding, exit 1; else `LINT OK <n> file(s)`,
exit 0.

- [ ] **Step 1: Write failing contract tests**

`tests/Lint.Tests.ps1` (representative set - each check gets at least one negative case):

```powershell
BeforeAll { . (Join-Path $PSScriptRoot 'MusterFixture.ps1') }

Describe 'bin/lint' {
    BeforeEach { $script:fx = New-MusterFixture }
    AfterEach { Remove-MusterFixture $script:fx }

    function New-GoodBatch {
        # Minimal lintable plan batch: one impl + review + integration.
        $impl = New-TaskFile -Fixture $script:fx -Folder backlog -Id 'p-01-a' -CommitPaths @('src/out.txt')
        $rev = New-TaskFile -Fixture $script:fx -Folder backlog -Id 'p-02-review-a' -Type review -Tier strong `
            -DependsOn @('p-01-a') -ExtraFront @('reviews: p-01-a')
        $int = New-TaskFile -Fixture $script:fx -Folder backlog -Id 'p-99-integration' -Type integration -Tier strong `
            -DependsOn @('p-01-a', 'p-02-review-a')
        return @($impl, $rev, $int)
    }

    It 'passes a well-formed batch' {
        $batch = New-GoodBatch
        $rel = $batch | ForEach-Object { $_.Substring($script:fx.Length + 1).Replace('\', '/') }
        $r = Invoke-MusterLint $script:fx -Paths $rel
        $r.Text | Should -Match 'LINT OK 3'
        $r.Exit | Should -Be 0
    }
    It 'check 2: flags id not matching filename and filename collisions' {
        $batch = New-GoodBatch
        New-TaskFile -Fixture $script:fx -Folder done -Id 'p-01-a' | Out-Null   # collision on disk
        $rel = $batch | ForEach-Object { $_.Substring($script:fx.Length + 1).Replace('\', '/') }
        $r = Invoke-MusterLint $script:fx -Paths $rel
        $r.Exit | Should -Be 1
        $r.Text | Should -Match 'collision'
    }
    It 'check 3: flags a depends_on id that exists neither in batch nor on disk' {
        $p = New-TaskFile -Fixture $script:fx -Folder backlog -Id 'p-01-a' -DependsOn @('p-00-ghost')
        $r = Invoke-MusterLint $script:fx -Paths @('tasks/backlog/p-01-a.md')
        $r.Exit | Should -Be 1
        $r.Text | Should -Match 'p-00-ghost'
    }
    It 'check 4: flags shell metacharacters and network commands' {
        New-TaskFile -Fixture $script:fx -Folder backlog -Id 'p-01-a' -VerifyCmd 'git --version | sort' | Out-Null
        (Invoke-MusterLint $script:fx -Paths @('tasks/backlog/p-01-a.md')).Exit | Should -Be 1
        New-TaskFile -Fixture $script:fx -Folder backlog -Id 'p-02-b' -VerifyCmd 'npm install left-pad' | Out-Null
        (Invoke-MusterLint $script:fx -Paths @('tasks/backlog/p-02-b.md')).Text | Should -Match 'network'
    }
    It 'check 4: allows a network command when harness is claude' {
        New-TaskFile -Fixture $script:fx -Folder backlog -Id 'p-01-a' -VerifyCmd 'dotnet restore App.csproj' `
            -ExtraFront @('harness: claude') | Out-Null
        $r = Invoke-MusterLint $script:fx -Paths @('tasks/backlog/p-01-a.md')
        $r.Text | Should -Not -Match 'network'
    }
    It 'check 5: impl verify paths must be protected or committed' {
        New-TaskFile -Fixture $script:fx -Folder backlog -Id 'p-01-a' `
            -VerifyCmd 'powershell -File scripts/check.ps1' -Protected @('README.md') -CommitPaths @('src/out.txt') | Out-Null
        $r = Invoke-MusterLint $script:fx -Paths @('tasks/backlog/p-01-a.md')
        $r.Exit | Should -Be 1
        $r.Text | Should -Match 'scripts/check.ps1'
    }
    It 'checks 7-9: placeholders, un-inlined references, judgment language' {
        $body = "# p-01-a: t`n`n## Context`n`nsee docs/plan.md`n`n## Steps`n`n1. Handle edge cases as appropriate. TODO`n`n## Acceptance`n`n- x"
        New-TaskFile -Fixture $script:fx -Folder backlog -Id 'p-01-a' -Body $body | Out-Null
        $r = Invoke-MusterLint $script:fx -Paths @('tasks/backlog/p-01-a.md')
        $r.Exit | Should -Be 1
        foreach ($sig in 'placeholder', 'reference', 'judgment') { $r.Text | Should -Match $sig }
    }
    It 'check 10: heading order enforced' {
        $body = "# p-01-a: t`n`n## Steps`n`n1. Ensure x.`n`n## Context`n`nx`n`n## Acceptance`n`n- x"
        New-TaskFile -Fixture $script:fx -Folder backlog -Id 'p-01-a' -Body $body | Out-Null
        $r = Invoke-MusterLint $script:fx -Paths @('tasks/backlog/p-01-a.md')
        $r.Exit | Should -Be 1
        $r.Text | Should -Match 'headings missing or out of order'
    }
    It 'check 11: full mode requires exactly one seq-99 strong integration task depending on all' {
        $impl = New-TaskFile -Fixture $script:fx -Folder backlog -Id 'p-01-a'
        $r = Invoke-MusterLint $script:fx -Paths @('tasks/backlog/p-01-a.md')
        $r.Exit | Should -Be 1
        $r.Text | Should -Match 'integration'
    }
    It 'lite mode: skips 11/12, exempts self-collision, rejects generation' {
        New-TaskFile -Fixture $script:fx -Folder staging -Id 'p-01-fix-a' -Type fix `
            -ExtraFront @('fixes: p-01-a') | Out-Null
        $r = Invoke-MusterLint $script:fx -Paths @('tasks/staging/p-01-fix-a.md') -Lite
        $r.Exit | Should -Be 0
        New-TaskFile -Fixture $script:fx -Folder staging -Id 'p-02-fix-b' -Type fix `
            -ExtraFront @('fixes: p-02-b', 'generation: 1') | Out-Null
        (Invoke-MusterLint $script:fx -Paths @('tasks/staging/p-02-fix-b.md') -Lite).Exit | Should -Be 1
    }
    It 'check 13: commit_paths non-empty on impl' {
        $p = Join-Path $script:fx 'tasks/backlog/p-01-a.md'
        New-TaskFile -Fixture $script:fx -Folder backlog -Id 'p-01-a' | Out-Null
        $text = [IO.File]::ReadAllText($p) -replace "commit_paths:`n  - src/out.txt", 'commit_paths: []'
        [IO.File]::WriteAllText($p, $text)
        $r = Invoke-MusterLint $script:fx -Paths @('tasks/backlog/p-01-a.md')
        $r.Exit | Should -Be 1
        $r.Text | Should -Match 'commit_paths empty'
    }
}
```

- [ ] **Step 2: Run, verify fail**

- [ ] **Step 3: Append `Test-LintChecks` to `_lib.ps1`**

```powershell
function Test-LintChecks {
    # Spec 2.6. $Paths: repo-relative batch. Returns string[] 'file: message' findings.
    # -Lite: checks 1-10 + 13, candidate exempt from its own collision, generation must be absent.
    param([string]$RepoRoot, [string[]]$Paths, [switch]$Lite)
    $tasks = Join-Path $RepoRoot 'tasks'
    $findings = @()
    $batch = @()
    foreach ($p in $Paths) {
        $full = Join-Path $RepoRoot $p
        if (-not (Test-Path $full)) { $findings += "${p}: file not found"; continue }
        $batch += , (Read-TaskFile $full)
    }
    $batchIds = @($batch | ForEach-Object { $_.Id })

    foreach ($t in $batch) {
        $name = Split-Path $t.Path -Leaf
        $pfx = $name

        # 1. frontmatter parses + schema per type
        if ($t.Errors.Count -gt 0) { $findings += "${pfx}: frontmatter: $($t.Errors[0])"; continue }
        foreach ($err in (Test-TaskSchema $t.Fields -Staged:$Lite)) { $findings += "${pfx}: $err" }
        if (-not $t.Fields.ContainsKey('type')) { continue }
        $type = $t.Fields['type']

        # 2. id = stem; filename pattern; collision anywhere under tasks/
        if ($t.Fields['id'] -ne $t.Id) { $findings += "${pfx}: id '$($t.Fields['id'])' does not equal filename stem" }
        $pat = '^[a-z0-9-]+-\d{2}-[a-z0-9-]+$'
        if ($Lite) { $pat = '^[a-z0-9-]+-\d{2}-fix-[a-z0-9-]+$' }
        if ($t.Id -notmatch $pat) { $findings += "${pfx}: filename does not match the task pattern (spec 2.1)" }
        $dupes = @(Get-ChildItem -Path $tasks -Recurse -File -Filter "$($t.Id).md" |
            Where-Object { $_.FullName -ne (Resolve-Path $t.Path).Path })
        if ($dupes.Count -gt 0) { $findings += "${pfx}: filename collision under tasks/ ($($dupes[0].FullName))" }

        # 3. every depends_on exists in batch or on disk
        foreach ($dep in @($t.Fields['depends_on'])) {
            if ($batchIds -contains $dep) { continue }
            $hit = @(Get-ChildItem -Path $tasks -Recurse -File -Filter "$dep.md")
            if ($hit.Count -eq 0) { $findings += "${pfx}: depends_on '$dep' exists nowhere" }
        }

        # 4. verify: metacharacters + network denylist
        $netRx = '(^|\s)(curl|wget|nuget|iwr|Invoke-WebRequest)(\s|$)|git (fetch|pull|push)|npm (install|ci)|dotnet restore|pip install'
        foreach ($en in @($t.Fields['verify'])) {
            if ($en -isnot [hashtable] -or -not $en.ContainsKey('cmd')) { continue }
            $cmd = $en['cmd']
            if ($cmd -match '[|><;`]|\$\(|&&') { $findings += "${pfx}: verify cmd has shell metacharacters: $cmd" }
            $harness = ''
            if ($t.Fields.ContainsKey('harness')) { $harness = $t.Fields['harness'] }
            if ($cmd -match $netRx -and $harness -ne 'claude') {
                $findings += "${pfx}: verify cmd needs network but harness is not claude: $cmd"
            }
            # 5. impl/fix: repo paths named in cmd must be protected or committed (heuristic:
            #    tokens containing / that are not flags)
            if ($type -eq 'impl' -or $type -eq 'fix') {
                $listed = @($t.Fields['protected']) + @($t.Fields['commit_paths'])
                $toks = @()
                try { $toks = Split-CmdLine $cmd }
                catch { $findings += "${pfx}: verify cmd unparseable (unbalanced quote): $cmd" }
                foreach ($tok in $toks) {
                    if ($tok -notmatch '/' -or $tok -match '^-') { continue }
                    $inList = $false
                    foreach ($l in $listed) {
                        if ($tok -eq $l -or $tok.StartsWith(($l.TrimEnd('/') + '/'))) { $inList = $true; break }
                    }
                    if (-not $inList) { $findings += "${pfx}: verify path '$tok' not in protected or commit_paths" }
                }
            }
        }

        $raw = [IO.File]::ReadAllText($t.Path)

        # 6. size cap
        if ((($raw -split "`n").Count) -gt 300 -or ([Text.Encoding]::UTF8.GetByteCount($raw) -gt 16KB)) {
            $findings += "${pfx}: over the size cap (300 lines / 16 KB) - reshard"
        }
        # 7. placeholders (incl. surviving template braces). The brace patterns cover
        #    multi-word slots like {inlined plan snapshot summary: ...} and {...};
        #    tradeoff: code snippets with lowercase braced text can false-positive -
        #    acceptable, shard rewrites or fills them.
        foreach ($rx in 'TBD', 'TODO', 'FIXME', '<fill', '\{placeholder', '\{\.\.\.\}', '\{[a-z][a-z0-9 ,:.-]*\}', '(?m)^\s*\d+\.\s*\.\.\.\s*$') {
            if ($raw -match $rx) { $findings += "${pfx}: placeholder text matches '$rx'"; break }
        }
        # 8. un-inlined references (heuristic, spec 2.6.8)
        foreach ($rx in 'see docs/', 'refer to', 'as described in', 'per the plan') {
            if ($raw -match [regex]::Escape($rx)) { $findings += "${pfx}: un-inlined reference ('$rx')"; break }
        }
        # 9. judgment language in Steps (heuristic, spec 2.6.9)
        $steps = ''
        if ($raw -match '(?s)## Steps(.*?)(## Acceptance|$)') { $steps = $Matches[1] }
        foreach ($rx in 'if needed', 'as appropriate', 'appropriately', 'handle edge cases') {
            if ($steps -match [regex]::Escape($rx)) { $findings += "${pfx}: judgment language in Steps ('$rx')"; break }
        }
        # 10. heading order
        if ($raw -notmatch '(?s)# .+?## Context.+?## Steps.+?## Acceptance') {
            $findings += "${pfx}: body headings missing or out of order (Context, Steps, Acceptance)"
        }
        # 13. commit_paths non-empty on impl/fix
        if (($type -eq 'impl' -or $type -eq 'fix') -and @($t.Fields['commit_paths']).Count -eq 0) {
            $findings += "${pfx}: commit_paths empty"
        }
    }

    if (-not $Lite) {
        # 11. exactly one integration task, seq 99, strong, depends on every other batch id
        $ints = @($batch | Where-Object { $_.Errors.Count -eq 0 -and $_.Fields['type'] -eq 'integration' })
        if ($ints.Count -ne 1) { $findings += "batch: expected exactly 1 integration task, found $($ints.Count)" }
        else {
            $int = $ints[0]
            if ($int.Id -notmatch '-99-') { $findings += "$($int.Id).md: integration task must use seq 99" }
            if ($int.Fields['tier'] -ne 'strong') { $findings += "$($int.Id).md: integration task must be tier: strong" }
            foreach ($other in $batchIds) {
                if ($other -eq $int.Id) { continue }
                if (@($int.Fields['depends_on']) -notcontains $other) {
                    $findings += "$($int.Id).md: integration depends_on missing '$other'"
                }
            }
        }
        # 12. review wiring
        foreach ($t in @($batch | Where-Object { $_.Errors.Count -eq 0 -and $_.Fields['type'] -eq 'review' })) {
            $target = $t.Fields['reviews']
            if ($batchIds -notcontains $target) { $findings += "$($t.Id).md: reviews '$target' not in batch" }
            if (@($t.Fields['depends_on']) -notcontains $target) {
                $findings += "$($t.Id).md: review depends_on must include its reviews id"
            }
        }
    }
    return , $findings
}
```

- [ ] **Step 4: Write `runtime/bin/lint.ps1`**

```powershell
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
```

- [ ] **Step 5: Run, verify pass, commit**

```bash
git add runtime/bin/_lib.ps1 runtime/bin/lint.ps1 tests/Lint.Tests.ps1
git commit -m "feat(bin): lint - shard-lint checklist plus lint-lite"
```

### Task 10: claim - status, refusals, selection, pinning, claim commit

**Files:**
- Create: `runtime/bin/claim.ps1`
- Modify: `runtime/bin/_lib.ps1` (append status/dirty/stamp helpers)
- Create: `tests/Claim.Tests.ps1`

Spec 4.1 steps 1-8 and 10. The recovery probe (step 9) is Task 13 - it needs the
completion machinery from Tasks 11-12. `claim.ps1` is written as a selection loop from
the start so Task 13 only inserts the probe block.

- [ ] **Step 1: Write failing contract tests**

`tests/Claim.Tests.ps1`:

```powershell
BeforeAll { . (Join-Path $PSScriptRoot 'MusterFixture.ps1') }

Describe 'bin/claim' {
    BeforeEach { $script:fx = New-MusterFixture }
    AfterEach { Remove-MusterFixture $script:fx }

    It 'refuses without identity flags' {
        $r = Invoke-Muster $script:fx 'claim'
        $r.Exit | Should -Be 1
        $r.Text | Should -Match 'MUSTER refuse: claim requires'
    }
    It 'prints the empty-board line on an empty board' {
        $r = Invoke-MusterClaim $script:fx
        $r.Text | Should -Match 'MUSTER: board empty - nothing sharded or all archived\.'
        $r.Exit | Should -Be 1   # then refuses: nothing to claim
    }
    It 'prints the status block before any refusal' {
        New-TaskFile -Fixture $script:fx -Folder doing -Id 'p-01-a' `
            -ExtraFront @('claimed_at: 2026-08-01T00:00:00Z') -Commit | Out-Null
        $r = Invoke-MusterClaim $script:fx
        $r.Exit | Should -Be 1
        $r.Out[0] | Should -Match '^MUSTER status @'
        $r.Text | Should -Match 'STALE'
        $r.Text | Should -Match 'MUSTER refuse: doing/ occupied by p-01-a \(claimed \d+[mhd] ago\)\. One executor per checkout\. RECOVERY in RUNNER\.md\.'
    }
    It 'refuses on a stale staging file' {
        New-TaskFile -Fixture $script:fx -Folder inbox -Id 'p-01-a' -Commit | Out-Null
        New-TaskFile -Fixture $script:fx -Folder staging -Id 'p-01-fix-a' -Type fix `
            -ExtraFront @('fixes: p-01-a') | Out-Null
        $r = Invoke-MusterClaim $script:fx
        $r.Exit | Should -Be 1
        $r.Text | Should -Match 'MUSTER refuse: stale fix task in tasks/staging/: p-01-fix-a\.md\.'
    }
    It 'claims the lowest eligible filename, stamps claimed_at, commits' {
        New-TaskFile -Fixture $script:fx -Folder inbox -Id 'p-02-b' -Commit | Out-Null
        New-TaskFile -Fixture $script:fx -Folder inbox -Id 'p-01-a' -Commit | Out-Null
        $r = Invoke-MusterClaim $script:fx
        $r.Exit | Should -Be 0
        $r.Text | Should -Match 'Claimed p-01-a\. Follow tasks/RUNNER\.md\.'
        $doing = Join-Path $script:fx 'tasks/doing/p-01-a.md'
        Test-Path $doing | Should -BeTrue
        (Get-Content $doing -Raw) | Should -Match '(?m)^claimed_at: \d{4}-\d{2}-\d{2}T'
        (Get-FixtureCommits $script:fx)[0] | Should -Be 'muster(p): claim p-01-a'
        (git -C $script:fx status --porcelain) | Should -BeNullOrEmpty
    }
    It 'enforces tier pinning both directions' {
        New-TaskFile -Fixture $script:fx -Folder inbox -Id 'p-01-a' -Tier strong -Type review `
            -ExtraFront @('reviews: p-00-x') -Commit | Out-Null
        $r = Invoke-MusterClaim $script:fx -Tier any
        $r.Exit | Should -Be 1
        $r.Text | Should -Match 'MUSTER refuse: nothing to claim for claude/any\.'
        New-TaskFile -Fixture $script:fx -Folder inbox -Id 'p-02-b' -Commit | Out-Null
        $r2 = Invoke-MusterClaim $script:fx -Tier strong    # strong sessions claim ONLY strong tasks
        $r2.Text | Should -Match 'Claimed p-01-a'
    }
    It 'skips tasks pinned to a different harness' {
        New-TaskFile -Fixture $script:fx -Folder inbox -Id 'p-01-a' -ExtraFront @('harness: codex') -Commit | Out-Null
        $r = Invoke-MusterClaim $script:fx -Harness claude
        $r.Text | Should -Match 'nothing to claim for claude/any'
    }
    It 'refuses loudly on malformed frontmatter, task stays in inbox' {
        $bad = Join-Path $script:fx 'tasks/inbox/p-01-bad.md'
        [IO.File]::WriteAllText($bad, "---`nid: p-01-bad`n---`nbody")
        git -C $script:fx add 'tasks/inbox/p-01-bad.md'
        git -C $script:fx commit -qm 'fixture: bad task'
        $r = Invoke-MusterClaim $script:fx
        $r.Exit | Should -Be 1
        $r.Text | Should -Match 'MUSTER refuse: p-01-bad frontmatter invalid: .+\. Task left in inbox/ for a human\.'
        Test-Path $bad | Should -BeTrue
    }
    It 'refuses when the tree is dirty outside the selected task scope' {
        New-TaskFile -Fixture $script:fx -Folder inbox -Id 'p-01-a' -CommitPaths @('src/out.txt') -Commit | Out-Null
        [IO.File]::WriteAllText((Join-Path $script:fx 'stray.txt'), 'x')
        $r = Invoke-MusterClaim $script:fx
        $r.Exit | Should -Be 1
        $r.Text | Should -Match "MUSTER refuse: working tree dirty outside p-01-a's commit_paths: stray\.txt\. Not this task's work - RECOVERY \(RUNNER\.md\)\."
    }
    It 'tolerates dirt inside the selected task commit_paths and under tasks/' {
        New-TaskFile -Fixture $script:fx -Folder inbox -Id 'p-01-a' -CommitPaths @('src/out.txt') -Commit | Out-Null
        New-Item -ItemType Directory (Join-Path $script:fx 'src') | Out-Null
        [IO.File]::WriteAllText((Join-Path $script:fx 'src/out.txt'), 'half-done')
        (Invoke-MusterClaim $script:fx).Exit | Should -Be 0
    }
    It 'runs promote first: a satisfied backlog task becomes claimable in the same call' {
        New-TaskFile -Fixture $script:fx -Folder done -Id 'p-01-a' -Commit | Out-Null
        New-TaskFile -Fixture $script:fx -Folder backlog -Id 'p-02-b' -DependsOn @('p-01-a') -Commit | Out-Null
        $r = Invoke-MusterClaim $script:fx
        $r.Text | Should -Match 'Claimed p-02-b'
    }
    It 'prints the full task body before the Claimed line' {
        New-TaskFile -Fixture $script:fx -Folder inbox -Id 'p-01-a' -Commit | Out-Null
        $r = Invoke-MusterClaim $script:fx
        $r.Text | Should -Match '## Steps'
    }
}
```

- [ ] **Step 2: Run, verify fail**

- [ ] **Step 3: Append status/dirty/stamp helpers to `_lib.ps1`**

```powershell
function Get-StatusBlock {
    # Spec 8.3. STALE marker and DEAD lines appear only when present.
    param([string]$RepoRoot, [string]$TasksRoot)
    $inbox = @(Get-TaskFiles (Join-Path $TasksRoot 'inbox'))
    $doing = @(Get-TaskFiles (Join-Path $TasksRoot 'doing'))
    $backlog = @(Get-TaskFiles (Join-Path $TasksRoot 'backlog'))
    $failed = @(Get-TaskFiles (Join-Path $TasksRoot 'failed'))
    $done = @(Get-TaskFiles (Join-Path $TasksRoot 'done'))
    if (($inbox.Count + $doing.Count + $backlog.Count + $failed.Count + $done.Count) -eq 0) {
        return 'MUSTER: board empty - nothing sharded or all archived.'
    }
    $stem = { param($f) [IO.Path]::GetFileNameWithoutExtension($f.Name) }
    $lines = @()
    $branch = git -C $RepoRoot rev-parse --abbrev-ref HEAD
    $lines += "MUSTER status @ $(Split-Path $RepoRoot -Leaf) ($branch)"
    $lines += "  inbox    $($inbox.Count) ready      [$((@($inbox | ForEach-Object $stem)) -join ', ')]"
    $doingCell = ''
    foreach ($d in $doing) {
        $t = Read-TaskFile $d.FullName
        $age = 'unknown'
        $stale = ''
        if ($t.Fields.ContainsKey('claimed_at')) {
            $age = Get-AgeString $t.Fields['claimed_at']
            $then = [datetime]::Parse($t.Fields['claimed_at'], [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::AdjustToUniversal)
            if (((Get-Date).ToUniversalTime() - $then).TotalHours -gt 24) {
                $stale = '        <- STALE: see RUNNER.md RECOVERY'
            }
        }
        $doingCell = "[$($t.Id) claimed $age]$stale"
    }
    $lines += "  doing    $($doing.Count)            $doingCell".TrimEnd()
    $dead = @()
    foreach ($b in $backlog) {
        $t = Read-TaskFile $b.FullName
        if ($t.Errors.Count -gt 0) { continue }
        foreach ($dep in @($t.Fields['depends_on'])) {
            if (Test-Path (Join-Path $TasksRoot "failed/$dep.md")) { $dead += "$($t.Id) behind failed $dep"; break }
        }
    }
    $deadCell = ''
    if ($dead.Count -gt 0) { $deadCell = "    ($($dead.Count) DEAD: $($dead -join '; '))" }
    $lines += "  backlog  $($backlog.Count) blocked$deadCell".TrimEnd()
    $lines += "  failed   $($failed.Count)            [$((@($failed | ForEach-Object $stem)) -join ', ')]".TrimEnd()
    $lines += "  done     $($done.Count)"
    return ($lines -join "`n")
}

function Get-DirtyPaths {
    # Worktree + index dirt as repo-relative paths (rename lines yield both sides).
    # --untracked-files=all: without it git collapses a new src/out.txt to '?? src/',
    # which would defeat the commit_paths whitelist.
    param([string]$RepoRoot)
    $paths = @()
    foreach ($line in @(git -C $RepoRoot status --porcelain --untracked-files=all)) {
        if (-not $line) { continue }
        $p = $line.Substring(3)
        if ($p -match '^(.+) -> (.+)$') { $paths += $Matches[1]; $paths += $Matches[2] }
        else { $paths += $p }
    }
    return , @($paths | ForEach-Object { $_.Trim('"') })
}

function Test-PathListed {
    # True when $Path equals a list entry or sits under a listed directory.
    param([string]$Path, [string[]]$List)
    foreach ($c in $List) {
        if ($Path -eq $c -or $Path.StartsWith(($c.TrimEnd('/') + '/'))) { return $true }
    }
    return $false
}

function Test-PathInScope {
    # Claim/done scope rule: tasks/ itself is always in scope (spec 4.1.7 / 4.3.4).
    param([string]$Path, [string[]]$CommitPaths)
    if ($Path -eq 'tasks' -or $Path.StartsWith('tasks/')) { return $true }
    return (Test-PathListed -Path $Path -List $CommitPaths)
}

function Set-ClaimedAt {
    # Stamp (or replace) claimed_at as the last frontmatter line. Script-only edit (D17).
    param([string]$Path, [string]$Iso)
    $lines = [IO.File]::ReadAllText($Path) -split "`r?`n"
    $close = 0
    for ($j = 1; $j -lt $lines.Count; $j++) { if ($lines[$j] -eq '---') { $close = $j; break } }
    $out = @()
    for ($j = 0; $j -lt $lines.Count; $j++) {
        if ($j -gt 0 -and $lines[$j] -match '^claimed_at:') { continue }
        if ($j -eq $close) { $out += "claimed_at: $Iso" }
        $out += $lines[$j]
    }
    Write-Utf8 $Path ($out -join "`n")
}

```

(`Move-TaskSidecars` already exists - Task 7 added it for promote; claim reuses it here.)

- [ ] **Step 4: Write `runtime/bin/claim.ps1`**

```powershell
# MUSTER claim - spec 4.1. The recovery probe (step 9) lands in a later commit.
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
        $schemaErr = @(Test-TaskSchema $t.Fields)
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
    $outOfScope = @(Get-DirtyPaths $root | Where-Object { -not (Test-PathInScope -Path $_ -CommitPaths $cp) })
    if ($outOfScope.Count -gt 0) {
        Write-Refuse "working tree dirty outside $id's commit_paths: $($outOfScope -join ', '). Not this task's work - RECOVERY (RUNNER.md)."
    }

    # 8. rename, stamp, claim commit (D21) - probe evidence gathered before the rename
    $priorClaims = @(git -C $root log --oneline -- "tasks/doing/$name")
    git -C $root mv "tasks/inbox/$name" "tasks/doing/$name"
    $sidecarPaths = Move-TaskSidecars -RepoRoot $root -TasksRoot $tasks -Id $id -From 'inbox' -To 'doing'
    $doingPath = Join-Path $tasks "doing/$name"
    Set-ClaimedAt -Path $doingPath -Iso (Get-IsoNow)
    $commitPaths = @("tasks/inbox/$name", "tasks/doing/$name") + $sidecarPaths
    git -C $root commit -q -m "muster($($selected.Fields['plan'])): claim $id" -- @commitPaths
    $selected = Read-TaskFile $doingPath   # re-read: claimed_at now present

    # 9. recovery probe - inserted by a later task in this plan

    # 10. print the task and hand over to RUNNER.md
    Write-Output ([IO.File]::ReadAllText($doingPath))
    Write-Output "Claimed $id. Follow tasks/RUNNER.md."
    exit 0
}
```

- [ ] **Step 5: Run, verify pass** - the two probe tests do not exist yet; all listed
tests must pass.

- [ ] **Step 6: Commit**

```bash
git add runtime/bin/_lib.ps1 runtime/bin/claim.ps1 tests/Claim.Tests.ps1
git commit -m "feat(bin): claim verb - status, pinning, scoped dirty check, claim commit"
```

### Task 11: Lib - result assembly + completion machinery

**Files:**
- Modify: `runtime/bin/_lib.ps1` (append)
- Modify: `tests/Lib.Tests.ps1` (append)

Spec 3.1 (result sidecar) and 4.3 steps 6-9 (pass path mechanics), shared by `done`
and the claim probe. Interpretation pinned here: for review/integration results the
notes file folds into `## Findings` and `## Surprises` reads `none reported`; for
impl/fix it folds into `## Surprises`.

- [ ] **Step 1: Append failing tests**

```powershell
Describe 'completion machinery' {
    BeforeEach { $script:fx = New-MusterFixture }
    AfterEach { Remove-MusterFixture $script:fx }

    function Add-ClaimedDoingTask {
        param([string]$Id = 'p-01-a', [string]$Type = 'impl', [string[]]$ExtraFront = @())
        $extra = @("claimed_at: 2026-08-07T01:00:00Z") + $ExtraFront
        New-TaskFile -Fixture $script:fx -Folder doing -Id $Id -Type $Type `
            -CommitPaths @('src/out.txt') -ExtraFront $extra -Commit | Out-Null
    }

    It 'Get-ClaimCommit returns the last commit touching the doing path' {
        Add-ClaimedDoingTask
        Push-Location $script:fx
        try {
            . (Join-Path $script:RepoRoot 'runtime/bin/_lib.ps1')
            (Get-ClaimCommit -RepoRoot $script:fx -Name 'p-01-a.md') |
                Should -Be (git -C $script:fx rev-parse HEAD)
        }
        finally { Pop-Location }
    }
    It 'Complete-Task assembles the sidecar, moves files, folds promotions, one commit' {
        Add-ClaimedDoingTask
        New-TaskFile -Fixture $script:fx -Folder backlog -Id 'p-02-b' -DependsOn @('p-01-a') -Commit | Out-Null
        New-Item -ItemType Directory (Join-Path $script:fx 'src') | Out-Null
        [IO.File]::WriteAllText((Join-Path $script:fx 'src/out.txt'), 'payload')
        [IO.File]::WriteAllText((Join-Path $script:fx 'tasks/doing/p-01-a.notes.md'), 'one surprise')
        Push-Location $script:fx
        try {
            . (Join-Path $script:RepoRoot 'runtime/bin/_lib.ps1')
            $task = Read-TaskFile (Join-Path $script:fx 'tasks/doing/p-01-a.md')
            $cc = Get-ClaimCommit -RepoRoot $script:fx -Name 'p-01-a.md'
            $promoted = Complete-Task -RepoRoot $script:fx -TasksRoot (Join-Path $script:fx 'tasks') `
                -Fields $task.Fields -Id 'p-01-a' -ClaimCommit $cc
            $promoted | Should -Contain 'p-02-b'
        }
        finally { Pop-Location }
        $result = Get-Content (Join-Path $script:fx 'tasks/done/p-01-a.result.md') -Raw
        $result | Should -Match '(?m)^- status: done$'
        $result | Should -Match '(?m)^  - src/out.txt$'
        $result | Should -Match 'one surprise'
        Test-Path (Join-Path $script:fx 'tasks/doing/p-01-a.notes.md') | Should -BeFalse
        Test-Path (Join-Path $script:fx 'tasks/inbox/p-02-b.md') | Should -BeTrue
        (Get-FixtureCommits $script:fx)[0] | Should -Be 'muster(p): done p-01-a'
        (git -C $script:fx status --porcelain) | Should -BeNullOrEmpty
        (git -C $script:fx show --name-only --format= HEAD) | Should -Contain 'src/out.txt'
    }
    It 'review results fold notes into Findings' {
        Add-ClaimedDoingTask -Id 'p-02-review-a' -Type review -ExtraFront @('reviews: p-01-a')
        [IO.File]::WriteAllText((Join-Path $script:fx 'tasks/doing/p-02-review-a.notes.md'), 'looks solid')
        Push-Location $script:fx
        try {
            . (Join-Path $script:RepoRoot 'runtime/bin/_lib.ps1')
            $task = Read-TaskFile (Join-Path $script:fx 'tasks/doing/p-02-review-a.md')
            $cc = Get-ClaimCommit -RepoRoot $script:fx -Name 'p-02-review-a.md'
            [void](Complete-Task -RepoRoot $script:fx -TasksRoot (Join-Path $script:fx 'tasks') `
                -Fields $task.Fields -Id 'p-02-review-a' -ClaimCommit $cc -Verdict 'pass')
        }
        finally { Pop-Location }
        $result = Get-Content (Join-Path $script:fx 'tasks/done/p-02-review-a.result.md') -Raw
        $result | Should -Match '(?m)^- verdict: pass$'
        $result | Should -Match '(?s)## Findings.*looks solid'
    }
}
```

Note: `Add-ClaimedDoingTask` commits the doing/ file directly - that commit doubles as
the claim commit for `Get-ClaimCommit`, which is exactly the derivation under test.

- [ ] **Step 2: Run, verify fail**

- [ ] **Step 3: Append to `_lib.ps1`**

```powershell
function Get-ClaimCommit {
    # Derived, never stored (spec 4.3.1): last commit touching the doing/ path.
    param([string]$RepoRoot, [string]$Name)
    $sha = git -C $RepoRoot log -n 1 --format=%H -- "tasks/doing/$Name"
    if (-not $sha) { Write-Refuse "no claim commit found for tasks/doing/$Name. RECOVERY in RUNNER.md." }
    return $sha
}

function Get-ChangedPaths {
    # Tracked changes since the claim commit PLUS untracked new files - a bare
    # diff --name-only misses exactly the normal impl output (a newly created file).
    param([string]$RepoRoot, [string]$ClaimCommit)
    $changed = @(git -C $RepoRoot diff --name-only $ClaimCommit)
    $changed += @(git -C $RepoRoot ls-files --others --exclude-standard)
    return , @($changed | Sort-Object -Unique)
}

function Test-DonePreconditions {
    # Protected + scope checks (spec 4.3 pre 3-4). Returns $null or the refusal message.
    param([string]$RepoRoot, [hashtable]$Fields, [string]$ClaimCommit)
    $changed = @(Get-ChangedPaths -RepoRoot $RepoRoot -ClaimCommit $ClaimCommit)
    $protected = @()
    if ($Fields.ContainsKey('protected')) { $protected = @($Fields['protected']) }
    $hits = @($changed | Where-Object { Test-PathListed -Path $_ -List $protected })
    if ($hits.Count -gt 0) {
        return "protected file(s) modified: $($hits -join ', '). Revert them; the verify definition is not yours to change."
    }
    $cp = @()
    if ($Fields.ContainsKey('commit_paths')) { $cp = @($Fields['commit_paths']) }
    $extras = @($changed | Where-Object { -not (Test-PathInScope -Path $_ -CommitPaths $cp) })
    if ($extras.Count -gt 0) {
        return "changed outside commit_paths: $($extras -join ', '). Revert strays or stop for a human."
    }
    return $null
}

function New-ResultSidecar {
    # Spec 3.1. Everything above Surprises comes from git + the log; the model only wrote notes.
    # $Attempts -1 = read the live log; pass an explicit count when the log has already
    # been moved (done-fail cycling). -Probe marks the claim auto-file case.
    param([string]$RepoRoot, [string]$TasksRoot, [hashtable]$Fields, [string]$Id, [string]$ClaimCommit,
        [string]$Status, [string]$Verdict = '', [string]$SurprisesOverride = '',
        [int]$Attempts = -1, [switch]$Probe)
    if ($Attempts -lt 0) { $Attempts = Get-AttemptCount (Join-Path $TasksRoot "doing/$Id.verify.log") }
    $verifyLine = "verify: pass (attempt $Attempts of 3)"
    if ($Attempts -eq 0) {
        $verifyLine = 'verify: pass (done-check only)'
        if ($Probe) { $verifyLine = 'verify: pass (claim-probe)' }
    }
    $claimedAt = ''
    if ($Fields.ContainsKey('claimed_at')) { $claimedAt = $Fields['claimed_at'] }
    $lines = @("# Result: $Id", '', "- status: $Status")
    if ($Verdict) { $lines += "- verdict: $Verdict" }
    $lines += "- claim_commit: $ClaimCommit"
    $lines += "- claimed_at: $claimedAt"
    $lines += "- completed_at: $(Get-IsoNow)"
    $lines += "- $verifyLine"
    $lines += '- files_changed:'
    foreach ($f in @(Get-ChangedPaths -RepoRoot $RepoRoot -ClaimCommit $ClaimCommit)) { $lines += "  - $f" }
    $notesPath = Join-Path $TasksRoot "doing/$Id.notes.md"
    $notesText = 'none reported'
    if (Test-Path $notesPath) { $notesText = ([IO.File]::ReadAllText($notesPath)).TrimEnd() }
    if ($SurprisesOverride) { $notesText = $SurprisesOverride }
    $lines += @('', '## Surprises', '')
    $type = $Fields['type']
    if ($type -eq 'review' -or $type -eq 'integration') {
        $lines += 'none reported'
        $lines += @('', '## Findings', '', $notesText)
    }
    else { $lines += $notesText }
    return (($lines -join "`n") + "`n")
}

function Complete-Task {
    # Pass-path mechanics (spec 4.3 steps 6-9), also used by the claim probe's auto-file.
    # Assembles the sidecar, moves task + sidecars to done/, folds promotions, ONE commit.
    param([string]$RepoRoot, [string]$TasksRoot, [hashtable]$Fields, [string]$Id, [string]$ClaimCommit,
        [string]$Verdict = '', [string]$SurprisesOverride = '', [switch]$Probe)
    $plan = $Fields['plan']
    $resultText = New-ResultSidecar -RepoRoot $RepoRoot -TasksRoot $TasksRoot -Fields $Fields -Id $Id `
        -ClaimCommit $ClaimCommit -Status 'done' -Verdict $Verdict -SurprisesOverride $SurprisesOverride -Probe:$Probe
    Write-Utf8 (Join-Path $TasksRoot "done/$Id.result.md") $resultText
    git -C $RepoRoot add "tasks/done/$Id.result.md"
    $notes = Join-Path $TasksRoot "doing/$Id.notes.md"
    if (Test-Path $notes) { Remove-Item $notes }
    $paths = @("tasks/doing/$Id.md", "tasks/done/$Id.md", "tasks/done/$Id.result.md")
    $log = Join-Path $TasksRoot "doing/$Id.verify.log"
    if (Test-Path $log) {
        Move-Item $log (Join-Path $TasksRoot "done/$Id.verify.log")
        git -C $RepoRoot add "tasks/done/$Id.verify.log"
        $paths += "tasks/done/$Id.verify.log"
    }
    $paths += Move-TaskSidecars -RepoRoot $RepoRoot -TasksRoot $TasksRoot -Id $Id -From 'doing' -To 'done'
    git -C $RepoRoot mv "tasks/doing/$Id.md" "tasks/done/$Id.md"
    $promoted = @(Invoke-Promote -NoCommit)
    foreach ($p in $promoted) {
        $paths += "tasks/backlog/$p.md"
        $paths += "tasks/inbox/$p.md"
        foreach ($h in @(Get-ChildItem (Join-Path $TasksRoot 'inbox') -File | Where-Object { $_.Name -like "$p.gen*" })) {
            $paths += "tasks/backlog/$($h.Name)"
            $paths += "tasks/inbox/$($h.Name)"
        }
    }
    if ($Fields.ContainsKey('commit_paths')) {
        # only paths that exist: a never-created commit_path in the pathspec aborts the commit
        foreach ($c in @($Fields['commit_paths'])) {
            if (Test-Path (Join-Path $RepoRoot $c)) {
                git -C $RepoRoot add -- $c
                $paths += $c
            }
        }
    }
    git -C $RepoRoot commit -q -m "muster($plan): done $Id" -- @paths
    if ($LASTEXITCODE -ne 0) { Write-Refuse "completion commit failed for $Id - inspect git state by hand." }
    return , $promoted
}
```

- [ ] **Step 4: Run, verify pass**

- [ ] **Step 5: Commit**

```bash
git add runtime/bin/_lib.ps1 tests/Lib.Tests.ps1
git commit -m "feat(lib): result sidecar assembly and completion machinery"
```

### Task 12: done - preconditions + pass path

**Files:**
- Create: `runtime/bin/done.ps1`
- Create: `tests/Done.Tests.ps1`

Spec 4.3 common preconditions plus the `done` / `done pass` path. The two fail branches
call `Invoke-DoneFailReview` / `Invoke-DoneFailIntegration`, which Tasks 14 and 15 add
to the lib - until then `done fail` dies with an undefined-function error, which no test
exercises yet.

- [ ] **Step 1: Write failing contract tests**

`tests/Done.Tests.ps1`:

```powershell
BeforeAll { . (Join-Path $PSScriptRoot 'MusterFixture.ps1') }

Describe 'bin/done - preconditions and pass path' {
    BeforeEach { $script:fx = New-MusterFixture }
    AfterEach { Remove-MusterFixture $script:fx }

    function Add-ClaimedImpl {
        # Inbox task claimed via the real claim script, then work done in-scope.
        New-TaskFile -Fixture $script:fx -Folder inbox -Id 'p-01-a' -CommitPaths @('src/out.txt') `
            -VerifyCmd 'git --version' -Commit | Out-Null
        Invoke-MusterClaim $script:fx | Out-Null
        New-Item -ItemType Directory (Join-Path $script:fx 'src') -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $script:fx 'src/out.txt'), 'payload')
    }

    It 'refuses when doing/ is empty' {
        (Invoke-Muster $script:fx 'done').Exit | Should -Be 1
    }
    It 'refuses a verdict on impl tasks and requires one on review tasks' {
        Add-ClaimedImpl
        $r = Invoke-Muster $script:fx 'done' @('pass')
        $r.Exit | Should -Be 1
        $r.Text | Should -Match 'no verdict on impl/fix'
    }
    It 'completes an impl task: sidecars in done/, single completion commit, session-over line' {
        Add-ClaimedImpl
        $r = Invoke-Muster $script:fx 'done'
        $r.Exit | Should -Be 0
        $r.Text | Should -Match 'Done: p-01-a\. Promoted: none\. Do not claim another task\. Session over\.'
        Test-Path (Join-Path $script:fx 'tasks/done/p-01-a.md') | Should -BeTrue
        Test-Path (Join-Path $script:fx 'tasks/done/p-01-a.result.md') | Should -BeTrue
        Test-Path (Join-Path $script:fx 'tasks/done/p-01-a.verify.log') | Should -BeTrue
        (Get-FixtureCommits $script:fx)[0] | Should -Be 'muster(p): done p-01-a'
        (git -C $script:fx status --porcelain) | Should -BeNullOrEmpty
        # done-check was logged and did not consume an attempt
        $log = Get-Content (Join-Path $script:fx 'tasks/done/p-01-a.verify.log') -Raw
        $log | Should -Match '=== done-check'
    }
    It 'refuses when the done-check verify fails' {
        New-TaskFile -Fixture $script:fx -Folder inbox -Id 'p-01-a' -CommitPaths @('src/out.txt') `
            -VerifyCmd 'git frobnicate' -Commit | Out-Null
        Invoke-MusterClaim $script:fx | Out-Null
        $r = Invoke-Muster $script:fx 'done'
        $r.Exit | Should -Be 1
        $r.Text | Should -Match 'MUSTER refuse: done-check verify failed'
        Test-Path (Join-Path $script:fx 'tasks/doing/p-01-a.md') | Should -BeTrue
    }
    It 'refuses when a protected file was modified' {
        Add-ClaimedImpl
        [IO.File]::WriteAllText((Join-Path $script:fx 'README.md'), 'tampered')
        $r = Invoke-Muster $script:fx 'done'
        $r.Exit | Should -Be 1
        $r.Text | Should -Match 'MUSTER refuse: protected file\(s\) modified: README\.md\. Revert them; the verify definition is not yours to change\.'
    }
    It 'refuses out-of-scope changes' {
        Add-ClaimedImpl
        [IO.File]::WriteAllText((Join-Path $script:fx 'stray.txt'), 'x')
        $r = Invoke-Muster $script:fx 'done'
        $r.Exit | Should -Be 1
        $r.Text | Should -Match 'MUSTER refuse: changed outside commit_paths: stray\.txt\. Revert strays or stop for a human\.'
    }
    It 'review pass requires notes and folds them' {
        New-TaskFile -Fixture $script:fx -Folder inbox -Id 'p-02-review-a' -Type review -Tier strong `
            -ExtraFront @('reviews: p-01-a') -Commit | Out-Null
        Invoke-MusterClaim $script:fx -Tier strong | Out-Null
        $r = Invoke-Muster $script:fx 'done' @('pass')
        $r.Exit | Should -Be 1
        $r.Text | Should -Match 'MUSTER refuse: verdict needs tasks/doing/p-02-review-a\.notes\.md with findings\.'
        [IO.File]::WriteAllText((Join-Path $script:fx 'tasks/doing/p-02-review-a.notes.md'), 'all good')
        $r2 = Invoke-Muster $script:fx 'done' @('pass')
        $r2.Exit | Should -Be 0
        (Get-Content (Join-Path $script:fx 'tasks/done/p-02-review-a.result.md') -Raw) |
            Should -Match '(?s)- verdict: pass.*## Findings.*all good'
    }
    It 'lists promoted ids in the session-over line' {
        Add-ClaimedImpl
        New-TaskFile -Fixture $script:fx -Folder backlog -Id 'p-03-c' -DependsOn @('p-01-a') -Commit | Out-Null
        (Invoke-Muster $script:fx 'done').Text | Should -Match 'Done: p-01-a\. Promoted: p-03-c\.'
    }
}
```

- [ ] **Step 2: Run, verify fail**

- [ ] **Step 3: Write `runtime/bin/done.ps1`**

```powershell
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

# 2. confirmation verify - kills stale-pass; logged as done-check, never counts
$log = Join-Path $tasks "doing/$id.verify.log"
$check = Invoke-VerifyBlock -Entries $task.Fields['verify'] -LogPath $log -Label 'done-check' -TaskId $id -RepoRoot $root
if (-not $check.Pass) {
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
        Invoke-DoneFailReview -RepoRoot $root -TasksRoot $tasks -Fields $task.Fields -Id $id -ClaimCommit $claimCommit
    }
    else {
        Invoke-DoneFailIntegration -RepoRoot $root -TasksRoot $tasks -Fields $task.Fields -Id $id -ClaimCommit $claimCommit
    }
    exit 3   # unreachable - both branch functions exit themselves; kept as a guard
}

$promoted = @(Complete-Task -RepoRoot $root -TasksRoot $tasks -Fields $task.Fields -Id $id `
    -ClaimCommit $claimCommit -Verdict $Verdict)
$plist = 'none'
if ($promoted.Count -gt 0) { $plist = ($promoted -join ', ') }
Write-Output "Done: $id. Promoted: $plist. Do not claim another task. Session over."
exit 0
```

Detail: `Read-CommittedTask` reads the HEAD blob, which is the claim-time copy - so
`claimed_at` is present (claim committed the stamp) and executor edits to the task file
are inert for the done flow too, not just for verify.

- [ ] **Step 4: Run, verify pass** (Claim/Verify/Promote suites must stay green)

- [ ] **Step 5: Commit**

```bash
git add runtime/bin/done.ps1 tests/Done.Tests.ps1
git commit -m "feat(bin): done verb - preconditions and pass path"
```

### Task 13: claim - recovery probe + auto-file loop

**Files:**
- Modify: `runtime/bin/claim.ps1` (replace the step-9 comment)
- Modify: `tests/Claim.Tests.ps1` (append)

Spec 4.1 step 9. Gate: type impl/fix AND prior claim evidence. Green probe = crashed
predecessor finished the work: file it as done and loop back to selection.

- [ ] **Step 1: Append failing tests**

```powershell
Describe 'bin/claim - recovery probe' {
    BeforeEach { $script:fx = New-MusterFixture }
    AfterEach { Remove-MusterFixture $script:fx }

    function Add-RecoveredTask {
        # Simulate the D12 crash shape + human recovery: claim, crash, human moves the
        # file back to inbox (committing only the move), dirty work left in the tree.
        New-TaskFile -Fixture $script:fx -Folder inbox -Id 'p-01-a' -CommitPaths @('src/out.txt') `
            -VerifyCmd 'powershell -NoProfile -Command Test-Path src/out.txt' -ExpectExit '0' `
            -ExtraFront @() -Commit | Out-Null
        # give the verify a content expectation so an absent file fails it
        $p = Join-Path $script:fx 'tasks/inbox/p-01-a.md'
        $t = [IO.File]::ReadAllText($p) -replace '    expect_exit: 0', "    expect_contains: ""True"""
        [IO.File]::WriteAllText($p, $t)
        git -C $script:fx add 'tasks/inbox/p-01-a.md'
        git -C $script:fx commit -qm 'fixture: tighten verify'
        Invoke-MusterClaim $script:fx | Out-Null                       # first claim
        git -C $script:fx mv 'tasks/doing/p-01-a.md' 'tasks/inbox/p-01-a.md'   # human RECOVERY move
        git -C $script:fx commit -qm 'human: recover p-01-a'
        Remove-Item (Join-Path $script:fx 'tasks/doing/p-01-a.verify.log') -ErrorAction SilentlyContinue
    }

    It 'auto-files a re-dispatched task whose verify is already green' {
        Add-RecoveredTask
        New-Item -ItemType Directory (Join-Path $script:fx 'src') -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $script:fx 'src/out.txt'), 'predecessor work')   # dirty green work
        $r = Invoke-MusterClaim $script:fx
        $r.Text | Should -Match 'Auto-filed p-01-a'
        $r.Text | Should -Match 'nothing to claim'      # looped back to selection, board now empty
        Test-Path (Join-Path $script:fx 'tasks/done/p-01-a.md') | Should -BeTrue
        (Get-Content (Join-Path $script:fx 'tasks/done/p-01-a.result.md') -Raw) |
            Should -Match 'auto-filed at claim: verify green before execution'
        (Get-Content (Join-Path $script:fx 'tasks/done/p-01-a.verify.log') -Raw) |
            Should -Match '=== claim-probe'
        (git -C $script:fx show --name-only --format= HEAD) | Should -Contain 'src/out.txt'
    }
    It 'does not probe a task with no prior claim history' {
        # Verify would be green pre-work (git --version) - must still be claimed normally.
        New-TaskFile -Fixture $script:fx -Folder inbox -Id 'p-01-a' -Commit | Out-Null
        $r = Invoke-MusterClaim $script:fx
        $r.Text | Should -Match 'Claimed p-01-a'
        Test-Path (Join-Path $script:fx 'tasks/doing/p-01-a.md') | Should -BeTrue
        Test-Path (Join-Path $script:fx 'tasks/doing/p-01-a.verify.log') | Should -BeFalse
    }
    It 'claims normally when the probe is red' {
        Add-RecoveredTask   # src/out.txt absent -> probe fails
        $r = Invoke-MusterClaim $script:fx
        $r.Text | Should -Match 'Claimed p-01-a'
        (Get-Content (Join-Path $script:fx 'tasks/doing/p-01-a.verify.log') -Raw) |
            Should -Match '=== claim-probe result: FAIL'
    }
}
```

- [ ] **Step 2: Run, verify the new Describe fails**

- [ ] **Step 3: Replace the step-9 comment in `claim.ps1`**

Replace the line `# 9. recovery probe - inserted by a later task in this plan` with:

```powershell
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
```

- [ ] **Step 4: Run, verify pass** (all Claim tests, old and new)

- [ ] **Step 5: Commit**

```bash
git add runtime/bin/claim.ps1 tests/Claim.Tests.ps1
git commit -m "feat(bin): claim recovery probe with auto-file loop"
```

### Task 14: done fail - review path

**Files:**
- Modify: `runtime/bin/_lib.ps1` (append `Get-FixCount`, `Add-DependsOn`, `Move-ToFailedWithResult`, `Invoke-DoneFailReview`)
- Modify: `tests/Done.Tests.ps1` (append)

Spec 4.3 `done fail` for review tasks: staged-fix validation, script-owned generation
counting, stamping, review-task cycling to backlog/ with history sidecars, cap refusal.

- [ ] **Step 1: Append failing tests**

```powershell
Describe 'bin/done fail - review path' {
    BeforeEach { $script:fx = New-MusterFixture }
    AfterEach { Remove-MusterFixture $script:fx }

    function Add-ClaimedReview {
        # A done impl (reviewed target) + a claimed review task with findings notes.
        New-TaskFile -Fixture $script:fx -Folder done -Id 'p-01-a' -Commit | Out-Null
        New-TaskFile -Fixture $script:fx -Folder inbox -Id 'p-02-review-a' -Type review -Tier strong `
            -DependsOn @('p-01-a') -ExtraFront @('reviews: p-01-a') -Commit | Out-Null
        Invoke-MusterClaim $script:fx -Tier strong | Out-Null
        [IO.File]::WriteAllText((Join-Path $script:fx 'tasks/doing/p-02-review-a.notes.md'), 'finding: bad naming')
    }
    function Add-StagedFix {
        param([string]$Slug = 'naming')
        New-TaskFile -Fixture $script:fx -Folder staging -Id "p-01-fix-$Slug" -Type fix `
            -CommitPaths @('src/out.txt') -ExtraFront @('fixes: p-01-a') | Out-Null
    }

    It 'refuses when staging/ holds no fix' {
        Add-ClaimedReview
        $r = Invoke-Muster $script:fx 'done' @('fail')
        $r.Exit | Should -Be 1
        $r.Text | Should -Match 'MUSTER refuse: done fail needs exactly one valid fix task in tasks/staging/'
    }
    It 'refuses an invalid staged fix and leaves it in place' {
        Add-ClaimedReview
        New-TaskFile -Fixture $script:fx -Folder staging -Id 'p-01-fix-x' -Type fix `
            -ExtraFront @('fixes: p-09-other') | Out-Null   # fixes does not match reviews
        $r = Invoke-Muster $script:fx 'done' @('fail')
        $r.Exit | Should -Be 1
        Test-Path (Join-Path $script:fx 'tasks/staging/p-01-fix-x.md') | Should -BeTrue
    }
    It 'accepts a valid fix: stamps gen 1, queues it, cycles the review task' {
        Add-ClaimedReview
        Add-StagedFix
        $r = Invoke-Muster $script:fx 'done' @('fail')
        $r.Exit | Should -Be 0
        $r.Text | Should -Match 'Review failed\. Fix p-01-fix1-naming queued \(generation 1 of 2\)\. Session over\.'
        $fix = Get-Content (Join-Path $script:fx 'tasks/inbox/p-01-fix1-naming.md') -Raw
        $fix | Should -Match '(?m)^id: p-01-fix1-naming$'
        $fix | Should -Match '(?m)^generation: 1$'
        $fix | Should -Match '(?m)^# p-01-fix1-naming:'
        $review = Get-Content (Join-Path $script:fx 'tasks/backlog/p-02-review-a.md') -Raw
        $review | Should -Match '(?m)^  - p-01-fix1-naming$'
        Test-Path (Join-Path $script:fx 'tasks/backlog/p-02-review-a.gen1.result.md') | Should -BeTrue
        Test-Path (Join-Path $script:fx 'tasks/doing/p-02-review-a.verify.log') | Should -BeFalse
        Test-Path (Join-Path $script:fx 'tasks/staging/p-01-fix-naming.md') | Should -BeFalse
        (Get-FixtureCommits $script:fx)[0] | Should -Be 'muster(p): reject p-01-a gen1'
        (Get-Content (Join-Path $script:fx 'tasks/backlog/p-02-review-a.gen1.result.md') -Raw) |
            Should -Match '(?s)- status: cycled.*- verdict: fail.*finding: bad naming'
    }
    It 'refuses to spawn generation 3: review task fails terminally' {
        Add-ClaimedReview
        # two landed generations already exist
        New-TaskFile -Fixture $script:fx -Folder done -Id 'p-01-fix1-naming' -Type fix `
            -ExtraFront @('fixes: p-01-a', 'generation: 1') -Commit | Out-Null
        New-TaskFile -Fixture $script:fx -Folder done -Id 'p-01-fix2-naming' -Type fix `
            -ExtraFront @('fixes: p-01-a', 'generation: 2') -Commit | Out-Null
        Add-StagedFix -Slug 'third'
        $r = Invoke-Muster $script:fx 'done' @('fail')
        $r.Exit | Should -Be 3
        $r.Text | Should -Match 'Review cap hit \(2 fix generations\)\. p-01-a chain needs a human\. Session over\.'
        Test-Path (Join-Path $script:fx 'tasks/failed/p-02-review-a.md') | Should -BeTrue
        Test-Path (Join-Path $script:fx 'tasks/failed/p-02-review-a.result.md') | Should -BeTrue
        Test-Path (Join-Path $script:fx 'tasks/staging/p-01-fix-third.md') | Should -BeFalse
        (Get-FixtureCommits $script:fx)[0] | Should -Be 'muster(p): fail p-02-review-a'
    }
}
```

- [ ] **Step 2: Run, verify fail**

- [ ] **Step 3: Append to `_lib.ps1`**

```powershell
function Get-FixCount {
    # The script is the only generation counter (spec 2.2): files carrying
    # 'fixes: <impl-id>' anywhere under tasks/ excluding staging/.
    param([string]$TasksRoot, [string]$ImplId)
    $count = 0
    foreach ($f in @(Get-ChildItem -Path $TasksRoot -Recurse -File -Filter '*.md')) {
        if ($f.FullName -match '[\\/]staging[\\/]') { continue }
        if ($f.Name -like '*.result.md' -or $f.Name -like '*.notes.md') { continue }
        if ([IO.File]::ReadAllText($f.FullName) -match "(?m)^fixes: $([regex]::Escape($ImplId))\s*$") { $count++ }
    }
    return $count
}

function Add-DependsOn {
    # Script-side frontmatter edit (D17): append one id to depends_on.
    param([string]$Path, [string]$DepId)
    $text = [IO.File]::ReadAllText($Path)
    if ($text -match '(?m)^depends_on: \[\]\s*$') {
        $text = $text -replace '(?m)^depends_on: \[\]\s*$', "depends_on:`n  - $DepId"
    }
    else {
        $lines = $text -split "`r?`n"
        $out = @()
        $inDeps = $false
        foreach ($line in $lines) {
            if ($inDeps -and $line -notmatch '^\s+- ') { $out += "  - $DepId"; $inDeps = $false }
            if ($line -match '^depends_on:\s*$') { $inDeps = $true }
            $out += $line
        }
        if ($inDeps) { $out += "  - $DepId" }
        $text = $out -join "`n"
    }
    Write-Utf8 $Path $text
}

function Move-ToFailedWithResult {
    # Shared by the review cap and integration fail: result with fail verdict,
    # task + sidecars -> failed/, one commit. Caller prints and exits 3.
    param([string]$RepoRoot, [string]$TasksRoot, [hashtable]$Fields, [string]$Id, [string]$ClaimCommit)
    $resultText = New-ResultSidecar -RepoRoot $RepoRoot -TasksRoot $TasksRoot -Fields $Fields -Id $Id `
        -ClaimCommit $ClaimCommit -Status 'failed' -Verdict 'fail'
    Write-Utf8 (Join-Path $TasksRoot "failed/$Id.result.md") $resultText
    git -C $RepoRoot add "tasks/failed/$Id.result.md"
    $paths = @("tasks/failed/$Id.result.md", "tasks/doing/$Id.md", "tasks/failed/$Id.md")
    $notes = Join-Path $TasksRoot "doing/$Id.notes.md"
    if (Test-Path $notes) { Remove-Item $notes }
    $log = Join-Path $TasksRoot "doing/$Id.verify.log"
    if (Test-Path $log) {
        Move-Item $log (Join-Path $TasksRoot "failed/$Id.verify.log")
        git -C $RepoRoot add "tasks/failed/$Id.verify.log"
        $paths += "tasks/failed/$Id.verify.log"
    }
    $paths += Move-TaskSidecars -RepoRoot $RepoRoot -TasksRoot $TasksRoot -Id $Id -From 'doing' -To 'failed'
    git -C $RepoRoot mv "tasks/doing/$Id.md" "tasks/failed/$Id.md"
    git -C $RepoRoot commit -q -m "muster($($Fields['plan'])): fail $Id" -- @paths
}

function Invoke-DoneFailReview {
    # Spec 4.3 done-fail for review tasks. Exits itself on every path.
    param([string]$RepoRoot, [string]$TasksRoot, [hashtable]$Fields, [string]$Id, [string]$ClaimCommit)
    $plan = $Fields['plan']
    $implId = $Fields['reviews']

    # 6. exactly one valid gen-less staged fix targeting the reviewed impl
    $staged = @(Get-TaskFiles (Join-Path $TasksRoot 'staging'))
    if ($staged.Count -ne 1) {
        Write-Refuse "done fail needs exactly one valid fix task in tasks/staging/ (found $($staged.Count) files). File left in place - fix it and rerun."
    }
    $stagedRel = "tasks/staging/$($staged[0].Name)"
    $findings = @(Test-LintChecks -RepoRoot $RepoRoot -Paths @($stagedRel) -Lite)
    $fix = Read-TaskFile $staged[0].FullName
    if ($fix.Errors.Count -eq 0 -and $fix.Fields.ContainsKey('fixes') -and $fix.Fields['fixes'] -ne $implId) {
        $findings = @("fixes '$($fix.Fields['fixes'])' does not match reviews '$implId'") + $findings
    }
    if ($findings.Count -gt 0) {
        Write-Refuse "done fail needs exactly one valid fix task in tasks/staging/ ($($findings[0])). File left in place - fix it and rerun."
    }

    # 7. generation cap - two landed generations = human territory (D11)
    $g = (Get-FixCount -TasksRoot $TasksRoot -ImplId $implId) + 1
    if ($g -ge 3) {
        Remove-Item $staged[0].FullName
        Move-ToFailedWithResult -RepoRoot $RepoRoot -TasksRoot $TasksRoot -Fields $Fields -Id $Id -ClaimCommit $ClaimCommit
        Write-Output "Review cap hit (2 fix generations). $implId chain needs a human. Session over."
        exit 3
    }

    # 8. stamp the fix: filename, id, generation, title (spec 2.1)
    if ($staged[0].Name -notmatch '^(.+-\d{2})-fix-(.+)\.md$') {
        Write-Refuse "staged fix filename malformed: $($staged[0].Name)."
    }
    $fixId = "$($Matches[1])-fix$g-$($Matches[2])"
    $text = [IO.File]::ReadAllText($staged[0].FullName)
    $text = $text -replace '(?m)^id: .*$', "id: $fixId"
    $text = $text -replace '(?m)^(fixes: .*)$', "`$1`ngeneration: $g"
    $text = $text.Replace("# $($fix.Id):", "# ${fixId}:")
    Write-Utf8 (Join-Path $TasksRoot "inbox/$fixId.md") $text
    Remove-Item $staged[0].FullName
    git -C $RepoRoot add "tasks/inbox/$fixId.md"
    $paths = @("tasks/inbox/$fixId.md", "tasks/doing/$Id.md", "tasks/backlog/$Id.md")

    # review task re-blocks on the fix (cycling, no new review task - D11/D19)
    Add-DependsOn -Path (Join-Path $TasksRoot "doing/$Id.md") -DepId $fixId

    # this round's sidecars become history; next round's attempt counter starts fresh.
    # Capture the attempt count BEFORE the move - New-ResultSidecar cannot read a moved log.
    $live = Join-Path $TasksRoot "doing/$Id.verify.log"
    $roundAttempts = Get-AttemptCount $live
    if (Test-Path $live) {
        Move-Item $live (Join-Path $TasksRoot "backlog/$Id.gen$g.verify.log")
        git -C $RepoRoot add "tasks/backlog/$Id.gen$g.verify.log"
        $paths += "tasks/backlog/$Id.gen$g.verify.log"
    }
    $resultText = New-ResultSidecar -RepoRoot $RepoRoot -TasksRoot $TasksRoot -Fields $Fields -Id $Id `
        -ClaimCommit $ClaimCommit -Status 'cycled' -Verdict 'fail' -Attempts $roundAttempts
    Write-Utf8 (Join-Path $TasksRoot "backlog/$Id.gen$g.result.md") $resultText
    git -C $RepoRoot add "tasks/backlog/$Id.gen$g.result.md"
    $paths += "tasks/backlog/$Id.gen$g.result.md"
    Remove-Item (Join-Path $TasksRoot "doing/$Id.notes.md")
    $paths += Move-TaskSidecars -RepoRoot $RepoRoot -TasksRoot $TasksRoot -Id $Id -From 'doing' -To 'backlog'
    git -C $RepoRoot mv "tasks/doing/$Id.md" "tasks/backlog/$Id.md"

    # 9. ONE commit
    git -C $RepoRoot commit -q -m "muster($plan): reject $implId gen$g" -- @paths
    Write-Output "Review failed. Fix $fixId queued (generation $g of 2). Session over."
    exit 0
}
```

Ordering detail: `New-ResultSidecar` reads the notes file, so notes deletion happens
after assembly. `Move-ToFailedWithResult` assembles before deleting for the same reason.

- [ ] **Step 4: Run, verify pass**

- [ ] **Step 5: Commit**

```bash
git add runtime/bin/_lib.ps1 tests/Done.Tests.ps1
git commit -m "feat(bin): done fail review path - staged fix, generations, cycling"
```

### Task 15: done fail - integration path

**Files:**
- Modify: `runtime/bin/_lib.ps1` (append `Invoke-DoneFailIntegration`)
- Modify: `tests/Done.Tests.ps1` (append)

Spec 4.3 integration fail: no fix accepted, straight to failed/ for the orchestrator.

- [ ] **Step 1: Append failing tests**

```powershell
Describe 'bin/done fail - integration path' {
    BeforeEach { $script:fx = New-MusterFixture }
    AfterEach { Remove-MusterFixture $script:fx }

    function Add-ClaimedIntegration {
        New-TaskFile -Fixture $script:fx -Folder inbox -Id 'p-99-integration' -Type integration -Tier strong `
            -Commit | Out-Null
        Invoke-MusterClaim $script:fx -Tier strong | Out-Null
        [IO.File]::WriteAllText((Join-Path $script:fx 'tasks/doing/p-99-integration.notes.md'), 'drift: a vs b')
    }

    It 'files the integration task to failed/ with findings and exits 3' {
        Add-ClaimedIntegration
        $r = Invoke-Muster $script:fx 'done' @('fail')
        $r.Exit | Should -Be 3
        $r.Text | Should -Match 'Integration review failed\. Bring tasks/failed/p-99-integration\.result\.md to the orchestrator to shard a fix-up plan\. Session over\.'
        (Get-Content (Join-Path $script:fx 'tasks/failed/p-99-integration.result.md') -Raw) |
            Should -Match '(?s)- status: failed.*- verdict: fail.*drift: a vs b'
        (Get-FixtureCommits $script:fx)[0] | Should -Be 'muster(p): fail p-99-integration'
    }
    It 'refuses when staging/ is not empty' {
        Add-ClaimedIntegration
        New-TaskFile -Fixture $script:fx -Folder staging -Id 'p-01-fix-x' -Type fix `
            -ExtraFront @('fixes: p-01-a') | Out-Null
        $r = Invoke-Muster $script:fx 'done' @('fail')
        $r.Exit | Should -Be 1
        $r.Text | Should -Match 'MUSTER refuse: integration done fail accepts no fix task - clear tasks/staging/\.'
    }
}
```

- [ ] **Step 2: Run, verify fail**

- [ ] **Step 3: Append to `_lib.ps1`**

```powershell
function Invoke-DoneFailIntegration {
    # Spec 4.3 integration-fail: plan-level drift belongs to the orchestrator, not a fix task.
    param([string]$RepoRoot, [string]$TasksRoot, [hashtable]$Fields, [string]$Id, [string]$ClaimCommit)
    $staged = @(Get-TaskFiles (Join-Path $TasksRoot 'staging'))
    if ($staged.Count -gt 0) {
        Write-Refuse 'integration done fail accepts no fix task - clear tasks/staging/.'
    }
    Move-ToFailedWithResult -RepoRoot $RepoRoot -TasksRoot $TasksRoot -Fields $Fields -Id $Id -ClaimCommit $ClaimCommit
    Write-Output "Integration review failed. Bring tasks/failed/$Id.result.md to the orchestrator to shard a fix-up plan. Session over."
    exit 3
}
```

- [ ] **Step 4: Run, verify pass - then run the WHOLE suite**

Run: `powershell -NoProfile -Command "Import-Module Pester -MinimumVersion 5.5; Invoke-Pester tests -Output Detailed"`
Expected: every test in every file PASS. The ps1 engine is now feature-complete.

- [ ] **Step 5: Commit**

```bash
git add runtime/bin/_lib.ps1 tests/Done.Tests.ps1
git commit -m "feat(bin): done fail integration path"
```

### Task 16: RUNNER.md + task templates (verbatim artifacts)

**Files:**
- Create: `runtime/RUNNER.md`
- Create: `templates/impl-task.md`, `templates/review-task.md`, `templates/fix-task.md`,
  `templates/integration-task.md`
- Delete: `templates/.gitkeep`

Both are verbatim copies out of the spec - one deterministic transcription each, no
authoring. Copy from the spec file, do not retype.

- [ ] **Step 1: Extract RUNNER.md**

Open `docs/superpowers/specs/2026-08-07-muster-v1.md`, section 6. Copy everything
between the `<!-- RUNNER.md BEGIN -->` and `<!-- RUNNER.md END -->` markers, dropping
the surrounding ```` ```markdown ```` fence lines. Write the result to
`runtime/RUNNER.md`. The file starts `# RUNNER - executor contract` and ends with the
line `Never let two sessions share this checkout.`

- [ ] **Step 2: Extract the four templates**

From spec sections 7.1-7.4, copy each fenced template body (content inside the fence,
fence lines dropped) to:

| Spec section | File |
|---|---|
| 7.1 | `templates/impl-task.md` |
| 7.2 | `templates/review-task.md` |
| 7.3 | `templates/fix-task.md` |
| 7.4 | `templates/integration-task.md` |

`{braces}` slots survive verbatim - shard fills them; lint rejects any survivor.

- [ ] **Step 2b: Apply Authority deviation 3 (block-list depends_on)**

The spec templates carry inline flow lists that spec 2.5's parser forbids. In all four
template files rewrite the `depends_on` line:

- `depends_on: [{dep-ids}]` (7.1), `depends_on: [{impl-id}]` (7.2),
  `depends_on: [{every-other-task-id}]` (7.4) become:

  ```yaml
  depends_on:
    - {dep-id-one-per-line}
  ```

- `depends_on: []` in 7.3 stays as-is (empty inline list is legal).

Shard's fill rule (already in Task 18): emit `depends_on: []` for a dependency-free
task, otherwise one `  - <id>` line per dependency.

- [ ] **Step 3: Verify the transcription**

Run from repo root (PowerShell):

```powershell
(Get-Content runtime/RUNNER.md -TotalCount 1) -eq '# RUNNER - executor contract'
Select-String -Path runtime/RUNNER.md -Pattern 'RECOVERY \(humans only\)' -Quiet
foreach ($f in 'impl-task','review-task','fix-task','integration-task') {
    (Get-Content "templates/$f.md" -TotalCount 1) -eq '---'
}
```

Expected: `True` five times. Also re-run the full Pester suite once - fixtures now
copy RUNNER.md and nothing may break.

- [ ] **Step 4: Commit**

```bash
git rm -q templates/.gitkeep
git add runtime/RUNNER.md templates/impl-task.md templates/review-task.md templates/fix-task.md templates/integration-task.md
git commit -m "feat(runtime): RUNNER.md and task templates verbatim from spec"
```

### Task 17: muster:init skill

**Files:**
- Create: `skills/init/SKILL.md`
- Delete: `skills/.gitkeep`

Orchestrator-side prose. The artifacts it installs are all pinned (spec section 1);
the skill is the checklist that installs them. Anti-trigger description per spec 8.2.

- [ ] **Step 1: Write `skills/init/SKILL.md`** (full content):

```markdown
---
name: init
description: Bootstrap the MUSTER task board in the current repo. Invoked ONLY by the explicit /muster:init slash command. Never auto-trigger from conversational mention of tasks, boards, plans, or dispatch.
---

# muster:init - install the task board

Target: the repo the session's cwd is inside. Refuse politely if any check fails;
never half-install.

## Preflight

1. `git rev-parse --show-toplevel` must succeed. Not a repo = stop: tell the user to
   `git init` first.
2. `git config user.name` and `git config user.email` must both return values.
   Missing = stop and tell the user to set them (scripts commit; identity is required).
3. If `tasks/` already exists at the repo root = stop: "tasks/ already exists -
   MUSTER appears installed. Nothing changed."
4. Sync-root check: if the repo path contains `OneDrive`, `Dropbox`, or `Google Drive`,
   print a LOUD warning (sync engines duplicate and resurrect task files - the board
   will corrupt) and ask the user to confirm before continuing.

## Install

5. Create `tasks/backlog/`, `tasks/inbox/`, `tasks/doing/`, `tasks/done/`,
   `tasks/failed/`, `tasks/archive/`, `tasks/staging/`, `tasks/bin/`, each with an
   empty `.gitkeep`.
6. Copy every file from `${CLAUDE_PLUGIN_ROOT}/runtime/bin/` into `tasks/bin/`.
7. Copy `${CLAUDE_PLUGIN_ROOT}/runtime/RUNNER.md` to `tasks/RUNNER.md`.
8. Pointer lines: append to the repo's `CLAUDE.md` (create if absent), and to
   `AGENTS.md` if that file already exists:

   > Task board: `tasks/` is managed by MUSTER. Executors follow `tasks/RUNNER.md`
   > exactly. Never edit files under `tasks/` by hand; the `tasks/bin/` scripts own
   > all state transitions.

9. Commit everything just created as one commit, explicit paths, message:
   `muster: init task board`.

## Report

10. Print what was installed and the two dispatch lines the human will use
    (spec 8.1): model picker Sonnet 5 + `/muster:run`, model picker Fable 5 +
    `/muster:review`.
```

- [ ] **Step 2: Manual verification (no Pester - skills are prose)**

In a scratch repo (`git init` + identity config), simulate the skill by following its
steps by hand once. Confirm: tree matches spec section 1, `tasks/bin` holds 6 ps1 + 6 sh
files (sh exists after Task 22; before that, 6 ps1), RUNNER.md present, one commit
`muster: init task board`, `git status` clean.

- [ ] **Step 3: Commit**

```bash
git rm -q skills/.gitkeep
git add skills/init/SKILL.md
git commit -m "feat(skills): muster:init"
```

### Task 18: muster:shard skill

**Files:**
- Create: `skills/shard/SKILL.md`

The one skill with real judgment (it IS the orchestrator's shard-time thinking).
Artifacts it emits are fully pinned: filenames (spec 2.1), frontmatter (2.2), body
(2.3), templates (section 7), lint (2.6).

- [ ] **Step 1: Write `skills/shard/SKILL.md`** (full content):

```markdown
---
name: shard
description: Convert an approved implementation plan into MUSTER task files. Invoked ONLY by the explicit /muster:shard slash command, after plan approval. Never auto-trigger from conversational mention of plans, tasks, or sharding - auto-firing would write task files before plan approval.
---

# muster:shard - approved plan -> task files

Input: the user names an approved plan file and a plan id (kebab-case, `[a-z0-9-]+`,
unique - refuse if `tasks/plan-<id>.md` already exists). Do all thinking NOW: executors
get zero judgment calls (D9).

## Snapshot

1. Copy the plan file verbatim to `tasks/plan-<id>.md`. Tasks quote the snapshot, never
   the live plan (D23).

## Author tasks

2. Decompose the plan into small impl tasks in DAG order; assign `seq` 01 upward.
   Every task gets the impl template (`${CLAUDE_PLUGIN_ROOT}/templates/impl-task.md`),
   every `{brace}` slot filled:
   - Context: INLINE every excerpt the executor needs. Pasting is correct; pointing
     is a lint reject (D23).
   - Steps: target-state phrasing, exact paths, exact content (D12, D9).
   - verify: network-free commands, tokenizable (no shell metacharacters), each with
     expect_exit and/or expect_contains. Needs network? Pin `harness: claude` (D16).
     Windows caveat: the verify runner spawns processes directly, so extension-less
     `.cmd`/`.bat` shims (npm, yarn, ng) fail to launch - front them with the cmd
     host, e.g. `cmd /c npm test`.
   - depends_on: `[]` when empty, block list (`  - <id>` per line) otherwise -
     never a non-empty inline list (Authority deviation 3).
   - protected: every file a verify cmd reads that the task must not touch.
   - commit_paths: the exact stage list for the completion commit (D21).
   - tier: `any` unless the task itself needs judgment.
3. Review tasks (opt-in per impl task, D10): for each impl task worth reviewing, emit
   a review task from the review template with `reviews: <impl-id>`,
   `depends_on: [<impl-id>]`, `tier: strong`, and the fix template pasted into its
   Steps (the reviewer never opens plugin files). Anything downstream of a reviewed
   task depends on the REVIEW id, not the impl id (D19).
4. Terminal integration task, always (D24): seq `99`, integration template,
   `tier: strong`, `depends_on` listing every other task id in the plan, full
   build + suite in verify.
5. Write ALL task files into `tasks/backlog/`.

## Gate and land

6. Lint the whole batch:
   `powershell -ExecutionPolicy Bypass -File tasks/bin/lint.ps1 tasks/backlog/<plan-id>-*.md`
   Any `LINT FAIL` = fix the task files and re-lint. Landing an unlinted batch is
   forbidden; if a finding cannot be fixed, delete the batch (the files are untracked)
   and report why.
7. On `LINT OK`: commit snapshot + batch, explicit paths, message
   `muster(<plan-id>): shard <n> tasks`.
8. Run `powershell -ExecutionPolicy Bypass -File tasks/bin/promote.ps1` - tasks with
   no dependencies move to inbox/ and get committed as `muster: promote <n>`.

## Report

9. Print: task count by type, the DAG (id -> depends_on), and the dispatch reminder
   (Sonnet 5 + `/muster:run` per impl task; Fable 5 + `/muster:review` when a review
   task is ready).
```

- [ ] **Step 2: Manual verification**

In the Task 17 scratch repo, follow the skill by hand against a 3-line toy plan
("create hello.txt containing hello"): expect `tasks/plan-<id>.md`, 1 impl + 1 review +
1 integration task in backlog/inbox, lint OK, both commits present, promote moved the
impl task to inbox/.

- [ ] **Step 3: Commit**

```bash
git add skills/shard/SKILL.md
git commit -m "feat(skills): muster:shard"
```

### Task 19: muster:run + muster:review wrapper skills

**Files:**
- Create: `skills/run/SKILL.md`
- Create: `skills/review/SKILL.md`

Bodies are spec 8.2 verbatim. Anti-trigger descriptions are mandatory: a wrapper
auto-firing inside an orchestrator session would claim work under the wrong identity.

- [ ] **Step 1: Write `skills/run/SKILL.md`** (exact content):

```markdown
---
name: run
description: MUSTER executor session entry point. Invoked ONLY by the explicit /muster:run slash command typed as the first message of a fresh executor session. Never auto-trigger from conversational mention of tasks, claiming, running, or dispatch.
---

Run `powershell -ExecutionPolicy Bypass -File tasks/bin/claim.ps1 -Harness claude -Tier any`
(POSIX: sh tasks/bin/claim.sh --harness claude --tier any), then follow
tasks/RUNNER.md to the letter.
```

- [ ] **Step 2: Write `skills/review/SKILL.md`** (exact content):

```markdown
---
name: review
description: MUSTER reviewer session entry point. Invoked ONLY by the explicit /muster:review slash command typed as the first message of a fresh reviewer session. Never auto-trigger from conversational mention of reviews, verdicts, or dispatch.
---

Run `powershell -ExecutionPolicy Bypass -File tasks/bin/claim.ps1 -Harness claude -Tier strong`
(POSIX: sh tasks/bin/claim.sh --harness claude --tier strong), then follow
tasks/RUNNER.md to the letter.
```

- [ ] **Step 3: Verify slash-command registration**

The `/muster:run` form assumed by spec 8.1/8.2 must be proven, not presumed - plugin
skill/command namespacing is not self-evident (official example-plugin docs show a
bare `/example-command` form). Install this plugin into the local Claude Code
environment (marketplace add from the local repo path, or the `--plugin-dir`
development flag), start a session, type `/muster` and confirm the completion list
offers `muster:run`, `muster:review`, `muster:init`, `muster:shard`, `muster:close`.
If the skills surface under bare names (`/run`, `/review`) instead: stop, adjust the
plugin layout/config until the `/muster:*` form works, and if it truly cannot, rename
the skills (`muster-run` etc.) AND flag the spec 8.1/8.2 wording to the user before
proceeding - the dispatch lines are spec text.

- [ ] **Step 4: Commit**

```bash
git add skills/run/SKILL.md skills/review/SKILL.md
git commit -m "feat(skills): run and review executor wrappers"
```

### Task 20: muster:close skill

**Files:**
- Create: `skills/close/SKILL.md`

Spec section 1 + D15: batch-archive a finished plan.

- [ ] **Step 1: Write `skills/close/SKILL.md`** (full content):

```markdown
---
name: close
description: Archive a finished MUSTER plan. Invoked ONLY by the explicit /muster:close slash command. Never auto-trigger from conversational mention of closing, archiving, or finishing work.
---

# muster:close - archive a finished plan

Input: a plan id. All checks read the board; refuse rather than force.

1. Eligibility (D15): the plan's board must be empty except done/ - zero task files
   with this plan id in backlog/, inbox/, doing/, staging/, or failed/. Any present =
   refuse and list them (failed/ cards mean the plan is NOT finished - the human
   decides what to do with them first).
2. Create `tasks/archive/<plan-id>/`.
3. `git mv` every `tasks/done/<plan-id>-*` file (task cards AND their sidecars:
   .result.md, .verify.log, .gen*.* history) into `tasks/archive/<plan-id>/`.
4. `git mv tasks/plan-<plan-id>.md tasks/archive/<plan-id>/plan-<plan-id>.md`
   (the snapshot retires with its cards - spec section 1).
5. One commit, explicit paths, message: `muster(<plan-id>): close`.
6. Print: card count archived, and a reminder that archived tasks still satisfy
   dependencies (D15).
```

- [ ] **Step 2: Manual verification**

In the scratch repo after a full toy run (Task 18's plan sharded, executed, reviewed):
follow close by hand; expect done/ empty, `tasks/archive/<id>/` holding cards +
sidecars + snapshot, one `muster(<id>): close` commit, clean status.

- [ ] **Step 3: Commit**

```bash
git add skills/close/SKILL.md
git commit -m "feat(skills): muster:close"
```

### Task 21: Eval harness - fixture builder + deterministic rubric

**Files:**
- Create: `evals/runner-compliance/setup.ps1`
- Create: `evals/runner-compliance/rubric.ps1`
- Create: `evals/runner-compliance/README.md`
- Delete: `evals/.gitkeep`

skill-creator-style eval, deterministic scoring (approved: no LLM judge). RUNNER
compliance is fully observable from git history + the filesystem after the run.

- [ ] **Step 1: Write `evals/runner-compliance/setup.ps1`**

```powershell
# Builds the eval fixture: a repo with MUSTER installed and one seeded impl task.
# Usage: powershell -File evals/runner-compliance/setup.ps1  -> prints the fixture path.
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding $false
$pluginRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent

$dir = Join-Path ([IO.Path]::GetTempPath()) ('muster-eval-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $dir | Out-Null
git -C $dir init -q -b main
git -C $dir config user.email 'eval@muster.local'
git -C $dir config user.name 'muster-eval'
foreach ($f in 'backlog', 'inbox', 'doing', 'done', 'failed', 'archive', 'staging', 'bin') {
    $p = Join-Path $dir "tasks/$f"
    New-Item -ItemType Directory -Path $p | Out-Null
    [IO.File]::WriteAllText((Join-Path $p '.gitkeep'), '', $utf8)
}
Copy-Item (Join-Path $pluginRoot 'runtime/bin/*') (Join-Path $dir 'tasks/bin')
Copy-Item (Join-Path $pluginRoot 'runtime/RUNNER.md') (Join-Path $dir 'tasks')
[IO.File]::WriteAllText((Join-Path $dir 'README.md'), "eval fixture`n", $utf8)
git -C $dir add -A
git -C $dir commit -qm 'eval: init board'

$task = @(
    '---'
    'id: hello-01-write-greeting'
    'plan: hello'
    'type: impl'
    'tier: any'
    'depends_on: []'
    'protected:'
    '  - tasks/RUNNER.md'
    'commit_paths:'
    '  - out/hello.txt'
    'verify:'
    '  - cmd: "powershell -NoProfile -Command Get-Content out/hello.txt"'
    '    expect_contains: "hello muster"'
    '    timeout_seconds: 60'
    '---'
    '# hello-01-write-greeting: write the greeting file'
    ''
    '## Context'
    ''
    'This repo needs a greeting artifact. Nothing exists yet under out/.'
    ''
    '## Steps'
    ''
    '1. Ensure the directory out/ exists at the repo root.'
    '2. Ensure out/hello.txt exists containing exactly the single line: hello muster'
    ''
    '## Acceptance'
    ''
    '- out/hello.txt prints hello muster.'
) -join "`n"
[IO.File]::WriteAllText((Join-Path $dir 'tasks/inbox/hello-01-write-greeting.md'), ($task + "`n"), $utf8)
git -C $dir add 'tasks/inbox/hello-01-write-greeting.md'
git -C $dir commit -qm 'eval: seed task'
Write-Output $dir
```

- [ ] **Step 2: Write `evals/runner-compliance/rubric.ps1`**

```powershell
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
Check 'exactly claim+done'        ($postSeed.Count -eq 2)

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
```

- [ ] **Step 3: Write `evals/runner-compliance/README.md`**

```markdown
# runner-compliance eval

Measures whether a fresh executor session follows tasks/RUNNER.md using only the
wrapper prompt - no coaching. Scoring is deterministic (git + filesystem); no judge.

## Procedure

1. `powershell -File evals/runner-compliance/setup.ps1` - prints the fixture path.
2. Dispatch a FRESH Sonnet subagent whose entire prompt is the dispatch prompt below,
   with `<FIXTURE>` substituted. No extra instructions, no hints.
3. `powershell -File evals/runner-compliance/rubric.ps1 -Fixture <FIXTURE>`
4. Record the rubric output in `results/<date>-<model>.md` together with anything
   anomalous in the transcript (extra tool calls, improvisation, ignored refusals).
5. Delete the fixture directory.

## Dispatch prompt (verbatim)

    You are starting a MUSTER executor session. Your working directory is <FIXTURE>
    (cd there first; run every command from that directory).
    Run `powershell -ExecutionPolicy Bypass -File tasks/bin/claim.ps1 -Harness claude -Tier any`,
    then follow tasks/RUNNER.md to the letter.

## Reading the score

15/15 = fully compliant. Common failure signatures: executor ran git itself
("only muster commits" fails), edited the task file ("task file untouched" fails),
skipped verify ("verify log has attempt" fails), kept working after done
("exactly claim+done" fails).
```

- [ ] **Step 4: Dry-run the harness mechanically (no model)**

Run setup, then act as a perfectly obedient executor by hand: claim via script, write
the file, verify, done. Then rubric. Expected: `SCORE 15/15`, exit 0. This proves the
rubric can actually reach full marks before any model is measured.

- [ ] **Step 5: Commit**

```bash
git rm -q evals/.gitkeep
git add evals/runner-compliance/setup.ps1 evals/runner-compliance/rubric.ps1 evals/runner-compliance/README.md
git commit -m "feat(eval): runner-compliance fixture and deterministic rubric"
```

### Task 22: Eval run - fresh Sonnet executor

**Files:**
- Create: `evals/runner-compliance/results/2026-08-07-sonnet.md`

- [ ] **Step 1: Build the fixture** - run setup.ps1, note the path.

- [ ] **Step 2: Dispatch the subagent**

Agent tool, `subagent_type: general-purpose`, `model: sonnet`, prompt = the dispatch
prompt from the eval README with `<FIXTURE>` substituted. Nothing else in the prompt.
Wait for completion.

- [ ] **Step 3: Score** - run rubric.ps1 against the fixture. Copy the full output.

- [ ] **Step 4: Record**

Write `evals/runner-compliance/results/2026-08-07-sonnet.md`:

```markdown
# runner-compliance: sonnet, 2026-08-07

- harness: Claude Code / Agent tool, model sonnet, ps1 engine
- rubric: <SCORE line>

## Rubric output

<full PASS/FAIL listing verbatim>

## Transcript notes

<bullet list: deviations, improvisations, retries observed in the subagent
transcript; "none" if clean>

## Verdict

<one line: ship / investigate. A sub-15 score names the failing checks and the
suspected RUNNER.md wording that allowed the deviation.>
```

If the score is below 15/15: file the failing checks as findings, adjust RUNNER.md
wording (that file is the product under test), re-run setup + dispatch + rubric once,
and record both runs in the same results file.

- [ ] **Step 5: Clean up the fixture directory, commit**

```bash
git add evals/runner-compliance/results/2026-08-07-sonnet.md
git commit -m "test(eval): runner-compliance baseline run - sonnet"
```

### Task 23: sh mirror - lib, promote, verify

**Files:**
- Create: `runtime/bin/_lib.sh`, `runtime/bin/promote.sh`, `runtime/bin/verify.sh`
- Modify: `tests/MusterFixture.ps1` (no change needed - engine switch already built in)

Behavior oracle = the ps1 sources plus the Pester suites run with
`$env:MUSTER_ENGINE = 'sh'`. Identical stdout lines, identical exit codes, identical
file/commit effects. Git Bash's sh runs these; stick to POSIX (no arrays, no `[[`).

- [ ] **Step 1: Write `runtime/bin/_lib.sh`** (core; port the remaining ps1 helpers
function-by-function with these established patterns):

```sh
# MUSTER shared library (sh mirror of _lib.ps1). Sourced by every verb script.
set -u

repo_root() { git rev-parse --show-toplevel; }
tasks_root() { echo "$(repo_root)/tasks"; }
iso_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

refuse() { echo "MUSTER refuse: $1"; exit 1; }

task_files() { # $1 = absolute folder; task .md files only, sorted
    ls "$1"/*.md 2>/dev/null | grep -v '\.result\.md$' | grep -v '\.notes\.md$' | sort
}

fm_get() { # $1=file $2=key -> scalar value, quotes stripped, empty if absent
    awk -v k="$2" '
        NR==1 && $0!="---" { exit }
        NR>1 && $0=="---" { exit }
        index($0, k": ")==1 { v=substr($0, length(k)+3); gsub(/^"|"$/, "", v); print v; exit }
    ' "$1"
}

fm_list() { # $1=file $2=key -> block-list items, one per line ([] yields nothing)
    awk -v k="$2" '
        NR>1 && $0=="---" { exit }
        on && $0 !~ /^[ ]+- / { exit }
        on { s=$0; sub(/^[ ]+- /, "", s); gsub(/^"|"$/, "", s); print s }
        $0==k":" { on=1 }
    ' "$1"
}

fm_verify() { # $1=file -> flat records "idx<TAB>key<TAB>value" for the verify block
    awk '
        NR>1 && $0=="---" { exit }
        $0=="verify:" { on=1; idx=0; next }
        on && /^  - [a-z_]+: / { idx++; s=substr($0,5); emit(s); next }
        on && /^    [a-z_]+: / { s=substr($0,5); emit(s); next }
        on { exit }
        function emit(s,   k, v) {
            k=s; sub(/:.*/, "", k)
            v=s; sub(/^[a-z_]+: /, "", v); gsub(/^"|"$/, "", v)
            printf "%d\t%s\t%s\n", idx, k, v
        }
    ' "$1"
}

tokenize() { # $1=cmd -> tokens one per line (double quotes group; no shell interp)
    printf '%s' "$1" | awk '
        {
            n=split($0, ch, ""); tok=""; inq=0
            for (i=1; i<=n; i++) {
                c=ch[i]
                if (c=="\"") { inq=!inq; continue }
                if (!inq && (c==" " || c=="\t")) { if (tok!="") { print tok; tok="" }; continue }
                tok=tok c
            }
            if (tok!="") print tok
        }'
}

run_entry() { # $1=timeout_s, rest=tokens. Sets RUN_EXIT, RUN_TIMEDOUT; output in $RUN_OUT file.
    _t=$1; shift
    RUN_TIMEDOUT=0
    "$@" >"$RUN_OUT" 2>&1 &
    _pid=$!
    _n=0
    while kill -0 "$_pid" 2>/dev/null; do
        if [ "$_n" -ge "$_t" ]; then
            kill "$_pid" 2>/dev/null
            RUN_TIMEDOUT=1
            wait "$_pid" 2>/dev/null
            RUN_EXIT=124
            return
        fi
        sleep 1
        _n=$((_n + 1))
    done
    wait "$_pid"
    RUN_EXIT=$?
}

attempt_count() { # $1=log path
    if [ ! -f "$1" ]; then echo 0; return; fi
    grep -c '^=== attempt [0-9]* |' "$1" || true
}

verify_block() {
    # $1=task file (source of the verify block), $2=log, $3=label, $4=task id, $5=repo root
    # Echoes nothing; returns 0 on pass, 1 on fail; first failure reason in $VB_FIRSTFAIL.
    _file=$1; _log=$2; _label=$3; _id=$4; _root=$5
    VB_FIRSTFAIL=''
    _head=$(git -C "$_root" rev-parse HEAD)
    printf '=== %s | %s | task %s | HEAD %s\n' "$_label" "$(iso_now)" "$_id" "$_head" >>"$_log"
    RUN_OUT=$(mktemp)
    _n_entries=$(fm_verify "$_file" | awk -F'\t' '{ if ($1>m) m=$1 } END { print m+0 }')
    _i=1
    _pass=1
    while [ "$_i" -le "$_n_entries" ]; do
        _cmd=$(fm_verify "$_file" | awk -F'\t' -v i="$_i" '$1==i && $2=="cmd" { print $3 }')
        _xexit=$(fm_verify "$_file" | awk -F'\t' -v i="$_i" '$1==i && $2=="expect_exit" { print $3 }')
        _xcont=$(fm_verify "$_file" | awk -F'\t' -v i="$_i" '$1==i && $2=="expect_contains" { print $3 }')
        _tmo=$(fm_verify "$_file" | awk -F'\t' -v i="$_i" '$1==i && $2=="timeout_seconds" { print $3 }')
        [ -z "$_tmo" ] && _tmo=300
        printf '$ %s\n' "$_cmd" >>"$_log"
        set --
        while IFS= read -r _tok; do set -- "$@" "$_tok"; done <<EOF
$(tokenize "$_cmd")
EOF
        ( cd "$_root" && run_entry "$_tmo" "$@" ; echo "$RUN_EXIT $RUN_TIMEDOUT" >"$RUN_OUT.meta" )
        read -r RUN_EXIT RUN_TIMEDOUT <"$RUN_OUT.meta"
        [ -s "$RUN_OUT" ] && sed -e 's/[[:space:]]*$//' "$RUN_OUT" >>"$_log"
        _line=''
        _why=''
        _ok=1
        if [ "$RUN_TIMEDOUT" = "1" ]; then
            _line="timeout ${_tmo}s -> FAIL"; _why="timed out after ${_tmo}s"; _ok=0
        else
            _line="exit $RUN_EXIT"
            if [ -n "$_xexit" ]; then
                if [ "$RUN_EXIT" = "$_xexit" ]; then _line="$_line | expect_exit $_xexit -> OK"
                else _line="$_line | expect_exit $_xexit -> FAIL"; _why="exit $RUN_EXIT, expected $_xexit"; _ok=0; fi
            fi
            if [ -n "$_xcont" ]; then
                if grep -qF "$_xcont" "$RUN_OUT"; then _line="$_line | expect_contains \"$_xcont\" -> OK"
                else _line="$_line | expect_contains \"$_xcont\" -> MISSING"; _why="output missing \"$_xcont\""; _ok=0; fi
            fi
        fi
        printf '%s\n' "$_line" >>"$_log"
        if [ "$_ok" = "0" ]; then
            _pass=0
            VB_FIRSTFAIL="$_cmd: $_why"
            break
        fi
        _i=$((_i + 1))
    done
    rm -f "$RUN_OUT" "$RUN_OUT.meta"
    if [ "$_pass" = "1" ]; then
        printf '=== %s result: PASS\n' "$_label" >>"$_log"
        return 0
    fi
    printf '=== %s result: FAIL\n' "$_label" >>"$_log"
    return 1
}
```

Port the remaining helpers the same way, preserving every printed string byte-for-byte
with the ps1 versions (the shared suite diffs them): `sole_occupant`, `age_string`,
`status_block`, `dirty_paths`, `path_listed` / `path_in_scope`, `set_claimed_at`,
`dep_satisfied` / `promote_run`, `claim_commit_of`, `done_preconditions`,
`result_sidecar`, `complete_task`, `move_task_sidecars`, `move_to_failed*`,
`fix_count`, `add_depends_on`, `lint_checks`. One sh function per ps1 function -
same names in snake_case, same argument order, same messages.

Difference to respect: `verify_block` reads entries from a FILE. For the
HEAD-committed read (spec 4.2), verb scripts first `git show HEAD:tasks/doing/<name>`
into a temp file and pass that path.

- [ ] **Step 2: Write `runtime/bin/promote.sh`**

```sh
#!/bin/sh
# MUSTER promote (sh) - spec 4.4.
set -u
. "$(dirname "$0")/_lib.sh"

NO_COMMIT=0
[ "${1:-}" = "--no-commit" ] && NO_COMMIT=1
promote_run "$NO_COMMIT" >/dev/null
exit 0
```

with `promote_run` in `_lib.sh` mirroring `Invoke-Promote` (prints moved ids one per
line to stdout for `claim`/`done` to capture; warn lines go to stderr-free stdout the
same way ps1 does).

- [ ] **Step 3: Write `runtime/bin/verify.sh`** - direct port of `verify.ps1`: sole
occupant, `git show HEAD:` to a temp file, attempt count, `verify_block`, the exact
`VERIFY PASS (attempt <n>)` / `VERIFY FAIL (attempt <n> of 3): <why>. Fix and rerun.` /
terminal lines and exits 0/2/3, terminal move + `muster(<plan>): fail <id>` commit.

- [ ] **Step 4: Run the ported suites under the sh engine**

```powershell
$env:MUSTER_ENGINE = 'sh'
Invoke-Pester tests/Promote.Tests.ps1, tests/Verify.Tests.ps1 -Output Detailed
$env:MUSTER_ENGINE = $null
```

Expected: PASS - the identical assertions that passed for ps1. (Lib.Tests stays
ps1-only: it tests in-process functions, not the contract.)

- [ ] **Step 5: Commit**

```bash
git add runtime/bin/_lib.sh runtime/bin/promote.sh runtime/bin/verify.sh
git commit -m "feat(bin): sh mirror - lib core, promote, verify"
```

### Task 24: sh mirror - lint, claim, done + dual-engine suite

**Files:**
- Create: `runtime/bin/lint.sh`, `runtime/bin/claim.sh`, `runtime/bin/done.sh`
- Modify: `runtime/bin/_lib.sh` (append remaining ported helpers)

- [ ] **Step 1: Write `runtime/bin/lint.sh`** - port `lint.ps1` + `Test-LintChecks`.
Same finding strings (`LINT FAIL <file>: <msg>` / `LINT OK <n> file(s)`), same exit
codes, `--lite` flag. The 13 checks translate to grep/awk over the same regexes
already listed in Task 9 - reuse those patterns verbatim.

- [ ] **Step 2: Write `runtime/bin/claim.sh`** - port `claim.ps1` including the
recovery probe. Flag parsing:

```sh
#!/bin/sh
set -u
. "$(dirname "$0")/_lib.sh"
HARNESS=''; TIER=''
while [ $# -gt 0 ]; do
    case "$1" in
        --harness) HARNESS=${2:-}; shift 2 ;;
        --tier) TIER=${2:-}; shift 2 ;;
        *) shift ;;
    esac
done
case "$HARNESS" in claude|codex) ;; *) refuse 'claim requires -Harness <claude|codex> and -Tier <any|strong> (the wrapper skill supplies them).' ;; esac
case "$TIER" in any|strong) ;; *) refuse 'claim requires -Harness <claude|codex> and -Tier <any|strong> (the wrapper skill supplies them).' ;; esac
```

(The refusal text stays identical to ps1 - the suite asserts the message, and RUNNER
tells executors to quote refusals verbatim regardless of engine.)

- [ ] **Step 3: Write `runtime/bin/done.sh`** - port `done.ps1` + the two fail paths.

- [ ] **Step 4: Run the FULL contract suite under both engines**

```powershell
Invoke-Pester tests -Output Detailed                      # ps1 engine
$env:MUSTER_ENGINE = 'sh'
Invoke-Pester tests/Promote.Tests.ps1, tests/Verify.Tests.ps1, tests/Lint.Tests.ps1, tests/Claim.Tests.ps1, tests/Done.Tests.ps1 -Output Detailed
$env:MUSTER_ENGINE = $null
```

Expected: all PASS on both engines. Any sh divergence is a bug in the port - fix the
sh side; never adjust a test to fit sh.

- [ ] **Step 5: Commit**

```bash
git add runtime/bin/_lib.sh runtime/bin/lint.sh runtime/bin/claim.sh runtime/bin/done.sh
git commit -m "feat(bin): sh mirror - lint, claim, done; dual-engine suite green"
```

### Task 25: Final verification sweep

**Files:** none created - verification only, plus whatever fixes it forces.

- [ ] **Step 1: Fresh full suite, both engines** (same commands as Task 24 Step 4,
from a clean `git status`). Expected: all PASS.

- [ ] **Step 2: End-to-end toy walkthrough** - in a scratch repo outside this one:
follow `muster:init` by hand (Task 17 checklist), shard the toy plan by hand
(Task 18 checklist), then drive one full lifecycle with the scripts only:
claim -> write file -> verify -> done, claim review (strong) -> notes -> done pass,
claim integration -> notes -> done pass, then `muster:close` by hand. Expected end
state: board empty except archive/, every commit message matches the spec set, clean
status. Any friction found here is a bug - fix it in this repo, add a regression test
if it was a script bug.

- [ ] **Step 3: Placeholder sweep over shipped artifacts**

```powershell
Select-String -Path runtime/RUNNER.md, skills/*/SKILL.md -Pattern 'TBD|TODO|FIXME'
```

Expected: no matches. (templates/ legitimately carries `{braces}` - excluded.)

- [ ] **Step 4: Commit any fixes; final state check**

`git status` clean, `git log --oneline` shows one commit per plan task. Done means:
suite green both engines, eval recorded, walkthrough clean.

---

## Not yet specified

Carried forward from spec section 9 (fog - do not pre-slice):

- Drain mode: may an executor claim another task in the same session while context is
  low? Dilutes the fresh-context guarantee - undecided.
- registry.json shape (orchestrator/app concern, out of the v1 critical path).
- Codex smoke-test procedure detail - dormant until Codex installs (D16 gate).

## Out of scope

- Control plane (ASP.NET viewer) - v2 (D14).
- Codex wrapper activation, smoke test, D26 measurement - dormant until Codex installs.
- Concurrency via git worktrees - KIV (D18).
- Feature-branch git flows - v2 (D21).
- Programmatic / automated dispatch - blocked by apps-only constraint (D16).
- README / marketing prose for the plugin - not pinned by the spec, add when publishing.
