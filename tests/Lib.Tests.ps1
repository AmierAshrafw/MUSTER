BeforeAll {
    . (Join-Path $PSScriptRoot 'MusterFixture.ps1')
    . (Join-Path $PSScriptRoot '../runtime/bin/_lib.ps1')
}

Describe 'Get-TaskFiles' {
    It 'lists task md files only, sorted, excluding sidecars and gitkeep' {
        $fx = New-MusterFixture
        try {
            New-TaskFile -Fixture $fx -Folder done -Id 'p-02-b' | Out-Null
            New-TaskFile -Fixture $fx -Folder done -Id 'p-01-a' | Out-Null
            $done = Join-Path $fx 'tasks/done'
            [IO.File]::WriteAllText((Join-Path $done 'p-01-a.result.md'), 'x', $script:Utf8NoBom)
            [IO.File]::WriteAllText((Join-Path $done 'p-01-a.notes.md'), 'x', $script:Utf8NoBom)
            [IO.File]::WriteAllText((Join-Path $done 'p-01-a.verify.log'), 'x', $script:Utf8NoBom)
            $files = @(Get-TaskFiles $done)
            $files.Count | Should -Be 2
            $files[0].Name | Should -Be 'p-01-a.md'
            $files[1].Name | Should -Be 'p-02-b.md'
        }
        finally { Remove-MusterFixture $fx }
    }
}

Describe 'Get-IsoNow' {
    It 'returns UTC ISO 8601 with Z suffix' {
        Get-IsoNow | Should -Match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$'
    }
}

Describe 'Write-Utf8 / Add-Utf8' {
    It 'writes without BOM and appends' {
        $f = Join-Path ([IO.Path]::GetTempPath()) ("muster-$(New-Guid).txt")
        try {
            Write-Utf8 $f "a`n"
            Add-Utf8 $f "b`n"
            $bytes = [IO.File]::ReadAllBytes($f)
            $bytes[0] | Should -Be 97      # 'a', not 0xEF BOM
            (Get-Content $f) -join ',' | Should -Be 'a,b'
        }
        finally { Remove-Item $f -ErrorAction SilentlyContinue }
    }
}

