# Test Speed Phase 0 + Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Record a repeatable timing baseline, then prove the in-process `CommandResult` pattern on `status` and `lint` while the full existing test suite stays green.

**Architecture:** Convert `Write-Refuse` from `exit`-based to a throw carrying a `MusterRefusal` tag; every verb script gets a boundary catch so refusals still print to stdout and exit 1. Extract `status` and `lint` bodies into `_lib.ps1` command functions returning a `CommandResult` object; the scripts become shims. New in-process tests run command functions in fresh 5.1 runspaces instead of ~1.8 s `powershell.exe` children (Task 5 records the measured per-call figure). The unchanged black-box suite is the parity gate at every commit.

**Tech Stack:** Windows PowerShell 5.1, Pester (installed 6.0.1; suite hosted via `powershell.exe` to pin the 5.1 engine), Git.

**Spec:** `docs/test-speed-consolidation-plan.md` (rev 2), Phases 0-1. Review context: `docs/runtime-consolidation/codex-review.md`.

**Constraints from spec:**
- No behavior change observable through the existing black-box suite. Both engines' suites stay green (sh scripts untouched).
- Single control-flow model: no dual-mode `Write-Refuse`.
- Baseline is recorded BEFORE any machine tuning; no NGen in this plan.
- Stop condition (Phase 1 exit): if extraction makes control flow more complex or fragile, halt and report - that outcome feeds the C# decision.

---

### Task 1: Baseline measurement script and baseline document

**Files:**
- Create: `tests/bench/Measure-Baseline.ps1`
- Create: `docs/runtime-consolidation/baseline-2026-08-13.md` (generated output, committed)

- [ ] **Step 1: Write the measurement script**

Create `tests/bench/Measure-Baseline.ps1`:

```powershell
# MUSTER baseline benchmark. Records the numbers the 30-second p95 gate is judged against.
# Run from repo root, Windows PowerShell 5.1 host:
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/bench/Measure-Baseline.ps1
# Full-suite timing across both engines takes roughly 1.5-2 hours; use -SkipSuite for micro-only reruns.
# WARNING: overwrites its output file. Phase 1 comparison results live in a separate file for this reason.
param([switch]$SkipSuite)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# Fixed measurement config - vary in source if a future phase needs it (YAGNI: no dead knobs).
$MicroRuns = 5
$SuiteRuns = 3
$Engines   = @('ps1', 'sh')
$OutFile   = 'docs/runtime-consolidation/baseline-2026-08-13.md'

# A leaked MUSTER_ENGINE=sh would silently make the micro rows measure the sh engine
# under a ps1-implied label. Clear it up front; the suite loop sets it per engine.
Remove-Item Env:MUSTER_ENGINE -ErrorAction SilentlyContinue

$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. (Join-Path $repoRoot 'tests/MusterFixture.ps1')

function Get-Percentile {
    param([double[]]$Samples, [double]$P)
    $s = @($Samples | Sort-Object)
    $idx = [math]::Ceiling($P * $s.Count) - 1
    if ($idx -lt 0) { $idx = 0 }
    return [math]::Round($s[$idx], 3)
}

function Measure-Samples {
    param([string]$Label, [int]$Runs, [scriptblock]$Body)
    $samples = @()
    for ($i = 1; $i -le $Runs; $i++) {
        $samples += (Measure-Command { & $Body }).TotalSeconds
    }
    [pscustomobject]@{
        Label = $Label
        Runs  = $Runs
        Cold  = [math]::Round($samples[0], 3)      # run 1 = cold-ish
        P50   = Get-Percentile -Samples $samples -P 0.50
        P95   = Get-Percentile -Samples $samples -P 0.95
        All   = ($samples | ForEach-Object { [math]::Round($_, 3) }) -join ', '
    }
}

$rows = @()

# --- micro benchmarks -------------------------------------------------------
$rows += Measure-Samples -Label 'powershell.exe spawn (-NoProfile, exit 0)' -Runs $MicroRuns -Body {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -Command 'exit 0' | Out-Null
}
$rows += Measure-Samples -Label 'fixture create+destroy (New-MusterFixture)' -Runs $MicroRuns -Body {
    $fx = New-MusterFixture; Remove-MusterFixture $fx
}
$fx = New-MusterFixture
try {
    $rows += Measure-Samples -Label 'git status in fixture' -Runs $MicroRuns -Body {
        git -C $fx status --porcelain | Out-Null
    }
    $rows += Measure-Samples -Label 'status verb via child process (Invoke-Muster)' -Runs $MicroRuns -Body {
        Invoke-Muster $fx 'status' | Out-Null
    }
}
finally { Remove-MusterFixture $fx }

# --- per-file suite timings -------------------------------------------------
$suiteRows = @()
if (-not $SkipSuite) {
    $testFiles = @(Get-ChildItem (Join-Path $repoRoot 'tests') -Filter '*.Tests.ps1' | Sort-Object Name)
    foreach ($engine in $Engines) {
        foreach ($tf in $testFiles) {
            $samples = @()
            for ($i = 1; $i -le $SuiteRuns; $i++) {
                $samples += (Measure-Command {
                    if ($engine -eq 'sh') { $env:MUSTER_ENGINE = 'sh' }
                    else { Remove-Item Env:MUSTER_ENGINE -ErrorAction SilentlyContinue }
                    & powershell.exe -NoProfile -ExecutionPolicy Bypass -Command `
                        "Invoke-Pester -Path '$($tf.FullName)'" | Out-Null
                }).TotalSeconds
            }
            Remove-Item Env:MUSTER_ENGINE -ErrorAction SilentlyContinue
            $suiteRows += [pscustomobject]@{
                Engine = $engine
                File   = $tf.Name
                Cold   = [math]::Round($samples[0], 3)
                P50    = Get-Percentile -Samples $samples -P 0.50
                P95    = Get-Percentile -Samples $samples -P 0.95
                All    = ($samples | ForEach-Object { [math]::Round($_, 3) }) -join ', '
            }
        }
    }
}

