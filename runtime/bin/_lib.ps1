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

function Test-TaskSchema {
    # Returns a string[] of schema errors (empty = valid). Field table: spec 2.2.
    # -Staged: lint-lite mode for a reviewer-authored fix in staging/ (generation must be absent).
    param([hashtable]$Fields, [switch]$Staged)
    $e = @()
    foreach ($req in 'id', 'plan', 'type', 'tier', 'depends_on', 'verify') {
        if (-not $Fields.ContainsKey($req)) { $e += "missing required field: $req" }
    }
    if ($e.Count -gt 0) { return , $e }

    $type = $Fields['type']
    if (@('impl', 'review', 'fix', 'integration') -notcontains $type) { $e += "type: illegal value '$type'"; return , $e }
    if (@('any', 'strong') -notcontains $Fields['tier']) { $e += "tier: illegal value '$($Fields['tier'])'" }
    if ($Fields.ContainsKey('harness') -and @('claude', 'codex') -notcontains $Fields['harness']) {
        $e += "harness: illegal value '$($Fields['harness'])'"
    }
    if ($Fields['id'] -notmatch '^[a-z0-9-]+$') { $e += 'id: must be kebab-case [a-z0-9-]+' }
    if ($Fields['depends_on'] -isnot [array]) { $e += 'depends_on: must be a list' }

    if ($type -eq 'review' -and -not $Fields.ContainsKey('reviews')) { $e += 'reviews: required on review tasks' }
    if ($type -eq 'fix' -and -not $Fields.ContainsKey('fixes')) { $e += 'fixes: required on fix tasks' }
    if ($type -eq 'impl' -or $type -eq 'fix') {
        foreach ($req in 'protected', 'commit_paths') {
            if (-not $Fields.ContainsKey($req)) { $e += "${req}: required on $type tasks" }
        }
    }
    else {
        if ($Fields.ContainsKey('commit_paths')) { $e += "commit_paths: must be omitted on $type tasks (outputs are sidecars only)" }
    }

    if ($Fields.ContainsKey('generation')) {
        if ($type -ne 'fix') { $e += 'generation: only legal on fix tasks' }
        elseif ($Staged) { $e += 'generation: must be absent on a staged fix (the done script stamps it)' }
        elseif (@('1', '2') -notcontains "$($Fields['generation'])") { $e += 'generation: must be 1 or 2' }
    }

    if ($Fields['verify'] -is [array]) {
        $allowed = @('cmd', 'expect_exit', 'expect_contains', 'timeout_seconds')
        foreach ($en in $Fields['verify']) {
            foreach ($k in $en.Keys) {
                if ($allowed -notcontains $k) { $e += "verify: unknown key '$k'" }
            }
            if (-not $en.ContainsKey('cmd')) { $e += 'verify: entry missing cmd' }
            if (-not $en.ContainsKey('expect_exit') -and -not $en.ContainsKey('expect_contains')) {
                $e += 'verify: entry needs expect_exit and/or expect_contains'
            }
            foreach ($ik in 'expect_exit', 'timeout_seconds') {
                if ($en.ContainsKey($ik)) {
                    $tmp = 0
                    if (-not [int]::TryParse("$($en[$ik])", [ref]$tmp)) { $e += "verify: $ik must be an integer" }
                }
            }
        }
    }
    return , $e
}

function Split-CmdLine {
    # Tokenize one command line: whitespace-separated, double quotes group (spec 2.4).
    # No shell interpretation anywhere downstream - tokens go straight to Process.Start.
    param([string]$Cmd)
    $tokens = @()
    $sb = New-Object System.Text.StringBuilder
    $inQuote = $false
    foreach ($ch in $Cmd.ToCharArray()) {
        if ($ch -eq '"') { $inQuote = -not $inQuote; continue }
        if (-not $inQuote -and ($ch -eq ' ' -or $ch -eq "`t")) {
            if ($sb.Length -gt 0) { $tokens += $sb.ToString(); [void]$sb.Clear() }
            continue
        }
        [void]$sb.Append($ch)
    }
    if ($inQuote) { throw "unbalanced double quote in cmd: $Cmd" }
    if ($sb.Length -gt 0) { $tokens += $sb.ToString() }
    return , $tokens
}

