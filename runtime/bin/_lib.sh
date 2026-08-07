# MUSTER shared library (sh mirror of _lib.ps1). Sourced by every verb script.
set -u

repo_root() { git rev-parse --show-toplevel; }
tasks_root() { echo "$(repo_root)/tasks"; }
iso_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

refuse() { echo "MUSTER refuse: $1"; exit 1; }

task_files() { # $1 = absolute folder; task .md files only, sorted
    ls "$1"/*.md 2>/dev/null | grep -v '\.result\.md$' | grep -v '\.notes\.md$' | sort
}

fm_get() { # $1=file $2=key -> scalar value, quotes stripped, empty if absent
    awk -v k="$2" '
        NR==1 && $0!="---" { exit }
        NR>1 && $0=="---" { exit }
        index($0, k": ")==1 { v=substr($0, length(k)+3); gsub(/^"|"$/, "", v); print v; exit }
    ' "$1"
}

fm_list() { # $1=file $2=key -> block-list items, one per line ([] yields nothing)
    awk -v k="$2" '
        NR>1 && $0=="---" { exit }
        on && $0 !~ /^[ ]+- / { exit }
        on { s=$0; sub(/^[ ]+- /, "", s); gsub(/^"|"$/, "", s); print s }
        $0==k":" { on=1 }
    ' "$1"
}

fm_verify() { # $1=file -> flat records "idx<TAB>key<TAB>value" for the verify block
    awk '
        NR>1 && $0=="---" { exit }
        $0=="verify:" { on=1; idx=0; next }
        on && /^  - [a-z_]+: / { idx++; s=substr($0,5); emit(s); next }
        on && /^    [a-z_]+: / { s=substr($0,5); emit(s); next }
        on { exit }
        function emit(s,   k, v) {
            k=s; sub(/:.*/, "", k)
            v=s; sub(/^[a-z_]+: /, "", v); gsub(/^"|"$/, "", v)
            printf "%d\t%s\t%s\n", idx, k, v
        }
    ' "$1"
}

tokenize() { # $1=cmd -> tokens one per line (double quotes group; no shell interp)
    printf '%s' "$1" | awk '
        {
            n=split($0, ch, ""); tok=""; inq=0
            for (i=1; i<=n; i++) {
                c=ch[i]
                if (c=="\"") { inq=!inq; continue }
                if (!inq && (c==" " || c=="\t")) { if (tok!="") { print tok; tok="" }; continue }
                tok=tok c
            }
            if (tok!="") print tok
        }'
}

run_entry() { # $1=timeout_s, rest=tokens. Sets RUN_EXIT, RUN_TIMEDOUT; output in $RUN_OUT file.
    _t=$1; shift
    RUN_TIMEDOUT=0
    "$@" >"$RUN_OUT" 2>&1 &
    _pid=$!
    _n=0
    while kill -0 "$_pid" 2>/dev/null; do
        if [ "$_n" -ge "$_t" ]; then
            kill "$_pid" 2>/dev/null
            RUN_TIMEDOUT=1
            wait "$_pid" 2>/dev/null
            RUN_EXIT=124
            return
        fi
        sleep 1
        _n=$((_n + 1))
    done
    wait "$_pid"
    RUN_EXIT=$?
}

attempt_count() { # $1=log path
    if [ ! -f "$1" ]; then echo 0; return; fi
    grep -c '^=== attempt [0-9]* |' "$1" || true
}

