BeforeAll { . (Join-Path $PSScriptRoot 'MusterFixture.ps1') }

Describe 'bin/claim' {
    BeforeEach { $script:fx = New-MusterFixture }
    AfterEach { Remove-MusterFixture $script:fx }

    It 'refuses without identity flags' -Tag 'CM-CLAIM-FAIL' {
        $r = Invoke-Muster $script:fx 'claim'
        $r.Exit | Should -Be 1
        $r.Text | Should -Match 'MUSTER refuse: claim requires'
    }
    It 'prints the empty-board line on an empty board' {
        $r = Invoke-MusterClaim $script:fx
        $r.Text | Should -Match 'MUSTER: board empty - nothing sharded or all archived\.'
        $r.Exit | Should -Be 1   # then refuses: nothing to claim
    }
    It 'prints the status block before any refusal' -Tag 'CM-ORDER' {
        New-TaskFile -Fixture $script:fx -Folder doing -Id 'p-01-a' `
            -ExtraFront @('claimed_at: 2026-08-01T00:00:00Z') -Commit | Out-Null
        $r = Invoke-MusterClaim $script:fx
        $r.Exit | Should -Be 1
        $r.Out[0] | Should -Match '^MUSTER status @'
        $r.Text | Should -Match '\(run 0, review 0\)'
        $r.Text | Should -Match 'STALE'
        $r.Text | Should -Match 'MUSTER refuse: doing/ occupied by p-01-a \(claimed \d+[mhd] ago\)\. One executor per checkout\. RECOVERY in RUNNER\.md\.'
    }
    It 'refuses on a stale staging file' {
        New-TaskFile -Fixture $script:fx -Folder inbox -Id 'p-01-a' -Commit | Out-Null
        New-TaskFile -Fixture $script:fx -Folder staging -Id 'p-01-fix-a' -Type fix `
            -ExtraFront @('fixes: p-01-a') | Out-Null
        $r = Invoke-MusterClaim $script:fx
        $r.Exit | Should -Be 1
        $r.Text | Should -Match 'MUSTER refuse: stale fix task in tasks/staging/: p-01-fix-a\.md\.'
    }
    It 'claims the lowest eligible filename, stamps claimed_at, commits' -Tag 'CM-CLAIM-OK' {
        New-TaskFile -Fixture $script:fx -Folder inbox -Id 'p-02-b' -Commit | Out-Null
        New-TaskFile -Fixture $script:fx -Folder inbox -Id 'p-01-a' -Commit | Out-Null
        $r = Invoke-MusterClaim $script:fx
        $r.Exit | Should -Be 0
        $r.Text | Should -Match 'Claimed p-01-a\. Follow tasks/RUNNER\.md\.'
        $doing = Join-Path $script:fx 'tasks/doing/p-01-a.md'
        Test-Path $doing | Should -BeTrue
        (Get-Content $doing -Raw) | Should -Match '(?m)^claimed_at: \d{4}-\d{2}-\d{2}T'
        (Get-FixtureCommits $script:fx)[0] | Should -Be 'muster(p): claim p-01-a'
        (git -C $script:fx status --porcelain) | Should -BeNullOrEmpty
    }
    It 'enforces tier pinning both directions' -Tag 'CM-ARG-CLAIM' {
        New-TaskFile -Fixture $script:fx -Folder inbox -Id 'p-01-a' -Tier strong -Type review `
            -ExtraFront @('reviews: p-00-x') -Commit | Out-Null
        $r = Invoke-MusterClaim $script:fx -Tier any
        $r.Exit | Should -Be 1
        $r.Text | Should -Match 'MUSTER refuse: nothing to claim for claude/any\.'
        New-TaskFile -Fixture $script:fx -Folder inbox -Id 'p-02-b' -Commit | Out-Null
        $r2 = Invoke-MusterClaim $script:fx -Tier strong    # strong sessions claim ONLY strong tasks
        $r2.Text | Should -Match 'Claimed p-01-a'
    }
    It 'skips tasks pinned to a different harness' {
        New-TaskFile -Fixture $script:fx -Folder inbox -Id 'p-01-a' -ExtraFront @('harness: codex') -Commit | Out-Null
        $r = Invoke-MusterClaim $script:fx -Harness claude
        $r.Text | Should -Match 'nothing to claim for claude/any'
    }
    It 'refuses loudly on malformed frontmatter, task stays in inbox' {
        $bad = Join-Path $script:fx 'tasks/inbox/p-01-bad.md'
        [IO.File]::WriteAllText($bad, "---`nid: p-01-bad`n---`nbody")
        git -c core.autocrlf=false -C $script:fx add 'tasks/inbox/p-01-bad.md'
        git -C $script:fx commit -qm 'fixture: bad task'
        $r = Invoke-MusterClaim $script:fx
        $r.Exit | Should -Be 1
        $r.Text | Should -Match 'MUSTER refuse: p-01-bad frontmatter invalid: .+\. Task left in inbox/ for a human\.'
        Test-Path $bad | Should -BeTrue
    }
    It 'refuses when the tree is dirty outside the selected task scope' {
        New-TaskFile -Fixture $script:fx -Folder inbox -Id 'p-01-a' -CommitPaths @('src/out.txt') -Commit | Out-Null
        [IO.File]::WriteAllText((Join-Path $script:fx 'stray.txt'), 'x')
        $r = Invoke-MusterClaim $script:fx
        $r.Exit | Should -Be 1
        $r.Text | Should -Match "MUSTER refuse: working tree dirty outside p-01-a's commit_paths: stray\.txt\. Likely leftovers from a failed or crashed task - see RECOVERY \(RUNNER\.md\), 'leftover dirt'\."
    }
    It 'tolerates dirt inside the selected task commit_paths and live doing/ sidecars' {
        New-TaskFile -Fixture $script:fx -Folder inbox -Id 'p-01-a' -CommitPaths @('src/out.txt') -Commit | Out-Null
        New-Item -ItemType Directory (Join-Path $script:fx 'src') | Out-Null
        [IO.File]::WriteAllText((Join-Path $script:fx 'src/out.txt'), 'half-done')
        [IO.File]::WriteAllText((Join-Path $script:fx 'tasks/doing/p-00-x.verify.log'), 'stale predecessor log')
        (Invoke-MusterClaim $script:fx).Exit | Should -Be 0
    }
    It 'refuses when a protocol file under tasks/ is dirty (D27)' {
        New-TaskFile -Fixture $script:fx -Folder inbox -Id 'p-01-a' -Commit | Out-Null
        [IO.File]::AppendAllText((Join-Path $script:fx 'tasks/RUNNER.md'), "tampered`n")
        $r = Invoke-MusterClaim $script:fx
        $r.Exit | Should -Be 1
        $r.Text | Should -Match "dirty outside p-01-a's commit_paths: tasks/RUNNER\.md"
    }
    It 'runs promote first: a satisfied backlog task becomes claimable in the same call' {
        New-TaskFile -Fixture $script:fx -Folder done -Id 'p-01-a' -Commit | Out-Null
        New-TaskFile -Fixture $script:fx -Folder backlog -Id 'p-02-b' -DependsOn @('p-01-a') -Commit | Out-Null
        $r = Invoke-MusterClaim $script:fx
        $r.Text | Should -Match 'Claimed p-02-b'
    }
    It 'prints the full task body before the Claimed line' {
        New-TaskFile -Fixture $script:fx -Folder inbox -Id 'p-01-a' -Commit | Out-Null
        $r = Invoke-MusterClaim $script:fx
        $r.Text | Should -Match '## Steps'
    }
    It 'ends the body flush against the Claimed line - no engine-specific blank' {
        # Both engines must render the task file exactly as `cat` does: the ps1 side once
        # emitted the file's own trailing newline on top of the one Write-Output adds,
        # so it printed a blank line the sh mirror never printed. Pin the tail sequence.
        New-TaskFile -Fixture $script:fx -Folder inbox -Id 'p-01-a' -Commit | Out-Null
        $r = Invoke-MusterClaim $script:fx
        $r.Exit | Should -Be 0
        $i = [array]::IndexOf($r.Out, 'Claimed p-01-a. Follow tasks/RUNNER.md.')
        $i | Should -BeGreaterThan 2
        $r.Out[$i - 1] | Should -Be '- Nothing.'      # last line of the fixture body
        $r.Out[$i - 2] | Should -Be ''                # the body's own blank line
        $r.Out[$i - 3] | Should -Be '## Acceptance'
        $r.Out[-1] | Should -Be 'Claimed p-01-a. Follow tasks/RUNNER.md.'
    }
}