# --- emit markdown ----------------------------------------------------------
$md = @()
$md += '# Baseline: 2026-08-13'
$md += ''
$md += "Machine: $env:COMPUTERNAME, Windows PowerShell $($PSVersionTable.PSVersion). No NGen or machine tuning applied."
$md += "Micro rows measured with the ps1 engine (MUSTER_ENGINE cleared at script start)."
$md += "MicroRuns=$MicroRuns, SuiteRuns=$SuiteRuns. Cold = run 1. p95 over N<=5 runs approximates the max - noted per spec."
$md += ''
$md += '## Micro benchmarks (seconds)'
$md += ''
$md += '| Operation | Runs | Cold | p50 | p95 | All samples |'
$md += '|---|---:|---:|---:|---:|---|'
foreach ($r in $rows) { $md += "| $($r.Label) | $($r.Runs) | $($r.Cold) | $($r.P50) | $($r.P95) | $($r.All) |" }
$md += ''
if ($suiteRows.Count -gt 0) {
    $md += '## Per-file suite timings (seconds)'
    $md += ''
    $md += '| Engine | File | Cold | p50 | p95 | All samples |'
    $md += '|---|---|---:|---:|---:|---|'
    foreach ($r in $suiteRows) { $md += "| $($r.Engine) | $($r.File) | $($r.Cold) | $($r.P50) | $($r.P95) | $($r.All) |" }
    $md += ''
    foreach ($engine in $Engines) {
        $tot = ($suiteRows | Where-Object Engine -eq $engine | Measure-Object P50 -Sum).Sum
        $md += "Total p50, engine ${engine}: $([math]::Round($tot, 1)) s"
    }
}
$outPath = Join-Path $repoRoot $OutFile
$dir = Split-Path $outPath -Parent
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
[IO.File]::WriteAllText($outPath, (($md -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding $false))
Write-Output "Baseline written: $OutFile"
```

- [ ] **Step 2: Run micro benchmarks only, verify output**

Run:
```
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/bench/Measure-Baseline.ps1 -SkipSuite
```
Expected: `Baseline written: docs/runtime-consolidation/baseline-2026-08-13.md`; file contains the micro table with 4 rows, spawn ~1.5-2 s, fixture ~0.5-0.9 s.

- [ ] **Step 3: Run the full baseline (both engines)**

Run (takes roughly 1.5-2 hours - the archived integration log alone records 794 s + 973 s per single suite pass; schedule it, run in background if the harness supports it):
```
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/bench/Measure-Baseline.ps1
```
Expected: baseline file now also contains per-file tables for both engines and total p50 lines. Sanity: ps1 total in the 600-1000 s range (archived integration log recorded 794 s), sh larger.

- [ ] **Step 4: Commit**

```bash
git add tests/bench/Measure-Baseline.ps1 docs/runtime-consolidation/baseline-2026-08-13.md
git commit -m "test(bench): baseline measurement script + 2026-08-13 baseline"
```

---

### Task 2: Throw-based refusal core + boundary wrappers in all six verb scripts

The single control-flow model: `Write-Refuse` throws a tagged exception; every verb script's boundary catch converts it to the `MUSTER refuse:` stdout line + `exit 1`. Refusals thrown at ANY helper depth (e.g. `Get-SoleOccupant` inside `verify`) propagate to the boundary unchanged. sh scripts untouched.

**Files:**
- Create: `tests/fast/CommandCore.Fast.Tests.ps1`
- Modify: `runtime/bin/_lib.ps1:8-12` (`Get-RepoRoot`), `runtime/bin/_lib.ps1:24-29` (`Write-Refuse`), plus two new functions after `Write-Refuse`
- Modify: `runtime/bin/claim.ps1`, `runtime/bin/promote.ps1`, `runtime/bin/verify.ps1`, `runtime/bin/done.ps1`, `runtime/bin/status.ps1`, `runtime/bin/lint.ps1` (boundary wrap only in this task)

- [ ] **Step 1: Write the failing tests**

Create `tests/fast/CommandCore.Fast.Tests.ps1`:

```powershell
BeforeAll {
    . (Join-Path $PSScriptRoot '../../runtime/bin/_lib.ps1')
}

Describe 'CommandResult core' {
    It 'New-CommandResult defaults to empty output, exit 0' {
        $r = New-CommandResult
        $r.ExitCode | Should -Be 0
        @($r.Output).Count | Should -Be 0
    }
    It 'New-CommandResult carries output lines and exit code' {
        $r = New-CommandResult -Output @('a', 'b') -ExitCode 3
        $r.Output[1] | Should -Be 'b'
        $r.ExitCode | Should -Be 3
    }
    It 'Write-Refuse throws a MusterRefusal-tagged exception with the refusal line' {
        $err = $null
        try { Write-Refuse 'boom' } catch { $err = $_ }
        $err | Should -Not -BeNullOrEmpty
        $err.Exception.Message | Should -Be 'MUSTER refuse: boom'
        $err.Exception.Data.Contains('MusterRefusal') | Should -BeTrue
    }
    It 'Invoke-CommandBoundary converts a refusal into a CommandResult' {
        $r = Invoke-CommandBoundary { Write-Refuse 'nope' }
        $r.ExitCode | Should -Be 1
        $r.Output[0] | Should -Be 'MUSTER refuse: nope'
    }
    It 'Invoke-CommandBoundary passes a normal result through' {
        $r = Invoke-CommandBoundary { New-CommandResult -Output @('hi') }
        $r.ExitCode | Should -Be 0
        $r.Output[0] | Should -Be 'hi'
    }
    It 'Invoke-CommandBoundary rethrows non-refusal errors' {
        { Invoke-CommandBoundary { throw 'genuine bug' } } | Should -Throw
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:
```
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Pester -Path tests/fast/CommandCore.Fast.Tests.ps1"
```
Expected: FAIL - `New-CommandResult` not recognized; the `Write-Refuse` test would `exit` the child (that is the current behavior being replaced).

- [ ] **Step 3: Implement the core in `_lib.ps1`**

Replace `Get-RepoRoot` (`runtime/bin/_lib.ps1:8-12`):

```powershell
function Get-RepoRoot {
    $root = git rev-parse --show-toplevel
    if ($LASTEXITCODE -ne 0 -or -not $root) { Write-Refuse 'not inside a git repository.' }
    return $root
}
```

(Message is byte-identical: old code printed `MUSTER refuse: not inside a git repository.` inline.)

Replace `Write-Refuse` (`runtime/bin/_lib.ps1:24-29`) and add the two new functions directly below it:

```powershell
function Write-Refuse {
    # Single-line refusal per spec 4.0. Throws a tagged exception; the verb-script
    # boundary catch (or Invoke-CommandBoundary) turns it into the 'MUSTER refuse:'
    # stdout line + exit 1. Callers still rely on this never returning.
    param([string]$Message)
    $ex = New-Object System.Exception "MUSTER refuse: $Message"
    $ex.Data['MusterRefusal'] = $true
    throw $ex
}

function New-CommandResult {
    param([string[]]$Output = @(), [int]$ExitCode = 0)
    [pscustomobject]@{ Output = @($Output); ExitCode = [int]$ExitCode }
}

function Invoke-CommandBoundary {
    # Runs a command scriptblock; a Write-Refuse throw becomes a refusal CommandResult,
    # anything else propagates as a genuine error.
    param([scriptblock]$Body)
    try { return & $Body }
    catch {
        if ($_.Exception.Data.Contains('MusterRefusal')) {
            return New-CommandResult -Output @($_.Exception.Message) -ExitCode 1
        }
        throw
    }
}

function Exit-OnRefusal {
    # Script-boundary twin of Invoke-CommandBoundary for not-yet-converted verb scripts:
    # prints the refusal line to stdout and exits 1; rethrows anything else.
    param($ErrorRecord)
    if ($ErrorRecord.Exception.Data.Contains('MusterRefusal')) {
        Write-Output $ErrorRecord.Exception.Message
        exit 1
    }
    throw $ErrorRecord
}
```

- [ ] **Step 4: Wrap all six verb scripts with the boundary catch**

For EACH of `claim.ps1`, `promote.ps1`, `verify.ps1`, `done.ps1`, `status.ps1`, `lint.ps1`: insert `try {` on a new line immediately AFTER the `. (Join-Path $PSScriptRoot '_lib.ps1')` line, and append this at end of file (leave the body's existing indentation untouched):

```powershell
}
catch { Exit-OnRefusal $_ }
```

Worked example - `promote.ps1` becomes:

```powershell
# MUSTER promote - spec 4.4. Thin wrapper; logic in _lib.ps1.
param([switch]$NoCommit)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_lib.ps1')
try {

[void](Invoke-Promote -NoCommit:$NoCommit)
exit 0
}
catch { Exit-OnRefusal $_ }
```

Notes:
- `exit` statements inside the `try` (claim's `exit 0`, done's paths, the remaining review/integration exits inside `Invoke-DoneFailReview` and `Invoke-DoneFailIntegration` in `_lib.ps1`) are NOT caught by `catch` - they exit as before. Only thrown refusals hit the new catch.
- `status.ps1` and `lint.ps1` get the same wrap here even though Tasks 3-4 rewrite them: `lint.ps1:7` has a live refusal and `status.ps1` refuses via `Get-RepoRoot` outside a repo - leaving them unwrapped would put those refusals on stderr for two commits.
- Do not touch the review/integration-path exits or any sh file in this task.

- [ ] **Step 5: Run the new tests to verify they pass**

Run:
```
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Pester -Path tests/fast/CommandCore.Fast.Tests.ps1"
```
Expected: 6 tests PASS.

- [ ] **Step 6: Run the FULL existing suite, both engines (parity gate)**

Run:
```
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Pester -Path tests"
```
then:
```
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "`$env:MUSTER_ENGINE='sh'; Invoke-Pester -Path tests"
```
Expected: 129 tests pass on BOTH arms - the 123 original plus the 6 new `tests/fast/` tests, which `-Path tests` picks up recursively; the fast tests dot-source `_lib.ps1` directly and run identically regardless of `MUSTER_ENGINE`. The sh arm exercises unchanged sh scripts; the ps1 arm exercises the wrapped scripts. Any refusal-message or exit-code diff = STOP, investigate before proceeding.

- [ ] **Step 7: Commit**

```bash
git add runtime/bin/_lib.ps1 runtime/bin/claim.ps1 runtime/bin/promote.ps1 runtime/bin/verify.ps1 runtime/bin/done.ps1 runtime/bin/status.ps1 runtime/bin/lint.ps1 tests/fast/CommandCore.Fast.Tests.ps1
git commit -m "refactor(runtime): throw-based refusals with CommandResult boundary"
```

---

### Task 3: In-process runspace harness + `Invoke-StatusCommand`

**Files:**
- Create: `tests/fast/InProcHarness.ps1`
- Create: `tests/fast/Status.Fast.Tests.ps1`
- Modify: `runtime/bin/_lib.ps1` (add `Invoke-StatusCommand` after `Get-StatusBlock`, i.e. after current line 716)
- Modify: `runtime/bin/status.ps1` (full rewrite to shim)

- [ ] **Step 1: Write the harness**

Create `tests/fast/InProcHarness.ps1`:

```powershell
# In-process runspace harness. Runs a command function in a FRESH Windows PowerShell
# runspace cd'd into a fixture - clean session state, far cheaper than a ~1.8 s
# powershell.exe child. Dot-source AFTER MusterFixture.ps1 (needs $script:RepoRoot).
#
# KNOWN DIVERGENCE from the child-process tier: under the library's
# $ErrorActionPreference='Stop', a FAILING native command's stderr becomes a
# terminating NativeCommandError inside a hosted runspace, so a refusal that follows
# a failing git call (e.g. Get-RepoRoot outside a repo) surfaces as Invoke() throwing,
# not as a refusal CommandResult. A powershell.exe -File child does not behave this
# way. Such cases belong to the retained process tier.
Set-StrictMode -Version 2.0

function Invoke-MusterInProc {
    # $Command is a PowerShell expression string, e.g. 'Invoke-StatusCommand' or
    # "Invoke-LintCommand -Paths @('tasks/backlog/p-01-a.md')". Returns the CommandResult.
    param([string]$Fixture, [string]$Command)
    $lib = Join-Path $script:RepoRoot 'runtime/bin/_lib.ps1'
    $ps = [powershell]::Create()   # fresh runspace per call
    try {
        [void]$ps.AddScript(@"
Set-Location -LiteralPath '$Fixture'
. '$lib'
Invoke-CommandBoundary { $Command }
"@)
        $out = @($ps.Invoke())   # terminating errors surface here as a thrown exception
        if ($out.Count -eq 0) { throw "InProc command produced no output: $Command" }
        return $out[$out.Count - 1]
    }
    finally { $ps.Dispose() }
}
```

- [ ] **Step 2: Write the failing tests**

Create `tests/fast/Status.Fast.Tests.ps1` - mirrors the four cases in `tests/Status.Tests.ps1` through the in-process path:

```powershell
BeforeAll {
    . (Join-Path $PSScriptRoot '../MusterFixture.ps1')
    . (Join-Path $PSScriptRoot 'InProcHarness.ps1')
}

Describe 'Invoke-StatusCommand (in-process)' {
    BeforeEach { $script:fx = New-MusterFixture }
    AfterEach { Remove-MusterFixture $script:fx }

    It 'returns the empty-board line with exit 0' {
        $r = Invoke-MusterInProc $script:fx 'Invoke-StatusCommand'
        $r.ExitCode | Should -Be 0
        ($r.Output -join "`n") | Should -Match 'MUSTER: board empty - nothing sharded or all archived\.'
    }
    It 'returns the status block with the dispatch split' {
        New-TaskFile -Fixture $script:fx -Folder inbox -Id 'p-01-a' -Commit | Out-Null
        New-TaskFile -Fixture $script:fx -Folder inbox -Id 'p-02-review-a' -Type review -Tier strong -Commit | Out-Null
        $r = Invoke-MusterInProc $script:fx 'Invoke-StatusCommand'
        $r.ExitCode | Should -Be 0
        ($r.Output -join "`n") | Should -Match '^MUSTER status @'
        ($r.Output -join "`n") | Should -Match '\(run 1, review 1\) \[p-01-a, p-02-review-a\]'
    }
    It 'flags invalid inbox files in the split' {
        New-TaskFile -Fixture $script:fx -Folder inbox -Id 'p-01-a' -Commit | Out-Null
        [IO.File]::WriteAllText((Join-Path $script:fx 'tasks/inbox/p-02-broken.md'), "no frontmatter`n", $script:Utf8NoBom)
        $r = Invoke-MusterInProc $script:fx 'Invoke-StatusCommand'
        ($r.Output -join "`n") | Should -Match '\(run 1, review 0, invalid 1\)'
    }
    It 'shows STALE and DEAD markers' {
        New-TaskFile -Fixture $script:fx -Folder doing -Id 'p-01-a' `
            -ExtraFront @('claimed_at: 2026-08-01T00:00:00Z') -Commit | Out-Null
        New-TaskFile -Fixture $script:fx -Folder failed -Id 'p-02-b' -Commit | Out-Null
        New-TaskFile -Fixture $script:fx -Folder backlog -Id 'p-03-c' -DependsOn @('p-02-b') -Commit | Out-Null
        $r = Invoke-MusterInProc $script:fx 'Invoke-StatusCommand'
        ($r.Output -join "`n") | Should -Match 'STALE'
        ($r.Output -join "`n") | Should -Match '1 DEAD: p-03-c behind failed p-02-b'
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run:
```
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Pester -Path tests/fast/Status.Fast.Tests.ps1"
```
Expected: FAIL - `Invoke-StatusCommand` is not recognized (thrown out of the runspace by the harness).

- [ ] **Step 4: Implement `Invoke-StatusCommand` and the shim**

Add to `runtime/bin/_lib.ps1`, directly after `Get-StatusBlock` (after current line 716):

```powershell
function Invoke-StatusCommand {
    # status verb (spec 8.3). Returns CommandResult; never writes or exits.
    # Split on LF so Output is uniformly one-entry-per-line across all command functions.
    New-CommandResult -Output @((Get-StatusBlock -RepoRoot (Get-RepoRoot) -TasksRoot (Get-TasksRoot)) -split "`n")
}
```

(The shim's `$r.Output | Write-Output` prints the same text either way; splitting only normalizes the `CommandResult` shape.)

Rewrite `runtime/bin/status.ps1` entirely (replaces the Task 2 wrapped version):

```powershell
# MUSTER status - on-demand board print (spec 8.3). Not part of the RUNNER contract.
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_lib.ps1')

$r = Invoke-CommandBoundary { Invoke-StatusCommand }
$r.Output | Write-Output
exit $r.ExitCode
```

- [ ] **Step 5: Run the fast tests to verify they pass**

Run:
```
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Pester -Path tests/fast/Status.Fast.Tests.ps1"
```
Expected: 4 tests PASS.

- [ ] **Step 6: Run the existing status suite (parity gate)**

Run:
```
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Pester -Path tests/Status.Tests.ps1"
```
Expected: 4 tests PASS - the shim's child-process output is unchanged.

- [ ] **Step 7: Commit**

```bash
git add runtime/bin/_lib.ps1 runtime/bin/status.ps1 tests/fast/InProcHarness.ps1 tests/fast/Status.Fast.Tests.ps1
git commit -m "refactor(runtime): extract Invoke-StatusCommand, status.ps1 becomes shim"
```

---

### Task 4: `Invoke-LintCommand`

**Files:**
- Create: `tests/fast/Lint.Fast.Tests.ps1`
- Modify: `runtime/bin/_lib.ps1` (add `Invoke-LintCommand` after `Invoke-StatusCommand`)
- Modify: `runtime/bin/lint.ps1` (full rewrite to shim)

- [ ] **Step 1: Write the failing tests**

Create `tests/fast/Lint.Fast.Tests.ps1` - covers OK path, findings path, and refusal path in-process:

```powershell
BeforeAll {
    . (Join-Path $PSScriptRoot '../MusterFixture.ps1')
    . (Join-Path $PSScriptRoot 'InProcHarness.ps1')
}

Describe 'Invoke-LintCommand (in-process)' {
    BeforeEach { $script:fx = New-MusterFixture }
    AfterEach { Remove-MusterFixture $script:fx }

    It 'passes a well-formed batch with LINT OK and exit 0' {
        # Lint check 11 requires exactly one integration task per non-Lite batch
        # (_lib.ps1, Test-LintChecks) - a lone impl file fails. Mirror the 3-file
        # good batch from tests/Lint.Tests.ps1 New-GoodBatch.
        New-TaskFile -Fixture $script:fx -Folder backlog -Id 'p-01-a' -CommitPaths @('src/out.txt') | Out-Null
        New-TaskFile -Fixture $script:fx -Folder backlog -Id 'p-02-review-a' -Type review -Tier strong `
            -DependsOn @('p-01-a') -ExtraFront @('reviews: p-01-a') | Out-Null
        New-TaskFile -Fixture $script:fx -Folder backlog -Id 'p-99-integration' -Type integration -Tier strong `
            -DependsOn @('p-01-a', 'p-02-review-a') | Out-Null
        $r = Invoke-MusterInProc $script:fx ("Invoke-LintCommand -Paths @(" +
            "'tasks/backlog/p-01-a.md','tasks/backlog/p-02-review-a.md','tasks/backlog/p-99-integration.md')")
        $r.ExitCode | Should -Be 0
        $r.Output[0] | Should -Match 'LINT OK 3 file\(s\)'
    }
    It 'returns LINT FAIL lines and exit 1 on findings' {
        New-TaskFile -Fixture $script:fx -Folder backlog -Id 'p-01-a' -DependsOn @('p-00-ghost') | Out-Null
        $r = Invoke-MusterInProc $script:fx "Invoke-LintCommand -Paths @('tasks/backlog/p-01-a.md')"
        $r.ExitCode | Should -Be 1
        ($r.Output -join "`n") | Should -Match 'LINT FAIL'
        ($r.Output -join "`n") | Should -Match 'p-00-ghost'
    }
    It 'refuses with exit 1 when no paths are given' {
        $r = Invoke-MusterInProc $script:fx 'Invoke-LintCommand -Paths @()'
        $r.ExitCode | Should -Be 1
        $r.Output[0] | Should -Be 'MUSTER refuse: lint needs at least one task file path.'
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:
```
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Pester -Path tests/fast/Lint.Fast.Tests.ps1"
```
Expected: FAIL - `Invoke-LintCommand` is not recognized.

- [ ] **Step 3: Implement `Invoke-LintCommand` and the shim**

Add to `runtime/bin/_lib.ps1` directly after `Invoke-StatusCommand`:

```powershell
function Invoke-LintCommand {
    # lint verb (spec 2.6 shard-lint + lint-lite). Returns CommandResult; never writes or exits.
    param([switch]$Lite, [string[]]$Paths)
    if (-not $Paths -or $Paths.Count -eq 0) { Write-Refuse 'lint needs at least one task file path.' }
    $findings = Test-LintChecks -RepoRoot (Get-RepoRoot) -Paths $Paths -Lite:$Lite
    if ($findings.Count -gt 0) {
        return New-CommandResult -Output @($findings | ForEach-Object { "LINT FAIL $_" }) -ExitCode 1
    }
    New-CommandResult -Output @("LINT OK $($Paths.Count) file(s)")
}
```

(Body semantics copied from current `lint.ps1:7-14`, including the direct `$findings = Test-LintChecks ...` capture - see the PS 5.1 array-return note at `runtime/bin/claim.ps1:42-43`.)

Rewrite `runtime/bin/lint.ps1` entirely (replaces the Task 2 wrapped version):

```powershell
# MUSTER lint - shard-lint (spec 2.6) and lint-lite. Not part of the RUNNER contract.
param([switch]$Lite, [Parameter(ValueFromRemainingArguments = $true)][string[]]$Paths)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_lib.ps1')

$r = Invoke-CommandBoundary { Invoke-LintCommand -Lite:$Lite -Paths $Paths }
$r.Output | Write-Output
exit $r.ExitCode
```

- [ ] **Step 4: Run the fast tests to verify they pass**

Run:
```
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Pester -Path tests/fast/Lint.Fast.Tests.ps1"
```
Expected: 3 tests PASS.

- [ ] **Step 5: Run the existing lint suites (parity gate)**

Run:
```
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Pester -Path tests/Lint.Tests.ps1, tests/LintOverlap.Tests.ps1"
```
Expected: all 27 lint tests PASS.

- [ ] **Step 6: Run the FULL suite, both engines (phase parity gate)**

Run:
```
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Pester -Path tests"
```
then:
```
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "`$env:MUSTER_ENGINE='sh'; Invoke-Pester -Path tests"
```
Expected: 136 tests green on BOTH arms (123 original + 13 fast tests; the fast tests are engine-agnostic, see Task 2 Step 6).

- [ ] **Step 7: Commit**

```bash
git add runtime/bin/_lib.ps1 runtime/bin/lint.ps1 tests/fast/Lint.Fast.Tests.ps1
git commit -m "refactor(runtime): extract Invoke-LintCommand, lint.ps1 becomes shim"
```

---

### Task 5: Prototype timing comparison (Phase 1 exit evidence)

**Files:**
- Create: `docs/runtime-consolidation/phase1-comparison-2026-08-13.md` (separate file - `Measure-Baseline.ps1` overwrites the baseline file on rerun, so the comparison must not live there)
- Modify: `docs/test-speed-consolidation-plan.md` (record Phase 0 + Phase 1 exit status)

- [ ] **Step 1: Measure in-process vs child-process for both verbs**

Run this once from repo root and capture the output. The lint target is the 3-file good batch - a lone impl file fails lint check 11, and timing a failing batch would not compare like with like:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "
. tests/MusterFixture.ps1
. tests/fast/InProcHarness.ps1
`$fx = New-MusterFixture
New-TaskFile -Fixture `$fx -Folder backlog -Id 'p-01-a' -CommitPaths @('src/out.txt') | Out-Null
New-TaskFile -Fixture `$fx -Folder backlog -Id 'p-02-review-a' -Type review -Tier strong -DependsOn @('p-01-a') -ExtraFront @('reviews: p-01-a') | Out-Null
New-TaskFile -Fixture `$fx -Folder backlog -Id 'p-99-integration' -Type integration -Tier strong -DependsOn @('p-01-a','p-02-review-a') | Out-Null
`$paths = @('tasks/backlog/p-01-a.md','tasks/backlog/p-02-review-a.md','tasks/backlog/p-99-integration.md')
`$lintExpr = \"Invoke-LintCommand -Paths @('tasks/backlog/p-01-a.md','tasks/backlog/p-02-review-a.md','tasks/backlog/p-99-integration.md')\"
[void](Invoke-MusterInProc `$fx 'Invoke-StatusCommand')   # warm-up JIT
`$inS  = (Measure-Command { 1..20 | ForEach-Object { Invoke-MusterInProc `$fx 'Invoke-StatusCommand' } }).TotalSeconds / 20
`$inL  = (Measure-Command { 1..20 | ForEach-Object { Invoke-MusterInProc `$fx `$lintExpr } }).TotalSeconds / 20
`$prS  = (Measure-Command { 1..5 | ForEach-Object { Invoke-Muster `$fx 'status' } }).TotalSeconds / 5
`$prL  = (Measure-Command { 1..5 | ForEach-Object { Invoke-MusterLint `$fx -Paths `$paths } }).TotalSeconds / 5
Remove-MusterFixture `$fx
'status  in-proc {0:N3}s  child {1:N3}s' -f `$inS, `$prS
'lint    in-proc {0:N3}s  child {1:N3}s' -f `$inL, `$prL
"
```

Expected: in-proc roughly 0.15 s per call (a review probe measured 146 ms average for status); child per call ~1.5-2 s. In-proc must be at least 5x faster than child or the Phase 1 verdict needs scrutiny.

- [ ] **Step 2: Write the comparison file**

Create `docs/runtime-consolidation/phase1-comparison-2026-08-13.md` with a `# Phase 1 prototype comparison` heading, a 2x2 table (verb x mechanism) using the measured numbers, one line naming the speedup factor, and one line noting the harness's native-stderr divergence (see the `InProcHarness.ps1` header comment) as a known in-proc limitation feeding the Phase 4 contract matrix.

- [ ] **Step 3: Record phase exits in the spec doc**

In `docs/test-speed-consolidation-plan.md`, under Phase 0 and Phase 1, add a one-line `**Result:**` note each: Phase 0 baseline committed (link the baseline file); Phase 1 measured speedup (link the comparison file) + "control flow complexity verdict: simpler / equal / worse" based on the actual diff experience. If the verdict is "worse", flag it - that is the plan's stop condition.

- [ ] **Step 4: Commit**

```bash
git add docs/runtime-consolidation/phase1-comparison-2026-08-13.md docs/test-speed-consolidation-plan.md
git commit -m "test(bench): record in-process vs child-process prototype timings"
```

---

## Verification checklist (whole plan)

- [ ] Full suite green on ps1 engine after every task's commit.
- [ ] Full suite green on sh engine after Tasks 2 and 4 (the tasks touching shared behavior).
- [ ] `git status` clean after each commit.
- [ ] Baseline doc has: micro table, per-file tables (both engines), prototype comparison.
- [ ] No sh file, review/integration-path exit (inside `Invoke-DoneFailReview` / `Invoke-DoneFailIntegration`), or NGen change anywhere in the diff.

## Not yet specified

In scope of the overall effort, deliberately too blurry to plan now (Phase 2+ of the spec):

- Fixture strategy replacement - awaits the Phase 2 benchmark (copy vs clone vs worktree vs status quo).
- Stateful vertical slice (`claim -> verify -> done` conversion) - Phase 3; depends on Phase 1 verdict.
- Contract matrix contents for the retained process tier - Phase 4.
- Conversion of the review/integration-path exits inside `Invoke-DoneFailReview` / `Invoke-DoneFailIntegration` - Phase 3 territory.
- In-proc handling of refusals that follow FAILING native commands (e.g. `Get-RepoRoot` outside a repo): under `$ErrorActionPreference='Stop'` a hosted runspace turns native stderr into a terminating error, so these cannot round-trip in-proc and must be routed to the process tier - Phase 3/4 decision.
- Byte-contract decision (spec open question 2) and PS7-orchestrated parallel CI (open question 3).

## Out of scope

- Any edit to `runtime/bin/*.sh` - parity is enforced by the unchanged black-box suite run under `MUSTER_ENGINE=sh`.
- Shell-support ADR (keep vs delete the sh mirror).
- Git hardening, checkout lock, `tasks/.muster-version` - separate change per spec Phase 5.2.
- NGen or any machine tuning - would invalidate the baseline.
- Anything C#.