function Invoke-VerifyEntry {
    # Run one verify entry: direct process invocation, merged stdout+stderr, wall timeout.
    param([hashtable]$Entry, [string]$WorkDir)
    $tokens = Split-CmdLine $Entry['cmd']
    $timeout = 300
    if ($Entry.ContainsKey('timeout_seconds')) { $timeout = [int]$Entry['timeout_seconds'] }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $tokens[0]
    $quoted = @()
    for ($k = 1; $k -lt $tokens.Count; $k++) {
        if ($tokens[$k] -match '\s') { $quoted += ('"' + $tokens[$k] + '"') } else { $quoted += $tokens[$k] }
    }
    $psi.Arguments = ($quoted -join ' ')
    $psi.WorkingDirectory = $WorkDir
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $out = ''; $code = -1; $timedOut = $false
    try {
        $p = [System.Diagnostics.Process]::Start($psi)
        $so = $p.StandardOutput.ReadToEndAsync()
        $se = $p.StandardError.ReadToEndAsync()
        if ($p.WaitForExit($timeout * 1000)) {
            $code = $p.ExitCode
            $out = $so.Result + $se.Result
        }
        else {
            $timedOut = $true
            try { $p.Kill() } catch { }
        }
    }
    catch { $out = "spawn failed: $($_.Exception.Message)" }
    return @{ Output = $out; ExitCode = $code; TimedOut = $timedOut; TimeoutSeconds = $timeout }
}

function Invoke-VerifyBlock {
    # Run all entries in order, appending a spec-3.2 transcript block to $LogPath.
    # $Label: 'attempt <n>' | 'done-check' | 'claim-probe'. Stops at first failing entry.
    param([array]$Entries, [string]$LogPath, [string]$Label, [string]$TaskId, [string]$RepoRoot)
    $head = git -C $RepoRoot rev-parse HEAD
    Add-Utf8 $LogPath ("=== $Label | $(Get-IsoNow) | task $TaskId | HEAD $head`n")
    $pass = $true
    $firstFail = $null
    foreach ($en in $Entries) {
        Add-Utf8 $LogPath ('$ ' + $en['cmd'] + "`n")
        $res = Invoke-VerifyEntry -Entry $en -WorkDir $RepoRoot
        if ($res.Output) { Add-Utf8 $LogPath ($res.Output.TrimEnd() + "`n") }
        $parts = @()
        $why = @()
        $ok = $true
        if ($res.TimedOut) {
            $parts += "timeout $($res.TimeoutSeconds)s -> FAIL"
            $why += "timed out after $($res.TimeoutSeconds)s"
            $ok = $false
        }
        else {
            $parts += "exit $($res.ExitCode)"
            if ($en.ContainsKey('expect_exit')) {
                if ([int]$en['expect_exit'] -eq $res.ExitCode) { $parts += "expect_exit $($en['expect_exit']) -> OK" }
                else { $parts += "expect_exit $($en['expect_exit']) -> FAIL"; $why += "exit $($res.ExitCode), expected $($en['expect_exit'])"; $ok = $false }
            }
            if ($en.ContainsKey('expect_contains')) {
                if ($res.Output.Contains($en['expect_contains'])) { $parts += "expect_contains ""$($en['expect_contains'])"" -> OK" }
                else { $parts += "expect_contains ""$($en['expect_contains'])"" -> MISSING"; $why += "output missing ""$($en['expect_contains'])"""; $ok = $false }
            }
        }
        Add-Utf8 $LogPath (($parts -join ' | ') + "`n")
        if (-not $ok) {
            $pass = $false
            $firstFail = "$($en['cmd']): $($why -join '; ')"
            break
        }
    }
    $verdict = 'FAIL'
    if ($pass) { $verdict = 'PASS' }
    Add-Utf8 $LogPath ("=== $Label result: $verdict`n")
    return @{ Pass = $pass; FirstFail = $firstFail }
}

function Get-AttemptCount {
    # Attempt number source of truth (spec 3.2): count of '=== attempt N |' headers.
    param([string]$LogPath)
    if (-not (Test-Path $LogPath)) { return 0 }
    return @([regex]::Matches([IO.File]::ReadAllText($LogPath), '(?m)^=== attempt \d+ \|')).Count
}

function Test-DepSatisfied {
    # Satisfied = task id present in done/ or anywhere under archive/ (spec 4.4, D15).
    param([string]$TasksRoot, [string]$DepId)
    if (Test-Path (Join-Path $TasksRoot "done/$DepId.md")) { return $true }
    $archive = Join-Path $TasksRoot 'archive'
    if (Test-Path $archive) {
        $hit = @(Get-ChildItem -Path $archive -Recurse -File -Filter "$DepId.md")
        if ($hit.Count -gt 0) { return $true }
    }
    return $false
}

