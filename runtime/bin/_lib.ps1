# MUSTER shared library. Dot-sourced by every verb script. PowerShell 5.1 compatible.
# Executors never call this file directly; it is not part of the RUNNER contract.
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:Utf8NoBom = New-Object System.Text.UTF8Encoding $false

function Get-RepoRoot {
    $root = git rev-parse --show-toplevel
    if ($LASTEXITCODE -ne 0 -or -not $root) { Write-Output 'MUSTER refuse: not inside a git repository.'; exit 1 }
    return $root
}

function Get-TasksRoot { Join-Path (Get-RepoRoot) 'tasks' }

function Get-IsoNow { (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'") }

function Write-Utf8 { param([string]$Path, [string]$Text) [IO.File]::WriteAllText($Path, $Text, $script:Utf8NoBom) }
function Add-Utf8 { param([string]$Path, [string]$Text) [IO.File]::AppendAllText($Path, $Text, $script:Utf8NoBom) }

function Write-Refuse {
    # Single-line refusal per spec 4.0; callers rely on this terminating the script.
    param([string]$Message)
    Write-Output "MUSTER refuse: $Message"
    exit 1
}

function Get-TaskFiles {
    # Task .md files only: sidecars (.result.md, .notes.md) and .gitkeep never count (spec 4.0).
    param([string]$Folder)
    @(Get-ChildItem -Path $Folder -File -Filter '*.md' |
        Where-Object { $_.Name -notlike '*.result.md' -and $_.Name -notlike '*.notes.md' } |
        Sort-Object Name)
}

function Get-AgeString {
    # Humanized age of an ISO UTC timestamp: 42m / 3h / 2d.
    param([string]$Iso)
    $then = [datetime]::Parse($Iso, [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::AdjustToUniversal)
    $delta = (Get-Date).ToUniversalTime() - $then
    if ($delta.TotalDays -ge 1) { return ('{0}d' -f [int][math]::Floor($delta.TotalDays)) }
    if ($delta.TotalHours -ge 1) { return ('{0}h' -f [int][math]::Floor($delta.TotalHours)) }
    return ('{0}m' -f [int][math]::Floor($delta.TotalMinutes))
}

function Read-QuoteStripped {
    param([string]$Value)
    if ($Value -match '^"(.*)"$') { return $Matches[1] }
    return $Value
}

function Read-Frontmatter {
    # Strict YAML subset per spec 2.5. Returns @{ Fields; Errors; Body }.
    # Values stay strings; typing/enums are Test-TaskSchema's job.
    param([string]$Text)
    $r = @{ Fields = @{}; Errors = @(); Body = '' }
    $lines = $Text -split "`r?`n"
    if ($lines.Count -lt 3 -or $lines[0] -ne '---') { $r.Errors += 'missing opening --- marker'; return $r }
    $close = 0
    for ($j = 1; $j -lt $lines.Count; $j++) { if ($lines[$j] -eq '---') { $close = $j; break } }
    if ($close -eq 0) { $r.Errors += 'missing closing --- marker'; return $r }

    $i = 1
    while ($i -lt $close) {
        $line = $lines[$i]
        if ($line -match '^\s*$') { $i++; continue }
        if ($line -notmatch '^([a-z_]+):(.*)$') {
            $r.Errors += "unparseable frontmatter line: $line"
            $i++
            continue
        }
        $key = $Matches[1]
        $val = $Matches[2].Trim()

        if ($key -eq 'verify') {
            if ($val -ne '') { $r.Errors += 'verify: must be a block list'; return $r }
            $entries = @()
            $i++
            while ($i -lt $close) {
                $vline = $lines[$i]
                if ($vline -match '^  - ([a-z_]+): (.+)$') {
                    $entries += , @{ $Matches[1] = (Read-QuoteStripped $Matches[2].Trim()) }
                    $i++
                }
                elseif ($vline -match '^    ([a-z_]+): (.+)$') {
                    if ($entries.Count -eq 0) { $r.Errors += "verify: continuation before first entry: $vline"; return $r }
                    $entries[$entries.Count - 1][$Matches[1]] = (Read-QuoteStripped $Matches[2].Trim())
                    $i++
                }
                else { break }
            }
            if ($entries.Count -eq 0) { $r.Errors += 'verify: empty block' }
            $r.Fields['verify'] = $entries
            continue
        }

        if ($val -eq '[]') {
            $r.Fields[$key] = @()
            $i++
        }
        elseif ($val -eq '') {
            $items = @()
            $i++
            while ($i -lt $close -and $lines[$i] -match '^\s+- (.+)$') {
                $items += (Read-QuoteStripped $Matches[1].Trim())
                $i++
            }
            if ($items.Count -eq 0) { $r.Errors += "${key}: empty value - use [] for an empty list" }
            $r.Fields[$key] = $items
        }
        else {
            if ($val -match '^[&*]') { $r.Errors += "${key}: anchors/aliases are not allowed" }
            $r.Fields[$key] = (Read-QuoteStripped $val)
            $i++
        }
    }
    if ($close + 1 -lt $lines.Count) {
        $r.Body = ($lines[($close + 1)..($lines.Count - 1)] -join "`n")
    }
    return $r
}

function Read-TaskFile {
    # Read + parse a task file from disk. Adds Id (filename stem) and Path.
    param([string]$Path)
    $r = Read-Frontmatter ([IO.File]::ReadAllText($Path))
    $r['Id'] = [IO.Path]::GetFileNameWithoutExtension($Path)
    $r['Path'] = $Path
    return $r
}
