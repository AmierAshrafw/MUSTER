BeforeAll {
    . (Join-Path $PSScriptRoot '../MusterFixture.ps1')
    . (Join-Path $PSScriptRoot 'InProcHarness.ps1')
}

Describe 'Invoke-VerifyCommand (in-process)' {
    BeforeEach { $script:fx = New-SharedMusterFixture }
    AfterEach { }

    BeforeAll {
        function New-DoingTask {
            param([string]$VerifyCmd = 'git --version', [string]$ExpectExit = '0')
            New-TaskFile -Fixture $script:fx -Folder doing -Id 'p-01-a' -VerifyCmd $VerifyCmd `
                -ExpectExit $ExpectExit -ExtraFront @('claimed_at: 2026-08-07T00:00:00Z') -Commit | Out-Null
        }
    }

    It 'refuses when doing/ is empty' {
        $r = Invoke-MusterInProc $script:fx 'Invoke-VerifyCommand'
        $r.ExitCode | Should -Be 1
        $r.Output[0] | Should -Match '^MUSTER refuse: doing/ is empty'
    }
    It 'passes a green task and logs attempt 1 (exit 0)' {
        New-DoingTask
        $r = Invoke-MusterInProc $script:fx 'Invoke-VerifyCommand'
        $r.ExitCode | Should -Be 0
        $r.Output[-1] | Should -Match 'VERIFY PASS \(attempt 1\)'
        (Get-Content (Join-Path $script:fx 'tasks/doing/p-01-a.verify.log') -Raw) | Should -Match '=== attempt 1 result: PASS'
    }
    It 'fails with exit 2 and increments attempts across runs' {
        New-DoingTask -VerifyCmd 'git frobnicate'
        (Invoke-MusterInProc $script:fx 'Invoke-VerifyCommand').ExitCode | Should -Be 2
        $r2 = Invoke-MusterInProc $script:fx 'Invoke-VerifyCommand'
        $r2.ExitCode | Should -Be 2
        $r2.Output[-1] | Should -Match 'VERIFY FAIL \(attempt 2 of 3\)'
    }
    It 'third failure is terminal: task moved to failed/, exit 3' {
        New-DoingTask -VerifyCmd 'git frobnicate'
        Invoke-MusterInProc $script:fx 'Invoke-VerifyCommand' | Out-Null
        Invoke-MusterInProc $script:fx 'Invoke-VerifyCommand' | Out-Null
        $r3 = Invoke-MusterInProc $script:fx 'Invoke-VerifyCommand'
        $r3.ExitCode | Should -Be 3
        $r3.Output[-1] | Should -Match 'VERIFY FAIL terminal'
        Test-Path (Join-Path $script:fx 'tasks/failed/p-01-a.md') | Should -BeTrue
        Test-Path (Join-Path $script:fx 'tasks/doing/p-01-a.md') | Should -BeFalse
        (Get-FixtureCommits $script:fx)[0] | Should -Be 'muster(p): fail p-01-a'
    }
    It 'reads the verify block from HEAD, ignoring working-tree edits (D20 happy path)' {
        New-DoingTask -VerifyCmd 'git frobnicate'
        $path = Join-Path $script:fx 'tasks/doing/p-01-a.md'
        $text = [IO.File]::ReadAllText($path) -replace 'git frobnicate', 'git --version'
        [IO.File]::WriteAllText($path, $text)
        (Invoke-MusterInProc $script:fx 'Invoke-VerifyCommand').ExitCode | Should -Be 2
    }
    It 'burns the attempt as a marker commit before running (D28)' {
        New-DoingTask
        Invoke-MusterInProc $script:fx 'Invoke-VerifyCommand' | Out-Null
        (Get-FixtureCommits $script:fx)[0] | Should -Be 'muster(p): attempt 1 p-01-a'
    }
}
