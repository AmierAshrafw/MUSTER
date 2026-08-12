# Commit-paths Overlap Lint (D32) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a shard-lint batch check that FAILs when two `impl`/`fix` tasks share a `commit_path` with no `depends_on` ordering between them, in both the PowerShell and POSIX-sh engines.

**Architecture:** One new batch-phase check (call it check 15) inside `Test-LintChecks` / `lint_checks`, beside the existing batch checks 11-12. It reuses the existing prefix helper (`Test-PathListed` / `path_listed`) for pairwise path overlap and adds one small transitive-reachability walk over the batch `depends_on` DAG. No frontmatter schema change, no new lint severity tier.

**Tech Stack:** PowerShell 5.1 (`runtime/bin/_lib.ps1`), POSIX sh + awk (`runtime/bin/_lib.sh`), Pester tests (`tests/Lint.Tests.ps1`), engine-parameterized via `$env:MUSTER_ENGINE`.

## Global Constraints

- Parity is mandatory (D6): the ps1 and sh engines must emit **byte-identical** finding text. The Pester suite runs against both by toggling `$env:MUSTER_ENGINE` (`sh` = mirror, unset = ps1).
- The lint output grammar stays binary: `LINT FAIL <msg>` (exit 1) / `LINT OK <n>` (exit 0). No WARN tier.
- No change to `Test-TaskSchema` / `schema_errors` - no new frontmatter field.
- The check runs in full batch mode only (`-not $Lite` / `_lint_lite != 1`). Lint-lite (fix tasks) is out of scope by design (see the spec's Accepted limit).
- Reachability is transitive and direction-agnostic: two tasks are ordered if either reaches the other through `depends_on`.
- Run everything from the repo root: `C:/Users/amierashraf.hadi/Downloads/GIT/MUSTER`.

## Reference: the design spec

`docs/superpowers/specs/2026-08-12-commit-paths-overlap-lint-design.md` is the source of truth for the mechanism, message, and accepted limit. This plan implements it.

## File Structure

- `runtime/bin/_lib.ps1` - add `Test-Reaches` helper + check 15 inside `Test-LintChecks`.
- `runtime/bin/_lib.sh` - add `lint_ordered` helper + check 15 inside `lint_checks`.
- `tests/Lint.Tests.ps1` - add a `Describe 'bin/lint - commit_paths overlap (D32)'` block.
- `docs/decisions.md` - add the `D32` ledger entry.

Overlap between the two source files (`_lib.ps1`, `_lib.sh`) is deliberate parity, not duplication; they are separate engines with a shared contract.

---

### Task 1: PowerShell check 15 + tests (TDD)

**Files:**
- Modify: `tests/Lint.Tests.ps1` (append a new `Describe` block after the existing `Describe 'bin/lint'` block, i.e. after its closing brace on line 164)
- Modify: `runtime/bin/_lib.ps1` (add `Test-Reaches` immediately before `function Test-LintChecks` at line 414; add check 15 inside the `if (-not $Lite)` block, after check 12, before the closing `}` at line 571)

- [ ] **Step 1: Write the failing tests**

Append to `tests/Lint.Tests.ps1`:

```powershell
Describe 'bin/lint - commit_paths overlap (D32)' {
    BeforeEach { $script:fx = New-MusterFixture }
    AfterEach { Remove-MusterFixture $script:fx }

    # NOTE: the minimal 2-task fixtures below also trip check 11 (no integration task),
    # so the batch exit is 1 regardless. The pass-case assertions therefore check that
    # the overlap message is ABSENT, not that exit is 0 - matching the existing
    # 'check 3'/'check 5' style in the block above.

    It 'FAILs two impl tasks sharing a commit_path with no ordering' {
        New-TaskFile -Fixture $script:fx -Folder backlog -Id 'p-01-a' -CommitPaths @('src/foo.txt') | Out-Null
        New-TaskFile -Fixture $script:fx -Folder backlog -Id 'p-02-b' -CommitPaths @('src/foo.txt') | Out-Null
        $r = Invoke-MusterLint $script:fx -Paths @('tasks/backlog/p-01-a.md', 'tasks/backlog/p-02-b.md')
        $r.Exit | Should -Be 1
        $r.Text | Should -Match "commit_path 'src/foo.txt' also written by 'p-02-b'"
    }
    It 'passes when the two are directly ordered' {
        New-TaskFile -Fixture $script:fx -Folder backlog -Id 'p-01-a' -CommitPaths @('src/foo.txt') | Out-Null
        New-TaskFile -Fixture $script:fx -Folder backlog -Id 'p-02-b' -CommitPaths @('src/foo.txt') `
            -DependsOn @('p-01-a') | Out-Null
        $r = Invoke-MusterLint $script:fx -Paths @('tasks/backlog/p-01-a.md', 'tasks/backlog/p-02-b.md')
        $r.Text | Should -Not -Match 'commit_path'
    }
    It 'passes when ordered transitively through a review task (D19 shape)' {
        New-TaskFile -Fixture $script:fx -Folder backlog -Id 'p-01-a' -CommitPaths @('src/foo.txt') | Out-Null
        New-TaskFile -Fixture $script:fx -Folder backlog -Id 'p-02-review-a' -Type review -Tier strong `
            -DependsOn @('p-01-a') -ExtraFront @('reviews: p-01-a') | Out-Null
        New-TaskFile -Fixture $script:fx -Folder backlog -Id 'p-03-b' -CommitPaths @('src/foo.txt') `
            -DependsOn @('p-02-review-a') | Out-Null
        $r = Invoke-MusterLint $script:fx -Paths @(
            'tasks/backlog/p-01-a.md', 'tasks/backlog/p-02-review-a.md', 'tasks/backlog/p-03-b.md')
        $r.Text | Should -Not -Match 'commit_path'
    }
    It 'FAILs on prefix overlap (dir vs file under it)' {
        New-TaskFile -Fixture $script:fx -Folder backlog -Id 'p-01-a' -CommitPaths @('src/') | Out-Null
        New-TaskFile -Fixture $script:fx -Folder backlog -Id 'p-02-b' -CommitPaths @('src/foo.txt') | Out-Null
        $r = Invoke-MusterLint $script:fx -Paths @('tasks/backlog/p-01-a.md', 'tasks/backlog/p-02-b.md')
        $r.Exit | Should -Be 1
        $r.Text | Should -Match 'no depends_on ordering'
    }
    It 'passes disjoint commit_paths with no ordering' {
        New-TaskFile -Fixture $script:fx -Folder backlog -Id 'p-01-a' -CommitPaths @('src/foo.txt') | Out-Null
        New-TaskFile -Fixture $script:fx -Folder backlog -Id 'p-02-b' -CommitPaths @('src/bar.txt') | Out-Null
        $r = Invoke-MusterLint $script:fx -Paths @('tasks/backlog/p-01-a.md', 'tasks/backlog/p-02-b.md')
        $r.Text | Should -Not -Match 'commit_path'
    }
    It 'FAILs two fix-type tasks sharing a commit_path with no ordering' {
        New-TaskFile -Fixture $script:fx -Folder backlog -Id 'p-01-x' -Type fix `
            -CommitPaths @('src/foo.txt') -ExtraFront @('fixes: p-00-a') | Out-Null
        New-TaskFile -Fixture $script:fx -Folder backlog -Id 'p-02-y' -Type fix `
            -CommitPaths @('src/foo.txt') -ExtraFront @('fixes: p-00-b') | Out-Null
        $r = Invoke-MusterLint $script:fx -Paths @('tasks/backlog/p-01-x.md', 'tasks/backlog/p-02-y.md')
        $r.Exit | Should -Be 1
        $r.Text | Should -Match "commit_path 'src/foo.txt' also written by 'p-02-y'"
    }
    It 'emits a finding per unordered overlapping pair (three-way, deterministic)' {
        New-TaskFile -Fixture $script:fx -Folder backlog -Id 'p-01-a' -CommitPaths @('src/foo.txt') | Out-Null
        New-TaskFile -Fixture $script:fx -Folder backlog -Id 'p-02-b' -CommitPaths @('src/foo.txt') | Out-Null
        New-TaskFile -Fixture $script:fx -Folder backlog -Id 'p-03-c' -CommitPaths @('src/foo.txt') | Out-Null
        $r = Invoke-MusterLint $script:fx -Paths @(
            'tasks/backlog/p-01-a.md', 'tasks/backlog/p-02-b.md', 'tasks/backlog/p-03-c.md')
        $r.Exit | Should -Be 1
        $r.Text | Should -Match "p-01-a.md: commit_path 'src/foo.txt' also written by 'p-02-b'"
        $r.Text | Should -Match "p-01-a.md: commit_path 'src/foo.txt' also written by 'p-03-c'"
        $r.Text | Should -Match "p-02-b.md: commit_path 'src/foo.txt' also written by 'p-03-c'"
    }
    It 'FAILs on prefix overlap in the reverse direction (file under dir)' {
        # test 4 covers lo=dir/hi=file; this covers lo=file/hi=dir - the other arm of
        # the sh double path_listed check (plan Task 2 Step 3).
        New-TaskFile -Fixture $script:fx -Folder backlog -Id 'p-01-a' -CommitPaths @('src/foo.txt') | Out-Null
        New-TaskFile -Fixture $script:fx -Folder backlog -Id 'p-02-b' -CommitPaths @('src/') | Out-Null
        $r = Invoke-MusterLint $script:fx -Paths @('tasks/backlog/p-01-a.md', 'tasks/backlog/p-02-b.md')
        $r.Exit | Should -Be 1
        $r.Text | Should -Match 'no depends_on ordering'
    }
    It 'does not fire on a clean full batch (regression)' {
        New-TaskFile -Fixture $script:fx -Folder backlog -Id 'p-01-a' -CommitPaths @('src/out.txt') | Out-Null
        New-TaskFile -Fixture $script:fx -Folder backlog -Id 'p-02-review-a' -Type review -Tier strong `
            -DependsOn @('p-01-a') -ExtraFront @('reviews: p-01-a') | Out-Null
        New-TaskFile -Fixture $script:fx -Folder backlog -Id 'p-99-integration' -Type integration -Tier strong `
            -DependsOn @('p-01-a', 'p-02-review-a') | Out-Null
        $r = Invoke-MusterLint $script:fx -Paths @(
            'tasks/backlog/p-01-a.md', 'tasks/backlog/p-02-review-a.md', 'tasks/backlog/p-99-integration.md')
        $r.Text | Should -Match 'LINT OK 3'
    }
}
```

- [ ] **Step 2: Run the tests to confirm they fail**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Pester tests/Lint.Tests.ps1 -Output Detailed"`
Expected: the four new `It`s that assert the overlap message (FAIL cases) fail because no such message is produced yet; the "does not fire" regression passes; the pass-cases may already pass (they assert absence). The two FAIL-case tests are the red signal.

