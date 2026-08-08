BeforeAll { . (Join-Path $PSScriptRoot 'MusterFixture.ps1') }

Describe 'bin/status' {
    BeforeEach { $script:fx = New-MusterFixture }
    AfterEach { Remove-MusterFixture $script:fx }

    It 'prints the empty-board line and exits 0 on an empty board' {
        $r = Invoke-Muster $script:fx 'status'
        $r.Exit | Should -Be 0
        $r.Text | Should -Match 'MUSTER: board empty - nothing sharded or all archived\.'
    }
    It 'prints the status block with the dispatch split and exits 0' {
        New-TaskFile -Fixture $script:fx -Folder inbox -Id 'p-01-a' -Commit | Out-Null
        New-TaskFile -Fixture $script:fx -Folder inbox -Id 'p-02-review-a' -Type review -Tier strong -Commit | Out-Null
        $r = Invoke-Muster $script:fx 'status'
        $r.Exit | Should -Be 0
        $r.Out[0] | Should -Match '^MUSTER status @'
        $r.Text | Should -Match '\(run 1, review 1\) \[p-01-a, p-02-review-a\]'
    }
    It 'flags invalid inbox files in the split' {
        New-TaskFile -Fixture $script:fx -Folder inbox -Id 'p-01-a' -Commit | Out-Null
        [IO.File]::WriteAllText((Join-Path $script:fx 'tasks/inbox/p-02-broken.md'), "no frontmatter`n", $script:Utf8NoBom)
        $r = Invoke-Muster $script:fx 'status'
        $r.Exit | Should -Be 0
        $r.Text | Should -Match '\(run 1, review 0, invalid 1\)'
    }
    It 'shows STALE and DEAD markers like the claim print' {
        New-TaskFile -Fixture $script:fx -Folder doing -Id 'p-01-a' `
            -ExtraFront @('claimed_at: 2026-08-01T00:00:00Z') -Commit | Out-Null
        New-TaskFile -Fixture $script:fx -Folder failed -Id 'p-02-b' -Commit | Out-Null
        New-TaskFile -Fixture $script:fx -Folder backlog -Id 'p-03-c' -DependsOn @('p-02-b') -Commit | Out-Null
        $r = Invoke-Muster $script:fx 'status'
        $r.Exit | Should -Be 0
        $r.Text | Should -Match 'STALE'
        $r.Text | Should -Match '1 DEAD: p-03-c behind failed p-02-b'
    }
}
