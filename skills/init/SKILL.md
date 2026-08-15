---
name: init
description: Bootstrap the MUSTER task board in this repo. Slash-only (/muster:init); do not auto-trigger.
---

# muster:init - install the task board (v2)

v2 is the only installable board (clean cut). The binary owns every check.

1. Confirm `muster` is on PATH (`muster board` prints a refusal or a board -
   either proves the binary resolves). Not found = stop: tell the user to
   install muster.exe first.
2. Run `muster init` from the repo root. The binary preflights (git repo,
   identity, sync-root guard, v1-liveness refusal), installs `.muster/`,
   decommissions a dead v1 tree (stubs `tasks/bin/*`, rewrites the CLAUDE.md
   pointer), and commits what it created.
3. Report the binary's output verbatim, including the two dispatch lines and
   the Defender-exclusion note. A `MUSTER refuse:` line = report it and stop;
   never work around a refusal (a live v1 board must be finished or closed
   first).
