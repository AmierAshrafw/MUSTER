# Test Speed Phase 2 (Fixture Experiment) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Benchmark four fixture-creation strategies against a shared correctness contract, then adopt the winner in `New-MusterFixture` only on repeatable material gain — otherwise record "kept as-is".

**Architecture:** A shared `FixtureStrategies.ps1` defines the four candidate strategies (`init` = current, `copy`, `clone-local`, `worktree`) and an `Assert-FixtureContract` function encoding the spec's validation checklist (clean status, exact history, fixture-owned git dir, no stale locks or remotes, independent mutation, working runtime, reliable cleanup). The contract test lives in the existing `tests/Harness.Tests.ps1` (which already asserts fixture shape) as permanent coverage; a one-shot benchmark script contract-checks AND times every candidate over two independent 20-run passes — a contract failure disqualifies a candidate from adoption but it is still timed for the record. Adoption (if any) swaps `New-MusterFixture` to a template-cached variant; the unchanged black-box suite on both engines is the parity gate.

**Tech Stack:** Windows PowerShell 5.1, Pester 6.0.1 (hosted via `powershell.exe` to pin the 5.1 engine), Git.

**Spec:** `docs/test-speed-consolidation-plan.md` (rev 2), Phase 2. Baseline: `docs/runtime-consolidation/baseline-2026-08-13.md` — fixture create+destroy p50 0.783 s; ~120 fixtures/run ≈ 94 s of ps1 suite time. (The baseline's 292.2 s total is a SUM OF PER-FILE p50s across nine separate `powershell.exe` hosts over root-level `tests/*.Tests.ps1` only — never compare a single `Invoke-Pester -Path tests` wall time against it without saying so.)

**Constraints from spec:**
- Benchmark at least: current `New-MusterFixture`, recursive copy of a prepared fixture, `git clone --local`, a worktree-or-equivalent strategy.
- Validate the winner for: no stale `.git` content, clean status, independent mutation between tests, reliable cleanup, compatibility with the future checkout lock (an exclusive lock file under `.git/` — so each fixture must OWN its git dir; a worktree's git dir lives under the template and is shared).
- Adopt only on a repeatable material gain. **Decision rule (fixed before measuring):** a candidate is material only if it PASSED `Assert-FixtureContract` AND BOTH benchmark passes show p50 ≤ 0.7 × the BEST `init` pass p50 (≥30% reduction against init's best showing). Ties go to the simpler strategy (`copy` beats `clone-local` beats `worktree`).
- No behavior change observable through the existing black-box suite; both engines' suites stay green if adoption happens.

**Exit:** fixture strategy chosen from measurements, or explicitly kept as-is — recorded in the spec's Phase 2 section either way.

## Overnight execution limits (unattended run)

This plan is executed unattended. Every long-running command gets a hard cap; a breached cap means KILL the process, do NOT commit the task, write what happened into the execution report, and STOP the phase — never leave a command running open-ended (Phase 0's full-suite baseline ran ~1-2 hours; nothing in Phase 2 is allowed to).

| Command | Expected | Hard cap | On breach |
|---|---|---|---|
| `Measure-Fixture.ps1` (Task 2) | 3-5 min | 20 min | kill, no commit, stop — a benchmark this slow IS a measurement problem |
| Full ps1 suite (Task 3 Step 4) | ~5 min | 25 min | kill, no commit, stop |
| Full sh suite (Task 3 Step 5) | ~13 min | 45 min | kill, no commit, stop |
| Any single test file / any other command | <2 min | 10 min | kill, investigate once, stop on repeat |

Run anything expected to exceed the tool's foreground timeout in the background and poll against the cap with a deadline; kill on breach. Do not re-run a breached command hoping it passes — record and stop.

## Out of scope

- NGen or any machine tuning (spec: never a repository acceptance condition).
- Demoting the sh engine from the dev loop (Phase 5.1 ADR) — the sh suite stays a parity gate here.
- Phase 3 stateful slice, Phase 4 tier migration, test parallelism.
- Re-running `tests/bench/Measure-Baseline.ps1` (its output file would be overwritten; post-swap its fixture row changes meaning — Task 3 leaves a pointer comment, nothing more).

## Not yet specified

- Which strategy wins — the benchmark decides; both outcome branches are planned (Task 3 vs straight to Task 4).
- Exact post-swap suite timings — recorded in the Task 4 Result line from measurement, with the measurement method stated inline.

---

### Task 1: Fixture contract + candidate strategies (TDD)

The contract test is permanent regression coverage for whatever `New-MusterFixture` does and lives in the existing harness test file; the strategies file is shared by that test and the benchmark.

**Files:**
- Modify: `tests/Harness.Tests.ps1:1` (BeforeAll) and `tests/Harness.Tests.ps1:3-24` (add one It)
- Create: `tests/bench/FixtureStrategies.ps1`

- [ ] **Step 1: Write the failing test**

In `tests/Harness.Tests.ps1`, replace line 1:

```powershell
BeforeAll { . (Join-Path $PSScriptRoot 'MusterFixture.ps1') }
```

with:

```powershell
BeforeAll {
    . (Join-Path $PSScriptRoot 'MusterFixture.ps1')
    . (Join-Path $PSScriptRoot 'bench/FixtureStrategies.ps1')
}
```

and add inside `Describe 'fixture harness'` (after the existing two Its):

```powershell
    It 'New-MusterFixture satisfies the fixture contract' {
        $s = (Get-FixtureStrategies)['init']
        { Assert-FixtureContract -NewFixture $s.New -RemoveFixture $s.Remove -Template '' } |
            Should -Not -Throw
    }
```

- [ ] **Step 2: Run test to verify it fails**

```bash
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Pester -Path tests/Harness.Tests.ps1 -Output Detailed"
```

Expected: FAIL — `bench/FixtureStrategies.ps1` does not exist (dot-source error in BeforeAll).

- [ ] **Step 3: Write the strategies + contract file**

Create `tests/bench/FixtureStrategies.ps1`:

```powershell
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
    # 'init' ignores Template: it is the current per-test git-init path.
    [ordered]@{
        'init' = @{
            New    = { param($Template) New-MusterFixture }
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
```

- [ ] **Step 4: Run test to verify it passes**

```bash
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Pester -Path tests/Harness.Tests.ps1 -Output Detailed"
```

Expected: PASS (3 tests — the contract builds 2 fixtures and runs one child-process verb, roughly 5-8 s total).

- [ ] **Step 5: Commit**

```bash
git add tests/Harness.Tests.ps1 tests/bench/FixtureStrategies.ps1
git commit -m "test(fixture): fixture contract + candidate strategy table for phase 2"
```

---

### Task 2: Benchmark script and comparison document

**Files:**
- Create: `tests/bench/Measure-Fixture.ps1`
- Create: `docs/runtime-consolidation/fixture-comparison-2026-08-13.md` (generated output, committed)

- [ ] **Step 1: Write the benchmark script**

Create `tests/bench/Measure-Fixture.ps1`:

```powershell
# Phase 2 fixture-strategy benchmark. Contract-checks AND times every candidate
# (a contract failure disqualifies from adoption but the strategy is still timed
# for the record - the spec says benchmark all four). Two independent passes per
# strategy so the adoption decision rests on repeated evidence.
# Run from repo root, Windows PowerShell 5.1 host:
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/bench/Measure-Fixture.ps1
# Takes roughly 3-5 minutes. WARNING: overwrites its output file.
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# Fixed measurement config - vary in source if a future phase needs it.
$RunsPerPass = 20
$Passes      = 2
$OutFile     = 'docs/runtime-consolidation/fixture-comparison-2026-08-13.md'

# A leaked MUSTER_ENGINE=sh would route the contract's Invoke-Muster call to the
# sh engine; keep the doc ps1-labeled and exact.
Remove-Item Env:MUSTER_ENGINE -ErrorAction SilentlyContinue

$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. (Join-Path $repoRoot 'tests/MusterFixture.ps1')
. (Join-Path $PSScriptRoot 'FixtureStrategies.ps1')

# Intentional duplicate of Measure-Baseline.ps1's Get-Percentile: that script
# runs its whole benchmark on load, so it cannot be dot-sourced for 7 lines.
function Get-Percentile {
    param([double[]]$Samples, [double]$P)
    $s = @($Samples | Sort-Object)
    $idx = [math]::Ceiling($P * $s.Count) - 1
    if ($idx -lt 0) { $idx = 0 }
    return [math]::Round($s[$idx], 3)
}

$templateCost = (Measure-Command { $template = New-MusterFixture }).TotalSeconds
$strategies   = Get-FixtureStrategies

$rows   = @()
$failed = @()
try {
    foreach ($name in $strategies.Keys) {
        $s = $strategies[$name]
        try {
            Assert-FixtureContract -NewFixture $s.New -RemoveFixture $s.Remove -Template $template
        }
        catch {
            $failed += [pscustomobject]@{ Strategy = $name; Reason = "$_" }
        }
        foreach ($pass in 1..$Passes) {
            $samples = @()
            for ($i = 1; $i -le $RunsPerPass; $i++) {
                $samples += (Measure-Command {
                    $d = & $s.New $template
                    & $s.Remove $template $d
                }).TotalSeconds
            }
            $rows += [pscustomobject]@{
                Strategy = $name
                Pass     = $pass
                P50      = Get-Percentile -Samples $samples -P 0.50
                P95      = Get-Percentile -Samples $samples -P 0.95
                All      = ($samples | ForEach-Object { [math]::Round($_, 3) }) -join ', '
            }
        }
    }
}
finally {
    Remove-MusterFixture $template
}

# The timing loop above appends rows unconditionally for every strategy, so the
# init rows always exist here (contract failures land in $failed, not a throw).
$initBest = ($rows | Where-Object { $_.Strategy -eq 'init' } |
    Measure-Object -Property P50 -Minimum).Minimum

# Decision rule fixed in the plan: material = contract passed AND both passes
# p50 <= 0.7 * best init p50.
$verdicts = @()
foreach ($name in ($strategies.Keys | Where-Object { $_ -ne 'init' })) {
    $fail  = $failed | Where-Object { $_.Strategy -eq $name }
    $mine  = @($rows | Where-Object { $_.Strategy -eq $name })
    $worst = ($mine | Measure-Object -Property P50 -Maximum).Maximum
    $ratio = [math]::Round($worst / $initBest, 2)
    if ($fail) {
        $verdicts += "- **${name}:** DISQUALIFIED (contract: $($fail.Reason)). Timed for the record: worst-pass p50 $worst s (${ratio}x init best)."
    }
    elseif ($worst -le 0.7 * $initBest) {
        $verdicts += "- **${name}:** MATERIAL - worst-pass p50 $worst s = ${ratio}x of init best p50 $initBest s (<= 0.70 required)."
    }
    else {
        $verdicts += "- **${name}:** not material - worst-pass p50 $worst s = ${ratio}x of init best p50 $initBest s (<= 0.70 required)."
    }
}

$L = @()
$L += '# Phase 2 fixture-strategy comparison'
$L += ''
$L += "Machine: $env:COMPUTERNAME, Windows PowerShell $($PSVersionTable.PSVersion). No NGen or machine tuning."
$L += "Measured $(Get-Date -Format 'yyyy-MM-dd') with tests/bench/Measure-Fixture.ps1, BEFORE any New-MusterFixture change (the init rows are the current per-test git-init path)."
$L += "Config: $Passes independent passes x $RunsPerPass create+destroy cycles per strategy."
$L += "One-time template build (New-MusterFixture): $([math]::Round($templateCost, 3)) s - under a template-based strategy this is paid once per Pester test file (each file dot-sources its own MusterFixture.ps1 scope), i.e. ~12x per full suite run."
$L += 'Every strategy was checked against Assert-FixtureContract (tests/bench/FixtureStrategies.ps1); failures disqualify from adoption but are still timed below.'
$L += ''
$L += '## Create+destroy timings (seconds)'
$L += ''
$L += '| Strategy | Pass | p50 | p95 | All samples |'
$L += '|---|---:|---:|---:|---|'
foreach ($r in $rows) {
    $L += "| $($r.Strategy) | $($r.Pass) | $($r.P50) | $($r.P95) | $($r.All) |"
}
$L += ''
$L += '## Verdicts (rule fixed before measurement)'
$L += ''
$L += "Material = contract passed AND both passes p50 <= 0.7x the best init pass p50 ($initBest s). Ties go to the simpler strategy: copy > clone-local > worktree."
$L += ''
$L += $verdicts
$L += ''

$enc = New-Object System.Text.UTF8Encoding $false
[IO.File]::WriteAllText((Join-Path $repoRoot $OutFile), (($L -join "`n") + "`n"), $enc)
Write-Host "Wrote $OutFile"
```

- [ ] **Step 2: Run the benchmark**

```bash
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/bench/Measure-Fixture.ps1
```

Expected: `Wrote docs/runtime-consolidation/fixture-comparison-2026-08-13.md`, roughly 3-5 minutes. A DISQUALIFIED verdict for `worktree` is EXPECTED (its git dir lives under the template — the contract's own-git-dir check catches this by design). `init` must not be disqualified.

- [ ] **Step 3: Sanity-check the output document**

Read `docs/runtime-consolidation/fixture-comparison-2026-08-13.md`. Check: 2 passes per strategy; `init` p50 near the baseline 0.78 s (large deviation means a measurement problem — investigate before proceeding); verdict lines consistent with the table.

- [ ] **Step 4: Commit**

```bash
git add tests/bench/Measure-Fixture.ps1 docs/runtime-consolidation/fixture-comparison-2026-08-13.md
git commit -m "test(bench): fixture strategy benchmark + 2026-08-13 comparison"
```

---

### Task 3: Decision gate — adopt the winner, or stop

Read the verdicts in `docs/runtime-consolidation/fixture-comparison-2026-08-13.md`.

**If NO candidate is MATERIAL:** skip to Task 4 and record "kept as-is". Do not adopt a marginal winner — the spec's early samples already showed copy (0.30-0.65 s) is not reliably faster than init (0.50-0.56 s); that outcome is expected and fine.

**If a candidate is MATERIAL:** adopt the highest-ranked material one (tie order: copy, clone-local; worktree cannot be material — the contract disqualifies it, and `Remove-MusterFixture` calls throughout the suite would leave stale worktree metadata in the template anyway).

**Files:**
- Modify: `tests/MusterFixture.ps1:8-31` (the `New-MusterFixture` function)
- Modify: `tests/bench/Measure-Baseline.ps1:53` (pointer comment only)

- [ ] **Step 1: Swap `New-MusterFixture` to the template-cached winner**

Rename the current function body to `New-MusterFixtureFromScratch` and make `New-MusterFixture` the winner. For **copy**:

```powershell
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
```

For **clone-local**, the `New-MusterFixture` body instead ends with:

```powershell
    $dir = Join-Path ([IO.Path]::GetTempPath()) ('muster-fix-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    git -c core.autocrlf=false clone -q --local $script:FixtureTemplate $dir
    git -C $dir config user.email 'test@muster.local'
    git -C $dir config user.name 'muster-test'
    git -C $dir remote remove origin
    return $dir
```

- [ ] **Step 2: Leave a pointer comment in the baseline script**

In `tests/bench/Measure-Baseline.ps1`, directly above the `fixture create+destroy (New-MusterFixture)` measurement (around line 53), add:

```powershell
# Post-Phase-2 note: New-MusterFixture is now template-cached. On a rerun of this
# script, sample 1 of this row includes the one-time template build and later
# samples measure the per-fixture copy only - the row no longer means what the
# committed baseline-2026-08-13.md row meant. See fixture-comparison-2026-08-13.md.
```

Do not change the baseline document itself.

- [ ] **Step 3: Run the fixture contract and fast tests**

```bash
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Pester -Path tests/Harness.Tests.ps1, tests/fast -Output Detailed"
```

Expected: PASS (contract test now exercises the template-cached path; 13 fast tests unaffected).

- [ ] **Step 4: Run the full ps1 suite (parity gate)**

```bash
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Remove-Item Env:MUSTER_ENGINE -ErrorAction SilentlyContinue; Invoke-Pester -Path tests -Output Detailed"
```

Expected: all green. Record the single-run wall time for Task 4 — but label it as such; it is NOT comparable to the baseline's 292.2 s (that number is a sum of per-file p50s across nine separate hosts over root-level files only, and `-Path tests` additionally discovers `tests/fast/`). Run with a 600000 ms timeout or in the background.

- [ ] **Step 5: Run the full sh suite (parity gate, both engines per spec)**

```bash
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command '$env:MUSTER_ENGINE="sh"; Invoke-Pester -Path tests -Output Detailed'
```

(Single-quoted payload — literal in both bash and PowerShell parents; an unquoted `$env:` gets expanded away by the parent shell and the suite silently reruns the ps1 engine.)

Expected: all green. Roughly 13 minutes — run in the background and wait for completion. The sh suite uses the same `New-MusterFixture`, so it exercises the new path too.

- [ ] **Step 6: Commit (only after BOTH suites are green)**

```bash
git add tests/MusterFixture.ps1 tests/bench/Measure-Baseline.ps1
git commit -m "perf(tests): template-cached fixture creation, adopted on phase 2 measurements"
```

---

### Task 4: Record the Phase 2 result in the spec

**Files:**
- Modify: `docs/test-speed-consolidation-plan.md` (Phase 2 section, after the "Exit:" line, mirroring the Phase 0/1 **Result:** entries)

- [ ] **Step 1: Append the result line**

Immediately after the line `Exit: fixture strategy chosen from measurements, or explicitly kept as-is.` add ONE of:

If adopted (fill in the measured numbers):

```markdown
**Result:** Adopted `<strategy>` via a lazily built template (rebuilt per Pester test file, ~12x per full run) - see [`runtime-consolidation/fixture-comparison-2026-08-13.md`](runtime-consolidation/fixture-comparison-2026-08-13.md). Per-fixture create+destroy p50 `<candidate p50>` s vs init `<init p50>` s (`<ratio>`), material under the pre-fixed 30% rule in both passes. Contract validated (permanent coverage in `tests/Harness.Tests.ps1`); full black-box suite green on both engines post-swap. Single-run `Invoke-Pester -Path tests` wall time post-swap: `<total>` s (not comparable to the 292.2 s baseline, which sums per-file p50s across separate hosts).
```

If kept as-is:

```markdown
**Result:** Kept `git init` as-is - see [`runtime-consolidation/fixture-comparison-2026-08-13.md`](runtime-consolidation/fixture-comparison-2026-08-13.md). No candidate met the pre-fixed material rule (contract passed AND both passes p50 <= 0.7x init best p50). Contract tests retained as permanent fixture coverage in `tests/Harness.Tests.ps1`; fixture cost stays ~0.78 s x ~120 fixtures, which feeds the Phase 4 gate arithmetic.
```

- [ ] **Step 2: Commit**

```bash
git add docs/test-speed-consolidation-plan.md
git commit -m "docs: record phase 2 fixture-experiment outcome"
```
