BeforeAll {
    . (Join-Path $PSScriptRoot '../../runtime/bin/_lib.ps1')
}

Describe 'CommandResult core' {
    It 'New-CommandResult defaults to empty output, exit 0' {
        $r = New-CommandResult
        $r.ExitCode | Should -Be 0
        @($r.Output).Count | Should -Be 0
    }
    It 'New-CommandResult carries output lines and exit code' {
        $r = New-CommandResult -Output @('a', 'b') -ExitCode 3
        $r.Output[1] | Should -Be 'b'
        $r.ExitCode | Should -Be 3
    }
    It 'Write-Refuse throws a MusterRefusal-tagged exception with the refusal line' {
        $err = $null
        try { Write-Refuse 'boom' } catch { $err = $_ }
        $err | Should -Not -BeNullOrEmpty
        $err.Exception.Message | Should -Be 'MUSTER refuse: boom'
        $err.Exception.Data.Contains('MusterRefusal') | Should -BeTrue
    }
    It 'Invoke-CommandBoundary converts a refusal into a CommandResult' {
        $r = Invoke-CommandBoundary { Write-Refuse 'nope' }
        $r.ExitCode | Should -Be 1
        $r.Output[0] | Should -Be 'MUSTER refuse: nope'
    }
    It 'Invoke-CommandBoundary passes a normal result through' {
        $r = Invoke-CommandBoundary { New-CommandResult -Output @('hi') }
        $r.ExitCode | Should -Be 0
        $r.Output[0] | Should -Be 'hi'
    }
    It 'Invoke-CommandBoundary rethrows non-refusal errors' {
        { Invoke-CommandBoundary { throw 'genuine bug' } } | Should -Throw
    }
}
