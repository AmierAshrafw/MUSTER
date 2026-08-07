#!/bin/sh
# MUSTER claim (sh) - spec 4.1.
set -u
. "$(dirname "$0")/_lib.sh"
HARNESS=''; TIER=''
while [ $# -gt 0 ]; do
    case "$1" in
        --harness) HARNESS=${2:-}; shift 2 ;;
        --tier) TIER=${2:-}; shift 2 ;;
        *) shift ;;
    esac
done
case "$HARNESS" in claude|codex) ;; *) refuse 'claim requires -Harness <claude|codex> and -Tier <any|strong> (the wrapper skill supplies them).' ;; esac
case "$TIER" in any|strong) ;; *) refuse 'claim requires -Harness <claude|codex> and -Tier <any|strong> (the wrapper skill supplies them).' ;; esac

root=$(repo_root)
tasks=$(tasks_root)

# 1. self-heal promotions dropped by a crashed predecessor (D7)
PROMOTE_OUT=$(mktemp)
promote_run 0
rm -f "$PROMOTE_OUT"

# 2. status print - fires before any refusal (D12)
status_block "$root" "$tasks"

# 3. one executor per checkout (D18)
_c_doing=$(task_files "$tasks/doing")
if [ -n "$_c_doing" ]; then
    _c_occfile=$_c_doing
    _c_occid=$(basename "$_c_occfile"); _c_occid=${_c_occid%.md}
    _c_age='unknown'
    if fm_has "$_c_occfile" claimed_at; then
        _c_age=$(age_string "$(fm_get "$_c_occfile" claimed_at)")
    fi
    refuse "doing/ occupied by $_c_occid (claimed $_c_age ago). One executor per checkout. RECOVERY in RUNNER.md."
fi

# 4. stale staged fix from a crashed done-fail
_c_staging=$(task_files "$tasks/staging")
if [ -n "$_c_staging" ]; then
    _c_stagingname=$(basename "$_c_staging")
    refuse "stale fix task in tasks/staging/: $_c_stagingname. Human clears it - RECOVERY in RUNNER.md."
fi

while :; do
    # 5. lowest eligible filename in inbox/; dependency order is the only order
    _c_selected=''
    for _c_f in $(task_files "$tasks/inbox"); do
        # 6. malformed = loud refusal, file stays for a human
        if ! fm_valid "$_c_f"; then
            _c_id0=$(basename "$_c_f"); _c_id0=${_c_id0%.md}
            _c_err0=$(fm_error "$_c_f")
            refuse "$_c_id0 frontmatter invalid: $_c_err0. Task left in inbox/ for a human."
        fi
        _c_schemaerr=$(schema_errors "$_c_f" 0)
        if [ -n "$_c_schemaerr" ]; then
            _c_id0=$(basename "$_c_f"); _c_id0=${_c_id0%.md}
            _c_first=$(printf '%s\n' "$_c_schemaerr" | head -1)
            refuse "$_c_id0 frontmatter invalid: $_c_first. Task left in inbox/ for a human."
        fi
        # pinning (D25): strong tasks need a strong session; strong sessions take ONLY strong tasks
        _c_ftier=$(fm_get "$_c_f" tier)
        if [ "$_c_ftier" = 'strong' ] && [ "$TIER" != 'strong' ]; then continue; fi
        if [ "$TIER" = 'strong' ] && [ "$_c_ftier" != 'strong' ]; then continue; fi
        if fm_has "$_c_f" harness; then
            _c_fharness=$(fm_get "$_c_f" harness)
            if [ "$_c_fharness" != "$HARNESS" ]; then continue; fi
        fi
        _c_selected=$_c_f
        break
    done
    if [ -z "$_c_selected" ]; then
        refuse "nothing to claim for $HARNESS/$TIER."
    fi
    _c_selname=$(basename "$_c_selected")
    _c_id=${_c_selname%.md}

    # 7. dirty-tree scope check, scoped to the selected task
    _c_cp=$(fm_list "$_c_selected" commit_paths)
    _c_dirty=$(get_dirty_paths "$root")
    _c_outfile=$(mktemp)
    if [ -n "$_c_dirty" ]; then
        printf '%s\n' "$_c_dirty" | while IFS= read -r _c_d; do
            [ -z "$_c_d" ] && continue
            path_in_scope "$_c_d" "$_c_cp" || printf '%s\n' "$_c_d" >>"$_c_outfile"
        done
    fi
    if [ -s "$_c_outfile" ]; then
        _c_joined=$(join_comma_file "$_c_outfile")
        rm -f "$_c_outfile"
        refuse "working tree dirty outside $_c_id's commit_paths: $_c_joined. Not this task's work - RECOVERY (RUNNER.md)."
    fi
    rm -f "$_c_outfile"

    # 8. rename, stamp, claim commit (D21) - probe evidence gathered before the rename
    _c_priorclaims=$(git -C "$root" log --oneline -- "tasks/doing/$_c_selname" 2>/dev/null)
    git -c core.autocrlf=false -C "$root" mv "tasks/inbox/$_c_selname" "tasks/doing/$_c_selname" 2>/dev/null
    _c_sidecarfile=$(mktemp)
    move_task_sidecars "$root" "$tasks" "$_c_id" inbox doing >"$_c_sidecarfile"
    _c_doingpath="$tasks/doing/$_c_selname"
    set_claimed_at "$_c_doingpath" "$(iso_now)"
    _c_plan=$(fm_get "$_c_doingpath" plan)
    _c_commitpathsfile=$(mktemp)
    printf 'tasks/inbox/%s\n' "$_c_selname" >>"$_c_commitpathsfile"
    printf 'tasks/doing/%s\n' "$_c_selname" >>"$_c_commitpathsfile"
    cat "$_c_sidecarfile" >>"$_c_commitpathsfile"
    rm -f "$_c_sidecarfile"
    git -c core.autocrlf=false -C "$root" commit -q -m "muster($_c_plan): claim $_c_id" -- $(cat "$_c_commitpathsfile") 2>/dev/null
    rm -f "$_c_commitpathsfile"

    # 9. recovery probe (D12) - only impl/fix, only with prior-claim evidence.
    _c_probetype=$(fm_get "$_c_doingpath" type)
    _c_nprior=$(nz_count "$_c_priorclaims")
    if [ "$_c_nprior" -gt 0 ] && { [ "$_c_probetype" = 'impl' ] || [ "$_c_probetype" = 'fix' ]; }; then
        _c_probelog="$tasks/doing/$_c_id.verify.log"
        if verify_block "$_c_doingpath" "$_c_probelog" 'claim-probe' "$_c_id" "$root"; then
            get_claim_commit "$root" "$_c_selname"
            _c_claimcommit=$GET_CLAIM_COMMIT
            _c_pre=$(done_preconditions "$root" "$_c_doingpath" "$_c_claimcommit")
            if [ -n "$_c_pre" ]; then refuse "$_c_pre"; fi
            complete_task "$root" "$tasks" "$_c_doingpath" "$_c_id" "$_c_claimcommit" '' \
                'auto-filed at claim: verify green before execution' 1
            echo "Auto-filed $_c_id - a crashed predecessor already finished it (claim-probe green)."
            continue
        fi
    fi

    # 10. print the task and hand over to RUNNER.md
    cat "$_c_doingpath"
    echo "Claimed $_c_id. Follow tasks/RUNNER.md."
    exit 0
done
