---
id: overlap-lint-99-integration
plan: overlap-lint
type: integration
tier: strong
depends_on:
  - overlap-lint-01-tests
  - overlap-lint-02-review-tests
  - overlap-lint-03-ps1
  - overlap-lint-04-review-ps1
  - overlap-lint-05-sh
  - overlap-lint-06-review-sh
  - overlap-lint-07-docs
verify:
  - cmd: "powershell -NoProfile -ExecutionPolicy Bypass -Command Invoke-Pester tests -Output Detailed"
    expect_exit: 0
    expect_contains: "Failed: 0,"
    timeout_seconds: 2700
  - cmd: cmd /c "set MUSTER_ENGINE=sh& powershell -NoProfile -ExecutionPolicy Bypass -Command Invoke-Pester tests -Output Detailed"
    expect_exit: 0
    expect_contains: "Failed: 0,"
    timeout_seconds: 3600
---
# overlap-lint-99-integration: integration review

## Context

All tasks of plan overlap-lint are done and individually reviewed. This task
catches cross-task drift no per-task check can see (D24). Plan summary:

Goal: a new shard-lint batch check (check 15, decision D32) that FAILs when two
impl/fix tasks share a commit_path (prefix-aware) with no transitive,
either-direction depends_on ordering between them, implemented with
byte-identical finding text in both lint engines. The finding contract:

"<lo-id>.md: commit_path '<path>' also written by '<hi-id>' with no depends_on ordering between them - add a dependency edge or reshard."

Task list and what each committed:
- overlap-lint-01-tests: NEW file tests/LintOverlap.Tests.ps1 - nine Pester
  tests defining check 15 (red until the engines landed).
- overlap-lint-02-review-tests: review verdict on the tests.
- overlap-lint-03-ps1: Test-Reaches helper (transitive depends_on walk) plus
  check 15 in runtime/bin/_lib.ps1, inside Test-LintChecks' full-batch block.
- overlap-lint-04-review-ps1: review verdict on the ps1 engine change.
- overlap-lint-05-sh: lint_ordered helper (awk fixpoint closure) plus check 15
  in runtime/bin/_lib.sh - the parity mirror, ps1 output authoritative.
- overlap-lint-06-review-sh: review verdict on the sh mirror.
- overlap-lint-07-docs: D32 ledger entry plus KIV line in docs/decisions.md.

Key interfaces the changes hang off: Test-PathListed / path_listed (prefix
overlap, called in both directions), the batch arrays in Test-LintChecks and the
_lint_clean temp file in lint_checks, and the LINT FAIL / LINT OK output grammar
(unchanged, no new severity tier). The check is full-batch only; lint-lite (fix
tasks) stays out of scope by design. The verify block above runs the full suite
on both engines (the second entry sets MUSTER_ENGINE=sh for the child powershell
via cmd /c).

## Steps

1. Run the verify script first - the full suite must be green on both engines
   before judging anything.
2. Collect every completion commit for this plan: each result sidecar in
   tasks/done/ names its claim commit; the completion commit is the one that
   introduced the sidecar. Review their combined diff against the plan summary
   above: coherence, no contradictory edits, no orphaned code, finding text
   byte-identical across both engines, D32 ledger entry consistent with the
   implemented behavior.
3. Write findings + verdict to the notes file.
4. PASS: done script pass - the plan is ready for muster:close.
5. FAIL: do NOT author a fix task. Run done script fail - it files this task
   to failed/ with your findings; the human takes them back to the orchestrator
   to shard a fix-up plan.

## Acceptance

- Full suite green on both engines; combined-diff verdict recorded.
