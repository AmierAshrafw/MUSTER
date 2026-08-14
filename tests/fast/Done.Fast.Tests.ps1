BeforeAll {
    . (Join-Path $PSScriptRoot '../MusterFixture.ps1')
    . (Join-Path $PSScriptRoot 'InProcHarness.ps1')
}

Describe 'Invoke-DoneCommand (in-process) - impl + preconditions' {
    BeforeEach { $script:fx = New-MusterFixture }
    AfterEach { Remove-MusterFixture $script:fx }

    BeforeAll {
        function Add-ClaimedImpl {
            New-TaskFile -Fixture $script:fx -Folder inbox -Id 'p-01-a' -CommitPaths @('src/out.txt') `
                -VerifyCmd 'git --version' -Commit | Out-Null
            Invoke-MusterClaim $script:fx | Out-Null
            New-Item -ItemType Directory (Join-Path $script:fx 'src') -Force | Out-Null
            [IO.File]::WriteAllText((Join-Path $script:fx 'src/out.txt'), 'payload')
        }
    }

    It 'refuses when doing/ is empty' {
        $r = Invoke-MusterInProc $script:fx 'Invoke-DoneCommand'
        $r.ExitCode | Should -Be 1
        $r.Output[0] | Should -Match '^MUSTER refuse: doing/ is empty'
    }
    It 'refuses a verdict on impl tasks' {
        Add-ClaimedImpl
        $r = Invoke-MusterInProc $script:fx "Invoke-DoneCommand -Verdict pass"
        $r.ExitCode | Should -Be 1
        ($r.Output -join "`n") | Should -Match 'no verdict on impl/fix'
    }
    It 'completes an impl task: files in done/, single commit, session-over line' {
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
        Invoke-MusterClaim $script:fx | Out-Null
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
}

Describe 'Invoke-DoneCommand (in-process) - review + integration' {
    BeforeEach { $script:fx = New-MusterFixture }
    AfterEach { Remove-MusterFixture $script:fx }

    BeforeAll {
        function Add-ClaimedReview {
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
        function Add-ClaimedIntegration {
            New-TaskFile -Fixture $script:fx -Folder inbox -Id 'p-99-integration' -Type integration -Tier strong -Commit | Out-Null
            Invoke-MusterClaim $script:fx -Tier strong | Out-Null
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
        Invoke-MusterClaim $script:fx -Tier strong | Out-Null
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
}
