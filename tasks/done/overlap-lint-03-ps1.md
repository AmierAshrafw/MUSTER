---
id: overlap-lint-03-ps1
plan: overlap-lint
type: impl
tier: any
depends_on:
  - overlap-lint-02-review-tests
protected:
  - tests/
  - runtime/bin/_lib.sh
commit_paths:
  - runtime/bin/_lib.ps1
verify:
  - cmd: "powershell -NoProfile -ExecutionPolicy Bypass -Command Invoke-Pester tests/LintOverlap.Tests.ps1 -Output Detailed"
    expect_exit: 0
    expect_contains: "Failed: 0,"
    timeout_seconds: 600
  - cmd: "powershell -NoProfile -ExecutionPolicy Bypass -Command Invoke-Pester tests/Lint.Tests.ps1 -Output Detailed"
    expect_exit: 0
    expect_contains: "Failed: 0,"
    timeout_seconds: 600
claimed_at: 2026-08-13T00:51:16Z
---
# overlap-lint-03-ps1: check 15 in the PowerShell engine

## Context

Batch check 15 (decision D32): FAIL when two impl/fix tasks share a commit_path
(prefix-aware) with no transitive, either-direction depends_on ordering between
them. The tests in tests/LintOverlap.Tests.ps1 already define the behavior and are
red; this task turns them green in runtime/bin/_lib.ps1 only. The file runs under
Set-StrictMode -Version 2.0.

Interfaces already in runtime/bin/_lib.ps1 that the new code uses:

- Test-LintChecks (starts at line 414): builds $batch, an array of hashtables
  with keys Id (filename stem), Path, Errors (string array), Fields (frontmatter
  hashtable; list values are string arrays). Findings accumulate as strings in
  $findings. Batch-only checks 11 and 12 sit inside an "if (-not $Lite) {" block
  whose closing brace is on line 571, directly above "return , $findings".
- Test-PathListed (line 686): "param([string]$Path, [string[]]$List)" - true when
  $Path equals a list entry or sits under a listed directory (prefix-aware).

## Steps

1. Ensure this function sits in runtime/bin/_lib.ps1 immediately before the line
   "function Test-LintChecks {" (line 414):

```powershell
function Test-Reaches {
    # True if $From reaches $To by following depends_on edges in $DepMap (transitive, D32).
    # Edges point child -> parent (a task -> the id it depends on). Missing keys are dead ends.
    param([hashtable]$DepMap, [string]$From, [string]$To)
    $seen = @{}
    $stack = New-Object System.Collections.Stack
    $stack.Push($From)
    while ($stack.Count -gt 0) {
        $cur = [string]$stack.Pop()
        if ($seen.ContainsKey($cur)) { continue }
        $seen[$cur] = $true
        if (-not $DepMap.ContainsKey($cur)) { continue }
        foreach ($p in $DepMap[$cur]) {
            if ($p -eq $To) { return $true }
            $stack.Push($p)
        }
    }
    return $false
}
```

2. Ensure this block sits inside Test-LintChecks, inside the "if (-not $Lite) {"
   block, after check 12's foreach loop and before that block's closing brace
   (line 571 before this edit):

```powershell
        # 15. shared commit_path without depends_on ordering (D32). A weak session's
        #     frozen Steps for one task predate a sibling's committed edits; an unordered
        #     overlap risks a silent clobber caught only by later verify/integration.
        #     Reachability is transitive and either-direction so the D19
        #     A -> review-A -> B chain does not false-positive. Only impl/fix carry
        #     commit_paths (schema), so the pair space is impl/fix x impl/fix.
        $depMap = @{}
        foreach ($dt in @($batch | Where-Object { $_.Errors.Count -eq 0 })) {
            # ContainsKey guard: a parse-clean but schema-invalid task can lack depends_on;
            # @($dt.Fields['depends_on']) would then be @($null) under StrictMode (review S2).
            if ($dt.Fields.ContainsKey('depends_on')) { $depMap[$dt.Id] = @($dt.Fields['depends_on']) }
            else { $depMap[$dt.Id] = @() }
        }
        $cpTasks = @($batch | Where-Object {
                $_.Errors.Count -eq 0 -and @('impl', 'fix') -contains $_.Fields['type'] -and
                $_.Fields.ContainsKey('commit_paths')
            })
        for ($x = 0; $x -lt $cpTasks.Count; $x++) {
            for ($y = $x + 1; $y -lt $cpTasks.Count; $y++) {
                $lo = $cpTasks[$x]; $hi = $cpTasks[$y]
                # ordinal compare to match the sh mirror's LC_ALL=C sort - PS -lt is
                # culture-aware and would pick a different lo for hyphen-adjacent ids,
                # breaking byte-identical parity (review W1).
                if ([string]::CompareOrdinal($hi.Id, $lo.Id) -lt 0) { $lo = $cpTasks[$y]; $hi = $cpTasks[$x] }
                if ((Test-Reaches -DepMap $depMap -From $lo.Id -To $hi.Id) -or
                    (Test-Reaches -DepMap $depMap -From $hi.Id -To $lo.Id)) { continue }
                $hit = $null
                foreach ($pl in @($lo.Fields['commit_paths'])) {
                    foreach ($ph in @($hi.Fields['commit_paths'])) {
                        if ((Test-PathListed -Path $pl -List @($ph)) -or
                            (Test-PathListed -Path $ph -List @($pl))) { $hit = $pl; break }
                    }
                    if ($hit) { break }
                }
                if ($hit) {
                    $findings += "$($lo.Id).md: commit_path '$hit' also written by '$($hi.Id)' with no depends_on ordering between them - add a dependency edge or reshard."
                }
            }
        }
```

3. Ensure no other file changed - in particular runtime/bin/_lib.sh and
   everything under tests/ stay untouched.

## Acceptance

- All nine tests in tests/LintOverlap.Tests.ps1 pass on the default (ps1) engine.
- All existing tests in tests/Lint.Tests.ps1 still pass.
- Diff touches runtime/bin/_lib.ps1 only.
