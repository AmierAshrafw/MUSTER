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

Describe 'bin/done fail - review path' {
    BeforeEach { $script:fx = New-MusterFixture }
    AfterEach { Remove-MusterFixture $script:fx }

    BeforeAll {
        function Add-ClaimedReview {
            # A done impl (reviewed target) + a claimed review task with findings notes.
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
    }

    It 'refuses when staging/ holds no fix' {
        Add-ClaimedReview
        $r = Invoke-Muster $script:fx 'done' @('fail')
        $r.Exit | Should -Be 1
        $r.Text | Should -Match 'MUSTER refuse: done fail needs exactly one valid fix task in tasks/staging/'
    }
    It 'refuses an invalid staged fix and leaves it in place' {
        Add-ClaimedReview
        New-TaskFile -Fixture $script:fx -Folder staging -Id 'p-01-fix-x' -Type fix `
            -ExtraFront @('fixes: p-09-other') | Out-Null   # fixes does not match reviews
        $r = Invoke-Muster $script:fx 'done' @('fail')
        $r.Exit | Should -Be 1
        Test-Path (Join-Path $script:fx 'tasks/staging/p-01-fix-x.md') | Should -BeTrue
    }
    It 'accepts a valid fix: stamps gen 1, queues it, cycles the review task' {
        Add-ClaimedReview
        Add-StagedFix
        $r = Invoke-Muster $script:fx 'done' @('fail')
        $r.Exit | Should -Be 0
        $r.Text | Should -Match 'Review failed\. Fix p-01-fix1-naming queued \(generation 1 of 2\)\. Session over\.'
        $fix = Get-Content (Join-Path $script:fx 'tasks/inbox/p-01-fix1-naming.md') -Raw
        $fix | Should -Match '(?m)^id: p-01-fix1-naming$'
        $fix | Should -Match '(?m)^generation: 1$'
        $fix | Should -Match '(?m)^# p-01-fix1-naming:'
        $review = Get-Content (Join-Path $script:fx 'tasks/backlog/p-02-review-a.md') -Raw
        $review | Should -Match '(?m)^  - p-01-fix1-naming$'
        Test-Path (Join-Path $script:fx 'tasks/backlog/p-02-review-a.gen1.result.md') | Should -BeTrue
        Test-Path (Join-Path $script:fx 'tasks/doing/p-02-review-a.verify.log') | Should -BeFalse
        Test-Path (Join-Path $script:fx 'tasks/staging/p-01-fix-naming.md') | Should -BeFalse
        (Get-FixtureCommits $script:fx)[0] | Should -Be 'muster(p): reject p-01-a gen1'
        (Get-Content (Join-Path $script:fx 'tasks/backlog/p-02-review-a.gen1.result.md') -Raw) |
            Should -Match '(?s)- status: cycled.*- verdict: fail.*finding: bad naming'
    }
    It 'refuses to spawn generation 3: review task fails terminally' {
        # two landed generations already exist - created BEFORE the claim so their
        # commits predate the claim commit (done fail still runs Test-DonePreconditions
        # before the fail branch; a post-claim tasks/ commit would trip the D27 scope guard).
        New-TaskFile -Fixture $script:fx -Folder done -Id 'p-01-fix1-naming' -Type fix `
            -ExtraFront @('fixes: p-01-a', 'generation: 1') -Commit | Out-Null
        New-TaskFile -Fixture $script:fx -Folder done -Id 'p-01-fix2-naming' -Type fix `
            -ExtraFront @('fixes: p-01-a', 'generation: 2') -Commit | Out-Null
        Add-ClaimedReview
        Add-StagedFix -Slug 'third'
        $r = Invoke-Muster $script:fx 'done' @('fail')
        $r.Exit | Should -Be 3
        $r.Text | Should -Match 'Review cap hit \(2 fix generations\)\. p-01-a chain needs a human\. Session over\.'
        Test-Path (Join-Path $script:fx 'tasks/failed/p-02-review-a.md') | Should -BeTrue
        Test-Path (Join-Path $script:fx 'tasks/failed/p-02-review-a.result.md') | Should -BeTrue
        Test-Path (Join-Path $script:fx 'tasks/staging/p-01-fix-third.md') | Should -BeFalse
        (Get-FixtureCommits $script:fx)[0] | Should -Be 'muster(p): fail p-02-review-a'
    }
}
