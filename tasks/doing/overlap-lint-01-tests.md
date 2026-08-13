---
id: overlap-lint-01-tests
plan: overlap-lint
type: impl
tier: any
depends_on: []
protected:
  - runtime/bin/
  - tests/MusterFixture.ps1
  - tests/LintOverlap.Tests.ps1
commit_paths:
  - tests/LintOverlap.Tests.ps1
verify:
  - cmd: "powershell -NoProfile -ExecutionPolicy Bypass -Command Invoke-Pester tests/LintOverlap.Tests.ps1 -Output Detailed"
    expect_exit: 0
    expect_contains: "[-] FAILs two impl tasks sharing a commit_path with no ordering"
    timeout_seconds: 600
  - cmd: "powershell -NoProfile -ExecutionPolicy Bypass -Command Invoke-Pester tests/LintOverlap.Tests.ps1 -Output Detailed"
    expect_exit: 0
    expect_contains: "[+] does not fire on a clean full batch (regression)"
    timeout_seconds: 600
claimed_at: 2026-08-13T00:42:12Z
---
# overlap-lint-01-tests: author the D32 overlap-lint Pester tests (red phase)

## Context

A new shard-lint batch check (check 15, decision D32) will FAIL when two impl/fix
tasks name the same commit_path with no depends_on ordering between them. This task
authors the Pester tests that define that behavior. The engines
(runtime/bin/_lib.ps1 and runtime/bin/_lib.sh) do not implement check 15 yet, so
the four tests that assert the overlap finding MUST be red after this task - that
red state is the TDD signal, and the verify block below asserts it (first entry
expects the failing-test marker, second entry expects the regression test to pass).
Do not touch either engine file; later tasks turn these tests green.

The tests go in a NEW file, tests/LintOverlap.Tests.ps1, not appended to
tests/Lint.Tests.ps1. Reason: downstream engine tasks freeze the grader by listing
tests/ as protected, and the freeze mechanics only allow a task to author a grader
it creates as a new file. Every test file in this suite starts by dot-sourcing
tests/MusterFixture.ps1, which provides the helpers used below: New-MusterFixture
(throwaway git repo with tasks/ tree + engine scripts installed),
Remove-MusterFixture, New-TaskFile (schema-valid task file writer; parameters
-Fixture -Folder -Id -Type -Tier -DependsOn -CommitPaths -ExtraFront), and
Invoke-MusterLint (runs bin/lint in the fixture; returns .Text and .Exit).

## Steps

1. Ensure the file tests/LintOverlap.Tests.ps1 exists with exactly this content:

