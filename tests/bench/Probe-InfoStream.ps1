# Phase 4 spec D3: promote's malformed-backlog warning goes through Write-Host
# (Information stream), which the runspace harness drops. Probe: does the warning
# land in $ps.Streams.Information, and do any black-box assertions require its
# ORDER relative to stdout lines (fold-by-append would lose interleaving)?
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. (Join-Path $repoRoot 'tests/MusterFixture.ps1')

$fx = New-MusterFixture
try {
    # Malformed = no frontmatter block at all (matches the black-box source of truth,
    # tests/Promote.Tests.ps1:44). A valid-but-incomplete frontmatter (e.g. only 'id:')
    # parses clean - Read-TaskFile.Errors covers frontmatter PARSE errors, not schema -
    # so it gets promoted silently and produces no warning.
    [IO.File]::WriteAllText((Join-Path $fx 'tasks/backlog/p-03-bad.md'), "no frontmatter here`n")
    git -c core.autocrlf=false -C $fx add 'tasks/backlog/p-03-bad.md'
    git -C $fx commit -qm 'fixture: bad backlog'

    $lib = Join-Path $repoRoot 'runtime/bin/_lib.ps1'
    $ps = [powershell]::Create()
    try {
        [void]$ps.AddScript("Set-Location -LiteralPath '$fx'`n. '$lib'`nInvoke-CommandBoundary { Invoke-PromoteCommand }")
        $out = @($ps.Invoke())
        Write-Output "result output lines: $($out[-1].Output.Count)"
        Write-Output "information records: $($ps.Streams.Information.Count)"
        $ps.Streams.Information | ForEach-Object { Write-Output "  info: $_" }
    }
    finally { $ps.Dispose() }

    $child = Invoke-Muster $fx 'promote'
    Write-Output "child stdout: $($child.Text)"
}
finally { Remove-MusterFixture $fx }
