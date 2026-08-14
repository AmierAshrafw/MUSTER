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

    It 'refuses when doing/ is empty' -Tag 'CM-VERIFY-FAIL' {
        $r = Invoke-Muster $script:fx 'verify'
        $r.Exit | Should -Be 1
        $r.Text | Should -Match '^MUSTER refuse:'
    }
    It 'passes a green task and logs attempt 1' -Tag 'CM-VERIFY-OK' {
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
    It 'burns the attempt as a marker commit before running (M1/D28)' {
        New-DoingTask
        Invoke-Muster $script:fx 'verify' | Out-Null
        (Get-FixtureCommits $script:fx)[0] | Should -Be 'muster(p): attempt 1 p-01-a'
        # marker blob holds the header; the command output stays working-tree until
        # the next marker or the terminal move commits it
        $blob = @(git -C $script:fx show 'HEAD:tasks/doing/p-01-a.verify.log') -join "`n"
        $blob | Should -Match '=== attempt 1 '
        (Get-Content (Join-Path $script:fx 'tasks/doing/p-01-a.verify.log') -Raw) |
            Should -Match '=== attempt 1 result: PASS'
    }
    It 'attempt cap survives log deletion before every run (M1)' {
        New-DoingTask -VerifyCmd 'git frobnicate'
        Invoke-Muster $script:fx 'verify' | Out-Null
        # executor tampers: wipe the live log before each rerun to reset the counter
        Remove-Item (Join-Path $script:fx 'tasks/doing/p-01-a.verify.log')
        (Invoke-Muster $script:fx 'verify').Exit | Should -Be 2
        Remove-Item (Join-Path $script:fx 'tasks/doing/p-01-a.verify.log')
        $r3 = Invoke-Muster $script:fx 'verify'
        $r3.Exit | Should -Be 3
        $r3.Text | Should -Match 'VERIFY FAIL terminal'
        Test-Path (Join-Path $script:fx 'tasks/failed/p-01-a.md') | Should -BeTrue
    }
}
