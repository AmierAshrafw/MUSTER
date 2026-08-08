# Board Visibility Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make board state readable on demand and at session end: dispatch-split inbox counts in the status block, a `bin/status` script, and a counts-only board line in `bin/done` output.

**Architecture:** All display logic stays in the shared libs (`runtime/bin/_lib.ps1` / `_lib.sh`), which already own the spec-8.3 status block. Three changes: (1) the status block's inbox line gains a `(run N, review N)` split computed from task `tier:` frontmatter; (2) new 6-line `status.ps1`/`status.sh` scripts expose the block outside `claim`; (3) `done` prints a counts-only `Board:` line before its terminal line. Two engines, identical output, engine-parameterized Pester suite.

**Tech Stack:** PowerShell 5.1 + POSIX sh (Git for Windows `sh.exe`), Pester tests in `tests/`, engine switch via `MUSTER_ENGINE=sh`.

**Spec:** `docs/superpowers/specs/2026-08-08-board-visibility-design.md` (approved). Amends `docs/superpowers/specs/2026-08-07-muster-v1.md` sections 1, 4.0, 4.3, 8.3.

**Conventions that bite (read before coding):**
- PS 5.1 array-return: lib functions returning arrays use `return , $arr`; callers assign directly, never wrap in `@()` twice (see existing NOTE comments in `claim.ps1:42` and `claim.ps1:62`).
- sh: a `... | while read` loop runs in a subshell — counters set inside are lost. The codebase's established workaround is a `mktemp` file (see `status_block`'s dead scan, `_lib.sh:732`). Reuse that pattern.
- Behavior tests call verb scripts as child processes via `Invoke-Muster` (`tests/MusterFixture.ps1`), which honors `MUSTER_ENGINE=sh`. Unit tests in `tests/Lib.Tests.ps1` dot-source `_lib.ps1` and are ps1-only.
- Fixture helper `New-TaskFile` defaults: `-Type impl -Tier any`, schema-valid frontmatter. `-Commit` commits the file.
- Test-run commands (run as plain cmdlet lines in your PowerShell session, from repo root — do NOT nest them in `powershell -Command "..."`; double-quoted nesting expands `$env:MUSTER_ENGINE` in the parent shell before the child sees it and breaks):
  - ps1 pass: `Invoke-Pester tests -Output Detailed`
  - sh pass: `$env:MUSTER_ENGINE = 'sh'; Invoke-Pester tests/Claim.Tests.ps1, tests/Done.Tests.ps1, tests/Promote.Tests.ps1, tests/Verify.Tests.ps1, tests/Lint.Tests.ps1, tests/Status.Tests.ps1 -Output Detailed; Remove-Item Env:\MUSTER_ENGINE`

---

## File structure

| File | Change | Responsibility |
|---|---|---|
| `runtime/bin/_lib.ps1` | modify | `Get-InboxSplit` (new), `Get-DeadEntries` (extracted from `Get-StatusBlock`), `Get-BoardLine` (new), `Get-StatusBlock` inbox line format |
| `runtime/bin/_lib.sh` | modify | `inbox_split` (new), `dead_scan` (extracted from `status_block`), `board_line` (new), `status_block` inbox line format |
| `runtime/bin/status.ps1` | create | print status block, exit 0; not a RUNNER verb |
| `runtime/bin/status.sh` | create | same, sh engine |
| `runtime/bin/done.ps1` | modify | print `Board:` line before terminal line |
| `runtime/bin/done.sh` | modify | same, sh engine |
| `tests/Lib.Tests.ps1` | modify | unit tests: `Get-InboxSplit`, `Get-BoardLine` |
| `tests/Claim.Tests.ps1` | modify | assert split appears in claim's status print |
| `tests/Status.Tests.ps1` | create | behavior tests for `bin/status`, both engines |
| `tests/Done.Tests.ps1` | modify | assert board line position + content |
| `docs/superpowers/specs/2026-08-07-muster-v1.md` | modify | sections 1, 4.0, 4.3, 8.3 amendments |
| `README.md` | modify | bin listing, `status` bullet, `done` bullet, test counts |

`muster:init` needs no change — its step 6 copies every file from `runtime/bin/`, so `status.*` ships automatically. `RUNNER.md` does not change (status is not an executor verb).

**Pinned output formats** (single source of truth for every task below):

Status block inbox line (split always printed, `, invalid N` only when N > 0):

```
  inbox    3 ready      (run 2, review 1) [p-01-a, p-02-b, p-03-review-a]
  inbox    3 ready      (run 1, review 1, invalid 1) [p-01-a, p-02-broken, p-03-review-a]
```

