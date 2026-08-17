# Codex run-task dispatch (filled per task by the orchestrator)

The orchestrator has already run `muster claim -harness codex -tier any`. Do NOT
run claim, done, verify, or any `muster` verb, and do NOT run git. You are a
dispatched executor with one job.

## Invocation

Write the filled prompt below to a scratch file, then:

```bash
codex exec -m gpt-5.6-luna -c model_reasoning_effort=xhigh \
  --sandbox workspace-write "$(cat '<scratch-prompt-file>')"
```

Set these in the environment of that call so the in-sandbox self-check can build.
The sandbox denies the default out-of-workspace Go cache; point the WRITE caches
at the system temp dir, which is in the sandbox allow-list (`[workdir, /tmp,
$TMPDIR]`) AND outside the working tree - so it never dirties the tree. (An
in-repo cache dir would be untracked and make `muster done` refuse via the
out-of-commit_paths check, done.go:51-59.) Leave `GOMODCACHE` default; module
reads from the outside cache are allowed.

Windows (this box):

```
GOCACHE=%TEMP%\muster-codex\go-build
GOTMPDIR=%TEMP%\muster-codex\go-tmp
```

For a non-Go toolchain, point that toolchain's WRITE cache env at a temp-dir
path the same way.

## Prompt template (fill `<...>`)

```
You are a dispatched MUSTER executor. This is a single scoped task - do exactly
the Steps, then stop. Skip any skill preamble (SUBAGENT-STOP applies: you were
dispatched to execute a specific task).

Your task card (already claimed for you):

<inlined card body: Steps, Acceptance, verify command(s), commit_paths>

Do:
1. Follow the Steps exactly. Edit only the files the card names.
2. Run the card's verify command(s) yourself to self-correct. If a command
   needs the Go toolchain, GOCACHE/GOTMPDIR are already workspace-local.
3. Write .muster/cards/<task-id>.notes.md: one short paragraph of anything a
   reviewer should know (surprises, workarounds, doubts). Skip the file if there
   is nothing to report.

Do NOT:
- run any `muster` command, or any git command;
- touch anything under .muster/ except your notes file, or anything under .git/;
- modify any file the card does not name.

When the Steps are done and your self-check passes, STOP. The orchestrator runs
verify and done.
```
