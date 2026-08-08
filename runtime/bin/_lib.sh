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

# --- Task 24 additions: lint (schema + Test-LintChecks) + claim/done helpers ---

fm_has() {
    # $1=file $2=key -> exit 0 if $2 is a top-level frontmatter field, else 1
    # (awk's exit in a main rule still runs END, so the found/not-found result
    # must be carried in a flag rather than the exit code of the main rule.)
    awk -v k="$2" '
        NR==1 && $0!="---" { exit }
        NR>1 && $0=="---" { exit }
        $0==k":" { f=1; exit }
        index($0, k": ")==1 { f=1; exit }
        END { exit !f }
    ' "$1"
}

verify_errors() {
    # $1=file -> verify-block schema errors (mirrors the verify-entry loop in Test-TaskSchema)
    awk '
        NR>1 && $0=="---" { exit }
        $0=="verify:" { on=1; idx=0; next }
        on && /^  - [a-z_]+: / {
            if (idx>0) { flush() }
            idx++; hascmd=0; hasee=0; hasec=0
            s=substr($0,5); handle(s)
            next
        }
        on && /^    [a-z_]+: / { s=substr($0,5); handle(s); next }
        on { exit }
        function handle(s,   k, v) {
            k=s; sub(/:.*/, "", k)
            v=s; sub(/^[a-z_]+: /, "", v); gsub(/^"|"$/, "", v)
            if (k=="cmd") hascmd=1
            else if (k=="expect_exit") { hasee=1; if (v !~ /^-?[0-9]+$/) print "verify: expect_exit must be an integer" }
            else if (k=="expect_contains") hasec=1
            else if (k=="timeout_seconds") { if (v !~ /^-?[0-9]+$/) print "verify: timeout_seconds must be an integer" }
            else print "verify: unknown key x27" k "x27"
        }
        function flush() {
            if (!hascmd) print "verify: entry missing cmd"
            if (!hasee && !hasec) print "verify: entry needs expect_exit and/or expect_contains"
        }
        END { if (idx>0) flush() }
    ' "$1" | sed "s/x27/'/g"
}

schema_errors() {
    # $1=file $2=staged(0/1) -> schema errors, one per line (mirrors Test-TaskSchema)
    _se_file=$1; _se_staged=$2
    _se_missing=''
    for _se_req in id plan type tier depends_on verify; do
        if ! fm_has "$_se_file" "$_se_req"; then
            _se_missing="${_se_missing}missing required field: $_se_req
"
        fi
    done
    if [ -n "$_se_missing" ]; then
        printf '%s' "$_se_missing"
        return
    fi
    _se_type=$(fm_get "$_se_file" type)
    case "$_se_type" in
        impl|review|fix|integration) ;;
        *) printf "type: illegal value '%s'\n" "$_se_type"; return ;;
    esac
    _se_err=''
    _se_tier=$(fm_get "$_se_file" tier)
    case "$_se_tier" in
        any|strong) ;;
        *) _se_err="${_se_err}tier: illegal value '$_se_tier'
" ;;
    esac
    if fm_has "$_se_file" harness; then
        _se_harness=$(fm_get "$_se_file" harness)
        case "$_se_harness" in
            claude|codex) ;;
            *) _se_err="${_se_err}harness: illegal value '$_se_harness'
" ;;
        esac
    fi
    _se_id=$(fm_get "$_se_file" id)
    case "$_se_id" in
        ''|*[!a-z0-9-]*) _se_err="${_se_err}id: must be kebab-case [a-z0-9-]+
" ;;
    esac
    _se_dep_list=$(fm_list "$_se_file" depends_on)
    _se_dep_scalar=$(fm_get "$_se_file" depends_on)
    if [ -z "$_se_dep_list" ] && [ "$_se_dep_scalar" != '[]' ]; then
        _se_err="${_se_err}depends_on: must be a list
"
    fi
    if [ "$_se_type" = 'review' ] && ! fm_has "$_se_file" reviews; then
        _se_err="${_se_err}reviews: required on review tasks
"
    fi
    if [ "$_se_type" = 'fix' ] && ! fm_has "$_se_file" fixes; then
        _se_err="${_se_err}fixes: required on fix tasks
"
    fi
    if [ "$_se_type" = 'impl' ] || [ "$_se_type" = 'fix' ]; then
        if ! fm_has "$_se_file" protected; then
            _se_err="${_se_err}protected: required on $_se_type tasks
"
        fi
        if ! fm_has "$_se_file" commit_paths; then
            _se_err="${_se_err}commit_paths: required on $_se_type tasks
"
        fi
    else
        if fm_has "$_se_file" commit_paths; then
            _se_err="${_se_err}commit_paths: must be omitted on $_se_type tasks (outputs are sidecars only)
"
        fi
    fi
    if fm_has "$_se_file" generation; then
        if [ "$_se_type" != 'fix' ]; then
            _se_err="${_se_err}generation: only legal on fix tasks
"
        elif [ "$_se_staged" = '1' ]; then
            _se_err="${_se_err}generation: must be absent on a staged fix (the done script stamps it)
"
        else
            _se_gen=$(fm_get "$_se_file" generation)
            case "$_se_gen" in
                1|2) ;;
                *) _se_err="${_se_err}generation: must be 1 or 2
" ;;
            esac
        fi
    fi
    _se_verify_err=$(verify_errors "$_se_file")
    if [ -n "$_se_verify_err" ]; then
        _se_err="${_se_err}${_se_verify_err}
"
    fi
    printf '%s' "$_se_err"
}

