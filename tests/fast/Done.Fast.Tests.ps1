BeforeAll {
    . (Join-Path $PSScriptRoot '../MusterFixture.ps1')
    . (Join-Path $PSScriptRoot 'InProcHarness.ps1')
}

Describe 'Invoke-DoneCommand (in-process) - impl + preconditions' {
    BeforeEach { $script:fx = New-SharedMusterFixture }
    AfterEach { }

    BeforeAll {
        function Add-ClaimedImpl {
            New-TaskFile -Fixture $script:fx -Folder inbox -Id 'p-01-a' -CommitPaths @('src/out.txt') `
                -VerifyCmd 'git --version' -Commit | Out-Null
            Invoke-MusterInProc $script:fx 'Invoke-ClaimCommand -Harness claude -Tier any' | Out-Null
            New-Item -ItemType Directory (Join-Path $script:fx 'src') -Force | Out-Null
            [IO.File]::WriteAllText((Join-Path $script:fx 'src/out.txt'), 'payload')
        }
    }

    It 'refuses when doing/ is empty' -Tag 'CM-DONE-FAIL' {
        $r = Invoke-MusterInProc $script:fx 'Invoke-DoneCommand'
        $r.ExitCode | Should -Be 1
        $r.Output[0] | Should -Match '^MUSTER refuse: doing/ is empty'
    }
    It 'refuses a verdict on impl tasks' -Tag 'CM-ARG-DONE' {
        Add-ClaimedImpl
        $r = Invoke-MusterInProc $script:fx "Invoke-DoneCommand -Verdict pass"
        $r.ExitCode | Should -Be 1
        ($r.Output -join "`n") | Should -Match 'no verdict on impl/fix'
    }
    It 'completes an impl task: files in done/, single commit, session-over line' -Tag 'CM-DONE-OK' {
        Add-ClaimedImpl
        $r = Invoke-MusterInProc $script:fx 'Invoke-DoneCommand'
        $r.ExitCode | Should -Be 0
        $r.Output[-1] | Should -Match 'Done: p-01-a\. Promoted: none\. Do not claim another task\. Session over\.'
        Test-Path (Join-Path $script:fx 'tasks/done/p-01-a.md') | Should -BeTrue
        Test-Path (Join-Path $script:fx 'tasks/done/p-01-a.result.md') | Should -BeTrue
        (Get-FixtureCommits $script:fx)[0] | Should -Be 'muster(p): done p-01-a'
        (git -C $script:fx status --porcelain) | Should -BeNullOrEmpty
    }
    It 'refuses when the done-check verify fails' {
        New-TaskFile -Fixture $script:fx -Folder inbox -Id 'p-01-a' -CommitPaths @('src/out.txt') `
            -VerifyCmd 'git frobnicate' -Commit | Out-Null
        Invoke-MusterInProc $script:fx 'Invoke-ClaimCommand -Harness claude -Tier any' | Out-Null
        $r = Invoke-MusterInProc $script:fx 'Invoke-DoneCommand'
        $r.ExitCode | Should -Be 1
        ($r.Output -join "`n") | Should -Match 'MUSTER refuse: done-check verify failed'
        Test-Path (Join-Path $script:fx 'tasks/doing/p-01-a.md') | Should -BeTrue
    }
    It 'refuses when a protected file was modified' {
        Add-ClaimedImpl
        [IO.File]::WriteAllText((Join-Path $script:fx 'README.md'), 'tampered')
        $r = Invoke-MusterInProc $script:fx 'Invoke-DoneCommand'
        $r.ExitCode | Should -Be 1
        ($r.Output -join "`n") | Should -Match 'MUSTER refuse: protected file\(s\) modified: README\.md\.'
    }
    It 'prints the counts-only board line directly before the terminal line' -Tag 'CM-TERMINAL' {
        New-TaskFile -Fixture $script:fx -Folder inbox -Id 'p-02-b' -Commit | Out-Null
        Add-ClaimedImpl
        $r = Invoke-MusterInProc $script:fx 'Invoke-DoneCommand'
        $r.ExitCode | Should -Be 0
        $r.Output[-1] | Should -Match '^Done: p-01-a\. .*Session over\.$'
        $r.Output[-2] | Should -Be 'Board: run 1 | review 0 | backlog 0 | failed 0 | done 1'
    }
    It 'allows a task to create the protected test it is graded by (self-authored grader)' {
        New-TaskFile -Fixture $script:fx -Folder inbox -Id 'p-01-a' `
            -Protected @('tests/test_geom.py') -CommitPaths @('tests/test_geom.py') `
            -VerifyCmd 'git --version' -Commit | Out-Null
        Invoke-MusterInProc $script:fx 'Invoke-ClaimCommand -Harness claude -Tier any' | Out-Null
        New-Item -ItemType Directory (Join-Path $script:fx 'tests') -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $script:fx 'tests/test_geom.py'), "def test_it():`n    assert True`n")
        $r = Invoke-MusterInProc $script:fx 'Invoke-DoneCommand'
        $r.ExitCode | Should -Be 0
        ($r.Output -join "`n") | Should -Match 'Done: p-01-a\.'
        Test-Path (Join-Path $script:fx 'tasks/done/p-01-a.md') | Should -BeTrue
    }
    It 'still refuses when a pre-existing protected file is deleted' {
        Add-ClaimedImpl
        Remove-Item (Join-Path $script:fx 'README.md')
        $r = Invoke-MusterInProc $script:fx 'Invoke-DoneCommand'
        $r.ExitCode | Should -Be 1
        ($r.Output -join "`n") | Should -Match 'MUSTER refuse: protected file\(s\) modified: README\.md\.'
    }
    It 'refuses out-of-scope changes' {
        Add-ClaimedImpl
        [IO.File]::WriteAllText((Join-Path $script:fx 'stray.txt'), 'x')
        $r = Invoke-MusterInProc $script:fx 'Invoke-DoneCommand'
        $r.ExitCode | Should -Be 1
        ($r.Output -join "`n") | Should -Match 'MUSTER refuse: changed outside commit_paths: stray\.txt\. Revert strays or stop for a human\.'
    }
    It 'refuses changes to the protocol surface under tasks/ (D27)' {
        Add-ClaimedImpl
        [IO.File]::AppendAllText((Join-Path $script:fx 'tasks/RUNNER.md'), "tampered`n")
        $r = Invoke-MusterInProc $script:fx 'Invoke-DoneCommand'
        $r.ExitCode | Should -Be 1
        ($r.Output -join "`n") | Should -Match 'changed outside commit_paths: tasks/RUNNER\.md'
    }
    It 'lists promoted ids in the session-over line' {
        New-TaskFile -Fixture $script:fx -Folder backlog -Id 'p-03-c' -DependsOn @('p-01-a') -Commit | Out-Null
        Add-ClaimedImpl
        ((Invoke-MusterInProc $script:fx 'Invoke-DoneCommand').Output -join "`n") | Should -Match 'Done: p-01-a\. Promoted: p-03-c\.'
    }
}

