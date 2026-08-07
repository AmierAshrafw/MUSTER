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
