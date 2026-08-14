# Growth-freeze + matrix enforcement (spec D4). Discovery-only: SkipRun executes no
# test bodies and no fixture setup. The nested discovery pass over ~20 files costs
# ~5-6 s wall, so this file is CHECKPOINT tier: run by run-full.ps1 and standalone,
# deliberately excluded from run-dev.ps1's file list.
BeforeAll {
    $script:RepoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $script:Matrix = (Import-PowerShellDataFile (Join-Path $script:RepoRoot 'tests/ContractMatrix.psd1')).Rows
    $script:Inventory = Import-PowerShellDataFile (Join-Path $script:RepoRoot 'tests/BlackBoxInventory.psd1')

    function Get-BlockTests {
        param($Block, [string]$File, [System.Collections.ArrayList]$Acc)
        foreach ($t in $Block.Tests) {
            [void]$Acc.Add([pscustomobject]@{ File = $File; Name = $t.Name; Tags = @($t.Tag) })
        }
        foreach ($nb in $Block.Blocks) { Get-BlockTests $nb $File $Acc }
    }
    $paths = @(Get-ChildItem (Join-Path $script:RepoRoot 'tests') -Filter '*.Tests.ps1' | ForEach-Object FullName)
    $paths += @(Get-ChildItem (Join-Path $script:RepoRoot 'tests/fast') -Filter '*.Fast.Tests.ps1' | ForEach-Object FullName)
    $conf = New-PesterConfiguration
    $conf.Run.Path = $paths
    $conf.Run.SkipRun = $true
    $conf.Run.PassThru = $true
    $res = Invoke-Pester -Configuration $conf
    $acc = New-Object System.Collections.ArrayList
    foreach ($c in $res.Containers) {
        $leaf = Split-Path $c.Item -Leaf
        foreach ($b in $c.Blocks) { Get-BlockTests $b $leaf $acc }
    }
    $script:BlackBox = @($acc | Where-Object { $_.File -notlike '*.Fast.Tests.ps1' })
    $script:Fast = @($acc | Where-Object { $_.File -like '*.Fast.Tests.ps1' })
}

Describe 'suite meta: contract matrix and growth freeze' {
    It 'every matrix row tags exactly one black-box It in the declared file' {
        foreach ($row in $script:Matrix) {
            $hits = @($script:BlackBox | Where-Object { $_.Tags -contains $row.Id })
            $hits.Count | Should -Be 1 -Because "row $($row.Id)"
            $hits[0].File | Should -Be (Split-Path $row.File -Leaf) -Because "row $($row.Id)"
        }
    }
    It 'every eligible matrix row has a same-tag fast twin' {
        foreach ($row in @($script:Matrix | Where-Object { $_.Eligible })) {
            @($script:Fast | Where-Object { $_.Tags -contains $row.Id }).Count |
                Should -BeGreaterOrEqual 1 -Because "row $($row.Id)"
        }
    }
    It 'the black-box inventory matches discovery (growth freeze)' {
        $byFile = $script:BlackBox | Group-Object File
        foreach ($file in $script:Inventory.Keys) {
            $found = @($byFile | Where-Object Name -eq $file)
            $found.Count | Should -Be 1 -Because $file
            $found[0].Count | Should -Be $script:Inventory[$file].Its -Because "$file It count - new black-box tests require a deliberate inventory update"
        }
        @($byFile).Count | Should -Be @($script:Inventory.Keys).Count -Because 'no untracked black-box files'
    }
}