Describe 'bin/claim - recovery probe' {
    BeforeEach { $script:fx = New-MusterFixture }
    AfterEach { Remove-MusterFixture $script:fx }

    BeforeAll {
        function Add-RecoveredTask {
            # Simulate the D12 crash shape + human recovery: claim, crash, human moves the
            # file back to inbox (committing only the move), dirty work left in the tree.
            New-TaskFile -Fixture $script:fx -Folder inbox -Id 'p-01-a' -CommitPaths @('src/out.txt') `
                -VerifyCmd 'powershell -NoProfile -Command Test-Path src/out.txt' -ExpectExit '0' `
                -ExtraFront @() -Commit | Out-Null
            # give the verify a content expectation so an absent file fails it
            $p = Join-Path $script:fx 'tasks/inbox/p-01-a.md'
            $t = [IO.File]::ReadAllText($p) -replace '    expect_exit: 0', "    expect_contains: ""True"""
            [IO.File]::WriteAllText($p, $t)
            git -c core.autocrlf=false -C $script:fx add 'tasks/inbox/p-01-a.md'
            git -C $script:fx commit -qm 'fixture: tighten verify'
            Invoke-MusterClaim $script:fx | Out-Null                       # first claim
            git -C $script:fx mv 'tasks/doing/p-01-a.md' 'tasks/inbox/p-01-a.md'   # human RECOVERY move
            git -C $script:fx commit -qm 'human: recover p-01-a'
            Remove-Item (Join-Path $script:fx 'tasks/doing/p-01-a.verify.log') -ErrorAction SilentlyContinue
        }
    }

    It 'auto-files a re-dispatched task whose verify is already green' {
        Add-RecoveredTask
        New-Item -ItemType Directory (Join-Path $script:fx 'src') -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $script:fx 'src/out.txt'), 'predecessor work')   # dirty green work
        $r = Invoke-MusterClaim $script:fx
        $r.Text | Should -Match 'Auto-filed p-01-a'
        $r.Text | Should -Match 'nothing to claim'      # looped back to selection, board now empty
        Test-Path (Join-Path $script:fx 'tasks/done/p-01-a.md') | Should -BeTrue
        (Get-Content (Join-Path $script:fx 'tasks/done/p-01-a.result.md') -Raw) |
            Should -Match 'auto-filed at claim: verify green before execution'
        (Get-Content (Join-Path $script:fx 'tasks/done/p-01-a.verify.log') -Raw) |
            Should -Match '=== claim-probe'
        (git -C $script:fx show --name-only --format= HEAD) | Should -Contain 'src/out.txt'
    }
    It 'does not probe a task with no prior claim history' {
        # Verify would be green pre-work (git --version) - must still be claimed normally.
        New-TaskFile -Fixture $script:fx -Folder inbox -Id 'p-01-a' -Commit | Out-Null
        $r = Invoke-MusterClaim $script:fx
        $r.Text | Should -Match 'Claimed p-01-a'
        Test-Path (Join-Path $script:fx 'tasks/doing/p-01-a.md') | Should -BeTrue
        Test-Path (Join-Path $script:fx 'tasks/doing/p-01-a.verify.log') | Should -BeFalse
    }
    It 'claims normally when the probe is red' {
        Add-RecoveredTask   # src/out.txt absent -> probe fails
        $r = Invoke-MusterClaim $script:fx
        $r.Text | Should -Match 'Claimed p-01-a'
        (Get-Content (Join-Path $script:fx 'tasks/doing/p-01-a.verify.log') -Raw) |
            Should -Match '=== claim-probe result: FAIL'
    }
}
