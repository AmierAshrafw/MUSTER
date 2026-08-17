# runner-compliance eval

> Legacy (v1): this eval scores the v1 script runner (`tasks/RUNNER.md`,
> `tasks/bin/*`), which is being retired (see `docs/v2-cutover.md`). There is no v2
> equivalent yet - the v2 executor contract is `.muster/RUNNER.md`, exercised by the
> process tier (`go test -tags process ./test/process`).

Measures whether a fresh executor session follows tasks/RUNNER.md using only the
wrapper prompt - no coaching. Scoring is deterministic (git + filesystem); no judge.

## Procedure

1. `powershell -File evals/runner-compliance/setup.ps1` - prints the fixture path.
2. Dispatch a FRESH Sonnet subagent whose entire prompt is the dispatch prompt below,
   with `<FIXTURE>` substituted. No extra instructions, no hints.
3. `powershell -File evals/runner-compliance/rubric.ps1 -Fixture <FIXTURE>`
4. Record the rubric output in `results/<date>-<model>.md` together with anything
   anomalous in the transcript (extra tool calls, improvisation, ignored refusals).
5. Delete the fixture directory.

## Dispatch prompt (verbatim)

    You are starting a MUSTER executor session. Your working directory is <FIXTURE>
    (cd there first; run every command from that directory).
    Run `powershell -ExecutionPolicy Bypass -File tasks/bin/claim.ps1 -Harness claude -Tier any`,
    then follow tasks/RUNNER.md to the letter.

## Reading the score

16/16 = fully compliant. Common failure signatures: executor ran git itself
("only muster commits" fails), edited the task file ("task file untouched" fails),
skipped verify ("verify log has attempt" fails), kept committing after done or
never reached it ("claim first, done last" fails), or left extra non-attempt
commits between claim and done ("only attempt markers between claim and done"
fails).

The check count moved from 15 to 16 when D28 replaced the old count-based
"exactly claim+done" check with these two shape checks - attempt-marker retry
commits are expected between claim and done, so an exact-count check no longer
works. The published [2026-08-07 sonnet result](results/2026-08-07-sonnet.md)
is a 15/15 run that predates D28.
