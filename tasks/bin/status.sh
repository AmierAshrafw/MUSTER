#!/bin/sh
# MUSTER status (sh) - on-demand board print (spec 8.3). Not part of the RUNNER contract.
set -u
. "$(dirname "$0")/_lib.sh"

root=$(repo_root) || refuse 'not inside a git repository.'
status_block "$root" "$root/tasks"
exit 0
