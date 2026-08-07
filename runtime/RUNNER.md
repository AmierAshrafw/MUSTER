# RUNNER - executor contract

You are an executor. Your whole job is five verbs, in order. Do not improvise,
do not optimize, do not skip.

Windows: run scripts as `powershell -ExecutionPolicy Bypass -File tasks/bin/<name>.ps1`
(works on Windows PowerShell 5.1 and PowerShell 7 alike). POSIX: `sh tasks/bin/<name>.sh`.

1. **CLAIM** - run the claim script exactly as your dispatch line told you
   (it carries your identity flags). It prints your task. If it prints a line
   starting `MUSTER refuse:`, STOP - report that line verbatim and end the
   session.

2. **DO** - follow the task's Steps section exactly, in order. Touch only the
   files the task names. The task file is read-only - never edit it. Under
   tasks/ you may write ONLY the files this contract or your task names: your
   notes file (step 4), and on a review task the one staged fix its Steps tell
   you to author. Nothing else under tasks/, ever.

3. **VERIFY** - run the verify script. `VERIFY PASS` = go to step 4.
   `VERIFY FAIL ... Fix and rerun` = fix your work, run it again. It stops you
   after 3 attempts - if it says terminal, STOP and end the session. Never edit
   test files or anything the task lists as protected.
   On a review or integration task a verify failure is NOT yours to fix - you
   changed no code, so the environment is broken: write what you saw to the
   notes file and STOP. Do not retry, do not touch code.

4. **REPORT** - write `tasks/doing/<task-id>.notes.md`: one short paragraph of
   anything a reviewer should know (surprises, workarounds, doubts). Nothing to
   report on an impl task = skip the file. On a review or integration task the
   notes file is your findings and is required.

5. **DONE** - run the done script (review and integration tasks: `done pass` or
   `done fail`). It commits everything itself.

Any script output ending `Session over.` means exactly that: end the session.
It is the only stop signal; there are no others to interpret.

## Hard rules

- Never run `git add`, `git commit`, `git push`, or any git write - scripts own
  all commits.
- One task per session. When done says session over, you are done - do not claim
  again.
- Blocked, confused, or the task contradicts the repo? Write what you know to
  the notes file and STOP. A stale claim is detected automatically; guessing is
  not recoverable.
- Scripts refusing is normal operation, not an error to work around. Report the
  message and stop.

## RECOVERY (humans only)

Executors: this section is not for you. Your job ended at the refusal message -
report it and stop. Moving files under tasks/ is a human action, always.

A stale doing/ entry or dead-blocked backlog shows up in every claim's status
print. To recover a stale claim, in this order:

1. Inspect `git log` and `git status`. The usual crash shape is a claim commit
   plus a dirty tree holding the task's half-done work.
2. Do NOT stash or discard the dirty work - it is exactly what the next claim's
   recovery probe detects as already-green.
3. Move the task file from doing/ back to inbox/ (redo - safe, steps are
   idempotent) or to failed/ (give up). Commit ONLY that move.
4. Re-dispatch. The claim script tolerates dirt belonging to the task it
   claims, probes verify first, and either auto-files finished work or lets the
   new session redo the steps.

A stale file in staging/ (crashed review session) is safe to delete - commit
the deletion. Never let two sessions share this checkout.
