BeforeAll { . (Join-Path $PSScriptRoot 'MusterFixture.ps1') }

Describe 'bin/claim' {
    BeforeEach { $script:fx = New-MusterFixture }
    AfterEach { Remove-MusterFixture $script:fx }

    It 'refuses without identity flags' {
        $r = Invoke-Muster $script:fx 'claim'
        $r.Exit | Should -Be 1
        $r.Text | Should -Match 'MUSTER refuse: claim requires'
    }
    It 'prints the empty-board line on an empty board' {
        $r = Invoke-MusterClaim $script:fx
        $r.Text | Should -Match 'MUSTER: board empty - nothing sharded or all archived\.'
        $r.Exit | Should -Be 1   # then refuses: nothing to claim
    }
    It 'prints the status block before any refusal' {
        New-TaskFile -Fixture $script:fx -Folder doing -Id 'p-01-a' `
            -ExtraFront @('claimed_at: 2026-08-01T00:00:00Z') -Commit | Out-Null
        $r = Invoke-MusterClaim $script:fx
        $r.Exit | Should -Be 1
        $r.Out[0] | Should -Match '^MUSTER status @'
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
    It 'claims the lowest eligible filename, stamps claimed_at, commits' {
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
    It 'enforces tier pinning both directions' {
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
        git -C $script:fx add 'tasks/inbox/p-01-bad.md'
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
        $r.Text | Should -Match "MUSTER refuse: working tree dirty outside p-01-a's commit_paths: stray\.txt\. Not this task's work - RECOVERY \(RUNNER\.md\)\."
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
}
