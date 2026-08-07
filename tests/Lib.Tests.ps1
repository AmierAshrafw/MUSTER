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