Done board line (counts only, no ids; `invalid N |` only when N > 0; `(N DEAD)` only when N > 0):

```
Board: run 2 | review 1 | backlog 2 (1 DEAD) | failed 1 | done 4
Board: run 1 | review 0 | invalid 1 | backlog 0 | failed 0 | done 1
```

Bucket rule (both engines, both lines): frontmatter unparseable → `invalid`; `tier: strong` → `review`; `tier: any` → `run`; any other/missing/non-scalar tier value → `invalid`. Parse-level only — no schema validation (matches the DEAD scan's skip-on-error spirit, but counted loudly instead of silently skipped).

Known, accepted engine asymmetry: "unparseable" means "as strict as that engine's frontmatter parser". ps1's `Read-Frontmatter` rejects more defect classes (anchors/aliases, empty values, bad verify blocks) than sh's `fm_valid` (marker check only), so a file that is half-broken in exactly one of those ways can classify `invalid` on ps1 and `run`/`review` on sh. Output parity is guaranteed for boards of schema-valid tasks — the only boards shard-lint lets exist; malformed files are hand-made damage, and both engines still flag the common no-frontmatter class identically (tested). Aligning the parsers is out of scope.

---

### Task 1: ps1 inbox split + status-block line

**Files:**
- Modify: `runtime/bin/_lib.ps1` (insert two functions above `Get-StatusBlock`, edit its inbox line)
- Test: `tests/Lib.Tests.ps1`

- [ ] **Step 1: Write the failing unit tests**

Append to `tests/Lib.Tests.ps1`:

```powershell
Describe 'Get-InboxSplit' {
    BeforeEach { $script:fx = New-MusterFixture }
    AfterEach { Remove-MusterFixture $script:fx }

    It 'buckets tier any as run and tier strong as review' {
        New-TaskFile -Fixture $script:fx -Folder inbox -Id 'p-01-a' | Out-Null
        New-TaskFile -Fixture $script:fx -Folder inbox -Id 'p-02-b' | Out-Null
        New-TaskFile -Fixture $script:fx -Folder inbox -Id 'p-03-review-a' -Type review -Tier strong | Out-Null
        $s = Get-InboxSplit -TasksRoot (Join-Path $script:fx 'tasks')
        $s.Run | Should -Be 2
        $s.Review | Should -Be 1
        $s.Invalid | Should -Be 0
    }
    It 'counts unparseable frontmatter as invalid, not run or review' {
        New-TaskFile -Fixture $script:fx -Folder inbox -Id 'p-01-a' | Out-Null
        [IO.File]::WriteAllText((Join-Path $script:fx 'tasks/inbox/p-02-broken.md'), "no frontmatter`n", $script:Utf8NoBom)
        $s = Get-InboxSplit -TasksRoot (Join-Path $script:fx 'tasks')
        $s.Run | Should -Be 1
        $s.Review | Should -Be 0
        $s.Invalid | Should -Be 1
    }
    It 'returns zeros on an empty inbox' {
        $s = Get-InboxSplit -TasksRoot (Join-Path $script:fx 'tasks')
        $s.Run | Should -Be 0
        $s.Review | Should -Be 0
        $s.Invalid | Should -Be 0
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `Invoke-Pester tests/Lib.Tests.ps1 -Output Detailed`
Expected: 3 new tests FAIL (`Get-InboxSplit` not recognized); all pre-existing tests PASS.

- [ ] **Step 3: Implement `Get-InboxSplit` and `Get-DeadEntries`, rewire `Get-StatusBlock`**

Insert immediately above `function Get-StatusBlock` in `runtime/bin/_lib.ps1`:

```powershell
function Get-InboxSplit {
    # Dispatch split of inbox/ (spec 8.3): run = tier any, review = tier strong,
    # invalid = unparseable frontmatter or any other tier value. Parse-level only.
    param([string]$TasksRoot)
    $run = 0; $review = 0; $invalid = 0
    foreach ($f in Get-TaskFiles (Join-Path $TasksRoot 'inbox')) {
        $t = Read-TaskFile $f.FullName
        if ($t.Errors.Count -gt 0 -or -not $t.Fields.ContainsKey('tier')) { $invalid++; continue }
        # A block-list tier: would make switch iterate the array and double-count;
        # any non-string tier value is invalid, keeping run + review + invalid == inbox total.
        if ($t.Fields['tier'] -isnot [string]) { $invalid++; continue }
        switch ($t.Fields['tier']) {
            'strong' { $review++ }
            'any' { $run++ }
            default { $invalid++ }
        }
    }
    return @{ Run = $run; Review = $review; Invalid = $invalid }
}

function Get-DeadEntries {
    # Backlog tasks with any dependency in failed/ (D12): "<id> behind failed <dep>".
    param([string]$TasksRoot)
    $dead = @()
    foreach ($b in Get-TaskFiles (Join-Path $TasksRoot 'backlog')) {
        $t = Read-TaskFile $b.FullName
        if ($t.Errors.Count -gt 0) { continue }
        foreach ($dep in @($t.Fields['depends_on'])) {
            if (Test-Path (Join-Path $TasksRoot "failed/$dep.md")) { $dead += "$($t.Id) behind failed $dep"; break }
        }
    }
    return , $dead
}
```

In `Get-StatusBlock`, replace the inbox line

```powershell
    $lines += "  inbox    $($inbox.Count) ready      [$((@($inbox | ForEach-Object $stem)) -join ', ')]"
```

with

```powershell
    $split = Get-InboxSplit -TasksRoot $TasksRoot
    $splitCell = "run $($split.Run), review $($split.Review)"
    if ($split.Invalid -gt 0) { $splitCell += ", invalid $($split.Invalid)" }
    $lines += "  inbox    $($inbox.Count) ready      ($splitCell) [$((@($inbox | ForEach-Object $stem)) -join ', ')]"
```

and replace the dead-scan block

```powershell
    $dead = @()
    foreach ($b in $backlog) {
        $t = Read-TaskFile $b.FullName
        if ($t.Errors.Count -gt 0) { continue }
        foreach ($dep in @($t.Fields['depends_on'])) {
            if (Test-Path (Join-Path $TasksRoot "failed/$dep.md")) { $dead += "$($t.Id) behind failed $dep"; break }
        }
    }
```

with

```powershell
    $dead = Get-DeadEntries -TasksRoot $TasksRoot
```

(Note: assign directly — `Get-DeadEntries` uses the `return , $arr` convention; `@(...)`-wrapping would double-wrap. The later `$dead.Count` uses keep working.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `Invoke-Pester tests/Lib.Tests.ps1 -Output Detailed`
Expected: all PASS.

- [ ] **Step 5: Run the full ps1 suite (claim print inherits the new line)**

Run: `Invoke-Pester tests -Output Detailed`
Expected: all PASS — no existing test asserts the old inbox-line format.

- [ ] **Step 6: Commit**

```bash
git add runtime/bin/_lib.ps1 tests/Lib.Tests.ps1
git commit -m "feat: dispatch split in status block inbox line (ps1)"
```

---

### Task 2: sh inbox split + status-block line + claim assertion

**Files:**
- Modify: `runtime/bin/_lib.sh` (insert two functions above `status_block`, edit its inbox line and dead scan)
- Modify: `tests/Claim.Tests.ps1` (split assertion — runs on both engines)

- [ ] **Step 1: Add the failing behavior assertion**

In `tests/Claim.Tests.ps1`, in the existing `It 'prints the status block before any refusal'`, after the line `$r.Out[0] | Should -Match '^MUSTER status @'`, add:

```powershell
        $r.Text | Should -Match '\(run 0, review 0\)'
```

(That fixture has one `doing/` occupant and an empty inbox — split is all zeros, no `invalid` suffix.)

- [ ] **Step 2: Verify ps1 passes and sh fails**

Run: `Invoke-Pester tests/Claim.Tests.ps1 -Output Detailed`
Expected: PASS (Task 1 already changed the ps1 engine).

Run: `$env:MUSTER_ENGINE = 'sh'; Invoke-Pester tests/Claim.Tests.ps1 -Output Detailed; Remove-Item Env:\MUSTER_ENGINE`
Expected: the status-block test FAILS (sh engine still prints the old line).

- [ ] **Step 3: Implement the sh side**

Insert immediately above `status_block()` in `runtime/bin/_lib.sh`:

```sh
inbox_split() { # $1=tasks_root -> sets INBOX_RUN INBOX_REVIEW INBOX_INVALID (spec 8.3 dispatch split)
    INBOX_RUN=0; INBOX_REVIEW=0; INBOX_INVALID=0
    _is_list=$(task_files "$1/inbox")
    [ -z "$_is_list" ] && return 0
    _is_file=$(mktemp)
    printf '%s\n' "$_is_list" | while IFS= read -r _is_f; do
        [ -z "$_is_f" ] && continue
        if ! fm_valid "$_is_f"; then echo invalid; continue; fi
        case "$(fm_get "$_is_f" tier)" in
            strong) echo review ;;
            any) echo run ;;
            *) echo invalid ;;
        esac
    done >"$_is_file"
    INBOX_RUN=$(grep -c '^run$' "$_is_file")
    INBOX_REVIEW=$(grep -c '^review$' "$_is_file")
    INBOX_INVALID=$(grep -c '^invalid$' "$_is_file")
    rm -f "$_is_file"
    return 0
}

dead_scan() { # $1=tasks_root $2=outfile -> appends "<id> behind failed <dep>" lines (D12)
    _dsc_backlog=$(task_files "$1/backlog")
    [ -z "$_dsc_backlog" ] && return 0
    printf '%s\n' "$_dsc_backlog" | while IFS= read -r _dsc_bf; do
        [ -z "$_dsc_bf" ] && continue
        fm_valid "$_dsc_bf" || continue
        _dsc_bid=$(basename "$_dsc_bf"); _dsc_bid=${_dsc_bid%.md}
        for _dsc_dep in $(fm_list "$_dsc_bf" depends_on); do
            if [ -f "$1/failed/$_dsc_dep.md" ]; then
                printf '%s behind failed %s\n' "$_dsc_bid" "$_dsc_dep" >>"$2"
                break
            fi
        done
    done
    return 0
}
```

(Prefix `_dsc_`, not `_ds_` — `dep_satisfied` already owns `_ds_` (`_lib.sh:192`), and `_lib.sh:146-147` pins one unique prefix per function so direct calls can never clobber the caller's vars.)

In `status_block`, replace the inbox printf

```sh
    printf '  inbox    %s ready      [%s]\n' "$_sb_ninbox" "$(stems_join "$_sb_inbox")"
```

with

```sh
    inbox_split "$_sb_tasks"
    _sb_split="run $INBOX_RUN, review $INBOX_REVIEW"
    [ "$INBOX_INVALID" -gt 0 ] && _sb_split="$_sb_split, invalid $INBOX_INVALID"
    printf '  inbox    %s ready      (%s) [%s]\n' "$_sb_ninbox" "$_sb_split" "$(stems_join "$_sb_inbox")"
```

and replace the inline dead scan — this exact span (`_lib.sh:732-745`, including the outer `if`/`fi`; leaving the `fi` behind is a shell syntax error):

```sh
    _sb_deadfile=$(mktemp)
    if [ -n "$_sb_backlog" ]; then
        printf '%s\n' "$_sb_backlog" | while IFS= read -r _sb_bf; do
            [ -z "$_sb_bf" ] && continue
            fm_valid "$_sb_bf" || continue
            _sb_bid=$(basename "$_sb_bf"); _sb_bid=${_sb_bid%.md}
            for _sb_dep in $(fm_list "$_sb_bf" depends_on); do
                if [ -f "$_sb_tasks/failed/$_sb_dep.md" ]; then
                    printf '%s behind failed %s\n' "$_sb_bid" "$_sb_dep" >>"$_sb_deadfile"
                    break
                fi
            done
        done
    fi
```

with:

```sh
    _sb_deadfile=$(mktemp)
    dead_scan "$_sb_tasks" "$_sb_deadfile"
```

(`dead_scan` handles the empty-backlog case itself. The existing lines from `_sb_ndead=$(wc -l <"$_sb_deadfile" | tr -d ' ')` onward — `_sb_deadcell` build, `rm -f`, backlog printf — stay unchanged.)

- [ ] **Step 4: Run both engines**

Run: `Invoke-Pester tests/Claim.Tests.ps1 -Output Detailed`
Expected: PASS.

Run: `$env:MUSTER_ENGINE = 'sh'; Invoke-Pester tests/Claim.Tests.ps1 -Output Detailed; Remove-Item Env:\MUSTER_ENGINE`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add runtime/bin/_lib.sh tests/Claim.Tests.ps1
git commit -m "feat: dispatch split in status block inbox line (sh) + claim assertion"
```

---

### Task 3: bin/status scripts

**Files:**
- Create: `runtime/bin/status.ps1`
- Create: `runtime/bin/status.sh`
- Test: `tests/Status.Tests.ps1` (create)

- [ ] **Step 1: Write the failing behavior tests**

Create `tests/Status.Tests.ps1`:

```powershell
BeforeAll { . (Join-Path $PSScriptRoot 'MusterFixture.ps1') }

Describe 'bin/status' {
    BeforeEach { $script:fx = New-MusterFixture }
    AfterEach { Remove-MusterFixture $script:fx }

    It 'prints the empty-board line and exits 0 on an empty board' {
        $r = Invoke-Muster $script:fx 'status'
        $r.Exit | Should -Be 0
        $r.Text | Should -Match 'MUSTER: board empty - nothing sharded or all archived\.'
    }
    It 'prints the status block with the dispatch split and exits 0' {
        New-TaskFile -Fixture $script:fx -Folder inbox -Id 'p-01-a' -Commit | Out-Null
        New-TaskFile -Fixture $script:fx -Folder inbox -Id 'p-02-review-a' -Type review -Tier strong -Commit | Out-Null
        $r = Invoke-Muster $script:fx 'status'
        $r.Exit | Should -Be 0
        $r.Out[0] | Should -Match '^MUSTER status @'
        $r.Text | Should -Match '\(run 1, review 1\) \[p-01-a, p-02-review-a\]'
    }
    It 'flags invalid inbox files in the split' {
        New-TaskFile -Fixture $script:fx -Folder inbox -Id 'p-01-a' -Commit | Out-Null
        [IO.File]::WriteAllText((Join-Path $script:fx 'tasks/inbox/p-02-broken.md'), "no frontmatter`n", $script:Utf8NoBom)
        $r = Invoke-Muster $script:fx 'status'
        $r.Exit | Should -Be 0
        $r.Text | Should -Match '\(run 1, review 0, invalid 1\)'
    }
    It 'shows STALE and DEAD markers like the claim print' {
        New-TaskFile -Fixture $script:fx -Folder doing -Id 'p-01-a' `
            -ExtraFront @('claimed_at: 2026-08-01T00:00:00Z') -Commit | Out-Null
        New-TaskFile -Fixture $script:fx -Folder failed -Id 'p-02-b' -Commit | Out-Null
        New-TaskFile -Fixture $script:fx -Folder backlog -Id 'p-03-c' -DependsOn @('p-02-b') -Commit | Out-Null
        $r = Invoke-Muster $script:fx 'status'
        $r.Exit | Should -Be 0
        $r.Text | Should -Match 'STALE'
        $r.Text | Should -Match '1 DEAD: p-03-c behind failed p-02-b'
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `Invoke-Pester tests/Status.Tests.ps1 -Output Detailed`
Expected: all 4 FAIL (`status.ps1` does not exist; `Invoke-Muster` reports a non-zero exit / missing file).

- [ ] **Step 3: Create the scripts**

`runtime/bin/status.ps1`:

```powershell
# MUSTER status - on-demand board print (spec 8.3). Not part of the RUNNER contract.
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_lib.ps1')

Write-Output (Get-StatusBlock -RepoRoot (Get-RepoRoot) -TasksRoot (Get-TasksRoot))
exit 0
```

`runtime/bin/status.sh` (LF line endings, like the other .sh files):

```sh
#!/bin/sh
# MUSTER status (sh) - on-demand board print (spec 8.3). Not part of the RUNNER contract.
set -u
. "$(dirname "$0")/_lib.sh"

root=$(repo_root) || refuse 'not inside a git repository.'
status_block "$root" "$root/tasks"
exit 0
```

(The explicit guard matters here and not in the other sh verbs: `repo_root` is a bare
`git rev-parse --show-toplevel` with no refusal, and `status` is the one script marketed
for bare-terminal use — without the guard, running it outside a repo would print
`MUSTER: board empty` and exit 0, which is actively misleading. The ps1 side needs no
guard: `Get-RepoRoot` already refuses with the same message. No automated test — the
fixture harness always runs inside a repo; verify once by hand if desired.)

- [ ] **Step 4: Run both engines**

Run: `Invoke-Pester tests/Status.Tests.ps1 -Output Detailed`
Expected: 4 PASS.

Run: `$env:MUSTER_ENGINE = 'sh'; Invoke-Pester tests/Status.Tests.ps1 -Output Detailed; Remove-Item Env:\MUSTER_ENGINE`
Expected: 4 PASS.

- [ ] **Step 5: Commit**

```bash
git add runtime/bin/status.ps1 runtime/bin/status.sh tests/Status.Tests.ps1
git commit -m "feat: bin/status - on-demand board print"
```

---

### Task 4: board line in done output

**Files:**
- Modify: `runtime/bin/_lib.ps1` (add `Get-BoardLine` below `Get-StatusBlock`)
- Modify: `runtime/bin/_lib.sh` (add `board_line` below `status_block`)
- Modify: `runtime/bin/done.ps1`, `runtime/bin/done.sh`
- Test: `tests/Lib.Tests.ps1`, `tests/Done.Tests.ps1`

- [ ] **Step 1: Write the failing unit test**

Append to `tests/Lib.Tests.ps1`:

```powershell
Describe 'Get-BoardLine' {
    BeforeEach { $script:fx = New-MusterFixture }
    AfterEach { Remove-MusterFixture $script:fx }

    It 'prints counts only, with DEAD marker, no task ids' {
        New-TaskFile -Fixture $script:fx -Folder inbox -Id 'p-02-b' | Out-Null
        New-TaskFile -Fixture $script:fx -Folder failed -Id 'p-01-a' | Out-Null
        New-TaskFile -Fixture $script:fx -Folder backlog -Id 'p-03-c' -DependsOn @('p-01-a') | Out-Null
        New-TaskFile -Fixture $script:fx -Folder done -Id 'p-00-z' | Out-Null
        Get-BoardLine -TasksRoot (Join-Path $script:fx 'tasks') |
            Should -Be 'Board: run 1 | review 0 | backlog 1 (1 DEAD) | failed 1 | done 1'
    }
    It 'appends invalid after review only when present, omits DEAD at zero' {
        New-TaskFile -Fixture $script:fx -Folder inbox -Id 'p-01-a' | Out-Null
        [IO.File]::WriteAllText((Join-Path $script:fx 'tasks/inbox/p-02-broken.md'), "no frontmatter`n", $script:Utf8NoBom)
        Get-BoardLine -TasksRoot (Join-Path $script:fx 'tasks') |
            Should -Be 'Board: run 1 | review 0 | invalid 1 | backlog 0 | failed 0 | done 0'
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `Invoke-Pester tests/Lib.Tests.ps1 -Output Detailed`
Expected: 2 new tests FAIL (`Get-BoardLine` not recognized); rest PASS.

- [ ] **Step 3: Implement both engines**

Insert below `Get-StatusBlock`'s closing brace in `runtime/bin/_lib.ps1`:

```powershell
function Get-BoardLine {
    # Counts-only board summary for done output (spec 4.3). Never prints task ids.
    param([string]$TasksRoot)
    $split = Get-InboxSplit -TasksRoot $TasksRoot
    $dead = Get-DeadEntries -TasksRoot $TasksRoot
    $parts = @("run $($split.Run)", "review $($split.Review)")
    if ($split.Invalid -gt 0) { $parts += "invalid $($split.Invalid)" }
    $backlogCell = "backlog $(@(Get-TaskFiles (Join-Path $TasksRoot 'backlog')).Count)"
    if ($dead.Count -gt 0) { $backlogCell += " ($($dead.Count) DEAD)" }
    $parts += $backlogCell
    $parts += "failed $(@(Get-TaskFiles (Join-Path $TasksRoot 'failed')).Count)"
    $parts += "done $(@(Get-TaskFiles (Join-Path $TasksRoot 'done')).Count)"
    return 'Board: ' + ($parts -join ' | ')
}
```

Insert below `status_block`'s closing brace in `runtime/bin/_lib.sh`:

```sh
board_line() { # $1=tasks_root -> prints the counts-only board summary (spec 4.3), no task ids
    inbox_split "$1"
    _bl_nbacklog=$(nz_count "$(task_files "$1/backlog")")
    _bl_nfailed=$(nz_count "$(task_files "$1/failed")")
    _bl_ndone=$(nz_count "$(task_files "$1/done")")
    _bl_deadfile=$(mktemp)
    dead_scan "$1" "$_bl_deadfile"
    _bl_ndead=$(wc -l <"$_bl_deadfile" | tr -d ' ')
    rm -f "$_bl_deadfile"
    _bl="Board: run $INBOX_RUN | review $INBOX_REVIEW"
    [ "$INBOX_INVALID" -gt 0 ] && _bl="$_bl | invalid $INBOX_INVALID"
    _bl="$_bl | backlog $_bl_nbacklog"
    [ "$_bl_ndead" -gt 0 ] && _bl="$_bl ($_bl_ndead DEAD)"
    _bl="$_bl | failed $_bl_nfailed | done $_bl_ndone"
    printf '%s\n' "$_bl"
}
```

- [ ] **Step 4: Run the unit tests**

Run: `Invoke-Pester tests/Lib.Tests.ps1 -Output Detailed`
Expected: all PASS.

- [ ] **Step 5: Write the failing done behavior test**

Append inside `Describe 'bin/done - preconditions and pass path'` in `tests/Done.Tests.ps1` (next to `It 'completes an impl task: ...'`, using the block's existing `Add-ClaimedImpl` helper at `tests/Done.Tests.ps1:7-16`).

ORDER MATTERS: `p-02-b` must be committed BEFORE `Add-ClaimedImpl`. The claim commit is the last commit touching `tasks/doing/<id>.md`; a commit landing on `tasks/` after it trips the done scope guard (D27) — `Test-PathInScope` rejects every `tasks/*` path — and `done` refuses with exit 1. The same hazard is documented at `tests/Done.Tests.ps1:85-87`. Claim ordering is unaffected: the fixture writes straight into `doing/`, and the board math is the same.

```powershell
    It 'prints the counts-only board line directly before the terminal line' {
        New-TaskFile -Fixture $script:fx -Folder inbox -Id 'p-02-b' -Commit | Out-Null
        Add-ClaimedImpl
        $r = Invoke-Muster $script:fx 'done'
        $r.Exit | Should -Be 0
        $r.Out[-1] | Should -Match '^Done: p-01-a\. .*Session over\.$'
        $r.Out[-2] | Should -Be 'Board: run 1 | review 0 | backlog 0 | failed 0 | done 1'
    }
```

- [ ] **Step 6: Run to verify it fails**

Run: `Invoke-Pester tests/Done.Tests.ps1 -Output Detailed`
Expected: the new test FAILS (`$r.Out[-2]` is not the board line); rest PASS.

- [ ] **Step 7: Wire the call sites**

In `runtime/bin/done.ps1`, replace

```powershell
Write-Output "Done: $id. Promoted: $plist. Do not claim another task. Session over."
```

with

```powershell
Write-Output (Get-BoardLine -TasksRoot $tasks)
Write-Output "Done: $id. Promoted: $plist. Do not claim another task. Session over."
```

In `runtime/bin/done.sh`, replace

```sh
echo "Done: $_d_id. Promoted: $_d_plist. Do not claim another task. Session over."
```

with

```sh
board_line "$tasks"
echo "Done: $_d_id. Promoted: $_d_plist. Do not claim another task. Session over."
```

(Success path only — the `done fail` branches exited earlier; their output is unchanged by design.)

- [ ] **Step 8: Run both engines**

Run: `Invoke-Pester tests/Done.Tests.ps1 -Output Detailed`
Expected: all PASS.

Run: `$env:MUSTER_ENGINE = 'sh'; Invoke-Pester tests/Done.Tests.ps1 -Output Detailed; Remove-Item Env:\MUSTER_ENGINE`
Expected: all PASS.

- [ ] **Step 9: Commit**

```bash
git add runtime/bin/_lib.ps1 runtime/bin/_lib.sh runtime/bin/done.ps1 runtime/bin/done.sh tests/Lib.Tests.ps1 tests/Done.Tests.ps1
git commit -m "feat: counts-only board line in done output"
```

---

### Task 5: docs + full-suite verification

**Files:**
- Modify: `docs/superpowers/specs/2026-08-07-muster-v1.md` (sections 1, 4.0, 4.3, 8.3)
- Modify: `README.md`

- [ ] **Step 1: Spec section 1 — bin/ listing**

Replace

```
  bin/              claim / verify / done / promote (.ps1 + .sh each)
```

with

```
  bin/              claim / verify / done / promote / lint / status (.ps1 + .sh each)
```

(`lint` was already installed but missing from this listing — folded into the same edit.)

- [ ] **Step 2: Spec section 4.0 — verb-count note**

After the bullet beginning `- Four verbs only (D17):`, append to that bullet's text:

```
  `lint` (2.6) and `status` (8.3) also ship in bin/ but are not RUNNER verbs -
  humans and the orchestrator call them; executors never do.
```

- [ ] **Step 3: Spec section 4.3 — board line in step 10**

Replace

```
10. Print: `Done: <id>. Promoted: <ids or none>. Do not claim another task.
    Session over.`
```

with

```
10. Print the counts-only board summary, then the terminal line (which stays
    literally last):
    `Board: run <n> | review <n> | backlog <n> (<n> DEAD) | failed <n> | done <n>`
    `Done: <id>. Promoted: <ids or none>. Do not claim another task. Session over.`
    Split rule as in 8.3: `invalid <n> |` appears after `review <n>` only when
    unparseable inbox files exist; `(<n> DEAD)` only when nonzero. No task ids -
    counts only. Success path only; the fail branches keep their own output.
```

- [ ] **Step 4: Spec section 8.3 — split format + callers note + stale heading**

Fix the heading first — the status print is claim step 2 (spec 4.1 step 2; `claim.ps1:16` comment `# 2. status print`), not step 3. Replace

```
### 8.3 Status print (claim step 3, exact format)
```

with

```
### 8.3 Status print (claim step 2, exact format)
```

Then replace the fenced status-block example's inbox line

```
  inbox    <n> ready      [<ids, filename order>]
```

with

```
  inbox    <n> ready      (run <n>, review <n>) [<ids, filename order>]
```

After the fenced block's existing bullet list, add:

```
- Dispatch split: `run` counts `tier: any` inbox tasks, `review` counts
  `tier: strong` (claim's two-way tier pinning makes these exactly what
  `/muster:run` and `/muster:review` can claim). Always printed, zeros
  included. Inbox files with unparseable frontmatter or an illegal tier count
  toward `<n>` and toward neither bucket; when any exist, `, invalid <n>` is
  appended inside the parentheses. Parse-level check only - no schema
  validation at print time, and "unparseable" is as strict as the engine's own
  frontmatter parser (ps1 rejects more defect classes than sh), so the invalid
  count on a hand-damaged board may differ between engines. Boards of
  schema-valid tasks print identically on both.
- Three callers share this block: `claim` step 2, `bin/status` (on-demand,
  not a RUNNER verb), and `done`'s counts-only `Board:` summary line (4.3)
  reuses the same split and DEAD scan.
```

- [ ] **Step 5: README — bin listing, status bullet, done bullet**

In the folder diagram, replace

```
bin/     -- claim / verify / done / promote / lint (.ps1 + .sh each)
```

with

```
bin/     -- claim / verify / done / promote / lint / status (.ps1 + .sh each)
```

In the script bullet list, extend the `done` bullet's final sentence: after `and
makes the single completion commit (code + sidecars + task move + promotions).`
append ` Its last output is a counts-only board summary plus the session-over
line, so the human reading the session tail knows what to dispatch next.`

Add a bullet after `lint`:

```
- `status` prints the same board block on demand -- from a bare terminal or any
  session, no claim required. Not part of the RUNNER contract; executors never
  run it.
```

- [ ] **Step 6: Full suite, both engines; update README test counts**

Run: `Invoke-Pester tests -Output Detailed`
Expected: all PASS. Note the total test count printed.

Run: `$env:MUSTER_ENGINE = 'sh'; Invoke-Pester tests/Claim.Tests.ps1, tests/Done.Tests.ps1, tests/Promote.Tests.ps1, tests/Verify.Tests.ps1, tests/Lint.Tests.ps1, tests/Status.Tests.ps1 -Output Detailed; Remove-Item Env:\MUSTER_ENGINE`
Expected: all PASS. Note the total.

In `README.md`, update the counts sentence (currently `141 tests total (87 ps1 + 54 sh; ...)`) with the two totals just observed — do not guess them; copy from the Pester output.

- [ ] **Step 7: Commit**

```bash
git add docs/superpowers/specs/2026-08-07-muster-v1.md README.md
git commit -m "docs: spec + README amendments for board visibility"
```

---

## Out of scope

- `/muster:status` skill wrapper, full folder-content dump at `done`, explicit
  `next: /muster:<verb>` hint line — all deliberately excluded by the design spec.
- Harness (claude/codex) dimension in the dispatch split — deferred until Codex
  activates (D16); noted in the design spec.
- Aligning sh `fm_valid` parse strength with ps1 `Read-Frontmatter` (see the
  accepted asymmetry note under "Pinned output formats").
- `RUNNER.md`, `muster:init` / `muster:shard` / `muster:close` skill prose — no
  changes; init's copy-everything step ships `status.*` for free.
- `registry.json`, v2 control-plane viewer.

## Not yet specified

- Nothing — output formats, bucket rules, and the file layout are pinned above.

## Self-review notes

- Spec coverage: design piece 1 → Tasks 1-2; piece 2 → Task 3; piece 3 → Task 4; "Costs (accepted)" doc list → Task 5; error handling (empty board exit 0, invalid counting, no-repo refusal via `_lib`'s existing `Get-RepoRoot`/`repo_root` failure) → Tasks 3-4 tests cover the first two, the third is existing lib behavior.
- Formats pinned once in "Pinned output formats" and repeated verbatim in tests and spec amendments — keep them byte-identical when executing.
- `Get-DeadEntries` extraction changes no behavior: the moved loop is byte-equivalent to the inline original.
