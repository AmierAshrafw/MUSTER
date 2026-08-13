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
