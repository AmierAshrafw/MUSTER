BeforeAll { . (Join-Path $PSScriptRoot 'MusterFixture.ps1') }

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
}