- [ ] **Step 3: Add the `Test-Reaches` helper**

Insert immediately before `function Test-LintChecks {` (line 414 of `runtime/bin/_lib.ps1`):

```powershell
function Test-Reaches {
    # True if $From reaches $To by following depends_on edges in $DepMap (transitive, D32).
    # Edges point child -> parent (a task -> the id it depends on). Missing keys are dead ends.
    param([hashtable]$DepMap, [string]$From, [string]$To)
    $seen = @{}
    $stack = New-Object System.Collections.Stack
    $stack.Push($From)
    while ($stack.Count -gt 0) {
        $cur = [string]$stack.Pop()
        if ($seen.ContainsKey($cur)) { continue }
        $seen[$cur] = $true
        if (-not $DepMap.ContainsKey($cur)) { continue }
        foreach ($p in $DepMap[$cur]) {
            if ($p -eq $To) { return $true }
            $stack.Push($p)
        }
    }
    return $false
}
```

- [ ] **Step 4: Add check 15**

Inside `Test-LintChecks`, in the `if (-not $Lite) {` block, after check 12's `foreach` loop and before the block's closing `}` (line 571):

```powershell
        # 15. shared commit_path without depends_on ordering (D32). A weak session's
        #     frozen Steps for one task predate a sibling's committed edits; an unordered
        #     overlap risks a silent clobber caught only by later verify/integration.
        #     Reachability is transitive and either-direction so the D19
        #     A -> review-A -> B chain does not false-positive. Only impl/fix carry
        #     commit_paths (schema), so the pair space is impl/fix x impl/fix.
        $depMap = @{}
        foreach ($dt in @($batch | Where-Object { $_.Errors.Count -eq 0 })) {
            # ContainsKey guard: a parse-clean but schema-invalid task can lack depends_on;
            # @($dt.Fields['depends_on']) would then be @($null) under StrictMode (review S2).
            if ($dt.Fields.ContainsKey('depends_on')) { $depMap[$dt.Id] = @($dt.Fields['depends_on']) }
            else { $depMap[$dt.Id] = @() }
        }
        $cpTasks = @($batch | Where-Object {
                $_.Errors.Count -eq 0 -and @('impl', 'fix') -contains $_.Fields['type'] -and
                $_.Fields.ContainsKey('commit_paths')
            })
        for ($x = 0; $x -lt $cpTasks.Count; $x++) {
            for ($y = $x + 1; $y -lt $cpTasks.Count; $y++) {
                $lo = $cpTasks[$x]; $hi = $cpTasks[$y]
                # ordinal compare to match the sh mirror's LC_ALL=C sort - PS -lt is
                # culture-aware and would pick a different lo for hyphen-adjacent ids,
                # breaking byte-identical parity (review W1).
                if ([string]::CompareOrdinal($hi.Id, $lo.Id) -lt 0) { $lo = $cpTasks[$y]; $hi = $cpTasks[$x] }
                if ((Test-Reaches -DepMap $depMap -From $lo.Id -To $hi.Id) -or
                    (Test-Reaches -DepMap $depMap -From $hi.Id -To $lo.Id)) { continue }
                $hit = $null
                foreach ($pl in @($lo.Fields['commit_paths'])) {
                    foreach ($ph in @($hi.Fields['commit_paths'])) {
                        if ((Test-PathListed -Path $pl -List @($ph)) -or
                            (Test-PathListed -Path $ph -List @($pl))) { $hit = $pl; break }
                    }
                    if ($hit) { break }
                }
                if ($hit) {
                    $findings += "$($lo.Id).md: commit_path '$hit' also written by '$($hi.Id)' with no depends_on ordering between them - add a dependency edge or reshard."
                }
            }
        }
```

