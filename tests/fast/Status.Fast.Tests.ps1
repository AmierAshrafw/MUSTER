BeforeAll {
    . (Join-Path $PSScriptRoot '../MusterFixture.ps1')
    . (Join-Path $PSScriptRoot 'InProcHarness.ps1')
}

Describe 'Invoke-StatusCommand (in-process)' {
    BeforeEach { $script:fx = New-SharedMusterFixture }
    AfterEach { }

    It 'returns the empty-board line with exit 0' {
        $r = Invoke-MusterInProc $script:fx 'Invoke-StatusCommand'
        $r.ExitCode | Should -Be 0
        ($r.Output -join "`n") | Should -Match 'MUSTER: board empty - nothing sharded or all archived\.'
    }
    It 'returns the status block with the dispatch split' {
        New-TaskFile -Fixture $script:fx -Folder inbox -Id 'p-01-a' -Commit | Out-Null
        New-TaskFile -Fixture $script:fx -Folder inbox -Id 'p-02-review-a' -Type review -Tier strong -Commit | Out-Null
        $r = Invoke-MusterInProc $script:fx 'Invoke-StatusCommand'
        $r.ExitCode | Should -Be 0
        ($r.Output -join "`n") | Should -Match '^MUSTER status @'
        ($r.Output -join "`n") | Should -Match '\(run 1, review 1\) \[p-01-a, p-02-review-a\]'
    }
    It 'flags invalid inbox files in the split' {
        New-TaskFile -Fixture $script:fx -Folder inbox -Id 'p-01-a' -Commit | Out-Null
        [IO.File]::WriteAllText((Join-Path $script:fx 'tasks/inbox/p-02-broken.md'), "no frontmatter`n", $script:Utf8NoBom)
        $r = Invoke-MusterInProc $script:fx 'Invoke-StatusCommand'
        ($r.Output -join "`n") | Should -Match '\(run 1, review 0, invalid 1\)'
    }
    It 'shows STALE and DEAD markers' {
        New-TaskFile -Fixture $script:fx -Folder doing -Id 'p-01-a' `
            -ExtraFront @('claimed_at: 2026-08-01T00:00:00Z') -Commit | Out-Null
        New-TaskFile -Fixture $script:fx -Folder failed -Id 'p-02-b' -Commit | Out-Null
        New-TaskFile -Fixture $script:fx -Folder backlog -Id 'p-03-c' -DependsOn @('p-02-b') -Commit | Out-Null
        $r = Invoke-MusterInProc $script:fx 'Invoke-StatusCommand'
        ($r.Output -join "`n") | Should -Match 'STALE'
        ($r.Output -join "`n") | Should -Match '1 DEAD: p-03-c behind failed p-02-b'
    }
}
