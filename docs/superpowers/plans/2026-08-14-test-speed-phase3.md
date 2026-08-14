# Test Speed Phase 3 — Stateful Vertical Slice Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Convert the stateful `claim` / `verify` / `done` verbs into in-process `Invoke-XCommand` functions in `runtime/bin/_lib.ps1` returning a `CommandResult`, proven in fresh 5.1 runspaces, while the unchanged black-box suite stays green on both engines as the parity backstop.

**Architecture:** Same in-process pattern Phase 1 proved on `status`/`lint` — the verb body moves into `Invoke-XCommand`; the `.ps1` becomes a shim `$r = Invoke-CommandBoundary { Invoke-XCommand … }; $r.Output | Write-Output; exit $r.ExitCode`. Two deviations forced by the design: (1) `done`'s self-exiting fail branches convert to *return* a CommandResult; (2) `claim` prints the status block before any refusal (D12), which the throw-based boundary would discard, so `Invoke-ClaimCommand` accumulates output and *returns* refusal results directly. A throwaway spike measures the native-stderr runspace divergence before any production code.

**Tech Stack:** Windows PowerShell 5.1, Pester 6.0.1 (hosted via `powershell.exe` to pin the 5.1 engine), Git.

**Spec:** `docs/superpowers/specs/2026-08-14-test-speed-phase3-design.md` (approved 2026-08-14). Parent: `docs/test-speed-consolidation-plan.md` Phase 3. Divergence background: `docs/runtime-consolidation/phase1-comparison-2026-08-13.md`.

**Constraints:**
- No behavior change observable through the black-box suite. Both engines' suites (`Claim.Tests.ps1` 17, `Done.Tests.ps1` 22, `Verify.Tests.ps1` 7) stay green, unchanged. No `runtime/bin/*.sh` edit.
- Fresh runspace per fast test. Fast tests assert on **both** the returned CommandResult and the resulting board state.
- Three native-stderr paths stay process-tier only (NOT mirrored in the fast tier): corrupted-state failing-git refusals (`Read-CommittedTask` on an uncommitted task, D20), the `eol=lf`+CRLF completion (`Done.Tests.ps1:134`), and `Invoke-Promote`'s `Write-Host` warnings.
- Stop condition: if the spike shows a **success / non-native-stderr** target-edge path tripping the divergence, or any verb's extraction verdict is "worse" — halt and report (feeds the deferred C# decision).

---

### Task 0: Divergence spike (throwaway measurement gate)

Runs BEFORE any extraction. Confirms the real native-stderr boundary using the **existing** helpers (`Complete-Task`, `Invoke-DoneFailReview`, `Read-CommittedTask`) inside a fresh runspace, so the later extraction proceeds on measured evidence, not reasoning.

**Files:**
- Create: `tests/bench/Probe-Phase3Divergence.ps1`
- Create: `docs/runtime-consolidation/phase3-spike-2026-08-14.md` (committed evidence)

- [ ] **Step 1: Write the probe script**

Create `tests/bench/Probe-Phase3Divergence.ps1`:

```powershell
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
```

- [ ] **Step 2: Run the probe**

Run:
```
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/bench/Probe-Phase3Divergence.ps1
```
Expected: Case 1 and Case 2 print `PASS (expected PASS)`; Case 3 and Case 4 print `THROW (expected THROW)`.

- [ ] **Step 3: GATE — evaluate the result**

- All four match their expectation → the boundary is exactly as the design maps it. Proceed to Task 1.
- **Case 1 or Case 2 prints `THROW`** (a success / non-native-stderr path trips the divergence): **HALT.** Record it and stop — this is the spec's halt-and-report condition feeding the C# decision. Do not start Task 1.
- Case 3 or Case 4 prints `PASS` (a carve-out did NOT throw): the divergence is narrower than assumed — note it; the carve-out may be safe to bring in-process later, but that is out of this plan's scope. Proceed to Task 1.

- [ ] **Step 4: Record the evidence**

Create `docs/runtime-consolidation/phase3-spike-2026-08-14.md`: a `# Phase 3 divergence spike` heading, the machine line (`$env:COMPUTERNAME`, `$PSVersionTable.PSVersion`), the four probe result lines verbatim, and a one-paragraph reading — which paths round-trip in-process, which are the confirmed process-tier carve-outs, and the gate verdict (proceed / halt).

- [ ] **Step 5: Commit**

```bash
git add tests/bench/Probe-Phase3Divergence.ps1 docs/runtime-consolidation/phase3-spike-2026-08-14.md
git commit -m "test(bench): phase 3 runspace-divergence spike + 2026-08-14 result"
```

---

### Task 1: Extract `Invoke-DoneCommand`, convert the self-exiting fail branches, shim `done.ps1`

**Files:**
- Create: `tests/fast/Done.Fast.Tests.ps1`
- Modify: `runtime/bin/_lib.ps1` — add `Invoke-DoneCommand` after `Invoke-LintCommand`; edit the tails of `Invoke-DoneFailReview` and `Invoke-DoneFailIntegration`
- Modify: `runtime/bin/done.ps1` (full rewrite to shim)

- [ ] **Step 1: Write the failing fast tests**

Create `tests/fast/Done.Fast.Tests.ps1`. Setup helpers are copied verbatim from `tests/Done.Tests.ps1` (the setup uses the real child `claim` — that is fine, only the verb under test runs in-process):