- [ ] **Step 5: Run the tests to confirm they pass**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Pester tests/Lint.Tests.ps1 -Output Detailed"`
Expected: all `It`s in both `Describe` blocks pass.

- [ ] **Step 6: Run the full suite (ps1 engine) for regression**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Pester tests/ -Output Detailed"`
Expected: 0 failed. If any pre-existing test that lints a multi-`impl` batch now fails on the new check, that is a real finding - stop and report it, do not weaken the check.

- [ ] **Step 7: Commit**

```bash
git add runtime/bin/_lib.ps1 tests/Lint.Tests.ps1
git commit -m "feat(lint): flag unordered commit_path overlap (D32, ps1)"
```

---

### Task 2: sh mirror (parity)

**Files:**
- Modify: `runtime/bin/_lib.sh` (add `lint_ordered` helper before `lint_checks` at line 436; add check 15 inside the `if [ "$_lint_lite" != '1' ]` block, after check 12's loop, before the block's closing `fi` at line 716)

- [ ] **Step 1: Confirm the tests are red on the sh engine**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -Command "$env:MUSTER_ENGINE='sh'; Invoke-Pester tests/Lint.Tests.ps1 -Output Detailed; Remove-Item Env:\MUSTER_ENGINE"`
Expected: the two overlap-message `It`s fail (sh has no check 15 yet); the ps1 change from Task 1 does not affect the sh run. This confirms the parity gap before closing it.

- [ ] **Step 2: Add the `lint_ordered` helper**

Insert before `lint_checks() {` (line 436 of `runtime/bin/_lib.sh`):

```sh
lint_ordered() {
    # $1=idA $2=idB $3=edges file (lines "child<TAB>parent"). Exit 0 if A reaches B or
    # B reaches A via transitive depends_on, else 1 (D32). Fixpoint transitive closure in
    # awk; batches are tiny so the O(n * edges) relaxation is fine. New keys are staged in
    # a side array so r is never mutated while iterated (portable across awk variants).
    awk -F'\t' -v a="$1" -v b="$2" '
        { c[NR]=$1; p[NR]=$2; n=NR }
        END {
            for (i=1;i<=n;i++) r[c[i] SUBSEP p[i]]=1
            changed=1
            while (changed) {
                changed=0
                for (i=1;i<=n;i++)
                    for (k in r) {
                        split(k, kv, SUBSEP)
                        if (kv[1]==p[i]) { nk[c[i] SUBSEP kv[2]]=1 }
                    }
                for (key in nk) if (!(key in r)) { r[key]=1; changed=1 }
                delete nk
            }
            if ((a SUBSEP b) in r || (b SUBSEP a) in r) exit 0
            exit 1
        }
    ' "$3"
}
```

- [ ] **Step 3: Add check 15**

Inside `lint_checks`, in the `if [ "$_lint_lite" != '1' ]` block, after check 12's `while ... done <"$_lint_clean"` loop and before the block's closing `fi` (line 716):

```sh
        # 15. shared commit_path without depends_on ordering (D32). Mirror of _lib.ps1.
        _lint_edges=$(mktemp)
        while IFS="$_lint_tab" read -r _lint_cid _lint_ctype _lint_cfp; do
            [ -z "$_lint_cid" ] && continue
            fm_list "$_lint_cfp" depends_on | while IFS= read -r _lint_dep; do
                [ -n "$_lint_dep" ] && printf '%s\t%s\n' "$_lint_cid" "$_lint_dep" >>"$_lint_edges"
            done
        done <"$_lint_clean"
        _lint_cp=$(mktemp)
        while IFS="$_lint_tab" read -r _lint_cid _lint_ctype _lint_cfp; do
            [ -z "$_lint_cid" ] && continue
            case "$_lint_ctype" in
                impl|fix) printf '%s\t%s\n' "$_lint_cid" "$_lint_cfp" >>"$_lint_cp" ;;
            esac
        done <"$_lint_clean"
        _lint_ai=0
        while IFS="$_lint_tab" read -r _lint_aid _lint_afp; do
            [ -z "$_lint_aid" ] && continue
            _lint_ai=$((_lint_ai + 1))
            _lint_bi=0
            while IFS="$_lint_tab" read -r _lint_bid _lint_bfp; do
                [ -z "$_lint_bid" ] && continue
                _lint_bi=$((_lint_bi + 1))
                [ "$_lint_bi" -le "$_lint_ai" ] && continue
                _lint_low=$(printf '%s\n%s\n' "$_lint_aid" "$_lint_bid" | LC_ALL=C sort | head -n1)
                if [ "$_lint_low" = "$_lint_aid" ]; then
                    _lint_lo=$_lint_aid; _lint_lofp=$_lint_afp; _lint_hi=$_lint_bid; _lint_hifp=$_lint_bfp
                else
                    _lint_lo=$_lint_bid; _lint_lofp=$_lint_bfp; _lint_hi=$_lint_aid; _lint_hifp=$_lint_afp
                fi
                if lint_ordered "$_lint_lo" "$_lint_hi" "$_lint_edges"; then continue; fi
                _lint_locp=$(fm_list "$_lint_lofp" commit_paths)
                _lint_hicp=$(fm_list "$_lint_hifp" commit_paths)
                printf '%s\n' "$_lint_locp" | while IFS= read -r _lint_pl; do
                    [ -z "$_lint_pl" ] && continue
                    if path_listed "$_lint_pl" "$_lint_hicp" || \
                       printf '%s\n' "$_lint_hicp" | { while IFS= read -r _lint_ph; do
                           [ -z "$_lint_ph" ] && continue
                           path_listed "$_lint_ph" "$_lint_pl" && exit 0
                       done; exit 1; }; then
                        printf "%s.md: commit_path '%s' also written by '%s' with no depends_on ordering between them - add a dependency edge or reshard.\n" \
                            "$_lint_lo" "$_lint_pl" "$_lint_hi" >>"${LINT_OUT:-/dev/null}"
                        break
                    fi
                done
            done <"$_lint_cp"
        done <"$_lint_cp"
        rm -f "$_lint_edges" "$_lint_cp"
