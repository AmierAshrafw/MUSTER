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
