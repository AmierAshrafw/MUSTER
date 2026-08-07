BeforeAll { . (Join-Path $PSScriptRoot 'MusterFixture.ps1') }

Describe 'bin/verify' {
    BeforeEach { $script:fx = New-MusterFixture }
    AfterEach { Remove-MusterFixture $script:fx }

    BeforeAll {
        function New-DoingTask {
            param([string]$VerifyCmd = 'git --version', [string]$ExpectExit = '0')
            New-TaskFile -Fixture $script:fx -Folder doing -Id 'p-01-a' -VerifyCmd $VerifyCmd `
                -ExpectExit $ExpectExit -ExtraFront @('claimed_at: 2026-08-07T00:00:00Z') -Commit | Out-Null
        }
    }

    It 'refuses when doing/ is empty' {
        $r = Invoke-Muster $script:fx 'verify'
        $r.Exit | Should -Be 1
        $r.Text | Should -Match '^MUSTER refuse:'
    }
    It 'passes a green task and logs attempt 1' {
        New-DoingTask
        $r = Invoke-Muster $script:fx 'verify'
        $r.Exit | Should -Be 0
        $r.Text | Should -Match 'VERIFY PASS \(attempt 1\)'
        (Get-Content (Join-Path $script:fx 'tasks/doing/p-01-a.verify.log') -Raw) |
            Should -Match '=== attempt 1 result: PASS'
    }
    It 'fails with exit 2 and increments attempts across runs' {
        New-DoingTask -VerifyCmd 'git frobnicate'
        (Invoke-Muster $script:fx 'verify').Exit | Should -Be 2
        $r2 = Invoke-Muster $script:fx 'verify'
        $r2.Exit | Should -Be 2
        $r2.Text | Should -Match 'VERIFY FAIL \(attempt 2 of 3\)'
    }
    It 'third failure is terminal: task moved to failed/, committed, exit 3' {
        New-DoingTask -VerifyCmd 'git frobnicate'
        Invoke-Muster $script:fx 'verify' | Out-Null
        Invoke-Muster $script:fx 'verify' | Out-Null
        $r3 = Invoke-Muster $script:fx 'verify'
        $r3.Exit | Should -Be 3
        $r3.Text | Should -Match 'VERIFY FAIL terminal'
        Test-Path (Join-Path $script:fx 'tasks/failed/p-01-a.md') | Should -BeTrue
        Test-Path (Join-Path $script:fx 'tasks/failed/p-01-a.verify.log') | Should -BeTrue
        Test-Path (Join-Path $script:fx 'tasks/doing/p-01-a.md') | Should -BeFalse
        (Get-FixtureCommits $script:fx)[0] | Should -Be 'muster(p): fail p-01-a'
    }
    It 'reads the verify block from HEAD, ignoring working-tree edits' {
        New-DoingTask -VerifyCmd 'git frobnicate'
        # Executor tampers: rewrite the committed task with an always-green cmd, unstaged.
        $path = Join-Path $script:fx 'tasks/doing/p-01-a.md'
        $text = [IO.File]::ReadAllText($path) -replace 'git frobnicate', 'git --version'
        [IO.File]::WriteAllText($path, $text)
        (Invoke-Muster $script:fx 'verify').Exit | Should -Be 2
    }
}