```powershell
BeforeAll {
    . (Join-Path $PSScriptRoot '../MusterFixture.ps1')
    . (Join-Path $PSScriptRoot 'InProcHarness.ps1')
}

Describe 'Invoke-DoneCommand (in-process) - impl + preconditions' {
    BeforeEach { $script:fx = New-MusterFixture }
    AfterEach { Remove-MusterFixture $script:fx }

    BeforeAll {
        function Add-ClaimedImpl {
            New-TaskFile -Fixture $script:fx -Folder inbox -Id 'p-01-a' -CommitPaths @('src/out.txt') `
                -VerifyCmd 'git --version' -Commit | Out-Null
            Invoke-MusterClaim $script:fx | Out-Null
            New-Item -ItemType Directory (Join-Path $script:fx 'src') -Force | Out-Null
            [IO.File]::WriteAllText((Join-Path $script:fx 'src/out.txt'), 'payload')
        }
    }

    It 'refuses when doing/ is empty' {
        $r = Invoke-MusterInProc $script:fx 'Invoke-DoneCommand'
        $r.ExitCode | Should -Be 1
        $r.Output[0] | Should -Match '^MUSTER refuse: doing/ is empty'
    }
    It 'refuses a verdict on impl tasks' {
        Add-ClaimedImpl
        $r = Invoke-MusterInProc $script:fx "Invoke-DoneCommand -Verdict pass"
        $r.ExitCode | Should -Be 1
        ($r.Output -join "`n") | Should -Match 'no verdict on impl/fix'
    }
    It 'completes an impl task: files in done/, single commit, session-over line' {
        Add-ClaimedImpl
        $r = Invoke-MusterInProc $script:fx 'Invoke-DoneCommand'
        $r.ExitCode | Should -Be 0
        $r.Output[-1] | Should -Match 'Done: p-01-a\. Promoted: none\. Do not claim another task\. Session over\.'
        Test-Path (Join-Path $script:fx 'tasks/done/p-01-a.md') | Should -BeTrue
        Test-Path (Join-Path $script:fx 'tasks/done/p-01-a.result.md') | Should -BeTrue
        (Get-FixtureCommits $script:fx)[0] | Should -Be 'muster(p): done p-01-a'
        (git -C $script:fx status --porcelain) | Should -BeNullOrEmpty
    }
    It 'refuses when the done-check verify fails' {
        New-TaskFile -Fixture $script:fx -Folder inbox -Id 'p-01-a' -CommitPaths @('src/out.txt') `
            -VerifyCmd 'git frobnicate' -Commit | Out-Null
        Invoke-MusterClaim $script:fx | Out-Null
        $r = Invoke-MusterInProc $script:fx 'Invoke-DoneCommand'
        $r.ExitCode | Should -Be 1
        ($r.Output -join "`n") | Should -Match 'MUSTER refuse: done-check verify failed'
        Test-Path (Join-Path $script:fx 'tasks/doing/p-01-a.md') | Should -BeTrue
    }
    It 'refuses when a protected file was modified' {
        Add-ClaimedImpl
        [IO.File]::WriteAllText((Join-Path $script:fx 'README.md'), 'tampered')
        $r = Invoke-MusterInProc $script:fx 'Invoke-DoneCommand'
        $r.ExitCode | Should -Be 1
        ($r.Output -join "`n") | Should -Match 'MUSTER refuse: protected file\(s\) modified: README\.md\.'
    }
}

