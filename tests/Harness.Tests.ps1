BeforeAll {
    . (Join-Path $PSScriptRoot 'MusterFixture.ps1')
    . (Join-Path $PSScriptRoot 'bench/FixtureStrategies.ps1')
}

Describe 'fixture harness' {
    It 'creates a git repo with the full tasks tree' {
        $fx = New-MusterFixture
        try {
            foreach ($f in 'backlog', 'inbox', 'doing', 'done', 'failed', 'archive', 'staging', 'bin') {
                Test-Path (Join-Path $fx "tasks/$f") | Should -BeTrue
            }
            @(git -C $fx log --oneline).Count | Should -Be 1
        }
        finally { Remove-MusterFixture $fx }
    }
    It 'writes a task file that starts and ends with frontmatter markers' {
        $fx = New-MusterFixture
        try {
            $p = New-TaskFile -Fixture $fx
            $lines = Get-Content $p
            $lines[0] | Should -Be '---'
            ($lines | Where-Object { $_ -eq '---' }).Count | Should -Be 2
        }
        finally { Remove-MusterFixture $fx }
    }
    It 'New-MusterFixture satisfies the fixture contract' {
        $s = (Get-FixtureStrategies)['init']
        { Assert-FixtureContract -NewFixture $s.New -RemoveFixture $s.Remove -Template '' } |
            Should -Not -Throw
    }
    It 'Invoke-Muster refuses to spawn under MUSTER_DEVLOOP' {
        $fx = New-MusterFixture
        try {
            $env:MUSTER_DEVLOOP = '1'
            { Invoke-Muster $fx 'status' } | Should -Throw '*MUSTER_DEVLOOP*'
        }
        finally {
            Remove-Item Env:MUSTER_DEVLOOP -ErrorAction SilentlyContinue
            Remove-MusterFixture $fx
        }
    }
}
