BeforeAll {
    . (Join-Path $PSScriptRoot '../MusterFixture.ps1')
    . (Join-Path $PSScriptRoot 'InProcHarness.ps1')
}

Describe 'Invoke-ClaimCommand (in-process)' {
    BeforeEach { $script:fx = New-SharedMusterFixture }
    AfterEach { }

    It 'prints the empty-board line then refuses nothing-to-claim (accumulate + return)' {
        $r = Invoke-MusterInProc $script:fx "Invoke-ClaimCommand -Harness claude -Tier any"
        $r.ExitCode | Should -Be 1
        ($r.Output -join "`n") | Should -Match 'MUSTER: board empty - nothing sharded or all archived\.'
        ($r.Output -join "`n") | Should -Match 'MUSTER refuse: nothing to claim for claude/any\.'
    }
    It 'prints the status block before an occupied refusal (D12)' -Tag 'CM-ORDER' {
        New-TaskFile -Fixture $script:fx -Folder doing -Id 'p-01-a' `
            -ExtraFront @('claimed_at: 2026-08-01T00:00:00Z') -Commit | Out-Null
        $r = Invoke-MusterInProc $script:fx "Invoke-ClaimCommand -Harness claude -Tier any"
        $r.ExitCode | Should -Be 1
        $r.Output[0] | Should -Match '^MUSTER status @'
        ($r.Output -join "`n") | Should -Match 'MUSTER refuse: doing/ occupied by p-01-a'
    }
    It 'claims the lowest eligible filename, stamps claimed_at, commits (exit 0)' -Tag 'CM-CLAIM-OK' {
        New-TaskFile -Fixture $script:fx -Folder inbox -Id 'p-02-b' -Commit | Out-Null
        New-TaskFile -Fixture $script:fx -Folder inbox -Id 'p-01-a' -Commit | Out-Null
        $r = Invoke-MusterInProc $script:fx "Invoke-ClaimCommand -Harness claude -Tier any"
        $r.ExitCode | Should -Be 0
        $r.Output[-1] | Should -Be 'Claimed p-01-a. Follow tasks/RUNNER.md.'
        (Get-Content (Join-Path $script:fx 'tasks/doing/p-01-a.md') -Raw) | Should -Match '(?m)^claimed_at: \d{4}-\d{2}-\d{2}T'
        (Get-FixtureCommits $script:fx)[0] | Should -Be 'muster(p): claim p-01-a'
        (git -C $script:fx status --porcelain) | Should -BeNullOrEmpty
    }
    It 'enforces tier pinning both directions' -Tag 'CM-ARG-CLAIM' {
        New-TaskFile -Fixture $script:fx -Folder inbox -Id 'p-01-a' -Tier strong -Type review `
            -ExtraFront @('reviews: p-00-x') -Commit | Out-Null
        $rAny = Invoke-MusterInProc $script:fx "Invoke-ClaimCommand -Harness claude -Tier any"
        $rAny.ExitCode | Should -Be 1
        ($rAny.Output -join "`n") | Should -Match 'MUSTER refuse: nothing to claim for claude/any\.'
        New-TaskFile -Fixture $script:fx -Folder inbox -Id 'p-02-b' -Commit | Out-Null
        $rStrong = Invoke-MusterInProc $script:fx "Invoke-ClaimCommand -Harness claude -Tier strong"
        ($rStrong.Output -join "`n") | Should -Match 'Claimed p-01-a'
    }
    It 'claim surfaces the promote skip warning for malformed backlog files' -Tag 'CM-PROMOTE-WARN-CLAIM' {
        [IO.File]::WriteAllText((Join-Path $script:fx 'tasks/backlog/p-03-bad.md'), "no frontmatter here`n")
        git -c core.autocrlf=false -C $script:fx add 'tasks/backlog/p-03-bad.md'
        git -C $script:fx commit -qm 'fixture: bad backlog'
        New-TaskFile -Fixture $script:fx -Folder inbox -Id 'p-01-a' -Commit | Out-Null
        $r = Invoke-MusterInProc $script:fx 'Invoke-ClaimCommand -Harness claude -Tier any'
        ($r.Output -join "`n") | Should -Match 'MUSTER warn: backlog/p-03-bad\.md frontmatter invalid - skipped by promote\.'
    }
    It 'refuses loudly on malformed frontmatter, task stays in inbox' {
        $bad = Join-Path $script:fx 'tasks/inbox/p-01-bad.md'
        [IO.File]::WriteAllText($bad, "---`nid: p-01-bad`n---`nbody")
        git -c core.autocrlf=false -C $script:fx add 'tasks/inbox/p-01-bad.md'
        git -C $script:fx commit -qm 'fixture: bad task'
        $r = Invoke-MusterInProc $script:fx "Invoke-ClaimCommand -Harness claude -Tier any"
        $r.ExitCode | Should -Be 1
        ($r.Output -join "`n") | Should -Match 'MUSTER refuse: p-01-bad frontmatter invalid: .+\. Task left in inbox/ for a human\.'
        Test-Path $bad | Should -BeTrue
    }
    It 'refuses when the tree is dirty outside the selected task scope' {
        New-TaskFile -Fixture $script:fx -Folder inbox -Id 'p-01-a' -CommitPaths @('src/out.txt') -Commit | Out-Null
        [IO.File]::WriteAllText((Join-Path $script:fx 'stray.txt'), 'x')
        $r = Invoke-MusterInProc $script:fx "Invoke-ClaimCommand -Harness claude -Tier any"
        $r.ExitCode | Should -Be 1
        ($r.Output -join "`n") | Should -Match "MUSTER refuse: working tree dirty outside p-01-a's commit_paths: stray\.txt\."
    }
    It 'refuses without identity flags' {
        $r = Invoke-MusterInProc $script:fx 'Invoke-ClaimCommand'
        $r.ExitCode | Should -Be 1
        ($r.Output -join "`n") | Should -Match 'MUSTER refuse: claim requires'
    }
    It 'refuses on a stale staging file' {
        New-TaskFile -Fixture $script:fx -Folder inbox -Id 'p-01-a' -Commit | Out-Null
        New-TaskFile -Fixture $script:fx -Folder staging -Id 'p-01-fix-a' -Type fix `
            -ExtraFront @('fixes: p-01-a') | Out-Null
        $r = Invoke-MusterInProc $script:fx 'Invoke-ClaimCommand -Harness claude -Tier any'
        $r.ExitCode | Should -Be 1
        ($r.Output -join "`n") | Should -Match 'MUSTER refuse: stale fix task in tasks/staging/: p-01-fix-a\.md\.'
    }
    It 'skips tasks pinned to a different harness' {
        New-TaskFile -Fixture $script:fx -Folder inbox -Id 'p-01-a' -ExtraFront @('harness: codex') -Commit | Out-Null
        $r = Invoke-MusterInProc $script:fx 'Invoke-ClaimCommand -Harness claude -Tier any'
        ($r.Output -join "`n") | Should -Match 'nothing to claim for claude/any'
    }
    It 'tolerates dirt inside the selected task commit_paths and live doing/ sidecars' {
        New-TaskFile -Fixture $script:fx -Folder inbox -Id 'p-01-a' -CommitPaths @('src/out.txt') -Commit | Out-Null
        New-Item -ItemType Directory (Join-Path $script:fx 'src') | Out-Null
        [IO.File]::WriteAllText((Join-Path $script:fx 'src/out.txt'), 'half-done')
        [IO.File]::WriteAllText((Join-Path $script:fx 'tasks/doing/p-00-x.verify.log'), 'stale predecessor log')
        (Invoke-MusterInProc $script:fx 'Invoke-ClaimCommand -Harness claude -Tier any').ExitCode | Should -Be 0
    }
    It 'refuses when a protocol file under tasks/ is dirty (D27)' {
        New-TaskFile -Fixture $script:fx -Folder inbox -Id 'p-01-a' -Commit | Out-Null
        [IO.File]::AppendAllText((Join-Path $script:fx 'tasks/RUNNER.md'), "tampered`n")
        $r = Invoke-MusterInProc $script:fx 'Invoke-ClaimCommand -Harness claude -Tier any'
        $r.ExitCode | Should -Be 1
        ($r.Output -join "`n") | Should -Match "dirty outside p-01-a's commit_paths: tasks/RUNNER\.md"
    }
    It 'runs promote first: a satisfied backlog task becomes claimable in the same call' {
        New-TaskFile -Fixture $script:fx -Folder done -Id 'p-01-a' -Commit | Out-Null
        New-TaskFile -Fixture $script:fx -Folder backlog -Id 'p-02-b' -DependsOn @('p-01-a') -Commit | Out-Null
        $r = Invoke-MusterInProc $script:fx 'Invoke-ClaimCommand -Harness claude -Tier any'
        ($r.Output -join "`n") | Should -Match 'Claimed p-02-b'
    }
    It 'prints the full task body before the Claimed line' {
        New-TaskFile -Fixture $script:fx -Folder inbox -Id 'p-01-a' -Commit | Out-Null
        $r = Invoke-MusterInProc $script:fx 'Invoke-ClaimCommand -Harness claude -Tier any'
        ($r.Output -join "`n") | Should -Match '## Steps'
    }
    It 'ends the body flush against the Claimed line - no engine-specific blank' {
        New-TaskFile -Fixture $script:fx -Folder inbox -Id 'p-01-a' -Commit | Out-Null
        $r = Invoke-MusterInProc $script:fx 'Invoke-ClaimCommand -Harness claude -Tier any'
        $r.ExitCode | Should -Be 0
        $i = [array]::IndexOf($r.Output, 'Claimed p-01-a. Follow tasks/RUNNER.md.')
        $i | Should -BeGreaterThan 2
        $r.Output[$i - 1] | Should -Be '- Nothing.'      # last line of the fixture body
        $r.Output[$i - 2] | Should -Be ''                # the body's own blank line
        $r.Output[$i - 3] | Should -Be '## Acceptance'
        $r.Output[-1] | Should -Be 'Claimed p-01-a. Follow tasks/RUNNER.md.'
    }
}

