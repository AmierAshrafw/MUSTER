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
        # the sidecar must not list ITSELF in files_changed: assembling it straight into the
        # destination (or a .tmp beside it) creates the file before the changed-paths sweep,
        # and `ls-files --others` then picks it up. Engine-divergent when it regresses.
        $result = Get-Content (Join-Path $script:fx 'tasks/done/p-01-a.result.md') -Raw
        $result | Should -Match '(?m)^  - src/out\.txt$'
        $result | Should -Not -Match 'tasks/done/p-01-a\.result\.md'
    }
    It 'prints the counts-only board line directly before the terminal line' {
        New-TaskFile -Fixture $script:fx -Folder inbox -Id 'p-02-b' -Commit | Out-Null
        Add-ClaimedImpl
        $r = Invoke-Muster $script:fx 'done'
        $r.Exit | Should -Be 0
        $r.Out[-1] | Should -Match '^Done: p-01-a\. .*Session over\.$'
        $r.Out[-2] | Should -Be 'Board: run 1 | review 0 | backlog 0 | failed 0 | done 1'
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
    It 'allows a task to create the protected test it is graded by (self-authored grader)' {
        # A greenfield test the same task both writes AND is graded by: listed in
        # protected (so it freezes for downstream consumers) AND commit_paths (this
        # task authors it). It does not exist at claim, so creating it is the
        # sanctioned self-authoring case (D30) - the protected guard must NOT refuse
        # a newly-created protected path. Pre-existing graders stay frozen: the
        # 'refuses when a protected file was modified' test above is the counterpart.
        New-TaskFile -Fixture $script:fx -Folder inbox -Id 'p-01-a' `
            -Protected @('tests/test_geom.py') -CommitPaths @('tests/test_geom.py') `
            -VerifyCmd 'git --version' -Commit | Out-Null
        Invoke-MusterClaim $script:fx | Out-Null
        New-Item -ItemType Directory (Join-Path $script:fx 'tests') -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $script:fx 'tests/test_geom.py'), "def test_it():`n    assert True`n")
        $r = Invoke-Muster $script:fx 'done'
        $r.Exit | Should -Be 0
        $r.Text | Should -Match 'Done: p-01-a\.'
        Test-Path (Join-Path $script:fx 'tasks/done/p-01-a.md') | Should -BeTrue
    }
    It 'still refuses when a pre-existing protected file is deleted' {
        # The narrowed guard keys off the diff arm (git diff --name-only since claim),
        # which reports deletions as well as edits - a tracked grader cannot be removed
        # to sidestep the freeze.
        Add-ClaimedImpl
        Remove-Item (Join-Path $script:fx 'README.md')
        $r = Invoke-Muster $script:fx 'done'
        $r.Exit | Should -Be 1
        $r.Text | Should -Match 'MUSTER refuse: protected file\(s\) modified: README\.md\.'
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
        $gen1Result = Get-Content (Join-Path $script:fx 'tasks/backlog/p-02-review-a.gen1.result.md') -Raw
        $gen1Result | Should -Match '(?s)- status: cycled.*- verdict: fail.*finding: bad naming'
        # done-check passed here (clean env, reviewer found a code-level issue) - the
        # verify line must keep saying pass, not be dragged into FAIL by the verdict alone.
        $gen1Result | Should -Match '- verify: pass \(done-check only\)'
        # cycled sidecar must not list itself either (done_fail_review's own write site)
        $gen1Result | Should -Not -Match 'p-02-review-a\.gen1\.result\.md'
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
    It 'review fail with a red done-check still cycles the fix (M4)' {
        # Add-ClaimedReview uses the default green verify; rebuild it red here.
        New-TaskFile -Fixture $script:fx -Folder done -Id 'p-01-a' -Commit | Out-Null
        New-TaskFile -Fixture $script:fx -Folder inbox -Id 'p-02-review-a' -Type review -Tier strong `
            -DependsOn @('p-01-a') -ExtraFront @('reviews: p-01-a') -VerifyCmd 'git frobnicate' -Commit | Out-Null
        Invoke-MusterClaim $script:fx -Tier strong | Out-Null
        [IO.File]::WriteAllText((Join-Path $script:fx 'tasks/doing/p-02-review-a.notes.md'), 'build broke under review')
        Add-StagedFix
        $r = Invoke-Muster $script:fx 'done' @('fail')
        $r.Exit | Should -Be 0
        $r.Text | Should -Match 'Review failed\. Fix p-01-fix1-naming queued'
        # the done-check itself was red - the sidecar's verify line must say so, not
        # falsely claim pass while the co-located gen1.verify.log shows FAIL (M4 follow-up)
        $gen1Log = Get-Content (Join-Path $script:fx 'tasks/backlog/p-02-review-a.gen1.verify.log') -Raw
        $gen1Log | Should -Match '=== done-check result: FAIL'
        $gen1Result = Get-Content (Join-Path $script:fx 'tasks/backlog/p-02-review-a.gen1.result.md') -Raw
        $gen1Result | Should -Match '- verify: FAIL \(done-check red - see verify\.log\)'
    }
}

Describe 'bin/done fail - integration path' {
    BeforeEach { $script:fx = New-MusterFixture }
    AfterEach { Remove-MusterFixture $script:fx }

    BeforeAll {
        function Add-ClaimedIntegration {
            New-TaskFile -Fixture $script:fx -Folder inbox -Id 'p-99-integration' -Type integration -Tier strong `
                -Commit | Out-Null
            Invoke-MusterClaim $script:fx -Tier strong | Out-Null
            [IO.File]::WriteAllText((Join-Path $script:fx 'tasks/doing/p-99-integration.notes.md'), 'drift: a vs b')
        }
    }

    It 'files the integration task to failed/ with findings and exits 3' {
        Add-ClaimedIntegration
        $r = Invoke-Muster $script:fx 'done' @('fail')
        $r.Exit | Should -Be 3
        $r.Text | Should -Match 'Integration review failed\. Bring tasks/failed/p-99-integration\.result\.md to the orchestrator to shard a fix-up plan\. Session over\.'
        (Get-Content (Join-Path $script:fx 'tasks/failed/p-99-integration.result.md') -Raw) |
            Should -Match '(?s)- status: failed.*- verdict: fail.*drift: a vs b'
        (Get-FixtureCommits $script:fx)[0] | Should -Be 'muster(p): fail p-99-integration'
    }
    It 'refuses when staging/ is not empty' {
        Add-ClaimedIntegration
        New-TaskFile -Fixture $script:fx -Folder staging -Id 'p-01-fix-x' -Type fix `
            -ExtraFront @('fixes: p-01-a') | Out-Null
        $r = Invoke-Muster $script:fx 'done' @('fail')
        $r.Exit | Should -Be 1
        $r.Text | Should -Match 'MUSTER refuse: integration done fail accepts no fix task - clear tasks/staging/\.'
    }
    It 'records a red done-check on integration fail instead of refusing (M4)' {
        New-TaskFile -Fixture $script:fx -Folder inbox -Id 'p-99-integration' -Type integration -Tier strong `
            -VerifyCmd 'git frobnicate' -Commit | Out-Null
        Invoke-MusterClaim $script:fx -Tier strong | Out-Null
        [IO.File]::WriteAllText((Join-Path $script:fx 'tasks/doing/p-99-integration.notes.md'), 'suite broken: frobnicate')
        $r = Invoke-Muster $script:fx 'done' @('fail')
        $r.Exit | Should -Be 3
        $r.Text | Should -Match 'Integration review failed\.'
        Test-Path (Join-Path $script:fx 'tasks/failed/p-99-integration.result.md') | Should -BeTrue
        (Get-Content (Join-Path $script:fx 'tasks/failed/p-99-integration.verify.log') -Raw) |
            Should -Match '=== done-check'
        # the done-check was red - result.md must not contradict the co-located verify.log
        # by claiming pass on the verdict:fail line above it (M4 follow-up)
        (Get-Content (Join-Path $script:fx 'tasks/failed/p-99-integration.result.md') -Raw) |
            Should -Match '- verify: FAIL \(done-check red - see verify\.log\)'
        # failed/ sidecar must not list itself (move_to_failed_with_result's write site)
        (Get-Content (Join-Path $script:fx 'tasks/failed/p-99-integration.result.md') -Raw) |
            Should -Not -Match 'p-99-integration\.result\.md'
    }
    It 'still refuses a pass verdict when the done-check fails' {
        New-TaskFile -Fixture $script:fx -Folder inbox -Id 'p-99-integration' -Type integration -Tier strong `
            -VerifyCmd 'git frobnicate' -Commit | Out-Null
        Invoke-MusterClaim $script:fx -Tier strong | Out-Null
        [IO.File]::WriteAllText((Join-Path $script:fx 'tasks/doing/p-99-integration.notes.md'), 'looks fine')
        $r = Invoke-Muster $script:fx 'done' @('pass')
        $r.Exit | Should -Be 1
        $r.Text | Should -Match 'MUSTER refuse: done-check verify failed'
    }
}
