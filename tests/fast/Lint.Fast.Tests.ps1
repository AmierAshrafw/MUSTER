BeforeAll {
    . (Join-Path $PSScriptRoot '../MusterFixture.ps1')
    . (Join-Path $PSScriptRoot 'InProcHarness.ps1')
}

Describe 'Invoke-LintCommand (in-process)' {
    BeforeEach { $script:fx = New-SharedMusterFixture }
    AfterEach { }

    It 'passes a well-formed batch with LINT OK and exit 0' -Tag 'CM-LINT-OK' {
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
    It 'check 2: flags id not matching filename and filename collisions' -Tag 'CM-LINT-FAIL' {
        New-TaskFile -Fixture $script:fx -Folder backlog -Id 'p-01-a' -CommitPaths @('src/out.txt') | Out-Null
        New-TaskFile -Fixture $script:fx -Folder backlog -Id 'p-02-review-a' -Type review -Tier strong `
            -DependsOn @('p-01-a') -ExtraFront @('reviews: p-01-a') | Out-Null
        New-TaskFile -Fixture $script:fx -Folder backlog -Id 'p-99-integration' -Type integration -Tier strong `
            -DependsOn @('p-01-a', 'p-02-review-a') | Out-Null
        New-TaskFile -Fixture $script:fx -Folder done -Id 'p-01-a' | Out-Null   # collision on disk
        $r = Invoke-MusterInProc $script:fx ("Invoke-LintCommand -Paths @(" +
            "'tasks/backlog/p-01-a.md','tasks/backlog/p-02-review-a.md','tasks/backlog/p-99-integration.md')")
        $r.ExitCode | Should -Be 1
        ($r.Output -join "`n") | Should -Match 'collision'
    }
    It 'check 3: flags a depends_on id that exists neither in batch nor on disk' {
        New-TaskFile -Fixture $script:fx -Folder backlog -Id 'p-01-a' -DependsOn @('p-00-ghost') | Out-Null
        $r = Invoke-MusterInProc $script:fx "Invoke-LintCommand -Paths @('tasks/backlog/p-01-a.md')"
        $r.ExitCode | Should -Be 1
        ($r.Output -join "`n") | Should -Match 'p-00-ghost'
    }
    It 'check 4: flags shell metacharacters and network commands' {
        New-TaskFile -Fixture $script:fx -Folder backlog -Id 'p-01-a' -VerifyCmd 'git --version | sort' | Out-Null
        $r1 = Invoke-MusterInProc $script:fx "Invoke-LintCommand -Paths @('tasks/backlog/p-01-a.md')"
        $r1.ExitCode | Should -Be 1
        New-TaskFile -Fixture $script:fx -Folder backlog -Id 'p-02-b' -VerifyCmd 'npm install left-pad' | Out-Null
        $r2 = Invoke-MusterInProc $script:fx "Invoke-LintCommand -Paths @('tasks/backlog/p-02-b.md')"
        ($r2.Output -join "`n") | Should -Match 'network'
    }
    It 'check 4: allows a network command when harness is claude' {
        New-TaskFile -Fixture $script:fx -Folder backlog -Id 'p-01-a' -VerifyCmd 'dotnet restore App.csproj' `
            -ExtraFront @('harness: claude') | Out-Null
        $r = Invoke-MusterInProc $script:fx "Invoke-LintCommand -Paths @('tasks/backlog/p-01-a.md')"
        ($r.Output -join "`n") | Should -Not -Match 'network'
    }
    It 'check 5: impl verify paths must be protected or committed' {
        New-TaskFile -Fixture $script:fx -Folder backlog -Id 'p-01-a' `
            -VerifyCmd 'powershell -File scripts/check.ps1' -Protected @('README.md') -CommitPaths @('src/out.txt') | Out-Null
        $r = Invoke-MusterInProc $script:fx "Invoke-LintCommand -Paths @('tasks/backlog/p-01-a.md')"
        $r.ExitCode | Should -Be 1
        ($r.Output -join "`n") | Should -Match 'scripts/check.ps1'
    }
    It 'check 5: does not treat single-letter cmd.exe switches like /c as repo paths' {
        New-TaskFile -Fixture $script:fx -Folder backlog -Id 'p-01-a' `
            -VerifyCmd 'cmd /c npm test' -CommitPaths @('src/out.txt') | Out-Null
        $r = Invoke-MusterInProc $script:fx "Invoke-LintCommand -Paths @('tasks/backlog/p-01-a.md')"
        ($r.Output -join "`n") | Should -Not -Match 'verify path'
    }
    It 'checks 7-9: placeholders, un-inlined references, judgment language' {
        $body = "# p-01-a: t`n`n## Context`n`nsee docs/plan.md`n`n## Steps`n`n1. Handle edge cases as appropriate. TODO`n`n## Acceptance`n`n- x"
        New-TaskFile -Fixture $script:fx -Folder backlog -Id 'p-01-a' -Body $body | Out-Null
        $r = Invoke-MusterInProc $script:fx "Invoke-LintCommand -Paths @('tasks/backlog/p-01-a.md')"
        $r.ExitCode | Should -Be 1
        $joined = ($r.Output -join "`n")
        foreach ($sig in 'placeholder', 'reference', 'judgment') { $joined | Should -Match $sig }
    }
    It 'check 8: review task filled literally from templates/review-task.md passes lint' {
        # Regression: template line 17 used to read "per the plan snapshot",
        # which check 8 rejects as an un-inlined reference.
        $tpl = [IO.File]::ReadAllText((Join-Path $script:RepoRoot 'templates/review-task.md'))
        $tpl | Should -Not -Match 'per the plan'
        $fill = @{
            '{inlined spec excerpt for the impl task}'                                    = 'Write src/out.txt.'
            '{fix template inlined here by shard, so the reviewer never opens plugin files}' = '(fix template omitted in fixture)'
            '{cheap-build-or-test-cmd}' = 'git --version'
            '{impl-id}'  = 'p-01-a'
            '{impl-seq}' = '01'
            '{plan}'     = 'p'
            '{seq}'      = '02'
            '{slug}'     = 'a'
            '{id}'       = 'p-02-review-a'
        }
        foreach ($k in $fill.Keys) { $tpl = $tpl.Replace($k, $fill[$k]) }
        New-TaskFile -Fixture $script:fx -Folder backlog -Id 'p-01-a' -CommitPaths @('src/out.txt') | Out-Null
        [IO.File]::WriteAllText((Join-Path $script:fx 'tasks/backlog/p-02-review-a.md'), $tpl, $script:Utf8NoBom)
        New-TaskFile -Fixture $script:fx -Folder backlog -Id 'p-99-integration' -Type integration -Tier strong `
            -DependsOn @('p-01-a', 'p-02-review-a') | Out-Null
        $r = Invoke-MusterInProc $script:fx ("Invoke-LintCommand -Paths @(" +
            "'tasks/backlog/p-01-a.md','tasks/backlog/p-02-review-a.md','tasks/backlog/p-99-integration.md')")
        ($r.Output -join "`n") | Should -Match 'LINT OK 3'
        $r.ExitCode | Should -Be 0
    }
    It 'check 10: heading order enforced' {
        $body = "# p-01-a: t`n`n## Steps`n`n1. Ensure x.`n`n## Context`n`nx`n`n## Acceptance`n`n- x"
        New-TaskFile -Fixture $script:fx -Folder backlog -Id 'p-01-a' -Body $body | Out-Null
        $r = Invoke-MusterInProc $script:fx "Invoke-LintCommand -Paths @('tasks/backlog/p-01-a.md')"
        $r.ExitCode | Should -Be 1
        ($r.Output -join "`n") | Should -Match 'headings missing or out of order'
    }
    It 'check 11: full mode requires exactly one seq-99 strong integration task depending on all' {
        New-TaskFile -Fixture $script:fx -Folder backlog -Id 'p-01-a' | Out-Null
        $r = Invoke-MusterInProc $script:fx "Invoke-LintCommand -Paths @('tasks/backlog/p-01-a.md')"
        $r.ExitCode | Should -Be 1
        ($r.Output -join "`n") | Should -Match 'integration'
    }
    It 'lite mode: skips 11/12, exempts self-collision, rejects generation' -Tag 'CM-ARG-LINT' {
        New-TaskFile -Fixture $script:fx -Folder staging -Id 'p-01-fix-a' -Type fix `
            -ExtraFront @('fixes: p-01-a') | Out-Null
        $r = Invoke-MusterInProc $script:fx "Invoke-LintCommand -Lite -Paths @('tasks/staging/p-01-fix-a.md')"
        $r.ExitCode | Should -Be 0
        New-TaskFile -Fixture $script:fx -Folder staging -Id 'p-02-fix-b' -Type fix `
            -ExtraFront @('fixes: p-02-b', 'generation: 1') | Out-Null
        $r2 = Invoke-MusterInProc $script:fx "Invoke-LintCommand -Lite -Paths @('tasks/staging/p-02-fix-b.md')"
        $r2.ExitCode | Should -Be 1
    }
    It 'check 13: commit_paths non-empty on impl' {
        $p = Join-Path $script:fx 'tasks/backlog/p-01-a.md'
        New-TaskFile -Fixture $script:fx -Folder backlog -Id 'p-01-a' | Out-Null
        $text = [IO.File]::ReadAllText($p) -replace "commit_paths:`n  - src/out.txt", 'commit_paths: []'
        [IO.File]::WriteAllText($p, $text)
        $r = Invoke-MusterInProc $script:fx "Invoke-LintCommand -Paths @('tasks/backlog/p-01-a.md')"
        $r.ExitCode | Should -Be 1
        ($r.Output -join "`n") | Should -Match 'commit_paths empty'
    }
    It 'schema: non-kebab plan value is rejected by lint (B1)' {
        New-TaskFile -Fixture $script:fx -Folder inbox -Id 'p-01-a' -Plan 'my plan (v2)' | Out-Null
        $r = Invoke-MusterInProc $script:fx "Invoke-LintCommand -Paths @('tasks/inbox/p-01-a.md')"
        $r.ExitCode | Should -Be 1
        ($r.Output -join "`n") | Should -Match 'plan: must be kebab-case'
    }
    It 'check 14: test-runner verify with empty protected is rejected (M2)' {
        New-TaskFile -Fixture $script:fx -Folder inbox -Id 'p-01-a' -Protected @() `
            -CommitPaths @('src/app.py') -VerifyCmd 'dotnet test' | Out-Null
        $r = Invoke-MusterInProc $script:fx "Invoke-LintCommand -Paths @('tasks/inbox/p-01-a.md')"
        $r.ExitCode | Should -Be 1
        ($r.Output -join "`n") | Should -Match 'verify runs a test runner but protected is empty'
    }
    It 'check 14: runner names as incidental substrings do not false-positive (M2 follow-up)' {
        New-TaskFile -Fixture $script:fx -Folder inbox -Id 'p-01-a' -Protected @() `
            -CommitPaths @('src/app.py') -VerifyCmd 'echo dotnet testing framework' | Out-Null
        $r = Invoke-MusterInProc $script:fx "Invoke-LintCommand -Paths @('tasks/inbox/p-01-a.md')"
        ($r.Output -join "`n") | Should -Not -Match 'verify runs a test runner but protected is empty'
    }
    It 'check 5b: test-looking verify path only in commit_paths is rejected (M2)' {
        New-TaskFile -Fixture $script:fx -Folder inbox -Id 'p-01-a' -Protected @('README.md') `
            -CommitPaths @('tests/test_app.py', 'src/app.py') -VerifyCmd 'pytest tests/test_app.py' | Out-Null
        $r = Invoke-MusterInProc $script:fx "Invoke-LintCommand -Paths @('tasks/inbox/p-01-a.md')"
        $r.ExitCode | Should -Be 1
        ($r.Output -join "`n") | Should -Match "verify test path 'tests/test_app.py' only in commit_paths"
    }
    It 'protected test path passes both new checks' {
        New-TaskFile -Fixture $script:fx -Folder inbox -Id 'p-01-a' -Protected @('tests/test_app.py') `
            -CommitPaths @('src/app.py') -VerifyCmd 'pytest tests/test_app.py' | Out-Null
        $r = Invoke-MusterInProc $script:fx "Invoke-LintCommand -Paths @('tasks/inbox/p-01-a.md')"
        ($r.Output -join "`n") | Should -Not -Match 'test runner but protected is empty'
        ($r.Output -join "`n") | Should -Not -Match 'only in commit_paths'
    }
}
