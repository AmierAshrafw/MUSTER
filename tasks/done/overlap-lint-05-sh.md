---
id: overlap-lint-05-sh
plan: overlap-lint
type: impl
tier: any
depends_on:
  - overlap-lint-04-review-ps1
protected:
  - tests/
  - runtime/bin/_lib.ps1
commit_paths:
  - runtime/bin/_lib.sh
verify:
  - cmd: cmd /c "set MUSTER_ENGINE=sh& powershell -NoProfile -ExecutionPolicy Bypass -Command Invoke-Pester tests\LintOverlap.Tests.ps1 -Output Detailed"
    expect_exit: 0
    expect_contains: "Failed: 0,"
    timeout_seconds: 900
  - cmd: cmd /c "set MUSTER_ENGINE=sh& powershell -NoProfile -ExecutionPolicy Bypass -Command Invoke-Pester tests\Lint.Tests.ps1 -Output Detailed"
    expect_exit: 0
    expect_contains: "Failed: 0,"
    timeout_seconds: 900
claimed_at: 2026-08-13T01:19:21Z
---
# overlap-lint-05-sh: check 15 in the POSIX sh engine (parity mirror)

## Context

Mirror batch check 15 (decision D32) into runtime/bin/_lib.sh. The PowerShell
engine already implements it; parity is mandatory (D6) - the sh engine must emit
byte-identical finding text, and the ps1 output is authoritative. The Pester
suite exercises the sh engine when the MUSTER_ENGINE environment variable is
"sh", which is exactly what the verify commands above do: cmd /c sets the
variable, then the child powershell run inherits it. The backslash in the test
path keeps the whole quoted payload free of forward slashes, which the verify
tokenizer's repo-path heuristic would otherwise misread; Pester resolves the
backslash form identically on Windows.

Interfaces already in runtime/bin/_lib.sh that the new code uses:

- lint_checks (starts at line 436): per-task loop writes findings one per line
  into "${LINT_OUT:-/dev/null}". Schema-clean tasks land in the temp file
  "$_lint_clean", one line each, three tab-separated columns:
  id, type, absolute file path. "$_lint_tab" holds a literal tab. Batch-only
  checks 11 and 12 sit inside the "if [ "$_lint_lite" != '1' ]" block; check 12's
  loop ends with: done <"$_lint_clean" (line 715), and the block's closing "fi"
  is on line 716.
- fm_list: "$1"=file "$2"=key, prints block-list items one per line ([] yields
  nothing).
- path_listed: "$1"=path "$2"=newline-separated list; exit 0 when the path
  equals an entry or sits under a listed directory (prefix-aware).

## Steps

1. Ensure this helper sits in runtime/bin/_lib.sh immediately before the line
   "lint_checks() {" (line 436 before this edit):

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

2. Ensure this block sits inside lint_checks, inside the
   "if [ "$_lint_lite" != '1' ]" block, after check 12's loop
   (done <"$_lint_clean", line 715 before this edit) and before that block's
   closing "fi":

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

   On the inner overlap test: path_listed "$_lint_pl" "$_lint_hicp" covers "lo
   path sits under a hi path"; the piped subshell covers the reverse ("a hi path
   sits under lo path"). Both directions, mirroring the ps1 double
   Test-PathListed.

3. Ensure no other file changed - in particular runtime/bin/_lib.ps1 and
   everything under tests/ stay untouched.

## Acceptance

- All nine tests in tests/LintOverlap.Tests.ps1 pass on the sh engine, with
  finding text byte-identical to the ps1 engine's.
- All existing tests in tests/Lint.Tests.ps1 still pass on the sh engine.
- Diff touches runtime/bin/_lib.sh only.
