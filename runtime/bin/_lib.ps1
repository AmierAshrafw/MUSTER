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

function Test-LintChecks {
    # Spec 2.6. $Paths: repo-relative batch. Returns string[] 'file: message' findings.
    # -Lite: checks 1-10 + 13, candidate exempt from its own collision, generation must be absent.
    param([string]$RepoRoot, [string[]]$Paths, [switch]$Lite)
    $tasks = Join-Path $RepoRoot 'tasks'
    $findings = @()
    $batch = @()
    foreach ($p in $Paths) {
        $full = Join-Path $RepoRoot $p
        if (-not (Test-Path $full)) { $findings += "${p}: file not found"; continue }
        $batch += , (Read-TaskFile $full)
    }
    $batchIds = @($batch | ForEach-Object { $_.Id })

    foreach ($t in $batch) {
        $name = Split-Path $t.Path -Leaf
        $pfx = $name

        # 1. frontmatter parses + schema per type
        if ($t.Errors.Count -gt 0) { $findings += "${pfx}: frontmatter: $($t.Errors[0])"; continue }
        foreach ($err in (Test-TaskSchema $t.Fields -Staged:$Lite)) { $findings += "${pfx}: $err" }
        if (-not $t.Fields.ContainsKey('type')) { continue }
        $type = $t.Fields['type']

        # 2. id = stem; filename pattern; collision anywhere under tasks/
        if ($t.Fields['id'] -ne $t.Id) { $findings += "${pfx}: id '$($t.Fields['id'])' does not equal filename stem" }
        $pat = '^[a-z0-9-]+-\d{2}-[a-z0-9-]+$'
        if ($Lite) { $pat = '^[a-z0-9-]+-\d{2}-fix-[a-z0-9-]+$' }
        if ($t.Id -notmatch $pat) { $findings += "${pfx}: filename does not match the task pattern (spec 2.1)" }
        $dupes = @(Get-ChildItem -Path $tasks -Recurse -File -Filter "$($t.Id).md" |
            Where-Object { $_.FullName -ne (Resolve-Path $t.Path).Path })
        if ($dupes.Count -gt 0) { $findings += "${pfx}: filename collision under tasks/ ($($dupes[0].FullName))" }

        # 3. every depends_on exists in batch or on disk
        foreach ($dep in @($t.Fields['depends_on'])) {
            if ($batchIds -contains $dep) { continue }
            $hit = @(Get-ChildItem -Path $tasks -Recurse -File -Filter "$dep.md")
            if ($hit.Count -eq 0) { $findings += "${pfx}: depends_on '$dep' exists nowhere" }
        }

        # 4. verify: metacharacters + network denylist
        $netRx = '(^|\s)(curl|wget|nuget|iwr|Invoke-WebRequest)(\s|$)|git (fetch|pull|push)|npm (install|ci)|dotnet restore|pip install'
        foreach ($en in @($t.Fields['verify'])) {
            if ($en -isnot [hashtable] -or -not $en.ContainsKey('cmd')) { continue }
            $cmd = $en['cmd']
            if ($cmd -match '[|><;`]|\$\(|&&') { $findings += "${pfx}: verify cmd has shell metacharacters: $cmd" }
            $harness = ''
            if ($t.Fields.ContainsKey('harness')) { $harness = $t.Fields['harness'] }
            if ($cmd -match $netRx -and $harness -ne 'claude') {
                $findings += "${pfx}: verify cmd needs network but harness is not claude: $cmd"
            }
            # 5. impl/fix: repo paths named in cmd must be protected or committed (heuristic:
            #    tokens containing / that are not flags)
            if ($type -eq 'impl' -or $type -eq 'fix') {
                $listed = @($t.Fields['protected']) + @($t.Fields['commit_paths'])
                $toks = @()
                try { $toks = Split-CmdLine $cmd }
                catch { $findings += "${pfx}: verify cmd unparseable (unbalanced quote): $cmd" }
                foreach ($tok in $toks) {
                    if ($tok -notmatch '/' -or $tok -match '^-') { continue }
                    if ($tok -match '^/[a-zA-Z]$') { continue }   # cmd.exe switch (/c, /d), not a path
                    $inList = $false
                    foreach ($l in $listed) {
                        if ($tok -eq $l -or $tok.StartsWith(($l.TrimEnd('/') + '/'))) { $inList = $true; break }
                    }
                    if (-not $inList) { $findings += "${pfx}: verify path '$tok' not in protected or commit_paths" }
                }
            }
        }

        $raw = [IO.File]::ReadAllText($t.Path)

        # 6. size cap
        if ((($raw -split "`n").Count) -gt 300 -or ([Text.Encoding]::UTF8.GetByteCount($raw) -gt 16KB)) {
            $findings += "${pfx}: over the size cap (300 lines / 16 KB) - reshard"
        }
        # 7. placeholders (incl. surviving template braces). The brace patterns cover
        #    multi-word slots like {inlined plan snapshot summary: ...} and {...};
        #    tradeoff: code snippets with lowercase braced text can false-positive -
        #    acceptable, shard rewrites or fills them.
        foreach ($rx in 'TBD', 'TODO', 'FIXME', '<fill', '\{placeholder', '\{\.\.\.\}', '\{[a-z][a-z0-9 ,:.-]*\}', '(?m)^\s*\d+\.\s*\.\.\.\s*$') {
            if ($raw -match $rx) { $findings += "${pfx}: placeholder text matches '$rx'"; break }
        }
        # 8. un-inlined references (heuristic, spec 2.6.8)
        foreach ($rx in 'see docs/', 'refer to', 'as described in', 'per the plan') {
            if ($raw -match [regex]::Escape($rx)) { $findings += "${pfx}: un-inlined reference ('$rx')"; break }
        }
        # 9. judgment language in Steps (heuristic, spec 2.6.9)
        $steps = ''
        if ($raw -match '(?s)## Steps(.*?)(## Acceptance|$)') { $steps = $Matches[1] }
        foreach ($rx in 'if needed', 'as appropriate', 'appropriately', 'handle edge cases') {
            if ($steps -match [regex]::Escape($rx)) { $findings += "${pfx}: judgment language in Steps ('$rx')"; break }
        }
        # 10. heading order
        if ($raw -notmatch '(?s)# .+?## Context.+?## Steps.+?## Acceptance') {
            $findings += "${pfx}: body headings missing or out of order (Context, Steps, Acceptance)"
        }
        # 13. commit_paths non-empty on impl/fix
        if (($type -eq 'impl' -or $type -eq 'fix') -and @($t.Fields['commit_paths']).Count -eq 0) {
            $findings += "${pfx}: commit_paths empty"
        }
    }

    if (-not $Lite) {
        # 11. exactly one integration task, seq 99, strong, depends on every other batch id
        $ints = @($batch | Where-Object { $_.Errors.Count -eq 0 -and $_.Fields['type'] -eq 'integration' })
        if ($ints.Count -ne 1) { $findings += "batch: expected exactly 1 integration task, found $($ints.Count)" }
        else {
            $int = $ints[0]
            if ($int.Id -notmatch '-99-') { $findings += "$($int.Id).md: integration task must use seq 99" }
            if ($int.Fields['tier'] -ne 'strong') { $findings += "$($int.Id).md: integration task must be tier: strong" }
            foreach ($other in $batchIds) {
                if ($other -eq $int.Id) { continue }
                if (@($int.Fields['depends_on']) -notcontains $other) {
                    $findings += "$($int.Id).md: integration depends_on missing '$other'"
                }
            }
        }
        # 12. review wiring
        foreach ($t in @($batch | Where-Object { $_.Errors.Count -eq 0 -and $_.Fields['type'] -eq 'review' })) {
            $target = $t.Fields['reviews']
            if ($batchIds -notcontains $target) { $findings += "$($t.Id).md: reviews '$target' not in batch" }
            if (@($t.Fields['depends_on']) -notcontains $target) {
                $findings += "$($t.Id).md: review depends_on must include its reviews id"
            }
        }
    }
    return , $findings
}

