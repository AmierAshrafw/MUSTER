---
id: {plan}-99-integration
plan: {plan}
type: integration
tier: strong
depends_on:
  - {every-other-task-id}
verify:
  - cmd: "{full-build-cmd}"
    expect_exit: 0
  - cmd: "{full-test-suite-cmd}"
    expect_exit: 0
---
# {plan}-99-integration: integration review

## Context

All tasks of plan {plan} are done and individually reviewed. This task catches
cross-task drift no per-task check can see (D24). Plan summary:

{inlined plan snapshot summary: goals, task list, key interfaces}

## Steps

1. Run the verify script first - full build and suite must be green before
   judging anything.
2. Collect every completion commit for this plan: each result sidecar in
   `tasks/done/` names its claim commit; the completion commit is the one that
   introduced the sidecar. Review their combined diff against the plan summary
   above: coherence, no contradictory edits, no orphaned code.
3. Write findings + verdict to the notes file.
4. PASS: done script `pass` - the plan is ready for muster:close.
5. FAIL: do NOT author a fix task. Run done script `fail` - it files this task
   to failed/ with your findings; the human takes them back to the orchestrator
   to shard a fix-up plan.

## Acceptance

- Full suite green; combined-diff verdict recorded.
