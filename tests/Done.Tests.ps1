BeforeAll { . (Join-Path $PSScriptRoot 'MusterFixture.ps1') }

Describe 'bin/done - preconditions and pass path' {
    BeforeEach { $script:fx = New-MusterFixture }
    AfterEach { Remove-MusterFixture $script:fx }

    BeforeAll {
        function Add-ClaimedImpl {
            # Inbox task claimed via the real claim script, then work done in-scope.
            New-TaskFile -Fixture $script:fx -Folder inbox -Id 'p-01-a' -CommitPaths @('src/out.txt') `
                -VerifyCmd 'git --version' -Commit | Out-Null
            Invoke-MusterClaim $script:fx | Out-Null
            New-Item -ItemType Directory (Join-Path $script:fx 'src') -Force | Out-Null
            [IO.File]::WriteAllText((Join-Path $script:fx 'src/out.txt'), 'payload')
        }
    }

    It 'refuses when doing/ is empty' {
        (Invoke-Muster $script:fx 'done').Exit | Should -Be 1
    }
    It 'refuses a verdict on impl tasks and requires one on review tasks' {
        Add-ClaimedImpl
        $r = Invoke-Muster $script:fx 'done' @('pass')
        $r.Exit | Should -Be 1
        $r.Text | Should -Match 'no verdict on impl/fix'
    }
    It 'completes an impl task: sidecars in done/, single completion commit, session-over line' {
        Add-ClaimedImpl
        $r = Invoke-Muster $script:fx 'done'
        $r.Exit | Should -Be 0
        $r.Text | Should -Match 'Done: p-01-a\. Promoted: none\. Do not claim another task\. Session over\.'
        Test-Path (Join-Path $script:fx 'tasks/done/p-01-a.md') | Should -BeTrue
        Test-Path (Join-Path $script:fx 'tasks/done/p-01-a.result.md') | Should -BeTrue
        Test-Path (Join-Path $script:fx 'tasks/done/p-01-a.verify.log') | Should -BeTrue
        (Get-FixtureCommits $script:fx)[0] | Should -Be 'muster(p): done p-01-a'
        (git -C $script:fx status --porcelain) | Should -BeNullOrEmpty
        # done-check was logged and did not consume an attempt
        $log = Get-Content (Join-Path $script:fx 'tasks/done/p-01-a.verify.log') -Raw
        $log | Should -Match '=== done-check'
    }
    It 'refuses when the done-check verify fails' {
        New-TaskFile -Fixture $script:fx -Folder inbox -Id 'p-01-a' -CommitPaths @('src/out.txt') `
            -VerifyCmd 'git frobnicate' -Commit | Out-Null
        Invoke-MusterClaim $script:fx | Out-Null
        $r = Invoke-Muster $script:fx 'done'
        $r.Exit | Should -Be 1
        $r.Text | Should -Match 'MUSTER refuse: done-check verify failed'
        Test-Path (Join-Path $script:fx 'tasks/doing/p-01-a.md') | Should -BeTrue
    }
    It 'refuses when a protected file was modified' {
        Add-ClaimedImpl
        [IO.File]::WriteAllText((Join-Path $script:fx 'README.md'), 'tampered')
        $r = Invoke-Muster $script:fx 'done'
        $r.Exit | Should -Be 1
        $r.Text | Should -Match 'MUSTER refuse: protected file\(s\) modified: README\.md\. Revert them; the verify definition is not yours to change\.'
    }
    It 'refuses out-of-scope changes' {
        Add-ClaimedImpl
        [IO.File]::WriteAllText((Join-Path $script:fx 'stray.txt'), 'x')
        $r = Invoke-Muster $script:fx 'done'
        $r.Exit | Should -Be 1
        $r.Text | Should -Match 'MUSTER refuse: changed outside commit_paths: stray\.txt\. Revert strays or stop for a human\.'
    }
    It 'refuses changes to the protocol surface under tasks/ (D27)' {
        Add-ClaimedImpl
        [IO.File]::AppendAllText((Join-Path $script:fx 'tasks/RUNNER.md'), "tampered`n")
        $r = Invoke-Muster $script:fx 'done'
        $r.Exit | Should -Be 1
        $r.Text | Should -Match 'changed outside commit_paths: tasks/RUNNER\.md'
    }
    It 'review pass requires notes and folds them' {
        New-TaskFile -Fixture $script:fx -Folder inbox -Id 'p-02-review-a' -Type review -Tier strong `
            -ExtraFront @('reviews: p-01-a') -Commit | Out-Null
        Invoke-MusterClaim $script:fx -Tier strong | Out-Null
        $r = Invoke-Muster $script:fx 'done' @('pass')
        $r.Exit | Should -Be 1
        $r.Text | Should -Match 'MUSTER refuse: verdict needs tasks/doing/p-02-review-a\.notes\.md with findings\.'
        [IO.File]::WriteAllText((Join-Path $script:fx 'tasks/doing/p-02-review-a.notes.md'), 'all good')
        $r2 = Invoke-Muster $script:fx 'done' @('pass')
        $r2.Exit | Should -Be 0
        (Get-Content (Join-Path $script:fx 'tasks/done/p-02-review-a.result.md') -Raw) |
            Should -Match '(?s)- verdict: pass.*## Findings.*all good'
    }
    It 'lists promoted ids in the session-over line' {
        # backlog entry committed BEFORE the claim: a commit landing on tasks/ after
        # claim (even an unrelated backlog add) trips the done scope guard (D27),
        # same guard the preceding test exercises directly - so this has to predate claim.
        New-TaskFile -Fixture $script:fx -Folder backlog -Id 'p-03-c' -DependsOn @('p-01-a') -Commit | Out-Null
        Add-ClaimedImpl
        (Invoke-Muster $script:fx 'done').Text | Should -Match 'Done: p-01-a\. Promoted: p-03-c\.'
    }
}