Describe 'Invoke-DoneCommand (in-process) - review + integration' {
    BeforeEach { $script:fx = New-MusterFixture }
    AfterEach { Remove-MusterFixture $script:fx }

    BeforeAll {
        function Add-ClaimedReview {
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
        function Add-ClaimedIntegration {
            New-TaskFile -Fixture $script:fx -Folder inbox -Id 'p-99-integration' -Type integration -Tier strong -Commit | Out-Null
            Invoke-MusterClaim $script:fx -Tier strong | Out-Null
            [IO.File]::WriteAllText((Join-Path $script:fx 'tasks/doing/p-99-integration.notes.md'), 'drift: a vs b')
        }
    }

    It 'review pass requires notes and folds them' {
        Add-ClaimedReview
        $r = Invoke-MusterInProc $script:fx "Invoke-DoneCommand -Verdict pass"
        $r.ExitCode | Should -Be 0
        (Get-Content (Join-Path $script:fx 'tasks/done/p-02-review-a.result.md') -Raw) |
            Should -Match '(?s)- verdict: pass.*## Findings.*bad naming'
    }
    It 'accepts a valid fix: stamps gen 1, queues it, cycles the review task (exit 0)' {
        Add-ClaimedReview
        Add-StagedFix
        $r = Invoke-MusterInProc $script:fx "Invoke-DoneCommand -Verdict fail"
        $r.ExitCode | Should -Be 0
        $r.Output[-1] | Should -Match 'Review failed\. Fix p-01-fix1-naming queued \(generation 1 of 2\)\. Session over\.'
        Test-Path (Join-Path $script:fx 'tasks/inbox/p-01-fix1-naming.md') | Should -BeTrue
        (Get-Content (Join-Path $script:fx 'tasks/backlog/p-02-review-a.md') -Raw) | Should -Match '(?m)^  - p-01-fix1-naming$'
        (Get-FixtureCommits $script:fx)[0] | Should -Be 'muster(p): reject p-01-a gen1'
    }
    It 'refuses to spawn generation 3: review task fails terminally (exit 3)' {
        New-TaskFile -Fixture $script:fx -Folder done -Id 'p-01-fix1-naming' -Type fix `
            -ExtraFront @('fixes: p-01-a', 'generation: 1') -Commit | Out-Null
        New-TaskFile -Fixture $script:fx -Folder done -Id 'p-01-fix2-naming' -Type fix `
            -ExtraFront @('fixes: p-01-a', 'generation: 2') -Commit | Out-Null
        Add-ClaimedReview
        Add-StagedFix -Slug 'third'
        $r = Invoke-MusterInProc $script:fx "Invoke-DoneCommand -Verdict fail"
        $r.ExitCode | Should -Be 3
        $r.Output[-1] | Should -Match 'Review cap hit \(2 fix generations\)\. p-01-a chain needs a human\. Session over\.'
        Test-Path (Join-Path $script:fx 'tasks/failed/p-02-review-a.md') | Should -BeTrue
        (Get-FixtureCommits $script:fx)[0] | Should -Be 'muster(p): fail p-02-review-a'
    }
    It 'review fail with a red done-check still cycles the fix (D29/M4, exit 0)' {
        New-TaskFile -Fixture $script:fx -Folder done -Id 'p-01-a' -Commit | Out-Null
        New-TaskFile -Fixture $script:fx -Folder inbox -Id 'p-02-review-a' -Type review -Tier strong `
            -DependsOn @('p-01-a') -ExtraFront @('reviews: p-01-a') -VerifyCmd 'git frobnicate' -Commit | Out-Null
        Invoke-MusterClaim $script:fx -Tier strong | Out-Null
        [IO.File]::WriteAllText((Join-Path $script:fx 'tasks/doing/p-02-review-a.notes.md'), 'build broke under review')
        Add-StagedFix
        $r = Invoke-MusterInProc $script:fx "Invoke-DoneCommand -Verdict fail"
        $r.ExitCode | Should -Be 0
        (Get-Content (Join-Path $script:fx 'tasks/backlog/p-02-review-a.gen1.result.md') -Raw) |
            Should -Match '- verify: FAIL \(done-check red - see verify\.log\)'
    }
    It 'files the integration task to failed/ with findings and exits 3' {
        Add-ClaimedIntegration
        $r = Invoke-MusterInProc $script:fx "Invoke-DoneCommand -Verdict fail"
        $r.ExitCode | Should -Be 3
        $r.Output[-1] | Should -Match 'Integration review failed\. Bring tasks/failed/p-99-integration\.result\.md'
        Test-Path (Join-Path $script:fx 'tasks/failed/p-99-integration.result.md') | Should -BeTrue
        (Get-FixtureCommits $script:fx)[0] | Should -Be 'muster(p): fail p-99-integration'
    }
}
```

- [ ] **Step 2: Run the fast tests to verify they fail**

Run:
```
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Pester -Path tests/fast/Done.Fast.Tests.ps1"
```
Expected: FAIL — `Invoke-DoneCommand` is not recognized (thrown out of the runspace by the harness).

- [ ] **Step 3: Add `Invoke-DoneCommand` to `_lib.ps1`**

Insert directly after the closing brace of `Invoke-LintCommand` (currently ends near `runtime/bin/_lib.ps1:766`):

```powershell
function Invoke-DoneCommand {
    # done verb (spec 4.3). Returns CommandResult; never writes or exits. done emits
    # nothing before any refusal, so Write-Refuse throws round-trip cleanly through the
    # boundary; the two fail branches RETURN their CommandResult (see below).
    param([string]$Verdict = '')
    $root = Get-RepoRoot
    $tasks = Get-TasksRoot
    $file = Get-SoleOccupant $tasks
    $task = Read-CommittedTask -RepoRoot $root -Name $file.Name
    if ($task.Errors.Count -gt 0) { Write-Refuse "$($task.Id) frontmatter invalid: $($task.Errors[0])." }
    $id = $task.Id
    $type = $task.Fields['type']

    $isJudgment = ($type -eq 'review' -or $type -eq 'integration')
    if (-not $isJudgment -and $Verdict) { Write-Refuse 'done takes no verdict on impl/fix tasks.' }
    if ($isJudgment -and @('pass', 'fail') -notcontains $Verdict) {
        Write-Refuse 'done needs a pass or fail verdict on review/integration tasks.'
    }

    $claimCommit = Get-ClaimCommit -RepoRoot $root -Name $file.Name

    $log = Join-Path $tasks "doing/$id.verify.log"
    $check = Invoke-VerifyBlock -Entries $task.Fields['verify'] -LogPath $log -Label 'done-check' -TaskId $id -RepoRoot $root
    if (-not $check.Pass -and -not ($isJudgment -and $Verdict -eq 'fail')) {
        Write-Refuse "done-check verify failed: $($check.FirstFail). Run the verify script, fix, and retry."
    }

    $pre = Test-DonePreconditions -RepoRoot $root -Fields $task.Fields -ClaimCommit $claimCommit
    if ($pre) { Write-Refuse $pre }

    if ($isJudgment -and -not (Test-Path (Join-Path $tasks "doing/$id.notes.md"))) {
        Write-Refuse "verdict needs tasks/doing/$id.notes.md with findings."
    }

    if ($Verdict -eq 'fail') {
        if ($type -eq 'review') {
            return Invoke-DoneFailReview -RepoRoot $root -TasksRoot $tasks -Fields $task.Fields -Id $id `
                -ClaimCommit $claimCommit -DoneCheckPass $check.Pass
        }
        return Invoke-DoneFailIntegration -RepoRoot $root -TasksRoot $tasks -Fields $task.Fields -Id $id `
            -ClaimCommit $claimCommit -DoneCheckPass $check.Pass
    }

    $promoted = Complete-Task -RepoRoot $root -TasksRoot $tasks -Fields $task.Fields -Id $id `
        -ClaimCommit $claimCommit -Verdict $Verdict
    $plist = 'none'
    if ($promoted.Count -gt 0) { $plist = ($promoted -join ', ') }
    return New-CommandResult -Output @(
        (Get-BoardLine -TasksRoot $tasks),
        "Done: $id. Promoted: $plist. Do not claim another task. Session over."
    ) -ExitCode 0
}
```

- [ ] **Step 4: Convert `Invoke-DoneFailReview`'s two terminal paths to `return`**

> **Locate by the quoted before-block, not the cited line numbers.** Step 3 inserted `Invoke-DoneCommand` (~52 lines) higher in the file, so every line number cited in Steps 4-5 (`_lib.ps1:1049-1054`, `1089-1091`, `1104-1106`, `1023`, `1004`) now points ~52 lines too low. The exact before/after code blocks below are the real anchors — search for the before-text.

In `Invoke-DoneFailReview`, change the comment line `# Spec 4.3 done-fail for review tasks. Exits itself on every path.` to `# Spec 4.3 done-fail for review tasks. Returns a CommandResult on every path.`

Also fix `Move-ToFailedWithResult`'s now-stale header comment (currently `runtime/bin/_lib.ps1:1004`): change `# task + sidecars -> failed/, one commit. Caller prints and exits 3.` to `# task + sidecars -> failed/, one commit. Caller returns a CommandResult (-ExitCode 3).` — both fail branches call it and no longer exit.

Replace the review-cap block (currently `runtime/bin/_lib.ps1:1049-1054`):

```powershell
    if ($g -ge 3) {
        Remove-Item $staged[0].FullName
        Move-ToFailedWithResult -RepoRoot $RepoRoot -TasksRoot $TasksRoot -Fields $Fields -Id $Id -ClaimCommit $ClaimCommit -DoneCheckPass $DoneCheckPass
        Write-Output "Review cap hit (2 fix generations). $implId chain needs a human. Session over."
        exit 3
    }
```

with:

```powershell
    if ($g -ge 3) {
        Remove-Item $staged[0].FullName
        Move-ToFailedWithResult -RepoRoot $RepoRoot -TasksRoot $TasksRoot -Fields $Fields -Id $Id -ClaimCommit $ClaimCommit -DoneCheckPass $DoneCheckPass
        return New-CommandResult -Output @("Review cap hit (2 fix generations). $implId chain needs a human. Session over.") -ExitCode 3
    }
```

Replace the cycle tail (currently `runtime/bin/_lib.ps1:1089-1091`):

```powershell
    git -c core.autocrlf=false -C $RepoRoot commit -q -m "muster($plan): reject $implId gen$g" -- @paths 2>$null
    Write-Output "Review failed. Fix $fixId queued (generation $g of 2). Session over."
    exit 0
```

with:

```powershell
    git -c core.autocrlf=false -C $RepoRoot commit -q -m "muster($plan): reject $implId gen$g" -- @paths 2>$null
    return New-CommandResult -Output @("Review failed. Fix $fixId queued (generation $g of 2). Session over.") -ExitCode 0
```

- [ ] **Step 5: Convert `Invoke-DoneFailIntegration`'s terminal path to `return`**

In `Invoke-DoneFailIntegration`, replace the tail (currently `runtime/bin/_lib.ps1:1104-1106`):

```powershell
    Move-ToFailedWithResult -RepoRoot $RepoRoot -TasksRoot $TasksRoot -Fields $Fields -Id $Id -ClaimCommit $ClaimCommit -DoneCheckPass $DoneCheckPass
    Write-Output "Integration review failed. Bring tasks/failed/$Id.result.md to the orchestrator to shard a fix-up plan. Session over."
    exit 3
```

with:

```powershell
    Move-ToFailedWithResult -RepoRoot $RepoRoot -TasksRoot $TasksRoot -Fields $Fields -Id $Id -ClaimCommit $ClaimCommit -DoneCheckPass $DoneCheckPass
    return New-CommandResult -Output @("Integration review failed. Bring tasks/failed/$Id.result.md to the orchestrator to shard a fix-up plan. Session over.") -ExitCode 3
```

The `Write-Refuse` paths inside both functions are unchanged — they throw and are caught at the boundary.

- [ ] **Step 6: Rewrite `done.ps1` as the shim**

Replace the entire contents of `runtime/bin/done.ps1` (the `exit 3   # unreachable` guard is deleted, not carried):

```powershell
# MUSTER done - spec 4.3. Thin wrapper; logic in _lib.ps1.
param([string]$Verdict = '')
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_lib.ps1')

$r = Invoke-CommandBoundary { Invoke-DoneCommand -Verdict $Verdict }
$r.Output | Write-Output
exit $r.ExitCode
```

- [ ] **Step 7: Run the fast tests to verify they pass**

Run:
```
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Pester -Path tests/fast/Done.Fast.Tests.ps1"
```
Expected: all fast tests PASS.

- [ ] **Step 8: Parity gate — run the black-box `done` suite on BOTH engines**

Run:
```
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Pester -Path tests/Done.Tests.ps1"
```
then:
```
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "`$env:MUSTER_ENGINE='sh'; Invoke-Pester -Path tests/Done.Tests.ps1"
```
Expected: 22 tests PASS on both arms. Any exit-code or message diff = STOP and investigate before committing.

- [ ] **Step 9: Verdict check (Phase 1 exit-style)**

Judge the diff: did extracting `done` and converting its fail branches make control flow *simpler / equal / worse*? Converting three `Write-Output; exit` tails to `return New-CommandResult` and deleting the unreachable guard is a mechanical simplification — expected verdict **simpler / equal**. If **worse** (the boundary made a path more tangled or fragile), HALT and report — that is the spec's stop condition. Note the verdict for Task 4.

- [ ] **Step 10: Commit**

```bash
git add runtime/bin/_lib.ps1 runtime/bin/done.ps1 tests/fast/Done.Fast.Tests.ps1
git commit -m "refactor(runtime): extract Invoke-DoneCommand, done.ps1 becomes shim"
```

---

### Task 2: Extract `Invoke-ClaimCommand` (accumulate-and-return), shim `claim.ps1`

**Files:**
- Create: `tests/fast/Claim.Fast.Tests.ps1`
- Modify: `runtime/bin/_lib.ps1` (add `Invoke-ClaimCommand` after `Invoke-DoneCommand`)
- Modify: `runtime/bin/claim.ps1` (full rewrite to shim)

- [ ] **Step 1: Write the failing fast tests**

Create `tests/fast/Claim.Fast.Tests.ps1`:

```powershell
BeforeAll {
    . (Join-Path $PSScriptRoot '../MusterFixture.ps1')
    . (Join-Path $PSScriptRoot 'InProcHarness.ps1')
}

Describe 'Invoke-ClaimCommand (in-process)' {
    BeforeEach { $script:fx = New-MusterFixture }
    AfterEach { Remove-MusterFixture $script:fx }

    It 'prints the empty-board line then refuses nothing-to-claim (accumulate + return)' {
        $r = Invoke-MusterInProc $script:fx "Invoke-ClaimCommand -Harness claude -Tier any"
        $r.ExitCode | Should -Be 1
        ($r.Output -join "`n") | Should -Match 'MUSTER: board empty - nothing sharded or all archived\.'
        ($r.Output -join "`n") | Should -Match 'MUSTER refuse: nothing to claim for claude/any\.'
    }
    It 'prints the status block before an occupied refusal (D12)' {
        New-TaskFile -Fixture $script:fx -Folder doing -Id 'p-01-a' `
            -ExtraFront @('claimed_at: 2026-08-01T00:00:00Z') -Commit | Out-Null
        $r = Invoke-MusterInProc $script:fx "Invoke-ClaimCommand -Harness claude -Tier any"
        $r.ExitCode | Should -Be 1
        $r.Output[0] | Should -Match '^MUSTER status @'
        ($r.Output -join "`n") | Should -Match 'MUSTER refuse: doing/ occupied by p-01-a'
    }
    It 'claims the lowest eligible filename, stamps claimed_at, commits (exit 0)' {
        New-TaskFile -Fixture $script:fx -Folder inbox -Id 'p-02-b' -Commit | Out-Null
        New-TaskFile -Fixture $script:fx -Folder inbox -Id 'p-01-a' -Commit | Out-Null
        $r = Invoke-MusterInProc $script:fx "Invoke-ClaimCommand -Harness claude -Tier any"
        $r.ExitCode | Should -Be 0
        $r.Output[-1] | Should -Be 'Claimed p-01-a. Follow tasks/RUNNER.md.'
        (Get-Content (Join-Path $script:fx 'tasks/doing/p-01-a.md') -Raw) | Should -Match '(?m)^claimed_at: \d{4}-\d{2}-\d{2}T'
        (Get-FixtureCommits $script:fx)[0] | Should -Be 'muster(p): claim p-01-a'
        (git -C $script:fx status --porcelain) | Should -BeNullOrEmpty
    }
    It 'enforces tier pinning both directions' {
        New-TaskFile -Fixture $script:fx -Folder inbox -Id 'p-01-a' -Tier strong -Type review `
            -ExtraFront @('reviews: p-00-x') -Commit | Out-Null
        $rAny = Invoke-MusterInProc $script:fx "Invoke-ClaimCommand -Harness claude -Tier any"
        $rAny.ExitCode | Should -Be 1
        ($rAny.Output -join "`n") | Should -Match 'MUSTER refuse: nothing to claim for claude/any\.'
        New-TaskFile -Fixture $script:fx -Folder inbox -Id 'p-02-b' -Commit | Out-Null
        $rStrong = Invoke-MusterInProc $script:fx "Invoke-ClaimCommand -Harness claude -Tier strong"
        ($rStrong.Output -join "`n") | Should -Match 'Claimed p-01-a'
    }
    It 'refuses loudly on malformed frontmatter, task stays in inbox' {
        $bad = Join-Path $script:fx 'tasks/inbox/p-01-bad.md'
        [IO.File]::WriteAllText($bad, "---`nid: p-01-bad`n---`nbody")
        git -c core.autocrlf=false -C $script:fx add 'tasks/inbox/p-01-bad.md'
        git -C $script:fx commit -qm 'fixture: bad task'
        $r = Invoke-MusterInProc $script:fx "Invoke-ClaimCommand -Harness claude -Tier any"
        $r.ExitCode | Should -Be 1
        ($r.Output -join "`n") | Should -Match 'MUSTER refuse: p-01-bad frontmatter invalid: .+\. Task left in inbox/ for a human\.'
        Test-Path $bad | Should -BeTrue
    }
    It 'refuses when the tree is dirty outside the selected task scope' {
        New-TaskFile -Fixture $script:fx -Folder inbox -Id 'p-01-a' -CommitPaths @('src/out.txt') -Commit | Out-Null
        [IO.File]::WriteAllText((Join-Path $script:fx 'stray.txt'), 'x')
        $r = Invoke-MusterInProc $script:fx "Invoke-ClaimCommand -Harness claude -Tier any"
        $r.ExitCode | Should -Be 1
        ($r.Output -join "`n") | Should -Match "MUSTER refuse: working tree dirty outside p-01-a's commit_paths: stray\.txt\."
    }
}

Describe 'Invoke-ClaimCommand (in-process) - recovery probe (D12)' {
    BeforeEach { $script:fx = New-MusterFixture }
    AfterEach { Remove-MusterFixture $script:fx }

    BeforeAll {
        function Add-RecoveredTask {
            New-TaskFile -Fixture $script:fx -Folder inbox -Id 'p-01-a' -CommitPaths @('src/out.txt') `
                -VerifyCmd 'powershell -NoProfile -Command Test-Path src/out.txt' -ExpectExit '0' -Commit | Out-Null
            $p = Join-Path $script:fx 'tasks/inbox/p-01-a.md'
            $t = [IO.File]::ReadAllText($p) -replace '    expect_exit: 0', "    expect_contains: ""True"""
            [IO.File]::WriteAllText($p, $t)
            git -c core.autocrlf=false -C $script:fx add 'tasks/inbox/p-01-a.md'
            git -C $script:fx commit -qm 'fixture: tighten verify'
            Invoke-MusterClaim $script:fx | Out-Null
            git -C $script:fx mv 'tasks/doing/p-01-a.md' 'tasks/inbox/p-01-a.md'
            git -C $script:fx commit -qm 'human: recover p-01-a'
            Remove-Item (Join-Path $script:fx 'tasks/doing/p-01-a.verify.log') -ErrorAction SilentlyContinue
        }
    }

    It 'auto-files a re-dispatched task whose verify is already green (accumulate + return, exit 1)' {
        Add-RecoveredTask
        New-Item -ItemType Directory (Join-Path $script:fx 'src') -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $script:fx 'src/out.txt'), 'predecessor work')
        $r = Invoke-MusterInProc $script:fx "Invoke-ClaimCommand -Harness claude -Tier any"
        $r.ExitCode | Should -Be 1
        ($r.Output -join "`n") | Should -Match 'Auto-filed p-01-a'
        ($r.Output -join "`n") | Should -Match 'nothing to claim'
        Test-Path (Join-Path $script:fx 'tasks/done/p-01-a.md') | Should -BeTrue
    }
    It 'claims normally when the probe is red (exit 0)' {
        Add-RecoveredTask
        $r = Invoke-MusterInProc $script:fx "Invoke-ClaimCommand -Harness claude -Tier any"
        $r.ExitCode | Should -Be 0
        ($r.Output -join "`n") | Should -Match 'Claimed p-01-a'
        (Get-Content (Join-Path $script:fx 'tasks/doing/p-01-a.verify.log') -Raw) |
            Should -Match '=== claim-probe result: FAIL'
    }
}
```

- [ ] **Step 2: Run the fast tests to verify they fail**

Run:
```
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Pester -Path tests/fast/Claim.Fast.Tests.ps1"
```
Expected: FAIL — `Invoke-ClaimCommand` is not recognized.

- [ ] **Step 3: Add `Invoke-ClaimCommand` to `_lib.ps1`**

Insert directly after the closing brace of `Invoke-DoneCommand`:

```powershell
function Invoke-ClaimCommand {
    # claim verb (spec 4.1). Returns CommandResult; never writes or exits. UNLIKE the
    # other verbs, claim prints the status block (D12) BEFORE any refusal can fire, so it
    # cannot lean on the throw-based Invoke-CommandBoundary for post-status refusals - the
    # boundary rebuilds Output from only the exception message and would discard the block.
    # It accumulates into $out and RETURNS a refusal CommandResult for every refusal after
    # the status print; only the pre-status identity refusal throws. Output is split one
    # entry per line to match the other command functions and the child-process line shape.
    param([string]$Harness = '', [string]$Tier = '')
    if (@('claude', 'codex') -notcontains $Harness -or @('any', 'strong') -notcontains $Tier) {
        Write-Refuse 'claim requires -Harness <claude|codex> and -Tier <any|strong> (the wrapper skill supplies them).'
    }
    $root = Get-RepoRoot
    $tasks = Get-TasksRoot

    # self-heal promotions dropped by a crashed predecessor (D7)
    [void](Invoke-Promote)

    # status print - fires before any refusal (D12). Split so Output is one entry per line.
    $out = @((Get-StatusBlock -RepoRoot $root -TasksRoot $tasks) -split "`n")

    # one executor per checkout (D18)
    $doing = @(Get-TaskFiles (Join-Path $tasks 'doing'))
    if ($doing.Count -gt 0) {
        $occ = Read-TaskFile $doing[0].FullName
        $age = 'unknown'
        if ($occ.Fields.ContainsKey('claimed_at')) { $age = Get-AgeString $occ.Fields['claimed_at'] }
        return New-CommandResult -Output ($out + "MUSTER refuse: doing/ occupied by $($occ.Id) (claimed $age ago). One executor per checkout. RECOVERY in RUNNER.md.") -ExitCode 1
    }
    # stale staged fix from a crashed done-fail
    $staging = @(Get-TaskFiles (Join-Path $tasks 'staging'))
    if ($staging.Count -gt 0) {
        return New-CommandResult -Output ($out + "MUSTER refuse: stale fix task in tasks/staging/: $($staging[0].Name). Human clears it - RECOVERY in RUNNER.md.") -ExitCode 1
    }

    while ($true) {
        # lowest eligible filename in inbox/; dependency order is the only order
        $selected = $null
        foreach ($f in Get-TaskFiles (Join-Path $tasks 'inbox')) {
            $t = Read-TaskFile $f.FullName
            # malformed = loud refusal, file stays for a human
            if ($t.Errors.Count -gt 0) {
                return New-CommandResult -Output ($out + "MUSTER refuse: $($t.Id) frontmatter invalid: $($t.Errors[0]). Task left in inbox/ for a human.") -ExitCode 1
            }
            $schemaErr = Test-TaskSchema $t.Fields
            if ($schemaErr.Count -gt 0) {
                return New-CommandResult -Output ($out + "MUSTER refuse: $($t.Id) frontmatter invalid: $($schemaErr[0]). Task left in inbox/ for a human.") -ExitCode 1
            }
            # pinning (D25): strong tasks need a strong session; strong sessions take ONLY strong tasks
            if ($t.Fields['tier'] -eq 'strong' -and $Tier -ne 'strong') { continue }
            if ($Tier -eq 'strong' -and $t.Fields['tier'] -ne 'strong') { continue }
            if ($t.Fields.ContainsKey('harness') -and $t.Fields['harness'] -ne $Harness) { continue }
            $selected = $t
            break
        }
        if (-not $selected) {
            return New-CommandResult -Output ($out + "MUSTER refuse: nothing to claim for $Harness/$Tier.") -ExitCode 1
        }
        $id = $selected.Id
        $name = "$id.md"

        # dirty-tree scope check, scoped to the selected task (spec 4.1)
        $cp = @()
        if ($selected.Fields.ContainsKey('commit_paths')) { $cp = @($selected.Fields['commit_paths']) }
        $dirty = Get-DirtyPaths $root
        $outOfScope = @($dirty | Where-Object { -not (Test-PathInScope -Path $_ -CommitPaths $cp) })
        if ($outOfScope.Count -gt 0) {
            return New-CommandResult -Output ($out + "MUSTER refuse: working tree dirty outside $id's commit_paths: $($outOfScope -join ', '). Likely leftovers from a failed or crashed task - see RECOVERY (RUNNER.md), 'leftover dirt'.") -ExitCode 1
        }

        # rename, stamp, claim commit (D21) - probe evidence gathered before the rename
        $priorClaims = @(git -C $root log --oneline -- "tasks/doing/$name")
        git -c core.autocrlf=false -C $root mv "tasks/inbox/$name" "tasks/doing/$name" 2>$null
        $sidecarPaths = Move-TaskSidecars -RepoRoot $root -TasksRoot $tasks -Id $id -From 'inbox' -To 'doing'
        $doingPath = Join-Path $tasks "doing/$name"
        Set-ClaimedAt -Path $doingPath -Iso (Get-IsoNow)
        $commitPaths = @("tasks/inbox/$name", "tasks/doing/$name") + $sidecarPaths
        git -c core.autocrlf=false -C $root commit -q -m "muster($($selected.Fields['plan'])): claim $id" -- @commitPaths 2>$null
        $selected = Read-TaskFile $doingPath   # re-read: claimed_at now present

        # recovery probe (D12) - only impl/fix, only with prior-claim evidence.
        $probeType = $selected.Fields['type']
        if ($priorClaims.Count -gt 0 -and ($probeType -eq 'impl' -or $probeType -eq 'fix')) {
            $probeLog = Join-Path $tasks "doing/$id.verify.log"
            $probe = Invoke-VerifyBlock -Entries $selected.Fields['verify'] -LogPath $probeLog `
                -Label 'claim-probe' -TaskId $id -RepoRoot $root
            if ($probe.Pass) {
                $claimCommit = Get-ClaimCommit -RepoRoot $root -Name $name
                $pre = Test-DonePreconditions -RepoRoot $root -Fields $selected.Fields -ClaimCommit $claimCommit
                if ($pre) { return New-CommandResult -Output ($out + "MUSTER refuse: $pre") -ExitCode 1 }
                [void](Complete-Task -RepoRoot $root -TasksRoot $tasks -Fields $selected.Fields -Id $id `
                    -ClaimCommit $claimCommit -SurprisesOverride 'auto-filed at claim: verify green before execution' -Probe)
                $out += "Auto-filed $id - a crashed predecessor already finished it (claim-probe green)."
                continue
            }
        }

        # print the task and hand over to RUNNER.md. Strip the file's own trailing newline
        # (Write-Output/the shim supplies one), then split so Output is one entry per line -
        # byte-identical to the child's `cat`-style print through the shim.
        $body = [IO.File]::ReadAllText($doingPath)
        if ($body.EndsWith("`r`n")) { $body = $body.Substring(0, $body.Length - 2) }
        elseif ($body.EndsWith("`n")) { $body = $body.Substring(0, $body.Length - 1) }
        $out += ($body -split "`n")
        $out += "Claimed $id. Follow tasks/RUNNER.md."
        return New-CommandResult -Output $out -ExitCode 0
    }
}
```

- [ ] **Step 4: Rewrite `claim.ps1` as the shim**

Replace the entire contents of `runtime/bin/claim.ps1`:

```powershell
# MUSTER claim - spec 4.1. Thin wrapper; logic in _lib.ps1.
param([string]$Harness = '', [string]$Tier = '')
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_lib.ps1')

