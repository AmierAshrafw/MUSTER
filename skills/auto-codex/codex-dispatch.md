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

The in-sandbox self-check needs a writable cache for the Go toolchain. Two facts
from the D26 dry run govern how:

- The sandbox DENIES writes to Go's default out-of-workspace cache
  (`%LocalAppData%\go-build`). A warm-cache `go build` still passes because it
  only reads, so the denial stays hidden until a command must WRITE - e.g.
  `go test` compiling a fresh test binary fails with "Go build-cache access
  denial".
- Env vars set on THIS `codex exec` process do NOT cross into the sandbox shell;
  the executor sees an empty `GOCACHE`. The cache therefore cannot be fixed by
  exporting it here - the dispatched prompt makes the executor export it in its
  own shell (template step 2).

Point the WRITE caches at the system temp dir: it is in the sandbox allow-list
(`[workdir, /tmp, $TMPDIR]`) AND outside the working tree, so a cold build there
succeeds and never dirties the tree. (An in-repo cache dir would be untracked and
make `muster done` refuse via the out-of-commit_paths check, done.go:51-59.)
Leave `GOMODCACHE` default; module reads from the outside cache are allowed.

Windows (this box) - PowerShell, exported by the executor in the same shell line
as each Go command (sandbox shells do not persist env across separate calls):

```
$env:GOCACHE = "$env:TEMP\muster-codex\go-build"
$env:GOTMPDIR = "$env:TEMP\muster-codex\go-tmp"
```

For a non-Go toolchain, export that toolchain's WRITE cache env at a temp-dir
path the same way, inside the executor's shell.

## Prompt template (fill `<...>`)

```
You are a dispatched MUSTER executor. This is a single scoped task - do exactly
the Steps, then stop. Skip any skill preamble (SUBAGENT-STOP applies: you were
dispatched to execute a specific task).

Your task card (already claimed for you):

<inlined card body: Steps, Acceptance, verify command(s), commit_paths>

Do:
1. Follow the Steps exactly. Edit only the files the card names.
2. Run the card's verify command(s) yourself to self-correct. Any Go command
   needs a writable build cache and the sandbox denies the default one, so in
   the SAME shell line as each Go command, create and point the caches at the
   system temp dir - e.g. PowerShell:
   `mkdir "$env:TEMP\muster-codex\go-build","$env:TEMP\muster-codex\go-tmp" -Force | Out-Null; $env:GOCACHE="$env:TEMP\muster-codex\go-build"; $env:GOTMPDIR="$env:TEMP\muster-codex\go-tmp"; <go command>`
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