function Move-TaskSidecars {
    # .gen<g>.* history sidecars move with their task file (spec 3). Returns commit paths.
    param([string]$RepoRoot, [string]$TasksRoot, [string]$Id, [string]$From, [string]$To)
    $paths = @()
    foreach ($h in @(Get-ChildItem (Join-Path $TasksRoot $From) -File | Where-Object { $_.Name -like "$Id.gen*" })) {
        git -c core.autocrlf=false -C $RepoRoot mv "tasks/$From/$($h.Name)" "tasks/$To/$($h.Name)" 2>$null
        $paths += "tasks/$From/$($h.Name)"
        $paths += "tasks/$To/$($h.Name)"
    }
    return , $paths
}

function Get-SoleOccupant {
    # The one task in doing/. Refuses (exit 1) when empty or ambiguous (spec 4.2/4.3).
    param([string]$TasksRoot)
    $files = @(Get-TaskFiles (Join-Path $TasksRoot 'doing'))
    if ($files.Count -eq 0) { Write-Refuse 'doing/ is empty - nothing in progress.' }
    if ($files.Count -gt 1) { Write-Refuse "doing/ holds $($files.Count) task files - one executor per checkout broke. RECOVERY in RUNNER.md." }
    return $files[0]
}

function Read-CommittedTask {
    # Claim-time copy: parse the task from the HEAD blob, not the working tree (D20).
    param([string]$RepoRoot, [string]$Name)
    $blob = git -C $RepoRoot show "HEAD:tasks/doing/$Name"
    if ($LASTEXITCODE -ne 0) { Write-Refuse "tasks/doing/$Name is not committed - claim did not complete. RECOVERY in RUNNER.md." }
    $r = Read-Frontmatter (($blob -join "`n"))
    $r['Id'] = [IO.Path]::GetFileNameWithoutExtension($Name)
    return $r
}

function Move-TaskToFailed {
    # Terminal move: task + live sidecars -> failed/, one pathspec commit (spec 4.2 step 6).
    param([string]$RepoRoot, [string]$TasksRoot, [string]$Id, [string]$Plan)
    $paths = @("tasks/doing/$Id.md", "tasks/failed/$Id.md")
    git -c core.autocrlf=false -C $RepoRoot mv "tasks/doing/$Id.md" "tasks/failed/$Id.md" 2>$null
    foreach ($side in "$Id.verify.log", "$Id.notes.md") {
        $src = Join-Path $TasksRoot "doing/$side"
        if (Test-Path $src) {
            Move-Item $src (Join-Path $TasksRoot "failed/$side")
            git -c core.autocrlf=false -C $RepoRoot add "tasks/failed/$side" 2>$null
            $paths += "tasks/failed/$side"
        }
    }
    git -c core.autocrlf=false -C $RepoRoot commit -q -m "muster($Plan): fail $Id" -- @paths 2>$null
}

function Invoke-Promote {
    # Spec 4.4. Returns the moved ids (filename ascending). -NoCommit: stage renames only.
    # Warnings go to Write-Host so the return value stays clean for claim/done callers
    # (child-process stdout still shows them, which the contract test relies on).
    param([switch]$NoCommit)
    $root = Get-RepoRoot
    $tasks = Get-TasksRoot
    $moved = @()
    $movedPaths = @()
    foreach ($f in Get-TaskFiles (Join-Path $tasks 'backlog')) {
        $t = Read-TaskFile $f.FullName
        if ($t.Errors.Count -gt 0) {
            Write-Host "MUSTER warn: backlog/$($f.Name) frontmatter invalid - skipped by promote."
            continue
        }
        $ok = $true
        foreach ($dep in @($t.Fields['depends_on'])) {
            if (-not (Test-DepSatisfied -TasksRoot $tasks -DepId $dep)) { $ok = $false; break }
        }
        if ($ok) {
            git -c core.autocrlf=false -C $root mv "tasks/backlog/$($f.Name)" "tasks/inbox/$($f.Name)" 2>$null
            $movedPaths += "tasks/backlog/$($f.Name)"
            $movedPaths += "tasks/inbox/$($f.Name)"
            $movedPaths += Move-TaskSidecars -RepoRoot $root -TasksRoot $tasks -Id $t.Id -From 'backlog' -To 'inbox'
            $moved += $t.Id
        }
    }
    if ($moved.Count -gt 0 -and -not $NoCommit) {
        git -c core.autocrlf=false -C $root commit -q -m "muster: promote $($moved.Count)" -- @movedPaths 2>$null
    }
    return , $moved
}
