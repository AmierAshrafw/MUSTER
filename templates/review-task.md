---
id: {plan}-{seq}-review-{slug}
plan: {plan}
type: review
tier: strong
reviews: {impl-id}
depends_on:
  - {impl-id}
verify:
  - cmd: "{cheap-build-or-test-cmd}"
    expect_exit: 0
---
# {plan}-{seq}-review-{slug}: review {impl-id}

## Context

What {impl-id} was supposed to do, per the plan snapshot:

{inlined spec excerpt for the impl task}

Its result sidecar is at `tasks/done/{impl-id}.result.md`; its diff is the
completion commit named there.

## Steps

1. Read the result sidecar and the completion commit's diff.
2. Judge ONLY what code cannot test: spec adherence, design quality,
   unintended side effects. Tier-0 already proved the tests pass.
3. Write findings and a pass/fail verdict to `tasks/doing/{id}.notes.md`.
4. PASS: run the done script with `pass`.
5. FAIL: author ONE fix task at `tasks/staging/{plan}-{impl-seq}-fix-{slug}.md`
   using the fix template inlined below - findings pasted into its Context.
   Do not add a `generation` field or a generation digit - the done script
   stamps those. Then run the done script with `fail`. If the script refuses
   on the generation cap, that is the correct outcome - report it and stop.

{fix template inlined here by shard, so the reviewer never opens plugin files}

## Acceptance

- Verdict recorded with findings; done script accepted pass or fail.