```powershell
BeforeAll { . (Join-Path $PSScriptRoot 'MusterFixture.ps1') }

Describe 'bin/lint - commit_paths overlap (D32)' {
    BeforeEach { $script:fx = New-MusterFixture }
    AfterEach { Remove-MusterFixture $script:fx }

    # NOTE: the minimal 2-task fixtures below also trip check 11 (no integration task),
    # so the batch exit is 1 regardless. The pass-case assertions therefore check that
    # the overlap message is ABSENT, not that exit is 0 - matching the existing
    # 'check 3'/'check 5' style in tests/Lint.Tests.ps1.

    It 'FAILs two impl tasks sharing a commit_path with no ordering' {
        New-TaskFile -Fixture $script:fx -Folder backlog -Id 'p-01-a' -CommitPaths @('src/foo.txt') | Out-Null
        New-TaskFile -Fixture $script:fx -Folder backlog -Id 'p-02-b' -CommitPaths @('src/foo.txt') | Out-Null
        $r = Invoke-MusterLint $script:fx -Paths @('tasks/backlog/p-01-a.md', 'tasks/backlog/p-02-b.md')
        $r.Exit | Should -Be 1
        $r.Text | Should -Match "commit_path 'src/foo.txt' also written by 'p-02-b'"
    }
    It 'passes when the two are directly ordered' {
        New-TaskFile -Fixture $script:fx -Folder backlog -Id 'p-01-a' -CommitPaths @('src/foo.txt') | Out-Null
        New-TaskFile -Fixture $script:fx -Folder backlog -Id 'p-02-b' -CommitPaths @('src/foo.txt') `
            -DependsOn @('p-01-a') | Out-Null
        $r = Invoke-MusterLint $script:fx -Paths @('tasks/backlog/p-01-a.md', 'tasks/backlog/p-02-b.md')
        $r.Text | Should -Not -Match 'commit_path'
    }
    It 'passes when ordered transitively through a review task (D19 shape)' {
        New-TaskFile -Fixture $script:fx -Folder backlog -Id 'p-01-a' -CommitPaths @('src/foo.txt') | Out-Null
        New-TaskFile -Fixture $script:fx -Folder backlog -Id 'p-02-review-a' -Type review -Tier strong `
            -DependsOn @('p-01-a') -ExtraFront @('reviews: p-01-a') | Out-Null
        New-TaskFile -Fixture $script:fx -Folder backlog -Id 'p-03-b' -CommitPaths @('src/foo.txt') `
            -DependsOn @('p-02-review-a') | Out-Null
        $r = Invoke-MusterLint $script:fx -Paths @(
            'tasks/backlog/p-01-a.md', 'tasks/backlog/p-02-review-a.md', 'tasks/backlog/p-03-b.md')
        $r.Text | Should -Not -Match 'commit_path'
    }
    It 'FAILs on prefix overlap (dir vs file under it)' {
        New-TaskFile -Fixture $script:fx -Folder backlog -Id 'p-01-a' -CommitPaths @('src/') | Out-Null
        New-TaskFile -Fixture $script:fx -Folder backlog -Id 'p-02-b' -CommitPaths @('src/foo.txt') | Out-Null
        $r = Invoke-MusterLint $script:fx -Paths @('tasks/backlog/p-01-a.md', 'tasks/backlog/p-02-b.md')
        $r.Exit | Should -Be 1
        $r.Text | Should -Match 'no depends_on ordering'
    }
    It 'passes disjoint commit_paths with no ordering' {
        New-TaskFile -Fixture $script:fx -Folder backlog -Id 'p-01-a' -CommitPaths @('src/foo.txt') | Out-Null
        New-TaskFile -Fixture $script:fx -Folder backlog -Id 'p-02-b' -CommitPaths @('src/bar.txt') | Out-Null
        $r = Invoke-MusterLint $script:fx -Paths @('tasks/backlog/p-01-a.md', 'tasks/backlog/p-02-b.md')
        $r.Text | Should -Not -Match 'commit_path'
    }
    It 'FAILs two fix-type tasks sharing a commit_path with no ordering' {
        New-TaskFile -Fixture $script:fx -Folder backlog -Id 'p-01-x' -Type fix `
            -CommitPaths @('src/foo.txt') -ExtraFront @('fixes: p-00-a') | Out-Null
        New-TaskFile -Fixture $script:fx -Folder backlog -Id 'p-02-y' -Type fix `
            -CommitPaths @('src/foo.txt') -ExtraFront @('fixes: p-00-b') | Out-Null
        $r = Invoke-MusterLint $script:fx -Paths @('tasks/backlog/p-01-x.md', 'tasks/backlog/p-02-y.md')
        $r.Exit | Should -Be 1
        $r.Text | Should -Match "commit_path 'src/foo.txt' also written by 'p-02-y'"
    }
    It 'emits a finding per unordered overlapping pair (three-way, deterministic)' {
        New-TaskFile -Fixture $script:fx -Folder backlog -Id 'p-01-a' -CommitPaths @('src/foo.txt') | Out-Null
        New-TaskFile -Fixture $script:fx -Folder backlog -Id 'p-02-b' -CommitPaths @('src/foo.txt') | Out-Null
        New-TaskFile -Fixture $script:fx -Folder backlog -Id 'p-03-c' -CommitPaths @('src/foo.txt') | Out-Null
        $r = Invoke-MusterLint $script:fx -Paths @(
            'tasks/backlog/p-01-a.md', 'tasks/backlog/p-02-b.md', 'tasks/backlog/p-03-c.md')
        $r.Exit | Should -Be 1
        $r.Text | Should -Match "p-01-a.md: commit_path 'src/foo.txt' also written by 'p-02-b'"
        $r.Text | Should -Match "p-01-a.md: commit_path 'src/foo.txt' also written by 'p-03-c'"
        $r.Text | Should -Match "p-02-b.md: commit_path 'src/foo.txt' also written by 'p-03-c'"
    }
    It 'FAILs on prefix overlap in the reverse direction (file under dir)' {
        # test 4 covers lo=dir/hi=file; this covers lo=file/hi=dir - the other arm
        # of the sh mirror's double path_listed check.
        New-TaskFile -Fixture $script:fx -Folder backlog -Id 'p-01-a' -CommitPaths @('src/foo.txt') | Out-Null
        New-TaskFile -Fixture $script:fx -Folder backlog -Id 'p-02-b' -CommitPaths @('src/') | Out-Null
        $r = Invoke-MusterLint $script:fx -Paths @('tasks/backlog/p-01-a.md', 'tasks/backlog/p-02-b.md')
        $r.Exit | Should -Be 1
        $r.Text | Should -Match 'no depends_on ordering'
    }
    It 'does not fire on a clean full batch (regression)' {
        New-TaskFile -Fixture $script:fx -Folder backlog -Id 'p-01-a' -CommitPaths @('src/out.txt') | Out-Null
        New-TaskFile -Fixture $script:fx -Folder backlog -Id 'p-02-review-a' -Type review -Tier strong `
            -DependsOn @('p-01-a') -ExtraFront @('reviews: p-01-a') | Out-Null
        New-TaskFile -Fixture $script:fx -Folder backlog -Id 'p-99-integration' -Type integration -Tier strong `
            -DependsOn @('p-01-a', 'p-02-review-a') | Out-Null
        $r = Invoke-MusterLint $script:fx -Paths @(
            'tasks/backlog/p-01-a.md', 'tasks/backlog/p-02-review-a.md', 'tasks/backlog/p-99-integration.md')
        $r.Text | Should -Match 'LINT OK 3'
    }
}
```

2. Ensure no other file changed - in particular runtime/bin/_lib.ps1,
   runtime/bin/_lib.sh, and tests/Lint.Tests.ps1 stay untouched.

## Acceptance

- tests/LintOverlap.Tests.ps1 exists with the nine tests above.
- The four overlap-finding tests fail (engines lack check 15); the regression
  test and the absence-assertion pass-cases succeed.
- No engine file or existing test file modified.
