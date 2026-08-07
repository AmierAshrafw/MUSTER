#!/bin/sh
# MUSTER lint (sh) - spec 2.6.
set -u
. "$(dirname "$0")/_lib.sh"

LITE=0
PATHS=''
_l_n=0
for _l_a in "$@"; do
    if [ "$_l_a" = '--lite' ]; then LITE=1; continue; fi
    PATHS="$PATHS$_l_a
"
    _l_n=$((_l_n + 1))
done
if [ "$_l_n" -eq 0 ]; then refuse 'lint needs at least one task file path.'; fi

root=$(repo_root)
LINT_OUT=$(mktemp)
_l_oldifs=$IFS
_l_nl=$(printf '\nx')
IFS=${_l_nl%x}
set -- $PATHS
IFS=$_l_oldifs
lint_checks "$root" "$LITE" "$@"

if [ -s "$LINT_OUT" ]; then
    while IFS= read -r _l_line; do
        echo "LINT FAIL $_l_line"
    done <"$LINT_OUT"
    rm -f "$LINT_OUT"
    exit 1
fi
rm -f "$LINT_OUT"
echo "LINT OK $_l_n file(s)"
exit 0