verify_block() {
    # $1=task file (source of the verify block), $2=log, $3=label, $4=task id, $5=repo root
    # Echoes nothing; returns 0 on pass, 1 on fail; first failure reason in $VB_FIRSTFAIL.
    _file=$1; _log=$2; _label=$3; _id=$4; _root=$5
    VB_FIRSTFAIL=''
    _head=$(git -C "$_root" rev-parse HEAD)
    printf '=== %s | %s | task %s | HEAD %s\n' "$_label" "$(iso_now)" "$_id" "$_head" >>"$_log"
    RUN_OUT=$(mktemp)
    _n_entries=$(fm_verify "$_file" | awk -F'\t' '{ if ($1>m) m=$1 } END { print m+0 }')
    _i=1
    _pass=1
    while [ "$_i" -le "$_n_entries" ]; do
        _cmd=$(fm_verify "$_file" | awk -F'\t' -v i="$_i" '$1==i && $2=="cmd" { print $3 }')
        _xexit=$(fm_verify "$_file" | awk -F'\t' -v i="$_i" '$1==i && $2=="expect_exit" { print $3 }')
        _xcont=$(fm_verify "$_file" | awk -F'\t' -v i="$_i" '$1==i && $2=="expect_contains" { print $3 }')
        _tmo=$(fm_verify "$_file" | awk -F'\t' -v i="$_i" '$1==i && $2=="timeout_seconds" { print $3 }')
        [ -z "$_tmo" ] && _tmo=300
        printf '$ %s\n' "$_cmd" >>"$_log"
        set --
        while IFS= read -r _tok; do set -- "$@" "$_tok"; done <<EOF
$(tokenize "$_cmd")
EOF
        ( cd "$_root" && run_entry "$_tmo" "$@" ; echo "$RUN_EXIT $RUN_TIMEDOUT" >"$RUN_OUT.meta" )
        read -r RUN_EXIT RUN_TIMEDOUT <"$RUN_OUT.meta"
        [ -s "$RUN_OUT" ] && sed -e 's/[[:space:]]*$//' "$RUN_OUT" >>"$_log"
        _line=''
        _why=''
        _ok=1
        if [ "$RUN_TIMEDOUT" = "1" ]; then
            _line="timeout ${_tmo}s -> FAIL"; _why="timed out after ${_tmo}s"; _ok=0
        else
            _line="exit $RUN_EXIT"
            if [ -n "$_xexit" ]; then
                if [ "$RUN_EXIT" = "$_xexit" ]; then _line="$_line | expect_exit $_xexit -> OK"
                else _line="$_line | expect_exit $_xexit -> FAIL"; _why="exit $RUN_EXIT, expected $_xexit"; _ok=0; fi
            fi
            if [ -n "$_xcont" ]; then
                if grep -qF "$_xcont" "$RUN_OUT"; then _line="$_line | expect_contains \"$_xcont\" -> OK"
                else _line="$_line | expect_contains \"$_xcont\" -> MISSING"; _why="output missing \"$_xcont\""; _ok=0; fi
            fi
        fi
        printf '%s\n' "$_line" >>"$_log"
        if [ "$_ok" = "0" ]; then
            _pass=0
            VB_FIRSTFAIL="$_cmd: $_why"
            break
        fi
        _i=$((_i + 1))
    done
    rm -f "$RUN_OUT" "$RUN_OUT.meta"
    if [ "$_pass" = "1" ]; then
        printf '=== %s result: PASS\n' "$_label" >>"$_log"
        return 0
    fi
    printf '=== %s result: FAIL\n' "$_label" >>"$_log"
    return 1
}

# --- Task 23 additions: promote + verify helpers (sh mirror of the matching _lib.ps1 funcs) ---
# One sh function per ps1 function, snake_case, same argument order, byte-identical messages.
# No `local`: each function below uses its own unique variable-name prefix so a direct
# (non-subshell) call from another of these functions can never clobber the caller's vars.

fm_error() { # $1=file -> pragmatic first frontmatter error (mirrors Read-Frontmatter's first
    # two checks: opening/closing --- markers), or empty when the file opens and closes cleanly.
    _fe_first=$(awk 'NR==1{print; exit}' "$1")
    if [ "$_fe_first" != "---" ]; then printf 'missing opening --- marker'; return; fi
    _fe_close=$(awk 'NR>1 && $0=="---"{print "1"; exit}' "$1")
    if [ -z "$_fe_close" ]; then printf 'missing closing --- marker'; fi
}

fm_valid() { # $1=file -> true (0) when frontmatter opens+closes cleanly, else false (1)
    [ -z "$(fm_error "$1")" ]
}

sole_occupant() {
    # The one task in doing/. Refuses (exit 1) when empty or ambiguous (spec 4.2/4.3).
    # $1=tasks_root -> sets SOLE_OCCUPANT to the sole file's full path.
    # NOTE: called as a plain statement, never via $(...) - refuse()'s exit must terminate
    # the real script, not a command-substitution subshell that would just swallow it.
    _so_tasks=$1
    _so_files=$(task_files "$_so_tasks/doing")
    if [ -z "$_so_files" ]; then refuse 'doing/ is empty - nothing in progress.'; fi
    _so_count=$(printf '%s\n' "$_so_files" | wc -l | tr -d ' ')
    if [ "$_so_count" -gt 1 ]; then
        refuse "doing/ holds $_so_count task files - one executor per checkout broke. RECOVERY in RUNNER.md."
    fi
    SOLE_OCCUPANT=$_so_files
}

show_head_task() {
    # Claim-time copy: read the task from the HEAD blob, not the working tree (D20).
    # $1=repo_root $2=name (e.g. p-01-a.md) -> sets SHOW_HEAD_TASK to a temp file path
    # holding the blob. NOTE: called as a plain statement, never via $(...) - see sole_occupant.
    _sht_root=$1; _sht_name=$2
    _sht_tmp=$(mktemp)
    if ! git -c core.autocrlf=false -C "$_sht_root" show "HEAD:tasks/doing/$_sht_name" >"$_sht_tmp" 2>/dev/null; then
        rm -f "$_sht_tmp"
        refuse "tasks/doing/$_sht_name is not committed - claim did not complete. RECOVERY in RUNNER.md."
    fi
    SHOW_HEAD_TASK=$_sht_tmp
}

dep_satisfied() {
    # Satisfied = task id present in done/ or anywhere under archive/ (spec 4.4, D15).
    # $1=tasks_root $2=dep_id
    _ds_tasks=$1; _ds_dep=$2
    if [ -f "$_ds_tasks/done/$_ds_dep.md" ]; then return 0; fi
    if [ -d "$_ds_tasks/archive" ]; then
        _ds_hit=$(find "$_ds_tasks/archive" -type f -name "$_ds_dep.md" 2>/dev/null | head -n 1)
        [ -n "$_ds_hit" ] && return 0
    fi
    return 1
}

