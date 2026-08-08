#!/bin/sh
# MUSTER done (sh) - spec 4.3.
set -u
. "$(dirname "$0")/_lib.sh"

VERDICT=${1:-}

root=$(repo_root)
tasks=$(tasks_root)
sole_occupant "$tasks"
_d_file=$SOLE_OCCUPANT
_d_name=$(basename "$_d_file")
_d_id=${_d_name%.md}

show_head_task "$root" "$_d_name"
_d_head=$SHOW_HEAD_TASK
if ! fm_valid "$_d_head"; then
    _d_err=$(fm_error "$_d_head")
    rm -f "$_d_head"
    refuse "$_d_id frontmatter invalid: $_d_err."
fi
_d_type=$(fm_get "$_d_head" type)

_d_isjudgment=0
if [ "$_d_type" = 'review' ] || [ "$_d_type" = 'integration' ]; then _d_isjudgment=1; fi

if [ "$_d_isjudgment" = 0 ] && [ -n "$VERDICT" ]; then
    rm -f "$_d_head"
    refuse 'done takes no verdict on impl/fix tasks.'
fi
if [ "$_d_isjudgment" = 1 ]; then
    case "$VERDICT" in
        pass|fail) ;;
        *) rm -f "$_d_head"; refuse 'done needs a pass or fail verdict on review/integration tasks.' ;;
    esac
fi

# 1. claim commit is derived, not stored
get_claim_commit "$root" "$_d_name"
_d_commit=$GET_CLAIM_COMMIT

# 2. confirmation verify - kills stale-pass; logged as done-check, never counts
_d_log="$tasks/doing/$_d_id.verify.log"
if ! verify_block "$_d_head" "$_d_log" 'done-check' "$_d_id" "$root"; then
    _d_firstfail=$VB_FIRSTFAIL
    rm -f "$_d_head"
    refuse "done-check verify failed: $_d_firstfail. Run the verify script, fix, and retry."
fi

# 3-4. protected + scope
_d_pre=$(done_preconditions "$root" "$_d_head" "$_d_commit")
if [ -n "$_d_pre" ]; then
    rm -f "$_d_head"
    refuse "$_d_pre"
fi

# 5. judgment tasks must carry findings
if [ "$_d_isjudgment" = 1 ] && [ ! -f "$tasks/doing/$_d_id.notes.md" ]; then
    rm -f "$_d_head"
    refuse "verdict needs tasks/doing/$_d_id.notes.md with findings."
fi

if [ "$VERDICT" = 'fail' ]; then
    if [ "$_d_type" = 'review' ]; then
        done_fail_review "$root" "$tasks" "$_d_head" "$_d_id" "$_d_commit"
    else
        done_fail_integration "$root" "$tasks" "$_d_head" "$_d_id" "$_d_commit"
    fi
    exit 3   # unreachable - both branch functions exit themselves; kept as a guard
fi

complete_task "$root" "$tasks" "$_d_head" "$_d_id" "$_d_commit" "$VERDICT" '' 0
_d_promoted=$COMPLETE_TASK_PROMOTED
rm -f "$_d_head"
_d_plist='none'
[ -n "$_d_promoted" ] && _d_plist=$(printf '%s\n' "$_d_promoted" | join_comma_file -)
board_line "$tasks"
echo "Done: $_d_id. Promoted: $_d_plist. Do not claim another task. Session over."
exit 0