```

Note on the inner overlap test: `path_listed "$pl" "$hicp"` covers "lo path sits under a hi path"; the piped subshell covers the reverse ("a hi path sits under lo path"). Both directions, mirroring the ps1 double `Test-PathListed`.

- [ ] **Step 4: Run the lint tests on the sh engine**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -Command "$env:MUSTER_ENGINE='sh'; Invoke-Pester tests/Lint.Tests.ps1 -Output Detailed; Remove-Item Env:\MUSTER_ENGINE"`
Expected: all `It`s pass, including the D32 block, with the same finding text as ps1.

- [ ] **Step 5: Run the full suite on both engines**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Pester tests/ -Output Detailed"`
Expected: 0 failed (ps1).

Run: `powershell -NoProfile -ExecutionPolicy Bypass -Command "$env:MUSTER_ENGINE='sh'; Invoke-Pester tests/ -Output Detailed; Remove-Item Env:\MUSTER_ENGINE"`
Expected: 0 failed (sh). If sh diverges from ps1 on any finding text, fix the sh code until byte-identical - the ps1 output is authoritative.

- [ ] **Step 6: Commit**

```bash
git add runtime/bin/_lib.sh
git commit -m "feat(lint): flag unordered commit_path overlap (D32, sh mirror)"
```

---