Describe 'Invoke-ClaimCommand (in-process) - recovery probe (D12)' {
    BeforeEach { $script:fx = New-SharedMusterFixture }
    AfterEach { }

    BeforeAll {
        function Add-RecoveredTask {
            New-TaskFile -Fixture $script:fx -Folder inbox -Id 'p-01-a' -CommitPaths @('src/out.txt') `
                -VerifyCmd 'cmd /c type src\out.txt' -ExpectExit '0' -Commit | Out-Null
            $p = Join-Path $script:fx 'tasks/inbox/p-01-a.md'
            $t = [IO.File]::ReadAllText($p) -replace '    expect_exit: 0', "    expect_contains: ""predecessor work"""
            [IO.File]::WriteAllText($p, $t)
            git -c core.autocrlf=false -C $script:fx add 'tasks/inbox/p-01-a.md'
            git -C $script:fx commit -qm 'fixture: tighten verify'
            Invoke-MusterInProc $script:fx 'Invoke-ClaimCommand -Harness claude -Tier any' | Out-Null
            git -C $script:fx mv 'tasks/doing/p-01-a.md' 'tasks/inbox/p-01-a.md'
            git -C $script:fx commit -qm 'human: recover p-01-a'
            Remove-Item (Join-Path $script:fx 'tasks/doing/p-01-a.verify.log') -ErrorAction SilentlyContinue
        }
    }

    It 'auto-files a re-dispatched task whose verify is already green (accumulate + return, exit 1)' {
        Add-RecoveredTask
        New-Item -ItemType Directory (Join-Path $script:fx 'src') -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $script:fx 'src/out.txt'), 'predecessor work')
        $r = Invoke-MusterInProc $script:fx "Invoke-ClaimCommand -Harness claude -Tier any"
        $r.ExitCode | Should -Be 1
        ($r.Output -join "`n") | Should -Match 'Auto-filed p-01-a'
        ($r.Output -join "`n") | Should -Match 'nothing to claim'
        Test-Path (Join-Path $script:fx 'tasks/done/p-01-a.md') | Should -BeTrue
    }
    It 'claims normally when the probe is red (exit 0)' {
        Add-RecoveredTask
        $r = Invoke-MusterInProc $script:fx "Invoke-ClaimCommand -Harness claude -Tier any"
        $r.ExitCode | Should -Be 0
        ($r.Output -join "`n") | Should -Match 'Claimed p-01-a'
        (Get-Content (Join-Path $script:fx 'tasks/doing/p-01-a.verify.log') -Raw) |
            Should -Match '=== claim-probe result: FAIL'
    }
    It 'does not probe a task with no prior claim history' {
        # Verify would be green pre-work (git --version) - must still be claimed normally.
        New-TaskFile -Fixture $script:fx -Folder inbox -Id 'p-01-a' -Commit | Out-Null
        $r = Invoke-MusterInProc $script:fx 'Invoke-ClaimCommand -Harness claude -Tier any'
        ($r.Output -join "`n") | Should -Match 'Claimed p-01-a'
        Test-Path (Join-Path $script:fx 'tasks/doing/p-01-a.md') | Should -BeTrue
        Test-Path (Join-Path $script:fx 'tasks/doing/p-01-a.verify.log') | Should -BeFalse
    }
}
