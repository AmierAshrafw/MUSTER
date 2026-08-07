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

count=$(attempt_count "$log")
if [ "$count" -ge 3 ]; then
    rm -f "$tmp"
    move_to_failed "$root" "$tasks" "$id" "$plan"
    echo 'VERIFY FAIL terminal. Task moved to failed/ for human review. Session over.'
    exit 3
fi
n=$((count + 1))
if verify_block "$tmp" "$log" "attempt $n" "$id" "$root"; then
    rm -f "$tmp"
    echo "VERIFY PASS (attempt $n)"
    exit 0
fi
firstfail=$VB_FIRSTFAIL
rm -f "$tmp"
if [ "$n" -lt 3 ]; then
    echo "VERIFY FAIL (attempt $n of 3): $firstfail. Fix and rerun."
    exit 2
fi
move_to_failed "$root" "$tasks" "$id" "$plan"
echo 'VERIFY FAIL terminal. Task moved to failed/ for human review. Session over.'
exit 3
