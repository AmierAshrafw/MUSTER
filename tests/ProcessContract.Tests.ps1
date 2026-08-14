BeforeAll { . (Join-Path $PSScriptRoot 'MusterFixture.ps1') }

Describe 'child-process contract gaps (Phase 4 matrix)' {
    BeforeAll {
        function New-NoGitRuntimeDir {
            # Installed tasks/bin layout WITHOUT a git repo - exercises the
            # failing-native-command refusal class (Get-RepoRoot) end to end.
            $dir = Join-Path ([IO.Path]::GetTempPath()) ('muster-nogit-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
            New-Item -ItemType Directory -Path (Join-Path $dir 'tasks/bin') -Force | Out-Null
            Copy-Item (Join-Path $script:RepoRoot 'runtime/bin/*') (Join-Path $dir 'tasks/bin')
            return $dir
        }
    }

    It 'claim refuses outside a git repository with exit 1' -Tag 'CM-GITFAIL' {
        $dir = New-NoGitRuntimeDir
        try {
            $r = Invoke-Muster $dir 'claim' @('-Harness', 'claude', '-Tier', 'any')
            $r.Exit | Should -Be 1
            $r.Text | Should -Match 'MUSTER refuse'
        }
        finally { Remove-Item -Recurse -Force $dir }
    }
    It 'status refuses outside a git repository with exit 1' -Tag 'CM-STATUS-FAIL' {
        $dir = New-NoGitRuntimeDir
        try {
            $r = Invoke-Muster $dir 'status'
            $r.Exit | Should -Be 1
            $r.Text | Should -Match 'MUSTER refuse'
        }
        finally { Remove-Item -Recurse -Force $dir }
    }
    It 'promote refuses outside a git repository with exit 1' -Tag 'CM-PROMOTE-FAIL' {
        $dir = New-NoGitRuntimeDir
        try {
            $r = Invoke-Muster $dir 'promote'
            $r.Exit | Should -Be 1
            $r.Text | Should -Match 'MUSTER refuse'
        }
        finally { Remove-Item -Recurse -Force $dir }
    }
    It 'done refuses an uncommitted doing task' -Tag 'CM-CO-UNCOMMITTED' {
        $fx = New-MusterFixture
        try {
            New-TaskFile -Fixture $fx -Folder doing -Id 'p-01-a' `
                -ExtraFront @('claimed_at: 2026-08-01T00:00:00Z') | Out-Null   # deliberately NOT committed
            $r = Invoke-Muster $fx 'done'
            $r.Exit | Should -Be 1
            $r.Text | Should -Match 'MUSTER refuse'
        }
        finally { Remove-MusterFixture $fx }
    }
    It 'claim surfaces the promote skip warning for malformed backlog files' -Tag 'CM-PROMOTE-WARN-CLAIM' {
        $fx = New-MusterFixture
        try {
            [IO.File]::WriteAllText((Join-Path $fx 'tasks/backlog/p-03-bad.md'), "no frontmatter here`n")
            git -c core.autocrlf=false -C $fx add 'tasks/backlog/p-03-bad.md'
            git -C $fx commit -qm 'fixture: bad backlog'
            New-TaskFile -Fixture $fx -Folder inbox -Id 'p-01-a' -Commit | Out-Null
            $r = Invoke-Muster $fx 'claim' @('-Harness', 'claude', '-Tier', 'any')
            $r.Text | Should -Match 'MUSTER warn: backlog/p-03-bad\.md frontmatter invalid - skipped by promote\.'
        }
        finally { Remove-MusterFixture $fx }
    }
}