Describe 'Get-AgeString' {
    It 'renders minutes, hours, days' {
        Get-AgeString ((Get-Date).ToUniversalTime().AddMinutes(-5).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'"))  | Should -Be '5m'
        Get-AgeString ((Get-Date).ToUniversalTime().AddHours(-3).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'"))    | Should -Be '3h'
        Get-AgeString ((Get-Date).ToUniversalTime().AddDays(-2).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'"))     | Should -Be '2d'
    }
}

Describe 'Read-Frontmatter' {
    It 'parses scalars, empty list, block list, and verify block' {
        $text = @(
            '---'
            'id: p-01-a'
            'plan: p'
            'type: impl'
            'tier: any'
            'depends_on: []'
            'protected:'
            '  - src/a.cs'
            '  - src/b.cs'
            'commit_paths:'
            '  - src/a.cs'
            'verify:'
            '  - cmd: "dotnet test X.csproj"'
            '    expect_exit: 0'
            '    timeout_seconds: 60'
            '  - cmd: "node check.js"'
            '    expect_contains: "SCHEMA OK"'
            '---'
            '# p-01-a: title'
        ) -join "`n"
        $r = Read-Frontmatter $text
        $r.Errors.Count | Should -Be 0
        $r.Fields['id'] | Should -Be 'p-01-a'
        @($r.Fields['depends_on']).Count | Should -Be 0
        @($r.Fields['protected']).Count | Should -Be 2
        @($r.Fields['verify']).Count | Should -Be 2
        $r.Fields['verify'][0]['cmd'] | Should -Be 'dotnet test X.csproj'
        $r.Fields['verify'][0]['expect_exit'] | Should -Be '0'
        $r.Fields['verify'][1]['expect_contains'] | Should -Be 'SCHEMA OK'
        $r.Body | Should -Match '^# p-01-a'
    }
    It 'errors on missing opening marker' {
        (Read-Frontmatter "id: x`n---`n").Errors.Count | Should -BeGreaterThan 0
    }
    It 'errors on missing closing marker' {
        (Read-Frontmatter "---`nid: x`n").Errors.Count | Should -BeGreaterThan 0
    }
    It 'errors on anchors and aliases' {
        (Read-Frontmatter "---`nid: &a x`n---`n").Errors.Count | Should -BeGreaterThan 0
    }
    It 'errors on a bare key with no items (must use [])' {
        (Read-Frontmatter "---`ndepends_on:`nid: x`n---`n").Errors.Count | Should -BeGreaterThan 0
    }
    It 'errors on unparseable lines' {
        (Read-Frontmatter "---`n  nested_map:`n    a: b`n---`n").Errors.Count | Should -BeGreaterThan 0
    }
    It 'strips double quotes from scalar values' {
        $r = Read-Frontmatter "---`nid: ""p-01-a""`n---`n"
        $r.Fields['id'] | Should -Be 'p-01-a'
    }
}

Describe 'Test-TaskSchema' {
    BeforeAll {
        function New-Fields([hashtable]$Over) {
            $f = @{
                id = 'p-01-a'; plan = 'p'; type = 'impl'; tier = 'any'
                depends_on = @()
                protected = @('src/a.cs'); commit_paths = @('src/a.cs')
                verify = @(, @{ cmd = 'git --version'; expect_exit = '0' })
            }
            foreach ($k in $Over.Keys) { $f[$k] = $Over[$k] }
            return $f
        }
    }
    It 'passes a valid impl task' {
        (Test-TaskSchema (New-Fields @{})).Count | Should -Be 0
    }
    It 'flags missing required fields' {
        $f = New-Fields @{}; $f.Remove('tier')
        (Test-TaskSchema $f) -join ';' | Should -Match 'tier'
    }
    It 'flags illegal enum values' {
        (Test-TaskSchema (New-Fields @{ type = 'chore' })).Count | Should -BeGreaterThan 0
        (Test-TaskSchema (New-Fields @{ tier = 'mega' })).Count | Should -BeGreaterThan 0
        (Test-TaskSchema (New-Fields @{ harness = 'gemini' })).Count | Should -BeGreaterThan 0
    }
    It 'requires reviews on review tasks and forbids commit_paths there' {
        $f = New-Fields @{ type = 'review' }
        $f.Remove('protected'); $f.Remove('commit_paths')
        (Test-TaskSchema $f) -join ';' | Should -Match 'reviews'
        $f['reviews'] = 'p-01-a'
        (Test-TaskSchema $f).Count | Should -Be 0
        $f['commit_paths'] = @('x')
        (Test-TaskSchema $f) -join ';' | Should -Match 'commit_paths'
    }
    It 'requires fixes on fix tasks and validates generation' {
        $f = New-Fields @{ type = 'fix'; fixes = 'p-01-a'; generation = '1' }
        (Test-TaskSchema $f).Count | Should -Be 0
        $f['generation'] = '3'
        (Test-TaskSchema $f).Count | Should -BeGreaterThan 0
    }
    It 'in staged mode generation must be absent' {
        $f = New-Fields @{ type = 'fix'; fixes = 'p-01-a' }
        (Test-TaskSchema $f -Staged).Count | Should -Be 0
        $f['generation'] = '1'
        (Test-TaskSchema $f -Staged) -join ';' | Should -Match 'generation'
    }
    It 'flags verify entries without expectation or with unknown keys' {
        (Test-TaskSchema (New-Fields @{ verify = @(, @{ cmd = 'git --version' }) })).Count | Should -BeGreaterThan 0
        (Test-TaskSchema (New-Fields @{ verify = @(, @{ cmd = 'x'; expect_exit = '0'; shell = 'bash' }) })).Count | Should -BeGreaterThan 0
        (Test-TaskSchema (New-Fields @{ verify = @(, @{ expect_exit = '0' }) })).Count | Should -BeGreaterThan 0
    }
    It 'flags non-integer expect_exit and timeout_seconds' {
        (Test-TaskSchema (New-Fields @{ verify = @(, @{ cmd = 'x'; expect_exit = 'zero' }) })).Count | Should -BeGreaterThan 0
        (Test-TaskSchema (New-Fields @{ verify = @(, @{ cmd = 'x'; expect_exit = '0'; timeout_seconds = 'long' }) })).Count | Should -BeGreaterThan 0
    }
    It 'flags a non-kebab id' {
        (Test-TaskSchema (New-Fields @{ id = 'P_01' })).Count | Should -BeGreaterThan 0
    }
}

Describe 'Split-CmdLine' {
    It 'splits on whitespace and honors double quotes' {
        $t = Split-CmdLine 'dotnet test "My Tests/X.csproj" -v q'
        $t.Count | Should -Be 5
        $t[2] | Should -Be 'My Tests/X.csproj'
    }
    It 'throws on unbalanced quotes' {
        { Split-CmdLine 'echo "oops' } | Should -Throw
    }
}

Describe 'Invoke-VerifyBlock' {
    BeforeEach { $script:fx = New-MusterFixture }
    AfterEach { Remove-MusterFixture $script:fx }

    It 'passing block writes PASS transcript and returns Pass' {
        $log = Join-Path $script:fx 'tasks/doing/t.verify.log'
        $entries = @(, @{ cmd = 'git --version'; expect_exit = '0'; expect_contains = 'git version' })
        $r = Invoke-VerifyBlock -Entries $entries -LogPath $log -Label 'attempt 1' -TaskId 't' -RepoRoot $script:fx
        $r.Pass | Should -BeTrue
        $raw = Get-Content $log -Raw
        $raw | Should -Match '(?m)^=== attempt 1 \| \d{4}.+\| task t \| HEAD [0-9a-f]+'
        $raw | Should -Match ([regex]::Escape('$ git --version'))
        $raw | Should -Match 'expect_exit 0 -> OK'
        $raw | Should -Match 'expect_contains "git version" -> OK'
        $raw | Should -Match '(?m)^=== attempt 1 result: PASS$'
    }
    It 'failing expectation stops at first failure and reports it' {
        $log = Join-Path $script:fx 'tasks/doing/t.verify.log'
        $entries = @(
            @{ cmd = 'git frobnicate'; expect_exit = '0' },
            @{ cmd = 'git --version'; expect_exit = '0' }
        )
        $r = Invoke-VerifyBlock -Entries $entries -LogPath $log -Label 'attempt 1' -TaskId 't' -RepoRoot $script:fx
        $r.Pass | Should -BeFalse
        $r.FirstFail | Should -Match 'git frobnicate'
        (Get-Content $log -Raw) | Should -Not -Match ([regex]::Escape('$ git --version'))
    }
    It 'missing executable fails the entry, not the script' {
        $log = Join-Path $script:fx 'tasks/doing/t.verify.log'
        $entries = @(, @{ cmd = 'muster-no-such-exe'; expect_exit = '0' })
        (Invoke-VerifyBlock -Entries $entries -LogPath $log -Label 'attempt 1' -TaskId 't' -RepoRoot $script:fx).Pass |
            Should -BeFalse
    }
    It 'timeout kills the process and fails' {
        $log = Join-Path $script:fx 'tasks/doing/t.verify.log'
        $entries = @(, @{ cmd = 'powershell -NoProfile -Command Start-Sleep 30'; expect_exit = '0'; timeout_seconds = '2' })
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $r = Invoke-VerifyBlock -Entries $entries -LogPath $log -Label 'attempt 1' -TaskId 't' -RepoRoot $script:fx
        $sw.Stop()
        $r.Pass | Should -BeFalse
        $sw.Elapsed.TotalSeconds | Should -BeLessThan 20
        (Get-Content $log -Raw) | Should -Match 'timeout 2s -> FAIL'
    }
}

Describe 'Get-AttemptCount' {
    It 'counts only attempt headers, not done-check or claim-probe' {
        $f = Join-Path ([IO.Path]::GetTempPath()) ("muster-log-$(New-Guid).log")
        try {
            $body = @(
                '=== attempt 1 | x | task t | HEAD a'
                '=== attempt 1 result: FAIL'
                '=== claim-probe | x | task t | HEAD a'
                '=== done-check | x | task t | HEAD a'
                '=== attempt 2 | x | task t | HEAD a'
            ) -join "`n"
            [IO.File]::WriteAllText($f, $body)
            Get-AttemptCount $f | Should -Be 2
        }
        finally { Remove-Item $f -ErrorAction SilentlyContinue }
    }
    It 'returns 0 for a missing file' {
        Get-AttemptCount (Join-Path ([IO.Path]::GetTempPath()) 'muster-nope.log') | Should -Be 0
    }
}

Describe 'completion machinery' {
    BeforeEach { $script:fx = New-MusterFixture }
    AfterEach { Remove-MusterFixture $script:fx }

    BeforeAll {
        function Add-ClaimedDoingTask {
            param([string]$Id = 'p-01-a', [string]$Type = 'impl', [string[]]$ExtraFront = @())
            $extra = @("claimed_at: 2026-08-07T01:00:00Z") + $ExtraFront
            New-TaskFile -Fixture $script:fx -Folder doing -Id $Id -Type $Type `
                -CommitPaths @('src/out.txt') -ExtraFront $extra -Commit | Out-Null
        }
    }

    It 'Get-ClaimCommit returns the last commit touching the doing path' {
        Add-ClaimedDoingTask
        Push-Location $script:fx
        try {
            . (Join-Path $script:RepoRoot 'runtime/bin/_lib.ps1')
            (Get-ClaimCommit -RepoRoot $script:fx -Name 'p-01-a.md') |
                Should -Be (git -C $script:fx rev-parse HEAD)
        }
        finally { Pop-Location }
    }
    It 'Complete-Task assembles the sidecar, moves files, folds promotions, one commit' {
        Add-ClaimedDoingTask
        New-TaskFile -Fixture $script:fx -Folder backlog -Id 'p-02-b' -DependsOn @('p-01-a') -Commit | Out-Null
        New-Item -ItemType Directory (Join-Path $script:fx 'src') | Out-Null
        [IO.File]::WriteAllText((Join-Path $script:fx 'src/out.txt'), 'payload')
        [IO.File]::WriteAllText((Join-Path $script:fx 'tasks/doing/p-01-a.notes.md'), 'one surprise')
        Push-Location $script:fx
        try {
            . (Join-Path $script:RepoRoot 'runtime/bin/_lib.ps1')
            $task = Read-TaskFile (Join-Path $script:fx 'tasks/doing/p-01-a.md')
            $cc = Get-ClaimCommit -RepoRoot $script:fx -Name 'p-01-a.md'
            $promoted = Complete-Task -RepoRoot $script:fx -TasksRoot (Join-Path $script:fx 'tasks') `
                -Fields $task.Fields -Id 'p-01-a' -ClaimCommit $cc
            $promoted | Should -Contain 'p-02-b'
        }
        finally { Pop-Location }
        $result = Get-Content (Join-Path $script:fx 'tasks/done/p-01-a.result.md') -Raw
        $result | Should -Match '(?m)^- status: done$'
        $result | Should -Match '(?m)^  - src/out.txt$'
        $result | Should -Match 'one surprise'
        Test-Path (Join-Path $script:fx 'tasks/doing/p-01-a.notes.md') | Should -BeFalse
        Test-Path (Join-Path $script:fx 'tasks/inbox/p-02-b.md') | Should -BeTrue
        (Get-FixtureCommits $script:fx)[0] | Should -Be 'muster(p): done p-01-a'
        (git -C $script:fx status --porcelain) | Should -BeNullOrEmpty
        (git -C $script:fx show --name-only --format= HEAD) | Should -Contain 'src/out.txt'
    }
    It 'review results fold notes into Findings' {
        Add-ClaimedDoingTask -Id 'p-02-review-a' -Type review -ExtraFront @('reviews: p-01-a')
        [IO.File]::WriteAllText((Join-Path $script:fx 'tasks/doing/p-02-review-a.notes.md'), 'looks solid')
        Push-Location $script:fx
        try {
            . (Join-Path $script:RepoRoot 'runtime/bin/_lib.ps1')
            $task = Read-TaskFile (Join-Path $script:fx 'tasks/doing/p-02-review-a.md')
            $cc = Get-ClaimCommit -RepoRoot $script:fx -Name 'p-02-review-a.md'
            [void](Complete-Task -RepoRoot $script:fx -TasksRoot (Join-Path $script:fx 'tasks') `
                -Fields $task.Fields -Id 'p-02-review-a' -ClaimCommit $cc -Verdict 'pass')
        }
        finally { Pop-Location }
        $result = Get-Content (Join-Path $script:fx 'tasks/done/p-02-review-a.result.md') -Raw
        $result | Should -Match '(?m)^- verdict: pass$'
        $result | Should -Match '(?s)## Findings.*looks solid'
    }
}
