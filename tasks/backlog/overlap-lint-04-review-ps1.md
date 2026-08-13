---
id: overlap-lint-04-review-ps1
plan: overlap-lint
type: review
tier: strong
reviews: overlap-lint-03-ps1
depends_on:
  - overlap-lint-03-ps1
verify:
  - cmd: "powershell -NoProfile -ExecutionPolicy Bypass -Command Invoke-Pester tests/LintOverlap.Tests.ps1 -Output Detailed"
    expect_exit: 0
    expect_contains: "Failed: 0,"
    timeout_seconds: 600
claimed_at: 2026-08-13T00:57:08Z
---
# overlap-lint-04-review-ps1: review overlap-lint-03-ps1

## Context

What overlap-lint-03-ps1 was supposed to do, from the plan snapshot:

Add batch check 15 (decision D32) to runtime/bin/_lib.ps1, and nothing else.
Two pieces, both with content fixed verbatim by the task:

- A helper "Test-Reaches" inserted immediately before "function Test-LintChecks {":
  depth-first walk over a child-to-parent depends_on edge map, with a seen-set,
  returning true when $From transitively reaches $To. Missing keys are dead ends.
- Check 15 inside Test-LintChecks' "if (-not $Lite) {" block, after check 12:
  builds $depMap from every parse-clean batch task (ContainsKey guard so a
  schema-invalid task without depends_on yields an empty list, not $null under
  StrictMode), collects parse-clean impl/fix tasks carrying commit_paths, and for
  each unordered pair - ordinal lo/hi ordering via [string]::CompareOrdinal to
  match the sh mirror's LC_ALL=C sort - skips pairs where Test-Reaches connects
  them in either direction, then flags the first prefix-aware commit_path overlap
  (Test-PathListed called in both directions) with exactly this finding:

  "$($lo.Id).md: commit_path '$hit' also written by '$($hi.Id)' with no depends_on ordering between them - add a dependency edge or reshard."

That finding text is the parity contract: the sh mirror task must reproduce it
byte-identically, so any wording drift here is a FAIL finding. The check is
full-batch only (not lint-lite) by design - reviewer-authored fix tasks are
linted solo, and D32 accepts that boundary.

Its result sidecar is at tasks/done/overlap-lint-03-ps1.result.md; its diff is
the completion commit named there.

## Steps

1. Read the result sidecar and the completion commit's diff.
2. Judge ONLY what code cannot test: spec adherence, design quality, unintended
   side effects. Tier-0 already proved both Pester files green. Specifically:
   the diff touches only runtime/bin/_lib.ps1, the helper and check sit at the
   stated anchors, the finding string matches the contract above byte-for-byte,
   and no existing check 1-14 logic was altered.
3. Write findings and a pass/fail verdict to tasks/doing/overlap-lint-04-review-ps1.notes.md.
4. PASS: run the done script with pass.
5. FAIL: author ONE fix task at tasks/staging/overlap-lint-03-fix-SLUG.md
   (replace SLUG with a short kebab-case slug, in the filename, the id line, and
   the title line) using the template below - findings pasted into its Context.
   Do not add a generation field or a generation digit - the done script stamps
   those. Then run the done script with fail. If the script refuses on the
   generation cap, that is the correct outcome - report it and stop.

Fix-task template:

```markdown
---
id: overlap-lint-03-fix-SLUG
plan: overlap-lint
type: fix
tier: any
fixes: overlap-lint-03-ps1
depends_on:
  - overlap-lint-03-fix2-lf-endings
protected:
  - tests/
  - runtime/bin/_lib.sh
commit_paths:
  - runtime/bin/_lib.ps1
verify:
  - cmd: "powershell -NoProfile -ExecutionPolicy Bypass -Command Invoke-Pester tests/LintOverlap.Tests.ps1 -Output Detailed"
    expect_exit: 0
    expect_contains: "Failed: 0,"
    timeout_seconds: 600
  - cmd: "powershell -NoProfile -ExecutionPolicy Bypass -Command Invoke-Pester tests/Lint.Tests.ps1 -Output Detailed"
    expect_exit: 0
    expect_contains: "Failed: 0,"
    timeout_seconds: 600
---
# overlap-lint-03-fix-SLUG: fix overlap-lint-03-ps1

## Context

Review of overlap-lint-03-ps1 failed. Findings, verbatim:

(paste findings verbatim here)

Original task intent: add Test-Reaches plus batch check 15 (D32 unordered
commit_path overlap) to runtime/bin/_lib.ps1 with the exact finding string the
sh mirror must reproduce; no other file touched.

## Steps

1. Ensure the target state for every finding above - exact paths, exact content,
   written out by the reviewer.

## Acceptance

- Every finding above addressed; verify green.
```

## Acceptance

- Verdict recorded with findings; done script accepted pass or fail.
