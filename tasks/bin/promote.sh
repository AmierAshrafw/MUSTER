#!/bin/sh
# MUSTER promote (sh) - spec 4.4.
# promote_run writes moved ids to $PROMOTE_OUT (discarded below) and prints warn lines
# straight to stdout - see the comment on promote_run in _lib.sh for why that split
# reproduces ps1's [void](Invoke-Promote) + Write-Host warning behavior exactly.
set -u
. "$(dirname "$0")/_lib.sh"

NO_COMMIT=0
[ "${1:-}" = "--no-commit" ] && NO_COMMIT=1
PROMOTE_OUT=$(mktemp)
promote_run "$NO_COMMIT"
rm -f "$PROMOTE_OUT"
exit 0