lint_checks() {
    # $1=repo_root $2=lite(0/1), remaining args = repo-relative paths.
    # Findings ('file: message' or 'batch: message'), one per line, into $LINT_OUT.
    _lint_root=$1; _lint_lite=$2; shift 2
    _lint_tasks="$_lint_root/tasks"
    : >"${LINT_OUT:-/dev/null}"
    _lint_batch=$(mktemp)
    _lint_ids=$(mktemp)
    _lint_clean=$(mktemp)
    _lint_tab=$(printf '\t')

    for _lint_p in "$@"; do
        _lint_full="$_lint_root/$_lint_p"
        if [ ! -f "$_lint_full" ]; then
            printf '%s: file not found\n' "$_lint_p" >>"${LINT_OUT:-/dev/null}"
            continue
        fi
        _lint_name=$(basename "$_lint_p")
        _lint_id=${_lint_name%.md}
        printf '%s\t%s\t%s\t%s\n' "$_lint_p" "$_lint_full" "$_lint_name" "$_lint_id" >>"$_lint_batch"
        printf '%s\n' "$_lint_id" >>"$_lint_ids"
    done

    while IFS="$_lint_tab" read -r _lint_rp _lint_fp _lint_nm _lint_id; do
        [ -z "$_lint_rp" ] && continue
        _lint_pfx=$_lint_nm

        if ! fm_valid "$_lint_fp"; then
            _lint_ferr=$(fm_error "$_lint_fp")
            printf '%s: frontmatter: %s\n' "$_lint_pfx" "$_lint_ferr" >>"${LINT_OUT:-/dev/null}"
            continue
        fi

        _lint_schema_err=$(schema_errors "$_lint_fp" "$_lint_lite")
        if [ -n "$_lint_schema_err" ]; then
            printf '%s\n' "$_lint_schema_err" | while IFS= read -r _lint_se; do
                [ -n "$_lint_se" ] && printf '%s: %s\n' "$_lint_pfx" "$_lint_se" >>"${LINT_OUT:-/dev/null}"
            done
        fi

        if ! fm_has "$_lint_fp" type; then continue; fi
        _lint_type=$(fm_get "$_lint_fp" type)

        # 2. id = stem; filename pattern; collision anywhere under tasks/
        _lint_idfield=$(fm_get "$_lint_fp" id)
        if [ "$_lint_idfield" != "$_lint_id" ]; then
            printf "%s: id '%s' does not equal filename stem\n" "$_lint_pfx" "$_lint_idfield" >>"${LINT_OUT:-/dev/null}"
        fi
        if [ "$_lint_lite" = '1' ]; then
            _lint_pat='^[a-z0-9-]+-[0-9][0-9]-fix-[a-z0-9-]+$'
        else
            _lint_pat='^[a-z0-9-]+-[0-9][0-9]-[a-z0-9-]+$'
        fi
        if ! printf '%s' "$_lint_id" | grep -Eq "$_lint_pat"; then
            printf '%s: filename does not match the task pattern (spec 2.1)\n' "$_lint_pfx" >>"${LINT_OUT:-/dev/null}"
        fi
        _lint_dupe=''
        for _lint_d in $(find "$_lint_tasks" -type f -name "$_lint_id.md" 2>/dev/null); do
            _lint_drel=${_lint_d#"$_lint_root"/}
            if [ "$_lint_drel" != "$_lint_rp" ]; then _lint_dupe=$_lint_drel; break; fi
        done
        if [ -n "$_lint_dupe" ]; then
            printf '%s: filename collision under tasks/ (%s)\n' "$_lint_pfx" "$_lint_dupe" >>"${LINT_OUT:-/dev/null}"
        fi

        # 3. every depends_on exists in batch or on disk
        for _lint_dep in $(fm_list "$_lint_fp" depends_on); do
            if grep -Fxq "$_lint_dep" "$_lint_ids" 2>/dev/null; then continue; fi
            _lint_hit=$(find "$_lint_tasks" -type f -name "$_lint_dep.md" 2>/dev/null | head -n 1)
            if [ -z "$_lint_hit" ]; then
                printf "%s: depends_on '%s' exists nowhere\n" "$_lint_pfx" "$_lint_dep" >>"${LINT_OUT:-/dev/null}"
            fi
        done

        # 4-5. verify cmd: metacharacters, network denylist, impl/fix path scoping
        _lint_harness=$(fm_get "$_lint_fp" harness)
        _lint_nverify=$(fm_verify "$_lint_fp" | awk -F'\t' '{ if ($1>m) m=$1 } END { print m+0 }')
        _lint_listed=$(mktemp)
        fm_list "$_lint_fp" protected >"$_lint_listed"
        fm_list "$_lint_fp" commit_paths >>"$_lint_listed"
        _lint_vi=1
        while [ "$_lint_vi" -le "$_lint_nverify" ]; do
            _lint_cmd=$(fm_verify "$_lint_fp" | awk -F'\t' -v i="$_lint_vi" '$1==i && $2=="cmd" { print $3 }')
            if printf '%s' "$_lint_cmd" | grep -Eq '[|><;`]|\$\(|&&'; then
                printf '%s: verify cmd has shell metacharacters: %s\n' "$_lint_pfx" "$_lint_cmd" >>"${LINT_OUT:-/dev/null}"
            fi
            if printf '%s' "$_lint_cmd" | grep -Eq '(^|[[:space:]])(curl|wget|nuget|iwr|Invoke-WebRequest)([[:space:]]|$)|git (fetch|pull|push)|npm (install|ci)|dotnet restore|pip install'; then
                if [ "$_lint_harness" != 'claude' ]; then
                    printf '%s: verify cmd needs network but harness is not claude: %s\n' "$_lint_pfx" "$_lint_cmd" >>"${LINT_OUT:-/dev/null}"
                fi
            fi
            if [ "$_lint_type" = 'impl' ] || [ "$_lint_type" = 'fix' ]; then
                _lint_oldifs2=$IFS
                _lint_nl2=$(printf '\nx')
                IFS=${_lint_nl2%x}
                set -- $(tokenize "$_lint_cmd")
                IFS=$_lint_oldifs2
                for _lint_tok in "$@"; do
                    case "$_lint_tok" in
                        -*) continue ;;
                    esac
                    case "$_lint_tok" in
                        */*) ;;
                        *) continue ;;
                    esac
                    # cmd.exe switch (/c, /d), not a path
                    case "$_lint_tok" in
                        /[a-zA-Z]) continue ;;
                    esac
                    _lint_inlist=0
                    while IFS= read -r _lint_l; do
                        [ -z "$_lint_l" ] && continue
                        if [ "$_lint_tok" = "$_lint_l" ]; then _lint_inlist=1; break; fi
                        _lint_ltrim=${_lint_l%/}
                        case "$_lint_tok" in
                            "$_lint_ltrim"/*) _lint_inlist=1; break ;;
                        esac
                    done <"$_lint_listed"
                    if [ "$_lint_inlist" = 0 ]; then
                        printf "%s: verify path '%s' not in protected or commit_paths\n" "$_lint_pfx" "$_lint_tok" >>"${LINT_OUT:-/dev/null}"
                    fi
                done
            fi
            _lint_vi=$((_lint_vi + 1))
        done
        rm -f "$_lint_listed"

        # 6. size cap
        _lint_lines=$(awk 'END{print NR}' "$_lint_fp")
        _lint_bytes=$(wc -c <"$_lint_fp" | tr -d ' ')
        if [ "${_lint_lines:-0}" -gt 300 ] || [ "${_lint_bytes:-0}" -gt 16384 ]; then
            printf '%s: over the size cap (300 lines / 16 KB) - reshard\n' "$_lint_pfx" >>"${LINT_OUT:-/dev/null}"
        fi

        # 7. placeholders
        _lint_ph=''
        if grep -q 'TBD' "$_lint_fp"; then _lint_ph='TBD'
        elif grep -q 'TODO' "$_lint_fp"; then _lint_ph='TODO'
        elif grep -q 'FIXME' "$_lint_fp"; then _lint_ph='FIXME'
        elif grep -q '<fill' "$_lint_fp"; then _lint_ph='<fill'
        elif grep -q '{placeholder' "$_lint_fp"; then _lint_ph='{placeholder'
        elif grep -Eq '\{\.\.\.\}' "$_lint_fp"; then _lint_ph='{...}'
        elif grep -Eq '\{[a-z][a-z0-9 ,:.-]*\}' "$_lint_fp"; then _lint_ph='{lowercase-braced-slot}'
        elif grep -Eq '^[[:space:]]*[0-9]+\.[[:space:]]*\.\.\.[[:space:]]*$' "$_lint_fp"; then _lint_ph='numbered-ellipsis'
        fi
        if [ -n "$_lint_ph" ]; then
            printf "%s: placeholder text matches '%s'\n" "$_lint_pfx" "$_lint_ph" >>"${LINT_OUT:-/dev/null}"
        fi

        # 8. un-inlined references
        _lint_ref=''
        if grep -qF 'see docs/' "$_lint_fp"; then _lint_ref='see docs/'
        elif grep -qF 'refer to' "$_lint_fp"; then _lint_ref='refer to'
        elif grep -qF 'as described in' "$_lint_fp"; then _lint_ref='as described in'
        elif grep -qF 'per the plan' "$_lint_fp"; then _lint_ref='per the plan'
        fi
        if [ -n "$_lint_ref" ]; then
            printf "%s: un-inlined reference ('%s')\n" "$_lint_pfx" "$_lint_ref" >>"${LINT_OUT:-/dev/null}"
        fi

        # 9. judgment language in Steps
        _lint_stepsfile=$(mktemp)
        awk '/^## Steps/{f=1;next} /^## Acceptance/{f=0} f' "$_lint_fp" >"$_lint_stepsfile"
        _lint_jl=''
        if grep -qF 'if needed' "$_lint_stepsfile"; then _lint_jl='if needed'
        elif grep -qF 'as appropriate' "$_lint_stepsfile"; then _lint_jl='as appropriate'
        elif grep -qF 'appropriately' "$_lint_stepsfile"; then _lint_jl='appropriately'
        elif grep -qF 'handle edge cases' "$_lint_stepsfile"; then _lint_jl='handle edge cases'
        fi
        rm -f "$_lint_stepsfile"
        if [ -n "$_lint_jl" ]; then
            printf "%s: judgment language in Steps ('%s')\n" "$_lint_pfx" "$_lint_jl" >>"${LINT_OUT:-/dev/null}"
        fi

        # 10. heading order
        _lint_lh=$(grep -n '^# ' "$_lint_fp" | head -1 | cut -d: -f1)
        _lint_lc=$(grep -n '^## Context' "$_lint_fp" | head -1 | cut -d: -f1)
        _lint_ls=$(grep -n '^## Steps' "$_lint_fp" | head -1 | cut -d: -f1)
        _lint_la=$(grep -n '^## Acceptance' "$_lint_fp" | head -1 | cut -d: -f1)
        if [ -z "$_lint_lh" ] || [ -z "$_lint_lc" ] || [ -z "$_lint_ls" ] || [ -z "$_lint_la" ] || \
           [ "$_lint_lh" -ge "$_lint_lc" ] || [ "$_lint_lc" -ge "$_lint_ls" ] || [ "$_lint_ls" -ge "$_lint_la" ]; then
            printf '%s: body headings missing or out of order (Context, Steps, Acceptance)\n' "$_lint_pfx" >>"${LINT_OUT:-/dev/null}"
        fi

        # 13. commit_paths non-empty on impl/fix
        if [ "$_lint_type" = 'impl' ] || [ "$_lint_type" = 'fix' ]; then
            _lint_cplist=$(fm_list "$_lint_fp" commit_paths)
            if [ -z "$_lint_cplist" ]; then
                printf '%s: commit_paths empty\n' "$_lint_pfx" >>"${LINT_OUT:-/dev/null}"
            fi
        fi

        if [ -z "$_lint_schema_err" ]; then
            printf '%s\t%s\t%s\n' "$_lint_id" "$_lint_type" "$_lint_fp" >>"$_lint_clean"
        fi
    done <"$_lint_batch"

    if [ "$_lint_lite" != '1' ]; then
        # 11. exactly one integration task, seq 99, strong, depends on every other batch id
        _lint_int_count=0
        _lint_int_id=''
        _lint_int_file=''
        while IFS="$_lint_tab" read -r _lint_cid _lint_ctype _lint_cfp; do
            [ -z "$_lint_cid" ] && continue
            if [ "$_lint_ctype" = 'integration' ]; then
                _lint_int_count=$((_lint_int_count + 1))
                _lint_int_id=$_lint_cid
                _lint_int_file=$_lint_cfp
            fi
        done <"$_lint_clean"
        if [ "$_lint_int_count" != 1 ]; then
            printf 'batch: expected exactly 1 integration task, found %s\n' "$_lint_int_count" >>"${LINT_OUT:-/dev/null}"
        else
            case "$_lint_int_id" in
                *-99-*) ;;
                *) printf '%s.md: integration task must use seq 99\n' "$_lint_int_id" >>"${LINT_OUT:-/dev/null}" ;;
            esac
            _lint_int_tier=$(fm_get "$_lint_int_file" tier)
            if [ "$_lint_int_tier" != 'strong' ]; then
                printf '%s.md: integration task must be tier: strong\n' "$_lint_int_id" >>"${LINT_OUT:-/dev/null}"
            fi
            _lint_int_deps=$(fm_list "$_lint_int_file" depends_on)
            while IFS= read -r _lint_other; do
                [ -z "$_lint_other" ] && continue
                [ "$_lint_other" = "$_lint_int_id" ] && continue
                if ! printf '%s\n' "$_lint_int_deps" | grep -Fxq "$_lint_other"; then
                    printf "%s.md: integration depends_on missing '%s'\n" "$_lint_int_id" "$_lint_other" >>"${LINT_OUT:-/dev/null}"
                fi
            done <"$_lint_ids"
        fi

        # 12. review wiring
        while IFS="$_lint_tab" read -r _lint_cid _lint_ctype _lint_cfp; do
            [ -z "$_lint_cid" ] && continue
            [ "$_lint_ctype" != 'review' ] && continue
            _lint_target=$(fm_get "$_lint_cfp" reviews)
            if ! grep -Fxq "$_lint_target" "$_lint_ids" 2>/dev/null; then
                printf "%s.md: reviews '%s' not in batch\n" "$_lint_cid" "$_lint_target" >>"${LINT_OUT:-/dev/null}"
            fi
            _lint_rdeps=$(fm_list "$_lint_cfp" depends_on)
            if ! printf '%s\n' "$_lint_rdeps" | grep -Fxq "$_lint_target"; then
                printf "%s.md: review depends_on must include its reviews id\n" "$_lint_cid" >>"${LINT_OUT:-/dev/null}"
            fi
        done <"$_lint_clean"
    fi

    rm -f "$_lint_batch" "$_lint_ids" "$_lint_clean"
}

# --- Task 24 additions: status/claim/done helpers (sh mirror of the matching _lib.ps1 funcs) ---

nz_count() { # $1 = newline list (possibly empty) -> line count
    if [ -z "$1" ]; then printf '0'; else printf '%s\n' "$1" | wc -l | tr -d ' '; fi
}

join_comma_file() { # $1=file (or - for stdin), one item per line -> "a, b, c"
    awk '{ if (NR>1) printf ", "; printf "%s", $0 } END{print ""}' "$1"
}

stems_join() { # $1 = newline list of full paths (possibly empty) -> "id1, id2, ..." (basename minus .md)
    _sj_list=$1
    [ -z "$_sj_list" ] && { printf ''; return; }
    printf '%s\n' "$_sj_list" | while IFS= read -r _sj_f; do
        [ -z "$_sj_f" ] && continue
        _sj_id=$(basename "$_sj_f")
        printf '%s\n' "${_sj_id%.md}"
    done | join_comma_file -
}

age_string() { # $1=iso -> humanized age: 42m / 3h / 2d
    _as_then=$(date -u -d "$1" +%s 2>/dev/null)
    _as_now=$(date -u +%s)
    _as_delta=$((_as_now - _as_then))
    _as_days=$((_as_delta / 86400))
    if [ "$_as_days" -ge 1 ]; then printf '%dd' "$_as_days"; return; fi
    _as_hours=$((_as_delta / 3600))
    if [ "$_as_hours" -ge 1 ]; then printf '%dh' "$_as_hours"; return; fi
    printf '%dm' $((_as_delta / 60))
}

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

status_block() {
    # $1=repo_root $2=tasks_root -> prints the status block (spec 8.3) to stdout.
    _sb_root=$1; _sb_tasks=$2
    _sb_inbox=$(task_files "$_sb_tasks/inbox")
    _sb_doing=$(task_files "$_sb_tasks/doing")
    _sb_backlog=$(task_files "$_sb_tasks/backlog")
    _sb_failed=$(task_files "$_sb_tasks/failed")
    _sb_done=$(task_files "$_sb_tasks/done")
    _sb_ninbox=$(nz_count "$_sb_inbox")
    _sb_ndoing=$(nz_count "$_sb_doing")
    _sb_nbacklog=$(nz_count "$_sb_backlog")
    _sb_nfailed=$(nz_count "$_sb_failed")
    _sb_ndone=$(nz_count "$_sb_done")
    _sb_total=$((_sb_ninbox + _sb_ndoing + _sb_nbacklog + _sb_nfailed + _sb_ndone))
    if [ "$_sb_total" -eq 0 ]; then
        printf 'MUSTER: board empty - nothing sharded or all archived.\n'
        return
    fi
    _sb_branch=$(git -C "$_sb_root" rev-parse --abbrev-ref HEAD 2>/dev/null)
    _sb_name=$(basename "$_sb_root")
    printf 'MUSTER status @ %s (%s)\n' "$_sb_name" "$_sb_branch"
    inbox_split "$_sb_tasks"
    _sb_split="run $INBOX_RUN, review $INBOX_REVIEW"
    [ "$INBOX_INVALID" -gt 0 ] && _sb_split="$_sb_split, invalid $INBOX_INVALID"
    printf '  inbox    %s ready      (%s) [%s]\n' "$_sb_ninbox" "$_sb_split" "$(stems_join "$_sb_inbox")"

    _sb_doingcell=''
    if [ -n "$_sb_doing" ]; then
        _sb_df=$_sb_doing
        _sb_did=$(basename "$_sb_df"); _sb_did=${_sb_did%.md}
        _sb_age='unknown'
        _sb_stale=''
        if fm_has "$_sb_df" claimed_at; then
            _sb_cat=$(fm_get "$_sb_df" claimed_at)
            _sb_age=$(age_string "$_sb_cat")
            _sb_then=$(date -u -d "$_sb_cat" +%s 2>/dev/null)
            _sb_now=$(date -u +%s)
            if [ -n "$_sb_then" ] && [ $(( (_sb_now - _sb_then) / 3600 )) -gt 24 ]; then
                _sb_stale='        <- STALE: see RUNNER.md RECOVERY'
            fi
        fi
        _sb_doingcell="[$_sb_did claimed $_sb_age]$_sb_stale"
    fi
    printf '  doing    %s            %s\n' "$_sb_ndoing" "$_sb_doingcell" | sed 's/[[:space:]]*$//'

    _sb_deadfile=$(mktemp)
    dead_scan "$_sb_tasks" "$_sb_deadfile"
    _sb_ndead=$(wc -l <"$_sb_deadfile" | tr -d ' ')
    _sb_deadcell=''
    if [ "$_sb_ndead" -gt 0 ]; then
        _sb_deadjoin=$(awk '{ if (NR>1) printf "; "; printf "%s", $0 } END{print ""}' "$_sb_deadfile")
        _sb_deadcell="    ($_sb_ndead DEAD: $_sb_deadjoin)"
    fi
    rm -f "$_sb_deadfile"
    printf '  backlog  %s blocked%s\n' "$_sb_nbacklog" "$_sb_deadcell" | sed 's/[[:space:]]*$//'
    printf '  failed   %s            [%s]\n' "$_sb_nfailed" "$(stems_join "$_sb_failed")" | sed 's/[[:space:]]*$//'
    printf '  done     %s\n' "$_sb_ndone"
}

get_dirty_paths() {
    # $1=repo_root -> worktree + index dirt as repo-relative paths, one per line (rename -> both sides)
    _gdp_root=$1
    git -C "$_gdp_root" status --porcelain --untracked-files=all 2>/dev/null | while IFS= read -r _gdp_line; do
        [ -z "$_gdp_line" ] && continue
        _gdp_p=$(printf '%s' "$_gdp_line" | cut -c4-)
        case "$_gdp_p" in
            *' -> '*)
                _gdp_a=${_gdp_p%% -> *}
                _gdp_b=${_gdp_p#*' -> '}
                printf '%s\n' "$_gdp_a" | sed 's/^"//; s/"$//'
                printf '%s\n' "$_gdp_b" | sed 's/^"//; s/"$//'
                ;;
            *) printf '%s\n' "$_gdp_p" | sed 's/^"//; s/"$//' ;;
        esac
    done
}

path_listed() {
    # $1=path $2=list(newline-separated, may be empty) -> 0 if $1 equals an entry or sits under one
    # (the loop runs in the pipe's subshell; a case with no matching pattern exits 0
    # by default, so the "not found" result must be forced explicitly on the way out.)
    _pl_path=$1; _pl_list=$2
    [ -z "$_pl_list" ] && return 1
    printf '%s\n' "$_pl_list" | {
        _pl_found=1
        while IFS= read -r _pl_c; do
            [ -z "$_pl_c" ] && continue
            if [ "$_pl_path" = "$_pl_c" ]; then _pl_found=0; break; fi
            _pl_ctrim=${_pl_c%/}
            case "$_pl_path" in
                "$_pl_ctrim"/*) _pl_found=0; break ;;
            esac
        done
        exit "$_pl_found"
    }
}

path_in_scope() {
    # $1=path $2=commit_paths(newline list) -> 0 if in scope (spec 4.1.7/4.3.4, D27)
    _pis_path=$1; _pis_cp=$2
    case "$_pis_path" in
        tasks/doing/*.notes.md) return 0 ;;
        tasks/doing/*.verify.log) return 0 ;;
        tasks/staging/*.md) return 0 ;;
    esac
    case "$_pis_path" in
        tasks|tasks/*) return 1 ;;
    esac
    path_listed "$_pis_path" "$_pis_cp"
}

set_claimed_at() {
    # $1=path $2=iso -> stamp (or replace) claimed_at as the last frontmatter line
    _sca_path=$1; _sca_iso=$2
    awk -v iso="$_sca_iso" '
        NR==1 { print; next }
        !closed && $0=="---" { closed=1; print "claimed_at: " iso; print; next }
        !closed && /^claimed_at:/ { next }
        { print }
    ' "$_sca_path" >"$_sca_path.tmp"
    mv "$_sca_path.tmp" "$_sca_path"
}

get_claim_commit() {
    # $1=repo_root $2=name -> sets GET_CLAIM_COMMIT. Refuses if none found (plain-statement call only).
    _gcc_root=$1; _gcc_name=$2
    _gcc_sha=$(git -C "$_gcc_root" log -n 1 --format=%H -- "tasks/doing/$_gcc_name" 2>/dev/null)
    if [ -z "$_gcc_sha" ]; then
        refuse "no claim commit found for tasks/doing/$_gcc_name. RECOVERY in RUNNER.md."
    fi
    GET_CLAIM_COMMIT=$_gcc_sha
}

get_changed_paths() {
    # $1=repo_root $2=claim_commit -> tracked diff since commit + untracked new files, sorted unique
    _gcp_root=$1; _gcp_commit=$2
    { git -c core.autocrlf=false -C "$_gcp_root" diff --name-only "$_gcp_commit" 2>/dev/null
      git -c core.autocrlf=false -C "$_gcp_root" ls-files --others --exclude-standard 2>/dev/null
    } | sort -u
}

done_preconditions() {
    # $1=repo_root $2=task_file(frontmatter source) $3=claim_commit -> prints refusal message or nothing
    _dp_root=$1; _dp_file=$2; _dp_commit=$3
    _dp_changedfile=$(mktemp)
    get_changed_paths "$_dp_root" "$_dp_commit" >"$_dp_changedfile"
    _dp_protected=$(fm_list "$_dp_file" protected)
    _dp_hitsfile=$(mktemp)
    while IFS= read -r _dp_c; do
        [ -z "$_dp_c" ] && continue
        path_listed "$_dp_c" "$_dp_protected" && printf '%s\n' "$_dp_c" >>"$_dp_hitsfile"
    done <"$_dp_changedfile"
    if [ -s "$_dp_hitsfile" ]; then
        _dp_joined=$(join_comma_file "$_dp_hitsfile")
        rm -f "$_dp_changedfile" "$_dp_hitsfile"
        printf 'protected file(s) modified: %s. Revert them; the verify definition is not yours to change.' "$_dp_joined"
        return
    fi
    rm -f "$_dp_hitsfile"
    _dp_cp=$(fm_list "$_dp_file" commit_paths)
    _dp_extrasfile=$(mktemp)
    while IFS= read -r _dp_c; do
        [ -z "$_dp_c" ] && continue
        path_in_scope "$_dp_c" "$_dp_cp" || printf '%s\n' "$_dp_c" >>"$_dp_extrasfile"
    done <"$_dp_changedfile"
    rm -f "$_dp_changedfile"
    if [ -s "$_dp_extrasfile" ]; then
        _dp_joined2=$(join_comma_file "$_dp_extrasfile")
        rm -f "$_dp_extrasfile"
        printf 'changed outside commit_paths: %s. Revert strays or stop for a human.' "$_dp_joined2"
        return
    fi
    rm -f "$_dp_extrasfile"
}

result_sidecar() {
    # $1=repo_root $2=tasks_root $3=task_file $4=id $5=claim_commit $6=status $7=verdict(''=omit)
    # $8=surprises_override('' = use notes) $9=attempts(-1=read live log) $10=probe(0/1)
    # Prints the sidecar text (with a single trailing newline) to stdout - redirect directly to a file.
    _rs_root=$1; _rs_tasks=$2; _rs_file=$3; _rs_id=$4; _rs_commit=$5
    _rs_status=$6; _rs_verdict=$7; _rs_override=$8; _rs_attempts=$9; _rs_probe=${10}
    if [ "$_rs_attempts" -lt 0 ] 2>/dev/null; then
        _rs_attempts=$(attempt_count "$_rs_tasks/doing/$_rs_id.verify.log")
    fi
    _rs_verifyline="verify: pass (attempt $_rs_attempts of 3)"
    if [ "$_rs_attempts" = '0' ]; then
        _rs_verifyline='verify: pass (done-check only)'
        [ "$_rs_probe" = '1' ] && _rs_verifyline='verify: pass (claim-probe)'
    fi
    _rs_claimedat=''
    fm_has "$_rs_file" claimed_at && _rs_claimedat=$(fm_get "$_rs_file" claimed_at)
    _rs_type=$(fm_get "$_rs_file" type)

    _rs_notespath="$_rs_tasks/doing/$_rs_id.notes.md"
    _rs_notes='none reported'
    [ -f "$_rs_notespath" ] && _rs_notes=$(cat "$_rs_notespath")
    [ -n "$_rs_override" ] && _rs_notes=$_rs_override

    printf '%s\n' "# Result: $_rs_id"
    printf '\n'
    printf '%s\n' "- status: $_rs_status"
    [ -n "$_rs_verdict" ] && printf '%s\n' "- verdict: $_rs_verdict"
    printf '%s\n' "- claim_commit: $_rs_commit"
    printf '%s\n' "- claimed_at: $_rs_claimedat"
    printf '%s\n' "- completed_at: $(iso_now)"
    printf '%s\n' "- $_rs_verifyline"
    printf '%s\n' '- files_changed:'
    get_changed_paths "$_rs_root" "$_rs_commit" | while IFS= read -r _rs_f; do
        [ -z "$_rs_f" ] && continue
        printf '%s\n' "  - $_rs_f"
    done
    printf '\n'
    printf '%s\n' '## Surprises'
    printf '\n'
    if [ "$_rs_type" = 'review' ] || [ "$_rs_type" = 'integration' ]; then
        printf '%s\n' 'none reported'
        printf '\n'
        printf '%s\n' '## Findings'
        printf '\n'
        printf '%s\n' "$_rs_notes"
    else
        printf '%s\n' "$_rs_notes"
    fi
}

complete_task() {
    # $1=repo_root $2=tasks_root $3=task_file $4=id $5=claim_commit $6=verdict('') $7=surprises_override('')
    # $8=probe(0/1). Sets COMPLETE_TASK_PROMOTED (newline list, may be empty). Can refuse -
    # plain-statement call only, never $(...).
    _ct_root=$1; _ct_tasks=$2; _ct_file=$3; _ct_id=$4; _ct_commit=$5
    _ct_verdict=$6; _ct_override=$7; _ct_probe=$8
    _ct_plan=$(fm_get "$_ct_file" plan)
    # captured now: $_ct_file (tasks/doing/<id>.md) stops existing once the git mv below runs
    _ct_cplist=$(fm_list "$_ct_file" commit_paths)

    result_sidecar "$_ct_root" "$_ct_tasks" "$_ct_file" "$_ct_id" "$_ct_commit" done "$_ct_verdict" "$_ct_override" -1 "$_ct_probe" \
        >"$_ct_tasks/done/$_ct_id.result.md"
    git -c core.autocrlf=false -C "$_ct_root" add "tasks/done/$_ct_id.result.md" 2>/dev/null

    _ct_pathsfile=$(mktemp)
    printf 'tasks/doing/%s.md\n' "$_ct_id" >>"$_ct_pathsfile"
    printf 'tasks/done/%s.md\n' "$_ct_id" >>"$_ct_pathsfile"
    printf 'tasks/done/%s.result.md\n' "$_ct_id" >>"$_ct_pathsfile"

    _ct_notes="$_ct_tasks/doing/$_ct_id.notes.md"
    [ -f "$_ct_notes" ] && rm -f "$_ct_notes"

    _ct_log="$_ct_tasks/doing/$_ct_id.verify.log"
    if [ -f "$_ct_log" ]; then
        mv "$_ct_log" "$_ct_tasks/done/$_ct_id.verify.log"
        git -c core.autocrlf=false -C "$_ct_root" add "tasks/done/$_ct_id.verify.log" 2>/dev/null
        printf 'tasks/done/%s.verify.log\n' "$_ct_id" >>"$_ct_pathsfile"
    fi

    move_task_sidecars "$_ct_root" "$_ct_tasks" "$_ct_id" doing done >>"$_ct_pathsfile"
    git -c core.autocrlf=false -C "$_ct_root" mv "tasks/doing/$_ct_id.md" "tasks/done/$_ct_id.md" 2>/dev/null

    PROMOTE_OUT=$(mktemp)
    promote_run 1
    _ct_promoted=$(cat "$PROMOTE_OUT")
    rm -f "$PROMOTE_OUT"
    if [ -n "$_ct_promoted" ]; then
        printf '%s\n' "$_ct_promoted" | while IFS= read -r _ct_p; do
            [ -z "$_ct_p" ] && continue
            printf 'tasks/backlog/%s.md\n' "$_ct_p" >>"$_ct_pathsfile"
            printf 'tasks/inbox/%s.md\n' "$_ct_p" >>"$_ct_pathsfile"
            for _ct_h in "$_ct_tasks/inbox/$_ct_p".gen*; do
                [ -e "$_ct_h" ] || continue
                _ct_hname=$(basename "$_ct_h")
                printf 'tasks/backlog/%s\n' "$_ct_hname" >>"$_ct_pathsfile"
                printf 'tasks/inbox/%s\n' "$_ct_hname" >>"$_ct_pathsfile"
            done
        done
    fi

    for _ct_cp in $_ct_cplist; do
        if [ -e "$_ct_root/$_ct_cp" ]; then
            git -c core.autocrlf=false -C "$_ct_root" add -- "$_ct_cp" 2>/dev/null
            printf '%s\n' "$_ct_cp" >>"$_ct_pathsfile"
        fi
    done

    git -c core.autocrlf=false -C "$_ct_root" commit -q -m "muster($_ct_plan): done $_ct_id" -- $(cat "$_ct_pathsfile") 2>/dev/null
    _ct_commitrc=$?
    rm -f "$_ct_pathsfile"
    if [ "$_ct_commitrc" -ne 0 ]; then
        refuse "completion commit failed for $_ct_id - inspect git state by hand."
    fi
    COMPLETE_TASK_PROMOTED=$_ct_promoted
}

fix_count() {
    # $1=tasks_root $2=impl_id -> count of files carrying 'fixes: <impl_id>' anywhere under
    # tasks/ excluding staging/ (the script is the only generation counter, spec 2.2)
    _fc_tasks=$1; _fc_impl=$2
    _fc_n=0
    for _fc_f in $(find "$_fc_tasks" -type f -name '*.md' 2>/dev/null); do
        case "$_fc_f" in
            */staging/*) continue ;;
            *.result.md|*.notes.md) continue ;;
        esac
        if awk -v imp="$_fc_impl" '$0=="fixes: " imp { f=1 } END { exit !f }' "$_fc_f"; then
            _fc_n=$((_fc_n + 1))
        fi
    done
    printf '%s' "$_fc_n"
}

add_depends_on() {
    # $1=path $2=dep_id -> script-side frontmatter edit (D17): append one id to depends_on
    _ado_path=$1; _ado_dep=$2
    if grep -qE '^depends_on: \[\][[:space:]]*$' "$_ado_path"; then
        awk -v dep="$_ado_dep" '
            /^depends_on: \[\][ \t]*$/ { print "depends_on:"; print "  - " dep; next }
            { print }
        ' "$_ado_path" >"$_ado_path.tmp"
    else
        awk -v dep="$_ado_dep" '
            BEGIN { indeps=0 }
            {
                if (indeps==1 && $0 !~ /^[ \t]+- /) { print "  - " dep; indeps=0 }
                if ($0 ~ /^depends_on:[ \t]*$/) { indeps=1 }
                print
            }
            END { if (indeps==1) print "  - " dep }
        ' "$_ado_path" >"$_ado_path.tmp"
    fi
    mv "$_ado_path.tmp" "$_ado_path"
}

move_to_failed_with_result() {
    # $1=repo_root $2=tasks_root $3=task_file $4=id $5=claim_commit
    # Shared by the review cap and integration fail: result with fail verdict, task + sidecars
    # -> failed/, one commit. Caller prints and exits.
    _mtfwr_root=$1; _mtfwr_tasks=$2; _mtfwr_file=$3; _mtfwr_id=$4; _mtfwr_commit=$5
    _mtfwr_plan=$(fm_get "$_mtfwr_file" plan)
    result_sidecar "$_mtfwr_root" "$_mtfwr_tasks" "$_mtfwr_file" "$_mtfwr_id" "$_mtfwr_commit" failed fail '' -1 0 \
        >"$_mtfwr_tasks/failed/$_mtfwr_id.result.md"
    git -c core.autocrlf=false -C "$_mtfwr_root" add "tasks/failed/$_mtfwr_id.result.md" 2>/dev/null
    _mtfwr_pathsfile=$(mktemp)
    printf 'tasks/failed/%s.result.md\n' "$_mtfwr_id" >>"$_mtfwr_pathsfile"
    printf 'tasks/doing/%s.md\n' "$_mtfwr_id" >>"$_mtfwr_pathsfile"
    printf 'tasks/failed/%s.md\n' "$_mtfwr_id" >>"$_mtfwr_pathsfile"
    _mtfwr_notes="$_mtfwr_tasks/doing/$_mtfwr_id.notes.md"
    [ -f "$_mtfwr_notes" ] && rm -f "$_mtfwr_notes"
    _mtfwr_log="$_mtfwr_tasks/doing/$_mtfwr_id.verify.log"
    if [ -f "$_mtfwr_log" ]; then
        mv "$_mtfwr_log" "$_mtfwr_tasks/failed/$_mtfwr_id.verify.log"
        git -c core.autocrlf=false -C "$_mtfwr_root" add "tasks/failed/$_mtfwr_id.verify.log" 2>/dev/null
        printf 'tasks/failed/%s.verify.log\n' "$_mtfwr_id" >>"$_mtfwr_pathsfile"
    fi
    move_task_sidecars "$_mtfwr_root" "$_mtfwr_tasks" "$_mtfwr_id" doing failed >>"$_mtfwr_pathsfile"
    git -c core.autocrlf=false -C "$_mtfwr_root" mv "tasks/doing/$_mtfwr_id.md" "tasks/failed/$_mtfwr_id.md" 2>/dev/null
    git -c core.autocrlf=false -C "$_mtfwr_root" commit -q -m "muster($_mtfwr_plan): fail $_mtfwr_id" -- $(cat "$_mtfwr_pathsfile") 2>/dev/null
    rm -f "$_mtfwr_pathsfile"
}

done_fail_review() {
    # $1=repo_root $2=tasks_root $3=task_file $4=id $5=claim_commit -> exits itself on every path.
    _dfr_root=$1; _dfr_tasks=$2; _dfr_file=$3; _dfr_id=$4; _dfr_commit=$5
    _dfr_plan=$(fm_get "$_dfr_file" plan)
    _dfr_implid=$(fm_get "$_dfr_file" reviews)

    _dfr_staged=$(task_files "$_dfr_tasks/staging")
    _dfr_nstaged=$(nz_count "$_dfr_staged")
    if [ "$_dfr_nstaged" != '1' ]; then
        rm -f "$_dfr_file"
        refuse "done fail needs exactly one valid fix task in tasks/staging/ (found $_dfr_nstaged files). File left in place - fix it and rerun."
    fi
    _dfr_stagedfull=$_dfr_staged
    _dfr_stagedname=$(basename "$_dfr_stagedfull")
    _dfr_stagedrel="tasks/staging/$_dfr_stagedname"

    LINT_OUT=$(mktemp)
    lint_checks "$_dfr_root" 1 "$_dfr_stagedrel"
    _dfr_findings=$(cat "$LINT_OUT")
    rm -f "$LINT_OUT"

    _dfr_extra=''
    if fm_valid "$_dfr_stagedfull" && fm_has "$_dfr_stagedfull" fixes; then
        _dfr_fixesval=$(fm_get "$_dfr_stagedfull" fixes)
        if [ "$_dfr_fixesval" != "$_dfr_implid" ]; then
            _dfr_extra="fixes '$_dfr_fixesval' does not match reviews '$_dfr_implid'"
        fi
    fi
    if [ -n "$_dfr_extra" ]; then
        _dfr_findings="$_dfr_extra
$_dfr_findings"
    fi
    if [ -n "$_dfr_findings" ]; then
        _dfr_first=$(printf '%s\n' "$_dfr_findings" | head -1)
        rm -f "$_dfr_file"
        refuse "done fail needs exactly one valid fix task in tasks/staging/ ($_dfr_first). File left in place - fix it and rerun."
    fi

    _dfr_g=$(( $(fix_count "$_dfr_tasks" "$_dfr_implid") + 1 ))
    if [ "$_dfr_g" -ge 3 ]; then
        rm -f "$_dfr_stagedfull"
        move_to_failed_with_result "$_dfr_root" "$_dfr_tasks" "$_dfr_file" "$_dfr_id" "$_dfr_commit"
        echo "Review cap hit (2 fix generations). $_dfr_implid chain needs a human. Session over."
        rm -f "$_dfr_file"
        exit 3
    fi

    case "$_dfr_stagedname" in
        *-[0-9][0-9]-fix-*.md) ;;
        *) rm -f "$_dfr_file"; refuse "staged fix filename malformed: $_dfr_stagedname." ;;
    esac
    _dfr_stem=${_dfr_stagedname%.md}
    _dfr_prefix=$(printf '%s' "$_dfr_stem" | sed -E 's/^(.+-[0-9]{2})-fix-(.+)$/\1/')
    _dfr_slug=$(printf '%s' "$_dfr_stem" | sed -E 's/^(.+-[0-9]{2})-fix-(.+)$/\2/')
    _dfr_fixid="${_dfr_prefix}-fix${_dfr_g}-${_dfr_slug}"

    _dfr_tmp1=$(mktemp)
    _dfr_tmp2=$(mktemp)
    cp "$_dfr_stagedfull" "$_dfr_tmp1"
    sed -E -e "s/^id: .*\$/id: $_dfr_fixid/" -e "s/^(fixes: .*)\$/\\1\\ngeneration: $_dfr_g/" "$_dfr_tmp1" >"$_dfr_tmp2"
    sed "s|# ${_dfr_stem}:|# ${_dfr_fixid}:|" "$_dfr_tmp2" >"$_dfr_tasks/inbox/$_dfr_fixid.md"
    rm -f "$_dfr_tmp1" "$_dfr_tmp2" "$_dfr_stagedfull"
    git -c core.autocrlf=false -C "$_dfr_root" add "tasks/inbox/$_dfr_fixid.md" 2>/dev/null

    _dfr_pathsfile=$(mktemp)
    printf 'tasks/inbox/%s.md\n' "$_dfr_fixid" >>"$_dfr_pathsfile"
    printf 'tasks/doing/%s.md\n' "$_dfr_id" >>"$_dfr_pathsfile"
    printf 'tasks/backlog/%s.md\n' "$_dfr_id" >>"$_dfr_pathsfile"

    add_depends_on "$_dfr_tasks/doing/$_dfr_id.md" "$_dfr_fixid"

    _dfr_live="$_dfr_tasks/doing/$_dfr_id.verify.log"
    _dfr_roundattempts=$(attempt_count "$_dfr_live")
    if [ -f "$_dfr_live" ]; then
        mv "$_dfr_live" "$_dfr_tasks/backlog/$_dfr_id.gen$_dfr_g.verify.log"
        git -c core.autocrlf=false -C "$_dfr_root" add "tasks/backlog/$_dfr_id.gen$_dfr_g.verify.log" 2>/dev/null
        printf 'tasks/backlog/%s.gen%s.verify.log\n' "$_dfr_id" "$_dfr_g" >>"$_dfr_pathsfile"
    fi

    result_sidecar "$_dfr_root" "$_dfr_tasks" "$_dfr_file" "$_dfr_id" "$_dfr_commit" cycled fail '' "$_dfr_roundattempts" 0 \
        >"$_dfr_tasks/backlog/$_dfr_id.gen$_dfr_g.result.md"
    git -c core.autocrlf=false -C "$_dfr_root" add "tasks/backlog/$_dfr_id.gen$_dfr_g.result.md" 2>/dev/null
    printf 'tasks/backlog/%s.gen%s.result.md\n' "$_dfr_id" "$_dfr_g" >>"$_dfr_pathsfile"

    rm -f "$_dfr_tasks/doing/$_dfr_id.notes.md"
    move_task_sidecars "$_dfr_root" "$_dfr_tasks" "$_dfr_id" doing backlog >>"$_dfr_pathsfile"
    git -c core.autocrlf=false -C "$_dfr_root" mv "tasks/doing/$_dfr_id.md" "tasks/backlog/$_dfr_id.md" 2>/dev/null

    git -c core.autocrlf=false -C "$_dfr_root" commit -q -m "muster($_dfr_plan): reject $_dfr_implid gen$_dfr_g" -- $(cat "$_dfr_pathsfile") 2>/dev/null
    rm -f "$_dfr_pathsfile"
    echo "Review failed. Fix $_dfr_fixid queued (generation $_dfr_g of 2). Session over."
    rm -f "$_dfr_file"
    exit 0
}

done_fail_integration() {
    # $1=repo_root $2=tasks_root $3=task_file $4=id $5=claim_commit -> exits itself.
    _dfi_root=$1; _dfi_tasks=$2; _dfi_file=$3; _dfi_id=$4; _dfi_commit=$5
    _dfi_staged=$(task_files "$_dfi_tasks/staging")
    if [ -n "$_dfi_staged" ]; then
        rm -f "$_dfi_file"
        refuse 'integration done fail accepts no fix task - clear tasks/staging/.'
    fi
    move_to_failed_with_result "$_dfi_root" "$_dfi_tasks" "$_dfi_file" "$_dfi_id" "$_dfi_commit"
    echo "Integration review failed. Bring tasks/failed/$_dfi_id.result.md to the orchestrator to shard a fix-up plan. Session over."
    rm -f "$_dfi_file"
    exit 3
}
