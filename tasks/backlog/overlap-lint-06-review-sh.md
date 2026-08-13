---
id: overlap-lint-06-review-sh
plan: overlap-lint
type: review
tier: strong
reviews: overlap-lint-05-sh
depends_on:
  - overlap-lint-05-sh
verify:
  - cmd: cmd /c "set MUSTER_ENGINE=sh& powershell -NoProfile -ExecutionPolicy Bypass -Command Invoke-Pester tests\LintOverlap.Tests.ps1 -Output Detailed"
    expect_exit: 0
    expect_contains: "Failed: 0,"
    timeout_seconds: 900
---
# overlap-lint-06-review-sh: review overlap-lint-05-sh

## Context

What overlap-lint-05-sh was supposed to do, from the plan snapshot:

Mirror batch check 15 (decision D32) into runtime/bin/_lib.sh, and nothing else.
Parity is mandatory (D6): byte-identical finding text to the ps1 engine, whose
output is authoritative. Two pieces, both with content fixed verbatim by the task:

- A helper "lint_ordered" inserted immediately before "lint_checks() {":
  args idA, idB, edges-file (lines "child<TAB>parent"); exit 0 when either id
  transitively reaches the other. Implemented as an awk fixpoint transitive
  closure that stages new keys in a side array (nk) so the iterated array r is
  never mutated mid-iteration.
- Check 15 inside lint_checks' full-batch block, after check 12: builds an edges
  temp file from every schema-clean task's depends_on (via fm_list), collects
  impl/fix tasks into a second temp file, and for each unordered pair - lo/hi
  picked by LC_ALL=C sort to match the ps1 engine's ordinal compare - skips
  lint_ordered pairs, then flags the first prefix-aware commit_path overlap
  (path_listed called in both directions: direct call for "lo under hi", piped
  subshell for "hi under lo") with exactly this finding into LINT_OUT:

  overlap-lint finding contract, printf format:
  "%s.md: commit_path '%s' also written by '%s' with no depends_on ordering between them - add a dependency edge or reshard.\n"
  filled with lo-id, path, hi-id.

Both temp files are removed at the end of the check. The task's verify runs the
Pester suite with MUSTER_ENGINE=sh (cmd /c sets the variable for the child
powershell), so tier-0 already proved both test files green on the sh engine.

Its result sidecar is at tasks/done/overlap-lint-05-sh.result.md; its diff is
the completion commit named there.

## Steps

1. Read the result sidecar and the completion commit's diff.
2. Judge ONLY what code cannot test: spec adherence, design quality, unintended
   side effects. Tier-0 already proved the sh-engine suite green. Specifically:
   the diff touches only runtime/bin/_lib.sh, the helper and check sit at the
   stated anchors, the printf finding format matches the contract above
   byte-for-byte against the ps1 engine's string, the awk closure stages keys in
   the side array, and temp files are cleaned up.
3. Write findings and a pass/fail verdict to tasks/doing/overlap-lint-06-review-sh.notes.md.
4. PASS: run the done script with pass.
5. FAIL: author ONE fix task at tasks/staging/overlap-lint-05-fix-SLUG.md
   (replace SLUG with a short kebab-case slug, in the filename, the id line, and
   the title line) using the template below - findings pasted into its Context.
   Do not add a generation field or a generation digit - the done script stamps
   those. Then run the done script with fail. If the script refuses on the
   generation cap, that is the correct outcome - report it and stop.

Fix-task template:

```markdown
---
id: overlap-lint-05-fix-SLUG
plan: overlap-lint
type: fix
tier: any
fixes: overlap-lint-05-sh
depends_on: []
protected:
  - tests/
  - runtime/bin/_lib.ps1
commit_paths:
  - runtime/bin/_lib.sh
verify:
  - cmd: cmd /c "set MUSTER_ENGINE=sh& powershell -NoProfile -ExecutionPolicy Bypass -Command Invoke-Pester tests\LintOverlap.Tests.ps1 -Output Detailed"
    expect_exit: 0
    expect_contains: "Failed: 0,"
    timeout_seconds: 900
  - cmd: cmd /c "set MUSTER_ENGINE=sh& powershell -NoProfile -ExecutionPolicy Bypass -Command Invoke-Pester tests\Lint.Tests.ps1 -Output Detailed"
    expect_exit: 0
    expect_contains: "Failed: 0,"
    timeout_seconds: 900
---
# overlap-lint-05-fix-SLUG: fix overlap-lint-05-sh

## Context

Review of overlap-lint-05-sh failed. Findings, verbatim:

(paste findings verbatim here)

Original task intent: mirror batch check 15 (lint_ordered helper + D32 overlap
check) into runtime/bin/_lib.sh with finding text byte-identical to the ps1
engine; no other file touched.

## Steps

1. Ensure the target state for every finding above - exact paths, exact content,
   written out by the reviewer.

## Acceptance

- Every finding above addressed; verify green.
```

## Acceptance

- Verdict recorded with findings; done script accepted pass or fail.