move_task_sidecars() {
    # .gen<g>.* history sidecars move with their task file (spec 3). Prints commit paths, one per line.
    # $1=repo_root $2=tasks_root $3=id $4=from $5=to
    _mts_root=$1; _mts_tasks=$2; _mts_id=$3; _mts_from=$4; _mts_to=$5
    for _mts_h in "$_mts_tasks/$_mts_from/$_mts_id".gen*; do
        [ -e "$_mts_h" ] || continue
        _mts_hname=$(basename "$_mts_h")
        git -c core.autocrlf=false -C "$_mts_root" mv "tasks/$_mts_from/$_mts_hname" "tasks/$_mts_to/$_mts_hname" 2>/dev/null
        printf 'tasks/%s/%s\n' "$_mts_from" "$_mts_hname"
        printf 'tasks/%s/%s\n' "$_mts_to" "$_mts_hname"
    done
}

move_to_failed() {
    # Terminal move: task + live sidecars -> failed/, one pathspec commit (spec 4.2 step 6).
    # $1=repo_root $2=tasks_root $3=id $4=plan
    _mtf_root=$1; _mtf_tasks=$2; _mtf_id=$3; _mtf_plan=$4
    _mtf_pathsfile=$(mktemp)
    printf 'tasks/doing/%s.md\n' "$_mtf_id" >>"$_mtf_pathsfile"
    printf 'tasks/failed/%s.md\n' "$_mtf_id" >>"$_mtf_pathsfile"
    git -c core.autocrlf=false -C "$_mtf_root" mv "tasks/doing/$_mtf_id.md" "tasks/failed/$_mtf_id.md" 2>/dev/null
    for _mtf_side in "$_mtf_id.verify.log" "$_mtf_id.notes.md"; do
        _mtf_src="$_mtf_tasks/doing/$_mtf_side"
        if [ -f "$_mtf_src" ]; then
            mv "$_mtf_src" "$_mtf_tasks/failed/$_mtf_side"
            git -c core.autocrlf=false -C "$_mtf_root" add "tasks/failed/$_mtf_side" 2>/dev/null
            printf 'tasks/failed/%s\n' "$_mtf_side" >>"$_mtf_pathsfile"
        fi
    done
    git -c core.autocrlf=false -C "$_mtf_root" commit -q -m "muster($_mtf_plan): fail $_mtf_id" -- $(cat "$_mtf_pathsfile") 2>/dev/null
    rm -f "$_mtf_pathsfile"
}

promote_run() {
    # Spec 4.4. $1=no_commit (0/1). Moved ids -> one per line into the file at $PROMOTE_OUT
    # (caller-provided path; use /dev/null to discard). Warn lines print straight to stdout -
    # the same channel ps1's Write-Host reaches regardless of what the caller does with the
    # function's own "return value" (here: the $PROMOTE_OUT file). promote.sh relies on this
    # split: it discards $PROMOTE_OUT but must NOT redirect promote_run's stdout, or the warn
    # line the "skips malformed backlog files" test asserts on would vanish along with it.
    _pr_no_commit=$1
    _pr_root=$(repo_root)
    _pr_tasks=$(tasks_root)
    : >"${PROMOTE_OUT:-/dev/null}"
    _pr_moved=0
    _pr_pathsfile=$(mktemp)
    for _pr_f in $(task_files "$_pr_tasks/backlog"); do
        _pr_name=$(basename "$_pr_f")
        if ! fm_valid "$_pr_f"; then
            echo "MUSTER warn: backlog/$_pr_name frontmatter invalid - skipped by promote."
            continue
        fi
        _pr_id=$(fm_get "$_pr_f" id)
        _pr_ok=1
        for _pr_dep in $(fm_list "$_pr_f" depends_on); do
            if ! dep_satisfied "$_pr_tasks" "$_pr_dep"; then _pr_ok=0; break; fi
        done
        if [ "$_pr_ok" = "1" ]; then
            git -c core.autocrlf=false -C "$_pr_root" mv "tasks/backlog/$_pr_name" "tasks/inbox/$_pr_name" 2>/dev/null
            printf 'tasks/backlog/%s\n' "$_pr_name" >>"$_pr_pathsfile"
            printf 'tasks/inbox/%s\n' "$_pr_name" >>"$_pr_pathsfile"
            move_task_sidecars "$_pr_root" "$_pr_tasks" "$_pr_id" backlog inbox >>"$_pr_pathsfile"
            printf '%s\n' "$_pr_id" >>"${PROMOTE_OUT:-/dev/null}"
            _pr_moved=$((_pr_moved + 1))
        fi
    done
    if [ "$_pr_moved" -gt 0 ] && [ "$_pr_no_commit" = "0" ]; then
        git -c core.autocrlf=false -C "$_pr_root" commit -q -m "muster: promote $_pr_moved" -- $(cat "$_pr_pathsfile") 2>/dev/null
    fi
    rm -f "$_pr_pathsfile"
}
