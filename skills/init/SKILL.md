---
name: init
description: Bootstrap the MUSTER task board in this repo. Slash-only (/muster:init); do not auto-trigger.
---

# muster:init - install the task board

Target: the repo the session's cwd is inside. Refuse politely if any check fails;
never half-install.

## Preflight

1. `git rev-parse --show-toplevel` must succeed. Not a repo = stop: tell the user to
   `git init` first.
2. `git config user.name` and `git config user.email` must both return values.
   Missing = stop and tell the user to set them (scripts commit; identity is required).
3. If `tasks/` already exists at the repo root = stop: "tasks/ already exists -
   MUSTER appears installed. Nothing changed."
4. Sync-root check: if the repo path contains `OneDrive`, `Dropbox`, or `Google Drive`,
   print a LOUD warning (sync engines duplicate and resurrect task files - the board
   will corrupt) and ask the user to confirm before continuing.

## Install

5. Create `tasks/backlog/`, `tasks/inbox/`, `tasks/doing/`, `tasks/done/`,
   `tasks/failed/`, `tasks/archive/`, `tasks/staging/`, `tasks/bin/`, each with an
   empty `.gitkeep`.
6. Copy every file from `${CLAUDE_PLUGIN_ROOT}/runtime/bin/` into `tasks/bin/`.
7. Copy `${CLAUDE_PLUGIN_ROOT}/runtime/RUNNER.md` to `tasks/RUNNER.md`.
8. Pointer lines: append to the repo's `CLAUDE.md` (create if absent), and to
   `AGENTS.md` if that file already exists:

   > Task board: `tasks/` is managed by MUSTER. Executors follow `tasks/RUNNER.md`
   > exactly. Never edit files under `tasks/` by hand; the `tasks/bin/` scripts own
   > all state transitions.

9. Commit everything just created as one commit, explicit paths, message:
   `muster: init task board`.

## Report

10. Print what was installed and the two dispatch lines the human will use
    (spec 8.1): model picker Sonnet 5 + `/muster:run`, model picker Fable 5 +
    `/muster:review`.