function Get-StatusBlock {
    # Spec 8.3. STALE marker and DEAD lines appear only when present.
    param([string]$RepoRoot, [string]$TasksRoot)
    $inbox = @(Get-TaskFiles (Join-Path $TasksRoot 'inbox'))
    $doing = @(Get-TaskFiles (Join-Path $TasksRoot 'doing'))
    $backlog = @(Get-TaskFiles (Join-Path $TasksRoot 'backlog'))
    $failed = @(Get-TaskFiles (Join-Path $TasksRoot 'failed'))
    $done = @(Get-TaskFiles (Join-Path $TasksRoot 'done'))
    if (($inbox.Count + $doing.Count + $backlog.Count + $failed.Count + $done.Count) -eq 0) {
        return 'MUSTER: board empty - nothing sharded or all archived.'
    }
    # NOTE: ForEach-Object -Process binds each item to $_, not to a scriptblock's formal
    # params - a param($f)/$f.Name form left $f unbound (PropertyNotFoundException under
    # strict mode). $_ is the correct binding here.
    $stem = { [IO.Path]::GetFileNameWithoutExtension($_.Name) }
    $lines = @()
    $branch = git -C $RepoRoot rev-parse --abbrev-ref HEAD
    $lines += "MUSTER status @ $(Split-Path $RepoRoot -Leaf) ($branch)"
    $lines += "  inbox    $($inbox.Count) ready      [$((@($inbox | ForEach-Object $stem)) -join ', ')]"
    $doingCell = ''
    foreach ($d in $doing) {
        $t = Read-TaskFile $d.FullName
        $age = 'unknown'
        $stale = ''
        if ($t.Fields.ContainsKey('claimed_at')) {
            $age = Get-AgeString $t.Fields['claimed_at']
            $then = [datetime]::Parse($t.Fields['claimed_at'], [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::AdjustToUniversal)
            if (((Get-Date).ToUniversalTime() - $then).TotalHours -gt 24) {
                $stale = '        <- STALE: see RUNNER.md RECOVERY'
            }
        }
        $doingCell = "[$($t.Id) claimed $age]$stale"
    }
    $lines += "  doing    $($doing.Count)            $doingCell".TrimEnd()
    $dead = @()
    foreach ($b in $backlog) {
        $t = Read-TaskFile $b.FullName
        if ($t.Errors.Count -gt 0) { continue }
        foreach ($dep in @($t.Fields['depends_on'])) {
            if (Test-Path (Join-Path $TasksRoot "failed/$dep.md")) { $dead += "$($t.Id) behind failed $dep"; break }
        }
    }
    $deadCell = ''
    if ($dead.Count -gt 0) { $deadCell = "    ($($dead.Count) DEAD: $($dead -join '; '))" }
    $lines += "  backlog  $($backlog.Count) blocked$deadCell".TrimEnd()
    $lines += "  failed   $($failed.Count)            [$((@($failed | ForEach-Object $stem)) -join ', ')]".TrimEnd()
    $lines += "  done     $($done.Count)"
    return ($lines -join "`n")
}

function Get-DirtyPaths {
    # Worktree + index dirt as repo-relative paths (rename lines yield both sides).
    # --untracked-files=all: without it git collapses a new src/out.txt to '?? src/',
    # which would defeat the commit_paths whitelist.
    param([string]$RepoRoot)
    $paths = @()
    foreach ($line in @(git -C $RepoRoot status --porcelain --untracked-files=all)) {
        if (-not $line) { continue }
        $p = $line.Substring(3)
        if ($p -match '^(.+) -> (.+)$') { $paths += $Matches[1]; $paths += $Matches[2] }
        else { $paths += $p }
    }
    return , @($paths | ForEach-Object { $_.Trim('"') })
}

function Test-PathListed {
    # True when $Path equals a list entry or sits under a listed directory.
    param([string]$Path, [string[]]$List)
    foreach ($c in $List) {
        if ($Path -eq $c -or $Path.StartsWith(($c.TrimEnd('/') + '/'))) { return $true }
    }
    return $false
}

function Test-PathInScope {
    # Claim/done scope rule (spec 4.1.7 / 4.3.4, D27): under tasks/ only the
    # executor-writable set is in scope - live doing/ sidecars and the staged fix.
    # Everything else there (bin/, RUNNER.md, task cards, done//failed/ history)
    # is protocol surface and never in scope, even if commit_paths names it.
    param([string]$Path, [string[]]$CommitPaths)
    if ($Path -like 'tasks/doing/*.notes.md') { return $true }
    if ($Path -like 'tasks/doing/*.verify.log') { return $true }
    if ($Path -like 'tasks/staging/*.md') { return $true }
    if ($Path -eq 'tasks' -or $Path.StartsWith('tasks/')) { return $false }
    return (Test-PathListed -Path $Path -List $CommitPaths)
}

function Set-ClaimedAt {
    # Stamp (or replace) claimed_at as the last frontmatter line. Script-only edit (D17).
    param([string]$Path, [string]$Iso)
    $lines = [IO.File]::ReadAllText($Path) -split "`r?`n"
    $close = 0
    for ($j = 1; $j -lt $lines.Count; $j++) { if ($lines[$j] -eq '---') { $close = $j; break } }
    $out = @()
    for ($j = 0; $j -lt $lines.Count; $j++) {
        if ($j -gt 0 -and $lines[$j] -match '^claimed_at:') { continue }
        if ($j -eq $close) { $out += "claimed_at: $Iso" }
        $out += $lines[$j]
    }
    Write-Utf8 $Path ($out -join "`n")
}

function Get-ClaimCommit {
    # Derived, never stored (spec 4.3.1): last commit touching the doing/ path.
    param([string]$RepoRoot, [string]$Name)
    $sha = git -C $RepoRoot log -n 1 --format=%H -- "tasks/doing/$Name"
    if (-not $sha) { Write-Refuse "no claim commit found for tasks/doing/$Name. RECOVERY in RUNNER.md." }
    return $sha
}

function Get-ChangedPaths {
    # Tracked changes since the claim commit PLUS untracked new files - a bare
    # diff --name-only misses exactly the normal impl output (a newly created file).
    param([string]$RepoRoot, [string]$ClaimCommit)
    $changed = @(git -c core.autocrlf=false -C $RepoRoot diff --name-only $ClaimCommit 2>$null)
    $changed += @(git -c core.autocrlf=false -C $RepoRoot ls-files --others --exclude-standard 2>$null)
    return , @($changed | Sort-Object -Unique)
}

function Test-DonePreconditions {
    # Protected + scope checks (spec 4.3 pre 3-4). Returns $null or the refusal message.
    param([string]$RepoRoot, [hashtable]$Fields, [string]$ClaimCommit)
    $changed = Get-ChangedPaths -RepoRoot $RepoRoot -ClaimCommit $ClaimCommit
    $protected = @()
    if ($Fields.ContainsKey('protected')) { $protected = @($Fields['protected']) }
    $hits = @($changed | Where-Object { Test-PathListed -Path $_ -List $protected })
    if ($hits.Count -gt 0) {
        return "protected file(s) modified: $($hits -join ', '). Revert them; the verify definition is not yours to change."
    }
    $cp = @()
    if ($Fields.ContainsKey('commit_paths')) { $cp = @($Fields['commit_paths']) }
    $extras = @($changed | Where-Object { -not (Test-PathInScope -Path $_ -CommitPaths $cp) })
    if ($extras.Count -gt 0) {
        return "changed outside commit_paths: $($extras -join ', '). Revert strays or stop for a human."
    }
    return $null
}

function New-ResultSidecar {
    # Spec 3.1. Everything above Surprises comes from git + the log; the model only wrote notes.
    # $Attempts -1 = read the live log; pass an explicit count when the log has already
    # been moved (done-fail cycling). -Probe marks the claim auto-file case.
    param([string]$RepoRoot, [string]$TasksRoot, [hashtable]$Fields, [string]$Id, [string]$ClaimCommit,
        [string]$Status, [string]$Verdict = '', [string]$SurprisesOverride = '',
        [int]$Attempts = -1, [switch]$Probe)
    if ($Attempts -lt 0) { $Attempts = Get-AttemptCount (Join-Path $TasksRoot "doing/$Id.verify.log") }
    $verifyLine = "verify: pass (attempt $Attempts of 3)"
    if ($Attempts -eq 0) {
        $verifyLine = 'verify: pass (done-check only)'
        if ($Probe) { $verifyLine = 'verify: pass (claim-probe)' }
    }
    $claimedAt = ''
    if ($Fields.ContainsKey('claimed_at')) { $claimedAt = $Fields['claimed_at'] }
    $lines = @("# Result: $Id", '', "- status: $Status")
    if ($Verdict) { $lines += "- verdict: $Verdict" }
    $lines += "- claim_commit: $ClaimCommit"
    $lines += "- claimed_at: $claimedAt"
    $lines += "- completed_at: $(Get-IsoNow)"
    $lines += "- $verifyLine"
    $lines += '- files_changed:'
    # NOTE: must assign before foreach - `foreach ($f in Get-ChangedPaths ...)` (call
    # used directly as the collection expression, unassigned) binds the whole array to
    # $f in a single iteration, same call-site gotcha as piping into ForEach-Object.
    $changedForSidecar = Get-ChangedPaths -RepoRoot $RepoRoot -ClaimCommit $ClaimCommit
    foreach ($f in $changedForSidecar) { $lines += "  - $f" }
    $notesPath = Join-Path $TasksRoot "doing/$Id.notes.md"
    $notesText = 'none reported'
    if (Test-Path $notesPath) { $notesText = ([IO.File]::ReadAllText($notesPath)).TrimEnd() }
    if ($SurprisesOverride) { $notesText = $SurprisesOverride }
    $lines += @('', '## Surprises', '')
    $type = $Fields['type']
    if ($type -eq 'review' -or $type -eq 'integration') {
        $lines += 'none reported'
        $lines += @('', '## Findings', '', $notesText)
    }
    else { $lines += $notesText }
    return (($lines -join "`n") + "`n")
}

function Complete-Task {
    # Pass-path mechanics (spec 4.3 steps 6-9), also used by the claim probe's auto-file.
    # Assembles the sidecar, moves task + sidecars to done/, folds promotions, ONE commit.
    param([string]$RepoRoot, [string]$TasksRoot, [hashtable]$Fields, [string]$Id, [string]$ClaimCommit,
        [string]$Verdict = '', [string]$SurprisesOverride = '', [switch]$Probe)
    $plan = $Fields['plan']
    $resultText = New-ResultSidecar -RepoRoot $RepoRoot -TasksRoot $TasksRoot -Fields $Fields -Id $Id `
        -ClaimCommit $ClaimCommit -Status 'done' -Verdict $Verdict -SurprisesOverride $SurprisesOverride -Probe:$Probe
    Write-Utf8 (Join-Path $TasksRoot "done/$Id.result.md") $resultText
    git -c core.autocrlf=false -C $RepoRoot add "tasks/done/$Id.result.md" 2>$null
    $notes = Join-Path $TasksRoot "doing/$Id.notes.md"
    if (Test-Path $notes) { Remove-Item $notes }
    $paths = @("tasks/doing/$Id.md", "tasks/done/$Id.md", "tasks/done/$Id.result.md")
    $log = Join-Path $TasksRoot "doing/$Id.verify.log"
    if (Test-Path $log) {
        Move-Item $log (Join-Path $TasksRoot "done/$Id.verify.log")
        git -c core.autocrlf=false -C $RepoRoot add "tasks/done/$Id.verify.log" 2>$null
        $paths += "tasks/done/$Id.verify.log"
    }
    $paths += Move-TaskSidecars -RepoRoot $RepoRoot -TasksRoot $TasksRoot -Id $Id -From 'doing' -To 'done'
    git -c core.autocrlf=false -C $RepoRoot mv "tasks/doing/$Id.md" "tasks/done/$Id.md" 2>$null
    $promoted = Invoke-Promote -NoCommit
    foreach ($p in $promoted) {
        $paths += "tasks/backlog/$p.md"
        $paths += "tasks/inbox/$p.md"
        foreach ($h in @(Get-ChildItem (Join-Path $TasksRoot 'inbox') -File | Where-Object { $_.Name -like "$p.gen*" })) {
            $paths += "tasks/backlog/$($h.Name)"
            $paths += "tasks/inbox/$($h.Name)"
        }
    }
    if ($Fields.ContainsKey('commit_paths')) {
        # only paths that exist: a never-created commit_path in the pathspec aborts the commit
        foreach ($c in @($Fields['commit_paths'])) {
            if (Test-Path (Join-Path $RepoRoot $c)) {
                git -c core.autocrlf=false -C $RepoRoot add -- $c 2>$null
                $paths += $c
            }
        }
    }
    git -c core.autocrlf=false -C $RepoRoot commit -q -m "muster($plan): done $Id" -- @paths 2>$null
    if ($LASTEXITCODE -ne 0) { Write-Refuse "completion commit failed for $Id - inspect git state by hand." }
    return , $promoted
}

function Get-FixCount {
    # The script is the only generation counter (spec 2.2): files carrying
    # 'fixes: <impl-id>' anywhere under tasks/ excluding staging/.
    param([string]$TasksRoot, [string]$ImplId)
    $count = 0
    foreach ($f in @(Get-ChildItem -Path $TasksRoot -Recurse -File -Filter '*.md')) {
        if ($f.FullName -match '[\\/]staging[\\/]') { continue }
        if ($f.Name -like '*.result.md' -or $f.Name -like '*.notes.md') { continue }
        if ([IO.File]::ReadAllText($f.FullName) -match "(?m)^fixes: $([regex]::Escape($ImplId))\s*$") { $count++ }
    }
    return $count
}

function Add-DependsOn {
    # Script-side frontmatter edit (D17): append one id to depends_on.
    param([string]$Path, [string]$DepId)
    $text = [IO.File]::ReadAllText($Path)
    if ($text -match '(?m)^depends_on: \[\]\s*$') {
        $text = $text -replace '(?m)^depends_on: \[\]\s*$', "depends_on:`n  - $DepId"
    }
    else {
        $lines = $text -split "`r?`n"
        $out = @()
        $inDeps = $false
        foreach ($line in $lines) {
            if ($inDeps -and $line -notmatch '^\s+- ') { $out += "  - $DepId"; $inDeps = $false }
            if ($line -match '^depends_on:\s*$') { $inDeps = $true }
            $out += $line
        }
        if ($inDeps) { $out += "  - $DepId" }
        $text = $out -join "`n"
    }
    Write-Utf8 $Path $text
}

