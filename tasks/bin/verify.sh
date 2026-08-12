#!/bin/sh
# MUSTER verify (sh) - spec 4.2.
set -u
. "$(dirname "$0")/_lib.sh"

root=$(repo_root)
tasks=$(tasks_root)
sole_occupant "$tasks"
file=$SOLE_OCCUPANT
name=$(basename "$file")
id=${name%.md}

show_head_task "$root" "$name"
tmp=$SHOW_HEAD_TASK
if ! fm_valid "$tmp"; then
    err=$(fm_error "$tmp")
    rm -f "$tmp"
    refuse "$id frontmatter invalid: $err."
fi

plan=$(fm_get "$tmp" plan)
log="$tasks/doing/$id.verify.log"

get_claim_commit "$root" "$name"
claim=$GET_CLAIM_COMMIT
count=$(attempt_count "$root" "$plan" "$id" "$claim")
if [ "$count" -ge 3 ]; then
    rm -f "$tmp"
    move_to_failed "$root" "$tasks" "$id" "$plan"
    echo 'VERIFY FAIL terminal. Task moved to failed/ for human review. Session over.'
    exit 3
fi
n=$((count + 1))
# D28: the attempt burns BEFORE any command runs - killing verify mid-run still
# counts. The marker commit message is the counter; the log content is transcript
# (the NEXT marker or the terminal move commits the output). Hard exit-code
# check: an unaccounted attempt must never run.
_vhead=$(git -C "$root" rev-parse HEAD)
printf '=== attempt %s | %s | task %s | HEAD %s\n' "$n" "$(iso_now)" "$id" "$_vhead" >>"$log"
git -c core.autocrlf=false -C "$root" add "tasks/doing/$id.verify.log"
if ! git -c core.autocrlf=false -C "$root" commit -q -m "muster($plan): attempt $n $id" -- "tasks/doing/$id.verify.log"; then
    rm -f "$tmp"
    refuse 'attempt marker commit failed - cannot account the attempt. Inspect git state by hand.'
fi
if verify_block "$tmp" "$log" "attempt $n" "$id" "$root" 1; then _vpass=1; else _vpass=0; fi
firstfail=$VB_FIRSTFAIL
rm -f "$tmp"
if [ "$_vpass" = 1 ]; then
    echo "VERIFY PASS (attempt $n)"
    exit 0
fi
if [ "$n" -lt 3 ]; then
    echo "VERIFY FAIL (attempt $n of 3): $firstfail. Fix and rerun."
    exit 2
fi
move_to_failed "$root" "$tasks" "$id" "$plan"
echo 'VERIFY FAIL terminal. Task moved to failed/ for human review. Session over.'
exit 3
