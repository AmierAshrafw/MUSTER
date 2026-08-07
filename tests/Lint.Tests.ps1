BeforeAll { . (Join-Path $PSScriptRoot 'MusterFixture.ps1') }

Describe 'bin/lint' {
    BeforeEach { $script:fx = New-MusterFixture }
    AfterEach { Remove-MusterFixture $script:fx }

    BeforeAll {
        function New-GoodBatch {
            # Minimal lintable plan batch: one impl + review + integration.
            $impl = New-TaskFile -Fixture $script:fx -Folder backlog -Id 'p-01-a' -CommitPaths @('src/out.txt')
            $rev = New-TaskFile -Fixture $script:fx -Folder backlog -Id 'p-02-review-a' -Type review -Tier strong `
                -DependsOn @('p-01-a') -ExtraFront @('reviews: p-01-a')
            $int = New-TaskFile -Fixture $script:fx -Folder backlog -Id 'p-99-integration' -Type integration -Tier strong `
                -DependsOn @('p-01-a', 'p-02-review-a')
            return @($impl, $rev, $int)
        }
    }

    It 'passes a well-formed batch' {
        $batch = New-GoodBatch
        $rel = $batch | ForEach-Object { $_.Substring($script:fx.Length + 1).Replace('\', '/') }
        $r = Invoke-MusterLint $script:fx -Paths $rel
        $r.Text | Should -Match 'LINT OK 3'
        $r.Exit | Should -Be 0
    }
    It 'check 2: flags id not matching filename and filename collisions' {
        $batch = New-GoodBatch
        New-TaskFile -Fixture $script:fx -Folder done -Id 'p-01-a' | Out-Null   # collision on disk
        $rel = $batch | ForEach-Object { $_.Substring($script:fx.Length + 1).Replace('\', '/') }
        $r = Invoke-MusterLint $script:fx -Paths $rel
        $r.Exit | Should -Be 1
        $r.Text | Should -Match 'collision'
    }
    It 'check 3: flags a depends_on id that exists neither in batch nor on disk' {
        $p = New-TaskFile -Fixture $script:fx -Folder backlog -Id 'p-01-a' -DependsOn @('p-00-ghost')
        $r = Invoke-MusterLint $script:fx -Paths @('tasks/backlog/p-01-a.md')
        $r.Exit | Should -Be 1
        $r.Text | Should -Match 'p-00-ghost'
    }
    It 'check 4: flags shell metacharacters and network commands' {
        New-TaskFile -Fixture $script:fx -Folder backlog -Id 'p-01-a' -VerifyCmd 'git --version | sort' | Out-Null
        (Invoke-MusterLint $script:fx -Paths @('tasks/backlog/p-01-a.md')).Exit | Should -Be 1
        New-TaskFile -Fixture $script:fx -Folder backlog -Id 'p-02-b' -VerifyCmd 'npm install left-pad' | Out-Null
        (Invoke-MusterLint $script:fx -Paths @('tasks/backlog/p-02-b.md')).Text | Should -Match 'network'
    }
    It 'check 4: allows a network command when harness is claude' {
        New-TaskFile -Fixture $script:fx -Folder backlog -Id 'p-01-a' -VerifyCmd 'dotnet restore App.csproj' `
            -ExtraFront @('harness: claude') | Out-Null
        $r = Invoke-MusterLint $script:fx -Paths @('tasks/backlog/p-01-a.md')
        $r.Text | Should -Not -Match 'network'
    }
    It 'check 5: impl verify paths must be protected or committed' {
        New-TaskFile -Fixture $script:fx -Folder backlog -Id 'p-01-a' `
            -VerifyCmd 'powershell -File scripts/check.ps1' -Protected @('README.md') -CommitPaths @('src/out.txt') | Out-Null
        $r = Invoke-MusterLint $script:fx -Paths @('tasks/backlog/p-01-a.md')
        $r.Exit | Should -Be 1
        $r.Text | Should -Match 'scripts/check.ps1'
    }
    It 'check 5: does not treat single-letter cmd.exe switches like /c as repo paths' {
        New-TaskFile -Fixture $script:fx -Folder backlog -Id 'p-01-a' `
            -VerifyCmd 'cmd /c npm test' -CommitPaths @('src/out.txt') | Out-Null
        $r = Invoke-MusterLint $script:fx -Paths @('tasks/backlog/p-01-a.md')
        $r.Text | Should -Not -Match 'verify path'
    }
    It 'checks 7-9: placeholders, un-inlined references, judgment language' {
        $body = "# p-01-a: t`n`n## Context`n`nsee docs/plan.md`n`n## Steps`n`n1. Handle edge cases as appropriate. TODO`n`n## Acceptance`n`n- x"
        New-TaskFile -Fixture $script:fx -Folder backlog -Id 'p-01-a' -Body $body | Out-Null
        $r = Invoke-MusterLint $script:fx -Paths @('tasks/backlog/p-01-a.md')
        $r.Exit | Should -Be 1
        foreach ($sig in 'placeholder', 'reference', 'judgment') { $r.Text | Should -Match $sig }
    }
    It 'check 8: review task filled literally from templates/review-task.md passes lint' {
        # Regression: template line 17 used to read "per the plan snapshot",
        # which check 8 rejects as an un-inlined reference.
        $tpl = [IO.File]::ReadAllText((Join-Path $script:RepoRoot 'templates/review-task.md'))
        $tpl | Should -Not -Match 'per the plan'
        $fill = @{
            '{inlined spec excerpt for the impl task}'                                    = 'Write src/out.txt.'
            '{fix template inlined here by shard, so the reviewer never opens plugin files}' = '(fix template omitted in fixture)'
            '{cheap-build-or-test-cmd}' = 'git --version'
            '{impl-id}'  = 'p-01-a'
            '{impl-seq}' = '01'
            '{plan}'     = 'p'
            '{seq}'      = '02'
            '{slug}'     = 'a'
            '{id}'       = 'p-02-review-a'
        }
        foreach ($k in $fill.Keys) { $tpl = $tpl.Replace($k, $fill[$k]) }
        New-TaskFile -Fixture $script:fx -Folder backlog -Id 'p-01-a' -CommitPaths @('src/out.txt') | Out-Null
        [IO.File]::WriteAllText((Join-Path $script:fx 'tasks/backlog/p-02-review-a.md'), $tpl, $script:Utf8NoBom)
        New-TaskFile -Fixture $script:fx -Folder backlog -Id 'p-99-integration' -Type integration -Tier strong `
            -DependsOn @('p-01-a', 'p-02-review-a') | Out-Null
        $r = Invoke-MusterLint $script:fx -Paths @(
            'tasks/backlog/p-01-a.md', 'tasks/backlog/p-02-review-a.md', 'tasks/backlog/p-99-integration.md')
        $r.Text | Should -Match 'LINT OK 3'
        $r.Exit | Should -Be 0
    }
    It 'check 10: heading order enforced' {
        $body = "# p-01-a: t`n`n## Steps`n`n1. Ensure x.`n`n## Context`n`nx`n`n## Acceptance`n`n- x"
        New-TaskFile -Fixture $script:fx -Folder backlog -Id 'p-01-a' -Body $body | Out-Null
        $r = Invoke-MusterLint $script:fx -Paths @('tasks/backlog/p-01-a.md')
        $r.Exit | Should -Be 1
        $r.Text | Should -Match 'headings missing or out of order'
    }
    It 'check 11: full mode requires exactly one seq-99 strong integration task depending on all' {
        $impl = New-TaskFile -Fixture $script:fx -Folder backlog -Id 'p-01-a'
        $r = Invoke-MusterLint $script:fx -Paths @('tasks/backlog/p-01-a.md')
        $r.Exit | Should -Be 1
        $r.Text | Should -Match 'integration'
    }
    It 'lite mode: skips 11/12, exempts self-collision, rejects generation' {
        New-TaskFile -Fixture $script:fx -Folder staging -Id 'p-01-fix-a' -Type fix `
            -ExtraFront @('fixes: p-01-a') | Out-Null
        $r = Invoke-MusterLint $script:fx -Paths @('tasks/staging/p-01-fix-a.md') -Lite
        $r.Exit | Should -Be 0
        New-TaskFile -Fixture $script:fx -Folder staging -Id 'p-02-fix-b' -Type fix `
            -ExtraFront @('fixes: p-02-b', 'generation: 1') | Out-Null
        (Invoke-MusterLint $script:fx -Paths @('tasks/staging/p-02-fix-b.md') -Lite).Exit | Should -Be 1
    }
    It 'check 13: commit_paths non-empty on impl' {
        $p = Join-Path $script:fx 'tasks/backlog/p-01-a.md'
        New-TaskFile -Fixture $script:fx -Folder backlog -Id 'p-01-a' | Out-Null
        $text = [IO.File]::ReadAllText($p) -replace "commit_paths:`n  - src/out.txt", 'commit_paths: []'
        [IO.File]::WriteAllText($p, $text)
        $r = Invoke-MusterLint $script:fx -Paths @('tasks/backlog/p-01-a.md')
        $r.Exit | Should -Be 1
        $r.Text | Should -Match 'commit_paths empty'
    }
}