function Move-ToFailedWithResult {
    # Shared by the review cap and integration fail: result with fail verdict,
    # task + sidecars -> failed/, one commit. Caller prints and exits 3.
    param([string]$RepoRoot, [string]$TasksRoot, [hashtable]$Fields, [string]$Id, [string]$ClaimCommit)
    $resultText = New-ResultSidecar -RepoRoot $RepoRoot -TasksRoot $TasksRoot -Fields $Fields -Id $Id `
        -ClaimCommit $ClaimCommit -Status 'failed' -Verdict 'fail'
    Write-Utf8 (Join-Path $TasksRoot "failed/$Id.result.md") $resultText
    git -c core.autocrlf=false -C $RepoRoot add "tasks/failed/$Id.result.md" 2>$null
    $paths = @("tasks/failed/$Id.result.md", "tasks/doing/$Id.md", "tasks/failed/$Id.md")
    $notes = Join-Path $TasksRoot "doing/$Id.notes.md"
    if (Test-Path $notes) { Remove-Item $notes }
    $log = Join-Path $TasksRoot "doing/$Id.verify.log"
    if (Test-Path $log) {
        Move-Item $log (Join-Path $TasksRoot "failed/$Id.verify.log")
        git -c core.autocrlf=false -C $RepoRoot add "tasks/failed/$Id.verify.log" 2>$null
        $paths += "tasks/failed/$Id.verify.log"
    }
    $paths += Move-TaskSidecars -RepoRoot $RepoRoot -TasksRoot $TasksRoot -Id $Id -From 'doing' -To 'failed'
    git -c core.autocrlf=false -C $RepoRoot mv "tasks/doing/$Id.md" "tasks/failed/$Id.md" 2>$null
    git -c core.autocrlf=false -C $RepoRoot commit -q -m "muster($($Fields['plan'])): fail $Id" -- @paths 2>$null
}

function Invoke-DoneFailReview {
    # Spec 4.3 done-fail for review tasks. Exits itself on every path.
    param([string]$RepoRoot, [string]$TasksRoot, [hashtable]$Fields, [string]$Id, [string]$ClaimCommit)
    $plan = $Fields['plan']
    $implId = $Fields['reviews']

    # 6. exactly one valid gen-less staged fix targeting the reviewed impl
    $staged = @(Get-TaskFiles (Join-Path $TasksRoot 'staging'))
    if ($staged.Count -ne 1) {
        Write-Refuse "done fail needs exactly one valid fix task in tasks/staging/ (found $($staged.Count) files). File left in place - fix it and rerun."
    }
    $stagedRel = "tasks/staging/$($staged[0].Name)"
    $findings = Test-LintChecks -RepoRoot $RepoRoot -Paths @($stagedRel) -Lite
    $fix = Read-TaskFile $staged[0].FullName
    if ($fix.Errors.Count -eq 0 -and $fix.Fields.ContainsKey('fixes') -and $fix.Fields['fixes'] -ne $implId) {
        $findings = @("fixes '$($fix.Fields['fixes'])' does not match reviews '$implId'") + $findings
    }
    if ($findings.Count -gt 0) {
        Write-Refuse "done fail needs exactly one valid fix task in tasks/staging/ ($($findings[0])). File left in place - fix it and rerun."
    }

    # 7. generation cap - two landed generations = human territory (D11)
    $g = (Get-FixCount -TasksRoot $TasksRoot -ImplId $implId) + 1
    if ($g -ge 3) {
        Remove-Item $staged[0].FullName
        Move-ToFailedWithResult -RepoRoot $RepoRoot -TasksRoot $TasksRoot -Fields $Fields -Id $Id -ClaimCommit $ClaimCommit
        Write-Output "Review cap hit (2 fix generations). $implId chain needs a human. Session over."
        exit 3
    }

    # 8. stamp the fix: filename, id, generation, title (spec 2.1)
    if ($staged[0].Name -notmatch '^(.+-\d{2})-fix-(.+)\.md$') {
        Write-Refuse "staged fix filename malformed: $($staged[0].Name)."
    }
    $fixId = "$($Matches[1])-fix$g-$($Matches[2])"
    $text = [IO.File]::ReadAllText($staged[0].FullName)
    $text = $text -replace '(?m)^id: .*$', "id: $fixId"
    $text = $text -replace '(?m)^(fixes: .*)$', "`$1`ngeneration: $g"
    $text = $text.Replace("# $($fix.Id):", "# ${fixId}:")
    Write-Utf8 (Join-Path $TasksRoot "inbox/$fixId.md") $text
    Remove-Item $staged[0].FullName
    git -c core.autocrlf=false -C $RepoRoot add "tasks/inbox/$fixId.md" 2>$null
    $paths = @("tasks/inbox/$fixId.md", "tasks/doing/$Id.md", "tasks/backlog/$Id.md")

    # review task re-blocks on the fix (cycling, no new review task - D11/D19)
    Add-DependsOn -Path (Join-Path $TasksRoot "doing/$Id.md") -DepId $fixId

    # this round's sidecars become history; next round's attempt counter starts fresh.
    # Capture the attempt count BEFORE the move - New-ResultSidecar cannot read a moved log.
    $live = Join-Path $TasksRoot "doing/$Id.verify.log"
    $roundAttempts = Get-AttemptCount $live
    if (Test-Path $live) {
        Move-Item $live (Join-Path $TasksRoot "backlog/$Id.gen$g.verify.log")
        git -c core.autocrlf=false -C $RepoRoot add "tasks/backlog/$Id.gen$g.verify.log" 2>$null
        $paths += "tasks/backlog/$Id.gen$g.verify.log"
    }
    $resultText = New-ResultSidecar -RepoRoot $RepoRoot -TasksRoot $TasksRoot -Fields $Fields -Id $Id `
        -ClaimCommit $ClaimCommit -Status 'cycled' -Verdict 'fail' -Attempts $roundAttempts
    Write-Utf8 (Join-Path $TasksRoot "backlog/$Id.gen$g.result.md") $resultText
    git -c core.autocrlf=false -C $RepoRoot add "tasks/backlog/$Id.gen$g.result.md" 2>$null
    $paths += "tasks/backlog/$Id.gen$g.result.md"
    Remove-Item (Join-Path $TasksRoot "doing/$Id.notes.md")
    $paths += Move-TaskSidecars -RepoRoot $RepoRoot -TasksRoot $TasksRoot -Id $Id -From 'doing' -To 'backlog'
    git -c core.autocrlf=false -C $RepoRoot mv "tasks/doing/$Id.md" "tasks/backlog/$Id.md" 2>$null

    # 9. ONE commit
    git -c core.autocrlf=false -C $RepoRoot commit -q -m "muster($plan): reject $implId gen$g" -- @paths 2>$null
    Write-Output "Review failed. Fix $fixId queued (generation $g of 2). Session over."
    exit 0
}

function Invoke-DoneFailIntegration {
    # Spec 4.3 integration-fail: plan-level drift belongs to the orchestrator, not a fix task.
    param([string]$RepoRoot, [string]$TasksRoot, [hashtable]$Fields, [string]$Id, [string]$ClaimCommit)
    $staged = @(Get-TaskFiles (Join-Path $TasksRoot 'staging'))
    if ($staged.Count -gt 0) {
        Write-Refuse 'integration done fail accepts no fix task - clear tasks/staging/.'
    }
    Move-ToFailedWithResult -RepoRoot $RepoRoot -TasksRoot $TasksRoot -Fields $Fields -Id $Id -ClaimCommit $ClaimCommit
    Write-Output "Integration review failed. Bring tasks/failed/$Id.result.md to the orchestrator to shard a fix-up plan. Session over."
    exit 3
}