$r = Invoke-CommandBoundary { Invoke-ClaimCommand -Harness $Harness -Tier $Tier }
$r.Output | Write-Output
exit $r.ExitCode
```

- [ ] **Step 5: Run the fast tests to verify they pass**

Run:
```
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Pester -Path tests/fast/Claim.Fast.Tests.ps1"
```
Expected: all fast tests PASS.

- [ ] **Step 6: Parity gate — run the black-box `claim` suite on BOTH engines**

Run:
```
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Pester -Path tests/Claim.Tests.ps1"
```
then:
```
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "`$env:MUSTER_ENGINE='sh'; Invoke-Pester -Path tests/Claim.Tests.ps1"
```
Expected: 17 tests PASS on both arms. Pay special attention to `prints the status block before any refusal`, `prints the empty-board line`, `ends the body flush against the Claimed line`, and `auto-files a re-dispatched task` — these assert the accumulated output the shim now emits. Any diff = STOP.

- [ ] **Step 7: Verdict check**

Judge the diff: the accumulate-and-return model is a genuine deviation from the uniform shim. Verdict is **worse** only if it made claim materially harder to follow; the structured returns arguably read *clearer* than `Write-Output`+`Write-Refuse`+`exit` scattered through a loop, so expected verdict **equal / simpler**. If **worse**, HALT and report. Note the verdict for Task 4.

- [ ] **Step 8: Commit**

```bash
git add runtime/bin/_lib.ps1 runtime/bin/claim.ps1 tests/fast/Claim.Fast.Tests.ps1
git commit -m "refactor(runtime): extract Invoke-ClaimCommand (accumulate-and-return), claim.ps1 becomes shim"
```

---

### Task 3: Extract `Invoke-VerifyCommand`, shim `verify.ps1`

**Files:**
- Create: `tests/fast/Verify.Fast.Tests.ps1`
- Modify: `runtime/bin/_lib.ps1` (add `Invoke-VerifyCommand` after `Invoke-ClaimCommand`)
- Modify: `runtime/bin/verify.ps1` (full rewrite to shim)

- [ ] **Step 1: Write the failing fast tests**

Create `tests/fast/Verify.Fast.Tests.ps1`:

```powershell
BeforeAll {
    . (Join-Path $PSScriptRoot '../MusterFixture.ps1')
    . (Join-Path $PSScriptRoot 'InProcHarness.ps1')
}

