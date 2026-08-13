# In-process runspace harness. Runs a command function in a FRESH Windows PowerShell
# runspace cd'd into a fixture - clean session state, far cheaper than a ~1.8 s
# powershell.exe child. Dot-source AFTER MusterFixture.ps1 (needs $script:RepoRoot).
#
# KNOWN DIVERGENCE from the child-process tier: under the library's
# $ErrorActionPreference='Stop', a FAILING native command's stderr becomes a
# terminating NativeCommandError inside a hosted runspace, so a refusal that follows
# a failing git call (e.g. Get-RepoRoot outside a repo) surfaces as Invoke() throwing,
# not as a refusal CommandResult. A powershell.exe -File child does not behave this
# way. Such cases belong to the retained process tier.
Set-StrictMode -Version 2.0

function Invoke-MusterInProc {
    # $Command is a PowerShell expression string, e.g. 'Invoke-StatusCommand' or
    # "Invoke-LintCommand -Paths @('tasks/backlog/p-01-a.md')". Returns the CommandResult.
    param([string]$Fixture, [string]$Command)
    $lib = Join-Path $script:RepoRoot 'runtime/bin/_lib.ps1'
    $ps = [powershell]::Create()   # fresh runspace per call
    try {
        [void]$ps.AddScript(@"
Set-Location -LiteralPath '$Fixture'
. '$lib'
Invoke-CommandBoundary { $Command }
"@)
        $out = @($ps.Invoke())   # terminating errors surface here as a thrown exception
        if ($out.Count -eq 0) { throw "InProc command produced no output: $Command" }
        return $out[$out.Count - 1]
    }
    finally { $ps.Dispose() }
}
