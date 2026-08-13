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
