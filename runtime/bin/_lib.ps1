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