Describe 'Invoke-VerifyCommand (in-process)' {
    BeforeEach { $script:fx = New-MusterFixture }
    AfterEach { Remove-MusterFixture $script:fx }

    BeforeAll {
        function New-DoingTask {
            param([string]$VerifyCmd = 'git --version', [string]$ExpectExit = '0')
            New-TaskFile -Fixture $script:fx -Folder doing -Id 'p-01-a' -VerifyCmd $VerifyCmd `
                -ExpectExit $ExpectExit -ExtraFront @('claimed_at: 2026-08-07T00:00:00Z') -Commit | Out-Null
        }
    }

    It 'refuses when doing/ is empty' {
        $r = Invoke-MusterInProc $script:fx 'Invoke-VerifyCommand'
        $r.ExitCode | Should -Be 1
        $r.Output[0] | Should -Match '^MUSTER refuse: doing/ is empty'
    }
    It 'passes a green task and logs attempt 1 (exit 0)' {
        New-DoingTask
        $r = Invoke-MusterInProc $script:fx 'Invoke-VerifyCommand'
        $r.ExitCode | Should -Be 0
        $r.Output[-1] | Should -Match 'VERIFY PASS \(attempt 1\)'
        (Get-Content (Join-Path $script:fx 'tasks/doing/p-01-a.verify.log') -Raw) | Should -Match '=== attempt 1 result: PASS'
    }
    It 'fails with exit 2 and increments attempts across runs' {
        New-DoingTask -VerifyCmd 'git frobnicate'
        (Invoke-MusterInProc $script:fx 'Invoke-VerifyCommand').ExitCode | Should -Be 2
        $r2 = Invoke-MusterInProc $script:fx 'Invoke-VerifyCommand'
        $r2.ExitCode | Should -Be 2
        $r2.Output[-1] | Should -Match 'VERIFY FAIL \(attempt 2 of 3\)'
    }
    It 'third failure is terminal: task moved to failed/, exit 3' {
        New-DoingTask -VerifyCmd 'git frobnicate'
        Invoke-MusterInProc $script:fx 'Invoke-VerifyCommand' | Out-Null
        Invoke-MusterInProc $script:fx 'Invoke-VerifyCommand' | Out-Null
        $r3 = Invoke-MusterInProc $script:fx 'Invoke-VerifyCommand'
        $r3.ExitCode | Should -Be 3
        $r3.Output[-1] | Should -Match 'VERIFY FAIL terminal'
        Test-Path (Join-Path $script:fx 'tasks/failed/p-01-a.md') | Should -BeTrue
        Test-Path (Join-Path $script:fx 'tasks/doing/p-01-a.md') | Should -BeFalse
        (Get-FixtureCommits $script:fx)[0] | Should -Be 'muster(p): fail p-01-a'
    }
    It 'reads the verify block from HEAD, ignoring working-tree edits (D20 happy path)' {
        New-DoingTask -VerifyCmd 'git frobnicate'
        $path = Join-Path $script:fx 'tasks/doing/p-01-a.md'
        $text = [IO.File]::ReadAllText($path) -replace 'git frobnicate', 'git --version'
        [IO.File]::WriteAllText($path, $text)
        (Invoke-MusterInProc $script:fx 'Invoke-VerifyCommand').ExitCode | Should -Be 2
    }
    It 'burns the attempt as a marker commit before running (D28)' {
        New-DoingTask
        Invoke-MusterInProc $script:fx 'Invoke-VerifyCommand' | Out-Null
        (Get-FixtureCommits $script:fx)[0] | Should -Be 'muster(p): attempt 1 p-01-a'
    }
}
```

- [ ] **Step 2: Run the fast tests to verify they fail**

Run:
```
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Pester -Path tests/fast/Verify.Fast.Tests.ps1"
```
Expected: FAIL — `Invoke-VerifyCommand` is not recognized.

- [ ] **Step 3: Add `Invoke-VerifyCommand` to `_lib.ps1`**

Insert directly after the closing brace of `Invoke-ClaimCommand`:

```powershell
function Invoke-VerifyCommand {
    # verify verb (spec 4.2). Returns CommandResult; never writes or exits.
    $root = Get-RepoRoot
    $tasks = Get-TasksRoot
    $file = Get-SoleOccupant $tasks
    $task = Read-CommittedTask -RepoRoot $root -Name $file.Name
    if ($task.Errors.Count -gt 0) { Write-Refuse "$($task.Id) frontmatter invalid: $($task.Errors[0])." }
    $id = $task.Id
    $plan = $task.Fields['plan']
    $log = Join-Path $tasks "doing/$id.verify.log"

    $claimCommit = Get-ClaimCommit -RepoRoot $root -Name "$id.md"
    $count = Get-AttemptCount -RepoRoot $root -Plan $plan -Id $id -ClaimCommit $claimCommit
    if ($count -ge 3) {
        Move-TaskToFailed -RepoRoot $root -TasksRoot $tasks -Id $id -Plan $plan
        return New-CommandResult -Output @('VERIFY FAIL terminal. Task moved to failed/ for human review. Session over.') -ExitCode 3
    }
    $n = $count + 1
    # D28: the attempt burns BEFORE any command runs. No stderr redirect and a hard
    # exit-code check - if this commit fails, running the verify would be an unaccounted
    # attempt. (On success the commit is silent, so no runspace stderr divergence.)
    $head = git -C $root rev-parse HEAD
    Add-Utf8 $log ("=== attempt $n | $(Get-IsoNow) | task $id | HEAD $head`n")
    git -c core.autocrlf=false -C $root add "tasks/doing/$id.verify.log"
    git -c core.autocrlf=false -C $root commit -q -m "muster($plan): attempt $n $id" -- "tasks/doing/$id.verify.log"
    if ($LASTEXITCODE -ne 0) {
        Write-Refuse 'attempt marker commit failed - cannot account the attempt. Inspect git state by hand.'
    }
    $res = Invoke-VerifyBlock -Entries $task.Fields['verify'] -LogPath $log -Label "attempt $n" -TaskId $id -RepoRoot $root -SkipHeader
    if ($res.Pass) {
        return New-CommandResult -Output @("VERIFY PASS (attempt $n)") -ExitCode 0
    }
    if ($n -lt 3) {
        return New-CommandResult -Output @("VERIFY FAIL (attempt $n of 3): $($res.FirstFail). Fix and rerun.") -ExitCode 2
    }
    Move-TaskToFailed -RepoRoot $root -TasksRoot $tasks -Id $id -Plan $plan
    return New-CommandResult -Output @('VERIFY FAIL terminal. Task moved to failed/ for human review. Session over.') -ExitCode 3
}
```

- [ ] **Step 4: Rewrite `verify.ps1` as the shim**

Replace the entire contents of `runtime/bin/verify.ps1`:

```powershell
# MUSTER verify - spec 4.2. Thin wrapper; logic in _lib.ps1.
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_lib.ps1')

$r = Invoke-CommandBoundary { Invoke-VerifyCommand }
$r.Output | Write-Output
exit $r.ExitCode
```

- [ ] **Step 5: Run the fast tests to verify they pass**

Run:
```
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Pester -Path tests/fast/Verify.Fast.Tests.ps1"
```
Expected: 6 tests PASS.

- [ ] **Step 6: Parity gate — run the black-box `verify` suite on BOTH engines**

Run:
```
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Pester -Path tests/Verify.Tests.ps1"
```
then:
```
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "`$env:MUSTER_ENGINE='sh'; Invoke-Pester -Path tests/Verify.Tests.ps1"
```
Expected: 7 tests PASS on both arms. Any diff = STOP.

- [ ] **Step 7: Verdict check**

`verify` is the simplest extraction (three exit codes → `-ExitCode`, no accumulate, no self-exiting branch). Expected verdict **simpler / equal**. If **worse**, HALT and report. Note the verdict for Task 4.

- [ ] **Step 8: Commit**

```bash
git add runtime/bin/_lib.ps1 runtime/bin/verify.ps1 tests/fast/Verify.Fast.Tests.ps1
git commit -m "refactor(runtime): extract Invoke-VerifyCommand, verify.ps1 becomes shim"
```

---

### Task 4: Re-measure the stateful verbs, record the Phase 3 exit

**Files:**
- Create: `docs/runtime-consolidation/phase3-comparison-2026-08-14.md`
- Modify: `docs/test-speed-consolidation-plan.md` (Phase 3 `**Result:**` note)

- [ ] **Step 1: Full-suite parity gate on BOTH engines**

Confirm nothing regressed across the whole suite (the three new fast files are picked up by `-Path tests` recursively; they are engine-agnostic).

Run:
```
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Pester -Path tests"
```
then:
```
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "`$env:MUSTER_ENGINE='sh'; Invoke-Pester -Path tests"
```
Expected: green on both arms — the prior total plus the new fast tests (Done ~10, Claim ~8, Verify 6). Any failure = STOP.

Note: the `tests/fast/*.Fast.Tests.ps1` files are engine-agnostic — the act always runs in a PS runspace via `Invoke-MusterInProc`. Under the sh arm their *setup* (`Add-ClaimedImpl` etc.) claims via `claim.sh`, so this pass also cross-checks that sh-produced board state feeds the PS in-process functions identically. That is harmless redundant coverage (parity guarantees setup fidelity), consistent with the Phase 1 precedent of running the fast tests under both arms; do not scope them out.

- [ ] **Step 2: Measure in-process vs child-process for `claim` and `done`**

Run from repo root and capture the output. Setup uses the real child `claim` so the measured `done` call starts from a genuinely claimed task:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "
. tests/MusterFixture.ps1
. tests/fast/InProcHarness.ps1
function New-DoneReady {
  `$fx = New-MusterFixture
  New-TaskFile -Fixture `$fx -Folder inbox -Id 'p-01-a' -CommitPaths @('src/out.txt') -VerifyCmd 'git --version' -Commit | Out-Null
  Invoke-MusterClaim `$fx | Out-Null
  New-Item -ItemType Directory (Join-Path `$fx 'src') -Force | Out-Null
  [IO.File]::WriteAllText((Join-Path `$fx 'src/out.txt'), 'payload')
  `$fx
}
# warm-up JIT
`$w = New-DoneReady; [void](Invoke-MusterInProc `$w 'Invoke-DoneCommand'); Remove-MusterFixture `$w
`$inDone = @(); `$prDone = @()
1..10 | ForEach-Object { `$fx = New-DoneReady; `$inDone += (Measure-Command { Invoke-MusterInProc `$fx 'Invoke-DoneCommand' }).TotalSeconds; Remove-MusterFixture `$fx }
1..5  | ForEach-Object { `$fx = New-DoneReady; `$prDone += (Measure-Command { Invoke-Muster `$fx 'done' }).TotalSeconds; Remove-MusterFixture `$fx }
'done  in-proc {0:N3}s  child {1:N3}s  ({2:N1}x)' -f (`$inDone | Measure-Object -Average).Average, (`$prDone | Measure-Object -Average).Average, ((`$prDone | Measure-Object -Average).Average / (`$inDone | Measure-Object -Average).Average)
"
```
Expected: in-proc faster than child, but a smaller multiple than status/lint's 4.6x (claim/done are git-subprocess-bound). Record the actual numbers.

- [ ] **Step 3: Write the comparison file**

Create `docs/runtime-consolidation/phase3-comparison-2026-08-14.md`: a `# Phase 3 stateful-verb comparison` heading, the machine line, the measured `done` in-proc vs child numbers, one line noting the multiple is smaller than status/lint because these verbs are git-subprocess-bound, and one line noting Phase 3 is net-slower in isolation (adds fast tests + keeps the full black-box suite on both engines) — the payoff is Phase 4's migration. This delta feeds the Phase 5 C# decision.

- [ ] **Step 4: Record the Phase 3 exit in the spec doc**

In `docs/test-speed-consolidation-plan.md`, under the Phase 3 heading, add a `**Result:**` note: the three verbs extracted and passing the unchanged black-box suite on both engines through shims; the fast tier proves the risky region (completion, verification failure, review cycling, non-native-stderr refusals) in-process; the three documented process-tier carve-outs (link `phase3-spike-2026-08-14.md`); the per-verb control-flow verdicts from Tasks 1/2/3 Step 7-9 (simpler / equal / worse); and the measured speedup (link `phase3-comparison-2026-08-14.md`). If any verdict was "worse", flag it as the stop condition per spec.

- [ ] **Step 5: Commit**

```bash
git add docs/runtime-consolidation/phase3-comparison-2026-08-14.md docs/test-speed-consolidation-plan.md
git commit -m "docs(phase3): record stateful-slice exit + in-process comparison"
```

---

## Verification checklist (whole plan)

- [ ] Spike (Task 0) ran and its gate was evaluated before any extraction; result committed.
- [ ] Full suite green on the ps1 engine after every task commit.
- [ ] Full suite green on the sh engine after Tasks 1, 2, 3 (each touching a converted verb).
- [ ] `git status` clean after each commit.
- [ ] No `runtime/bin/*.sh` file in any diff; no black-box `*.Tests.ps1` under `tests/` edited (only new `tests/fast/*.Fast.Tests.ps1` added).
- [ ] `done.ps1:51` `exit 3` guard deleted, not carried; `Invoke-DoneFailReview` / `Invoke-DoneFailIntegration` return CommandResults on all non-refusal paths.
- [ ] No fast test targets a documented carve-out (uncommitted `Read-CommittedTask` refusal, `eol=lf`+CRLF completion, promote `Write-Host` warning).
- [ ] Per-verb control-flow verdicts recorded; any "worse" verdict halted the flow and was reported.

## Not yet specified

In scope of the overall effort but deliberately not planned here (Phase 4+ of the spec):

- The process-tier contract matrix (which verbs/paths keep child-process tests, minimum coverage) — Phase 4.
- Classifying and migrating each existing black-box test to function/runspace execution — Phase 4.
- Whether the three native-stderr carve-outs can be brought in-process by a local, guard-safe git-call restructure — deferred; this plan explicitly does not restructure shared helpers.

## Out of scope

- `promote` extraction (`Invoke-Promote` stays a helper; its `Write-Host` warnings cannot round-trip in-process).
- Phase 4 contract matrix, tier classification, and migration of black-box tests.
- Byte-contract decision (spec open question 2); PS7-orchestrated parallel CI (open question 3).
- NGen / machine tuning; any edit to `runtime/bin/*.sh`; anything C#.
- Bringing the three native-stderr carve-outs in-process by restructuring shared git helpers.
