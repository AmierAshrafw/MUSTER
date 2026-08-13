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

5. Line endings: pin the repo to LF **before** any copy or commit below, so the
   init commit itself stores LF and Windows `core.autocrlf=true` can never
   reintroduce CRLF (the attribute overrides autocrlf, including muster's own
   `-c core.autocrlf=false` commits). Without this, PowerShell/tool whole-file
   writes commit CRLF blobs that MUSTER's own review/integration gates flag as
   defects and stall the auto loop.
   - `.gitattributes` absent at repo root: copy
     `${CLAUDE_PLUGIN_ROOT}/runtime/gitattributes` to `<root>/.gitattributes`.
   - Present and it already contains an `eol=lf` rule: leave it untouched.
   - Present without any `eol=` rule: append the two rule lines from the template
     (`* text=auto eol=lf` and `*.sh text eol=lf`).
   Do **not** run `git add --renormalize .` across the target repo - init owns
   only the files it creates, not the user's pre-existing history.
6. Create `tasks/backlog/`, `tasks/inbox/`, `tasks/doing/`, `tasks/done/`,
   `tasks/failed/`, `tasks/archive/`, `tasks/staging/`, `tasks/bin/`, each with an
   empty `.gitkeep`.
7. Copy every file from `${CLAUDE_PLUGIN_ROOT}/runtime/bin/` into `tasks/bin/`.
8. Copy `${CLAUDE_PLUGIN_ROOT}/runtime/RUNNER.md` to `tasks/RUNNER.md`.
9. Pointer lines: append to the repo's `CLAUDE.md` (create if absent), and to
   `AGENTS.md` if that file already exists:

   > Task board: `tasks/` is managed by MUSTER. Executors follow `tasks/RUNNER.md`
   > exactly. Never edit files under `tasks/` by hand; the `tasks/bin/` scripts own
   > all state transitions.

10. Commit everything just created as one commit, explicit paths (include
    `.gitattributes` when step 5 created or changed it), message:
    `muster: init task board`.

## Report

11. Print what was installed and the two dispatch lines the human will use
    (spec 8.1): model picker Sonnet 5 + `/muster:run`, model picker Opus 4.8 +
    `/muster:review`.
12. If the repo already had CRLF-committed files from before init, note that init
    normalized nothing pre-existing; the user may run `git add --renormalize .`
    themselves to bring the rest of the repo to LF.
