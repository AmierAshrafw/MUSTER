# Result: overlap-lint-99-integration

- status: failed
- verdict: fail
- claim_commit: 5254f23121f78c0c60ce0768ec0d83870cf8ce62
- claimed_at: 2026-08-13T02:38:19Z
- completed_at: 2026-08-13T03:36:42Z
- verify: pass (attempt 1 of 3)
- files_changed:
  - tasks/doing/overlap-lint-99-integration.notes.md
  - tasks/doing/overlap-lint-99-integration.verify.log

## Surprises

none reported

## Findings

# Integration review findings: plan overlap-lint

Verdict: FAIL (one finding, F1). The check-15 implementation itself is coherent,
parity-clean, and fully green; the failure is an unintended whole-file side
effect in the 07-docs completion commit that no per-task check reviewed.

## Verify (step 1)

VERIFY PASS (attempt 1). Full suite green on both engines:
- ps1 engine: Tests Passed: 121, Failed: 0 (740s)
- sh engine (MUSTER_ENGINE=sh): Tests Passed: 121, Failed: 0
Log: tasks/doing/overlap-lint-99-integration.verify.log.

## Combined diff reviewed (step 2)

Base e70e44b (muster: promote 2) to 2ba9f99 (done overlap-lint-07-docs).
Completion commits: 7028d9c (01-tests), faf607e (02-review), 2230d68 (03-ps1),
a17fe50 (04-review, gen2 cycle + gen3 pass), 72c9e2d (03-fix2-lf-endings),
3f61277 (05-sh), d5d6617 (06-review), 2ba9f99 (07-docs). Two chore commits in
the range (8499ccc, 5b30c9c) touch only .claude-plugin/plugin.json and
skills/ - out of plan, no interference with plan files.

## What passed

- Coherence: outside tasks/ the plan diff is exactly the four intended files.
  runtime/bin/_lib.ps1: pure 59-line insertion (Test-Reaches + check 15 inside
  Test-LintChecks' full-batch block, after check 12). runtime/bin/_lib.sh:
  pure insertion (lint_ordered awk fixpoint helper + check 15 in lint_checks'
  full-batch block, findings to LINT_OUT, mktemp files removed).
  tests/LintOverlap.Tests.ps1: new, the nine specified tests.
  docs/decisions.md: content-wise a pure 40-line insertion (D32 + KIV line) -
  but see F1. No check 1-14 logic altered; LINT OK/FAIL grammar unchanged.
- Finding text byte-identical across engines, verified mechanically: the ps1
  interpolated string at the check-15 site and the sh printf template
  "%s.md: commit_path '%s' also written by '%s' with no depends_on ordering
  between them - add a dependency edge or reshard." expand identically;
  substring equality checks on the constant segments pass in both blobs at
  2ba9f99. Both anchor lo/hi by ordinal compare (CompareOrdinal vs LC_ALL=C
  sort), test reachability transitively in both directions, and call the
  prefix-overlap predicate (Test-PathListed / path_listed) both ways.
- No orphaned code: the mid-plan review cycle resolved cleanly. gen2 review
  FAILed 03-ps1 for a whole-file LF-to-CRLF rewrite of _lib.ps1; fix task
  72c9e2d restored LF with content byte-identical (gen3 re-review confirmed
  via tr -d '\r' hash equality); _lib.ps1 at 2ba9f99 has 0 CR bytes. Board
  clean: staging/inbox/backlog empty, 8 result sidecars in done/. The stray
  overlap-lint-07-docs.verify.log in failed/ is the documented harmless
  leftover of that task's manual fail/recover cycle (RUNNER recovery notes).
- D32 ledger entry consistent with the implemented behavior: batch check 15,
  impl/fix pair space, prefix-aware overlap, transitive either-direction
  depends_on reachability, full-batch only (lint-lite out of scope), D19
  review-chain shape non-flagging, KIV line for done-time clobber detection
  present under Rejected/KIV.

## F1 (FAIL): 07-docs completion commit rewrote docs/decisions.md LF-to-CRLF

Commit 2ba9f99 rewrote every pre-existing line of docs/decisions.md from LF to
CRLF: old blob (e70e44b) 23800 bytes, 0 CR; new blob 26675 bytes, 347 CR - one
per line. Raw diff is 654 lines (347+/307-) for a 40-line real insertion; the
--ignore-space-at-eol diff is the clean insertion. Every other file this plan
touched is CR-free at 2ba9f99, and the file itself was LF before the task.

This is the exact defect class the plan's own gen2 review ruled FAIL-worthy on
_lib.ps1 (its F1), which forced fix task overlap-lint-03-fix2-lf-endings. The
combined diff therefore contains contradictory edits: 72c9e2d exists solely to
repair a whole-file CRLF rewrite, and 2ba9f99 reintroduces one in the plan's
most-appended file (the decisions ledger - every future plan diffs against it,
so blame and diff churn compound). 07-docs had no review pair and was
auto-filed at claim (verify green before execution, after a fail/recover
cycle), so this integration review is the first check that could see it -
the D24 lane. Root cause matches the fix2 executor's recorded warning: global
core.autocrlf=true plus a PowerShell whole-file rewrite; muster commits with
-c core.autocrlf=false, preserving the CRLF working bytes verbatim.
(docs/problem.md is also fully CRLF, but pre-existing - last touched 272fd1e,
2026-08-10 - and untouched by this plan; not attributable here.)

Fix shape for the follow-up plan (mirror of fix2-lf-endings, one fix task):
rewrite docs/decisions.md in place with LF endings only, content otherwise
byte-identical (347 lines, trailing newline preserved). Self-checks:
(Get-Content -Raw docs/decisions.md).Contains([char]13) must be False, and the
old blob piped through tr -d '\r' must hash equal to the new blob.

## Verdict

FAIL. Per this task's Steps, no fix task authored; findings go to the human to
shard a fix-up plan. Everything except F1 is ready - the fix is mechanical and
narrowly scoped to docs/decisions.md line endings.