### Task 3: D32 decision-ledger entry

**Files:**
- Modify: `docs/decisions.md` (add `## D32` after the D31 block, before the `## Rejected` section)

- [ ] **Step 1: Add the D32 entry**

Insert after the D31 block and before `## Rejected (do not reopen without new facts)`:

```markdown
## D32. Shard-lint flags unordered commit_path overlap

Two `impl`/`fix` tasks may name the same `commit_path` with no `depends_on` edge
between them. Nothing detected it: `Test-LintChecks` read `commit_paths` per-task
only (checks 5, 13); the batch checks were just integration-count (11) and review
wiring (12). Execution is serial (D18) so there is no git race, but the second
same-file task's Steps are frozen at shard time against a view of the file that
predates the first task's committed edits. Non-additive Steps then silently
overwrite the first task's work at HEAD, caught only if a later verify or the
integration suite re-covers the clobbered code. Additive appends (MUSTER's own
`_lib.ps1` was built this way) are fine, but a lint cannot tell additive from
destructive - a shared path is a risk signal, not a proven defect.

New batch check (15): FAIL when two `impl`/`fix` tasks share a `commit_path`
(prefix-aware) with no transitive, either-direction `depends_on` ordering between
them. The author adds an edge (`Add-DependsOn`-shaped, one line) or reshards. The
forced edge costs nothing under D18's serial execution and stays correct under
future worktree concurrency (you cannot safely parallel-edit one file).
Reachability is transitive so the D19 `A -> review-A -> B` chain does not
false-positive.

Boundary: the check is full-batch only. Reviewer-authored fix tasks are linted
solo via lint-lite (no batch), so they are out of scope - acceptable because a
fix task is authored against the impl's real committed diff, not a stale plan
view, so it is the one same-file case without stale-Steps risk.

Rejected alternatives (solution-auditor pass, 2026-08-12):
- Done-time clobber detection: opposes D22 (reject shard output, not executor
  mess), fires after a burned session, fuzzy attribution. Parked as KIV; revisit
  only if fix-task overlap is seen in practice.
- `overlap_ack:` frontmatter marker: unbacked self-attestation (cf. D30), adds
  schema surface for a false positive D18 already makes harmless.
- WARN severity tier: breaks the binary LINT grammar for weaker enforcement.
- FAIL only when the shared path is not also `protected`: unsafe - `protected`
  does not make a write additive, and D30 dual-lists self-authored tests in both
  lists, so the predicate would wave through the exact clobber shape.

Source: analysis session 2026-08-12 + solution-auditor.
```