Describe 'Invoke-DoneCommand (in-process) - review + integration' {
    BeforeEach { $script:fx = New-SharedMusterFixture }
    AfterEach { }

    BeforeAll {
        function Add-ClaimedReview {
            New-TaskFile -Fixture $script:fx -Folder done -Id 'p-01-a' -Commit | Out-Null
            New-TaskFile -Fixture $script:fx -Folder inbox -Id 'p-02-review-a' -Type review -Tier strong `
                -DependsOn @('p-01-a') -ExtraFront @('reviews: p-01-a') -Commit | Out-Null
            Invoke-MusterInProc $script:fx 'Invoke-ClaimCommand -Harness claude -Tier strong' | Out-Null
            [IO.File]::WriteAllText((Join-Path $script:fx 'tasks/doing/p-02-review-a.notes.md'), 'finding: bad naming')
        }
        function Add-StagedFix {
            param([string]$Slug = 'naming')
            New-TaskFile -Fixture $script:fx -Folder staging -Id "p-01-fix-$Slug" -Type fix `
                -CommitPaths @('src/out.txt') -ExtraFront @('fixes: p-01-a') | Out-Null
        }
        function Add-ClaimedIntegration {
            New-TaskFile -Fixture $script:fx -Folder inbox -Id 'p-99-integration' -Type integration -Tier strong -Commit | Out-Null
            Invoke-MusterInProc $script:fx 'Invoke-ClaimCommand -Harness claude -Tier strong' | Out-Null
            [IO.File]::WriteAllText((Join-Path $script:fx 'tasks/doing/p-99-integration.notes.md'), 'drift: a vs b')
        }
    }

    It 'review pass requires notes and folds them' {
        Add-ClaimedReview
        $r = Invoke-MusterInProc $script:fx "Invoke-DoneCommand -Verdict pass"
        $r.ExitCode | Should -Be 0
        (Get-Content (Join-Path $script:fx 'tasks/done/p-02-review-a.result.md') -Raw) |
            Should -Match '(?s)- verdict: pass.*## Findings.*bad naming'
    }
    It 'accepts a valid fix: stamps gen 1, queues it, cycles the review task (exit 0)' {
        Add-ClaimedReview
        Add-StagedFix
        $r = Invoke-MusterInProc $script:fx "Invoke-DoneCommand -Verdict fail"
        $r.ExitCode | Should -Be 0
        $r.Output[-1] | Should -Match 'Review failed\. Fix p-01-fix1-naming queued \(generation 1 of 2\)\. Session over\.'
        Test-Path (Join-Path $script:fx 'tasks/inbox/p-01-fix1-naming.md') | Should -BeTrue
        (Get-Content (Join-Path $script:fx 'tasks/backlog/p-02-review-a.md') -Raw) | Should -Match '(?m)^  - p-01-fix1-naming$'
        (Get-FixtureCommits $script:fx)[0] | Should -Be 'muster(p): reject p-01-a gen1'
    }
    It 'refuses to spawn generation 3: review task fails terminally (exit 3)' {
        New-TaskFile -Fixture $script:fx -Folder done -Id 'p-01-fix1-naming' -Type fix `
            -ExtraFront @('fixes: p-01-a', 'generation: 1') -Commit | Out-Null
        New-TaskFile -Fixture $script:fx -Folder done -Id 'p-01-fix2-naming' -Type fix `
            -ExtraFront @('fixes: p-01-a', 'generation: 2') -Commit | Out-Null
        Add-ClaimedReview
        Add-StagedFix -Slug 'third'
        $r = Invoke-MusterInProc $script:fx "Invoke-DoneCommand -Verdict fail"
        $r.ExitCode | Should -Be 3
        $r.Output[-1] | Should -Match 'Review cap hit \(2 fix generations\)\. p-01-a chain needs a human\. Session over\.'
        Test-Path (Join-Path $script:fx 'tasks/failed/p-02-review-a.md') | Should -BeTrue
        (Get-FixtureCommits $script:fx)[0] | Should -Be 'muster(p): fail p-02-review-a'
    }
    It 'review fail with a red done-check still cycles the fix (D29/M4, exit 0)' {
        New-TaskFile -Fixture $script:fx -Folder done -Id 'p-01-a' -Commit | Out-Null
        New-TaskFile -Fixture $script:fx -Folder inbox -Id 'p-02-review-a' -Type review -Tier strong `
            -DependsOn @('p-01-a') -ExtraFront @('reviews: p-01-a') -VerifyCmd 'git frobnicate' -Commit | Out-Null
        Invoke-MusterInProc $script:fx 'Invoke-ClaimCommand -Harness claude -Tier strong' | Out-Null
        [IO.File]::WriteAllText((Join-Path $script:fx 'tasks/doing/p-02-review-a.notes.md'), 'build broke under review')
        Add-StagedFix
        $r = Invoke-MusterInProc $script:fx "Invoke-DoneCommand -Verdict fail"
        $r.ExitCode | Should -Be 0
        (Get-Content (Join-Path $script:fx 'tasks/backlog/p-02-review-a.gen1.result.md') -Raw) |
            Should -Match '- verify: FAIL \(done-check red - see verify\.log\)'
    }
    It 'files the integration task to failed/ with findings and exits 3' {
        Add-ClaimedIntegration
        $r = Invoke-MusterInProc $script:fx "Invoke-DoneCommand -Verdict fail"
        $r.ExitCode | Should -Be 3
        $r.Output[-1] | Should -Match 'Integration review failed\. Bring tasks/failed/p-99-integration\.result\.md'
        Test-Path (Join-Path $script:fx 'tasks/failed/p-99-integration.result.md') | Should -BeTrue
        (Get-FixtureCommits $script:fx)[0] | Should -Be 'muster(p): fail p-99-integration'
    }
    It 'refuses when staging/ holds no fix' {
        Add-ClaimedReview
        $r = Invoke-MusterInProc $script:fx 'Invoke-DoneCommand -Verdict fail'
        $r.ExitCode | Should -Be 1
        ($r.Output -join "`n") | Should -Match 'MUSTER refuse: done fail needs exactly one valid fix task in tasks/staging/'
    }
    It 'refuses an invalid staged fix and leaves it in place' {
        Add-ClaimedReview
        New-TaskFile -Fixture $script:fx -Folder staging -Id 'p-01-fix-x' -Type fix `
            -ExtraFront @('fixes: p-09-other') | Out-Null   # fixes does not match reviews
        $r = Invoke-MusterInProc $script:fx 'Invoke-DoneCommand -Verdict fail'
        $r.ExitCode | Should -Be 1
        Test-Path (Join-Path $script:fx 'tasks/staging/p-01-fix-x.md') | Should -BeTrue
    }
    It 'refuses when staging/ is not empty' {
        Add-ClaimedIntegration
        New-TaskFile -Fixture $script:fx -Folder staging -Id 'p-01-fix-x' -Type fix `
            -ExtraFront @('fixes: p-01-a') | Out-Null
        $r = Invoke-MusterInProc $script:fx 'Invoke-DoneCommand -Verdict fail'
        $r.ExitCode | Should -Be 1
        ($r.Output -join "`n") | Should -Match 'MUSTER refuse: integration done fail accepts no fix task - clear tasks/staging/\.'
    }
    It 'records a red done-check on integration fail instead of refusing (M4)' {
        New-TaskFile -Fixture $script:fx -Folder inbox -Id 'p-99-integration' -Type integration -Tier strong `
            -VerifyCmd 'git frobnicate' -Commit | Out-Null
        Invoke-MusterInProc $script:fx 'Invoke-ClaimCommand -Harness claude -Tier strong' | Out-Null
        [IO.File]::WriteAllText((Join-Path $script:fx 'tasks/doing/p-99-integration.notes.md'), 'suite broken: frobnicate')
        $r = Invoke-MusterInProc $script:fx 'Invoke-DoneCommand -Verdict fail'
        $r.ExitCode | Should -Be 3
        ($r.Output -join "`n") | Should -Match 'Integration review failed\.'
        Test-Path (Join-Path $script:fx 'tasks/failed/p-99-integration.result.md') | Should -BeTrue
        (Get-Content (Join-Path $script:fx 'tasks/failed/p-99-integration.verify.log') -Raw) |
            Should -Match '=== done-check'
        (Get-Content (Join-Path $script:fx 'tasks/failed/p-99-integration.result.md') -Raw) |
            Should -Match '- verify: FAIL \(done-check red - see verify\.log\)'
        (Get-Content (Join-Path $script:fx 'tasks/failed/p-99-integration.result.md') -Raw) |
            Should -Not -Match 'p-99-integration\.result\.md'
    }
    It 'still refuses a pass verdict when the done-check fails' {
        New-TaskFile -Fixture $script:fx -Folder inbox -Id 'p-99-integration' -Type integration -Tier strong `
            -VerifyCmd 'git frobnicate' -Commit | Out-Null
        Invoke-MusterInProc $script:fx 'Invoke-ClaimCommand -Harness claude -Tier strong' | Out-Null
        [IO.File]::WriteAllText((Join-Path $script:fx 'tasks/doing/p-99-integration.notes.md'), 'looks fine')
        $r = Invoke-MusterInProc $script:fx 'Invoke-DoneCommand -Verdict pass'
        $r.ExitCode | Should -Be 1
        ($r.Output -join "`n") | Should -Match 'MUSTER refuse: done-check verify failed'
    }
}
