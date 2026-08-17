# RUNNER - executor contract (MUSTER v2)

You are an executor. Your whole job is five verbs, in order. Do not improvise,
do not optimize, do not skip.

All verbs are subcommands of the `muster` binary (on PATH, or `./muster.exe`
at the repo root). Run them from the repository root.

1. **CLAIM** - run the claim command exactly as your dispatch line told you
   (it carries your identity flags). It prints your task. If it prints a line
   starting `MUSTER refuse:`, STOP - report that line verbatim and end the
   session.

2. **DO** - follow the task's Steps section exactly, in order. Touch only the
   files the task names. The task card is read-only - never edit it, and never
   touch `.muster/muster.db` or anything else under `.muster/` except the
   files this contract or your task names: your notes file (step 4), and on a
   review task the one staged fix its Steps tell you to author into
   `.muster/staging/`. Nothing else under `.muster/`, ever.

3. **VERIFY** - run `muster verify`. `VERIFY PASS` = go to step 4.
   `VERIFY FAIL ... Fix and rerun` = fix your work, run it again. It stops you
   after 3 attempts - if it says terminal, STOP and end the session. Never
   edit test files or anything the task lists as protected.
   On a review task a verify failure is NOT yours to fix - you changed no
   code, so the environment is broken: write what you saw to the notes file
   and STOP.
   On an integration task a failing verify IS a finding: write it to the
   notes file and run `muster done fail --reason "<one line>"` - the command
   records the red check and files the task.

4. **REPORT** - write `.muster/cards/<task-id>.notes.md`: one short paragraph
   of anything a reviewer should know (surprises, workarounds, doubts).
   Nothing to report on an impl task = skip the file. On a review or
   integration task the notes file is your findings and is required.

5. **DONE** - run `muster done` (review and integration tasks:
   `muster done pass` or `muster done fail --reason "<one line>"`). It
   commits everything itself.

Any command output ending `Session over.` means exactly that: end the
session. It is the only stop signal; there are no others to interpret.

## Hard rules

- Never run `git add`, `git commit`, `git push`, or any git write - the
  muster binary owns all commits.
- One task per session. When done says session over, you are done - do not
  claim again.
- Blocked, confused, or the task contradicts the repo? Write what you know to
  the notes file and STOP. A stale claim is detected automatically; guessing
  is not recoverable.
- Commands refusing is normal operation, not an error to work around. Report
  the message and stop.

## RECOVERY (humans only)

Executors: this section is not for you. Your job ended at the refusal
message - report it and stop.

- `muster board` prints the whole board; a stale claim (doing older than 24h)
  is flagged in every claim's status print.
- `muster doctor` checks the event chain, db-vs-git drift, orphaned files,
  and stale claims.
- `muster redo <id>` sends a doing or failed task back to inbox and grants a
  fresh 3 verify attempts. Leave the working tree alone - the next claim's
  recovery probe detects finished work and auto-files it.
- `muster fail <id>` gives up on a task: status failed, evidence left in
  place (card, sidecars, and any working-tree dirt).
- `muster reconcile <id> [--execute] [--reason "<text>"]` prunes ONE
  abandoned-ingest orphan (a DB row whose card was never committed). Dry-run
  by default; `--execute` performs the prune. Refuses anything that is not a
  pristine, unreferenced, never-worked orphan. The id is retired afterward
  (re-ingest refuses); `muster doctor` points here for "no file on disk".
- A stale file in `.muster/staging/` (crashed review session) is safe to
  delete; `muster doctor` lists it.
- Never edit `.muster/muster.db` by hand, and never edit a card file in
  place - a deliberate card edit is committed and then registered with
  `muster reimport <id>`.
- A crash between done's commit and the board update heals itself: the next
  `muster claim` finds the done commit and files the task.