- [ ] **Step 2: Add the KIV line for the parked alternative**

In the same file, under `## KIV (revisit later, do not delete)`, add:

```markdown
- Done-time / executor-stage commit_path clobber detection (D32 alternative) - only if fix-task overlap is observed in practice.
```

- [ ] **Step 3: Commit**

```bash
git add docs/decisions.md
git commit -m "docs: record D32 (commit_path overlap lint) in the decision ledger"
```

---

## Self-Review

**Spec coverage:** mechanism (Task 1/2 check 15), transitive reachability (`Test-Reaches` / `lint_ordered`), prefix overlap (reused `Test-PathListed` / `path_listed` both directions), message (verbatim in both engines), accepted lint-lite limit (constraint + D32 boundary), tests (Task 1 Step 1, the six spec cases plus fix-type, three-way-determinism, and reverse-prefix from plan review S1), decision entry (Task 3). No spec requirement left without a task.

**Placeholder scan:** every code step carries complete code; every run step carries an exact command and expected result. No TBD/TODO.

**Type consistency:** the finding string is identical across `_lib.ps1` check 15, `_lib.sh` check 15, the D32 entry, and every test assertion. `Test-Reaches` / `lint_ordered` signatures match their call sites. `Test-PathListed` / `path_listed` are used with their real signatures (verified against `_lib.ps1:686`, `_lib.sh:884`).

## Not yet specified

Way is fully clear. No in-scope item is too blurry to plan.

## Out of scope

- Done-time clobber detection (parked KIV in D32).
- The action-verb / idempotency lint (original "Fix B", cut for YAGNI).
- Any new lint severity tier (no WARN).
- Any auto-insertion of `depends_on` by the lint - it reports, the author edits.
- Spaces inside `commit_paths` values on the sh engine: `fm_list` word-splitting in `$(...)` assumes path tokens have no spaces, consistent with every existing sh check. Not introduced by this work; not fixed here.
- Participant-set divergence on schema-invalid batches (plan review W2): check 15 selects by `Errors.Count` (ps1) vs `_lint_clean`/schema-clean (sh), so a parse-clean-but-schema-invalid task is scanned by one engine only. Cosmetic - a schema-invalid batch already fails - and it mirrors the pre-existing checks 11/12 split, not introduced here. Aligning the 11/12/15 participant filter across engines is a separate cleanup, tracked outside this plan.
