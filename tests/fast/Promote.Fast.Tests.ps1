BeforeAll {
    . (Join-Path $PSScriptRoot '../MusterFixture.ps1')
    . (Join-Path $PSScriptRoot 'InProcHarness.ps1')
}

Describe 'Invoke-PromoteCommand (in-process)' {
    BeforeEach { $script:fx = New-SharedMusterFixture }

    It 'moves a backlog task whose deps are all in done/ and commits (exit 0, silent)' {
        New-TaskFile -Fixture $script:fx -Folder done -Id 'p-01-a' -Commit | Out-Null
        New-TaskFile -Fixture $script:fx -Folder backlog -Id 'p-02-b' -DependsOn @('p-01-a') -Commit | Out-Null
        $r = Invoke-MusterInProc $script:fx 'Invoke-PromoteCommand'
        $r.ExitCode | Should -Be 0
        Test-Path (Join-Path $script:fx 'tasks/inbox/p-02-b.md') | Should -BeTrue
        (Get-FixtureCommits $script:fx)[0] | Should -Be 'muster: promote 1'
    }
    It 'counts archived deps as satisfied' {
        New-TaskFile -Fixture $script:fx -Folder archive -Id 'p-01-a' -Commit | Out-Null
        New-TaskFile -Fixture $script:fx -Folder backlog -Id 'p-02-b' -DependsOn @('p-01-a') -Commit | Out-Null
        $r = Invoke-MusterInProc $script:fx 'Invoke-PromoteCommand'
        $r.ExitCode | Should -Be 0
        Test-Path (Join-Path $script:fx 'tasks/inbox/p-02-b.md') | Should -BeTrue
    }
    It 'leaves unsatisfied tasks in backlog, exits 0 silently' {
        New-TaskFile -Fixture $script:fx -Folder backlog -Id 'p-02-b' -DependsOn @('p-01-a') -Commit | Out-Null
        $r = Invoke-MusterInProc $script:fx 'Invoke-PromoteCommand'
        $r.ExitCode | Should -Be 0
        Test-Path (Join-Path $script:fx 'tasks/backlog/p-02-b.md') | Should -BeTrue
    }
    It 'with -NoCommit stages the rename without committing' {
        New-TaskFile -Fixture $script:fx -Folder done -Id 'p-01-a' -Commit | Out-Null
        New-TaskFile -Fixture $script:fx -Folder backlog -Id 'p-02-b' -DependsOn @('p-01-a') -Commit | Out-Null
        $r = Invoke-MusterInProc $script:fx 'Invoke-PromoteCommand -NoCommit'
        $r.ExitCode | Should -Be 0
        (git -C $script:fx status --porcelain) | Should -Match 'R  tasks/backlog/p-02-b\.md -> tasks/inbox/p-02-b\.md'
        (Get-FixtureCommits $script:fx)[0] | Should -Not -Match 'promote'
    }
    It 'skips malformed backlog files with a warning' {
        # Malformed = no frontmatter block (matches tests/Promote.Tests.ps1:44, the
        # black-box source of truth). A valid-but-incomplete frontmatter parses clean
        # and would be promoted silently - it does not trigger the warning. The warning
        # goes through Write-Host (Information stream); the harness fold surfaces it.
        [IO.File]::WriteAllText((Join-Path $script:fx 'tasks/backlog/p-03-bad.md'), "no frontmatter here`n")
        git -c core.autocrlf=false -C $script:fx add 'tasks/backlog/p-03-bad.md'
        git -C $script:fx commit -qm 'fixture: bad backlog'
        $r = Invoke-MusterInProc $script:fx 'Invoke-PromoteCommand'
        ($r.Output -join "`n") | Should -Match 'MUSTER warn: backlog/p-03-bad\.md frontmatter invalid - skipped by promote\.'
    }
}
