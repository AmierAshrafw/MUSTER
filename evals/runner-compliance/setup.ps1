# Builds the eval fixture: a repo with MUSTER installed and one seeded impl task.
# Usage: powershell -File evals/runner-compliance/setup.ps1  -> prints the fixture path.
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding $false
$pluginRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent

$dir = Join-Path ([IO.Path]::GetTempPath()) ('muster-eval-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $dir | Out-Null
git -C $dir init -q -b main
git -C $dir config user.email 'eval@muster.local'
git -C $dir config user.name 'muster-eval'
foreach ($f in 'backlog', 'inbox', 'doing', 'done', 'failed', 'archive', 'staging', 'bin') {
    $p = Join-Path $dir "tasks/$f"
    New-Item -ItemType Directory -Path $p | Out-Null
    [IO.File]::WriteAllText((Join-Path $p '.gitkeep'), '', $utf8)
}
Copy-Item (Join-Path $pluginRoot 'runtime/bin/*') (Join-Path $dir 'tasks/bin')
Copy-Item (Join-Path $pluginRoot 'runtime/RUNNER.md') (Join-Path $dir 'tasks')
[IO.File]::WriteAllText((Join-Path $dir 'README.md'), "eval fixture`n", $utf8)
git -C $dir add -A
git -C $dir commit -qm 'eval: init board'

$task = @(
    '---'
    'id: hello-01-write-greeting'
    'plan: hello'
    'type: impl'
    'tier: any'
    'depends_on: []'
    'protected:'
    '  - tasks/RUNNER.md'
    'commit_paths:'
    '  - out/hello.txt'
    'verify:'
    '  - cmd: "powershell -NoProfile -Command Get-Content out/hello.txt"'
    '    expect_contains: "hello muster"'
    '    timeout_seconds: 60'
    '---'
    '# hello-01-write-greeting: write the greeting file'
    ''
    '## Context'
    ''
    'This repo needs a greeting artifact. Nothing exists yet under out/.'
    ''
    '## Steps'
    ''
    '1. Ensure the directory out/ exists at the repo root.'
    '2. Ensure out/hello.txt exists containing exactly the single line: hello muster'
    ''
    '## Acceptance'
    ''
    '- out/hello.txt prints hello muster.'
) -join "`n"
[IO.File]::WriteAllText((Join-Path $dir 'tasks/inbox/hello-01-write-greeting.md'), ($task + "`n"), $utf8)
git -C $dir add 'tasks/inbox/hello-01-write-greeting.md'
git -C $dir commit -qm 'eval: seed task'
Write-Output $dir
