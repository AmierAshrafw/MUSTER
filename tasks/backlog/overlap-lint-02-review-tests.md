---
id: overlap-lint-02-review-tests
plan: overlap-lint
type: review
tier: strong
reviews: overlap-lint-01-tests
depends_on:
  - overlap-lint-01-tests
verify:
  - cmd: "powershell -NoProfile -ExecutionPolicy Bypass -Command Invoke-Pester tests/LintOverlap.Tests.ps1 -Output Detailed"
    expect_exit: 0
    expect_contains: "[-] FAILs two impl tasks sharing a commit_path with no ordering"
    timeout_seconds: 600
---
# overlap-lint-02-review-tests: review overlap-lint-01-tests

## Context

What overlap-lint-01-tests was supposed to do, from the plan snapshot:

Create the NEW file tests/LintOverlap.Tests.ps1 (a new file rather than an append
to tests/Lint.Tests.ps1, so downstream engine tasks can freeze it via protected)
holding one Describe block, 'bin/lint - commit_paths overlap (D32)', with exactly
nine tests defining the new batch check 15:

1. Two impl tasks sharing a commit_path, no ordering: exit 1, finding matches
   "commit_path 'src/foo.txt' also written by 'p-02-b'".
2. Same pair directly ordered via depends_on: no 'commit_path' finding.
3. Ordered transitively through a review task (D19 chain A, review-A, B): no finding.
4. Prefix overlap, dir vs file under it (src/ vs src/foo.txt): exit 1, finding
   matches 'no depends_on ordering'.
5. Disjoint commit_paths, no ordering: no finding.
6. Two fix-type tasks sharing a commit_path: exit 1, same finding shape as test 1.
7. Three-way overlap: one finding per unordered pair, deterministic lo/hi order
   (p-01-a vs p-02-b, p-01-a vs p-03-c, p-02-b vs p-03-c).
8. Prefix overlap in the reverse direction (file as lo, dir as hi): exit 1.
9. Clean full batch (impl + review + integration, disjoint paths): LINT OK 3.

The engines do not implement check 15 yet, so the four finding-assertion tests
(1, 4, 6, 8 above) must currently FAIL - that red state is intended TDD signal,
and this review's verify asserts it. Pass-cases assert the ABSENCE of the overlap
message rather than exit 0, because the minimal fixtures also trip check 11.
The task was forbidden from touching runtime/bin/_lib.ps1, runtime/bin/_lib.sh,
and tests/Lint.Tests.ps1.

Its result sidecar is at tasks/done/overlap-lint-01-tests.result.md; its diff is
the completion commit named there.

## Steps

1. Read the result sidecar and the completion commit's diff.
2. Judge ONLY what code cannot test: spec adherence, design quality,
   unintended side effects. Tier-0 already proved the red/regression markers.
   Specifically: the nine tests match the list above with no weakened
   assertions, the diff touches only tests/LintOverlap.Tests.ps1, and the
   finding-message strings match the exact shapes quoted above.
3. Write findings and a pass/fail verdict to tasks/doing/overlap-lint-02-review-tests.notes.md.
4. PASS: run the done script with pass.
5. FAIL: author ONE fix task at tasks/staging/overlap-lint-01-fix-SLUG.md
   (replace SLUG with a short kebab-case slug, in the filename, the id line, and
   the title line) using the template below - findings pasted into its Context.
   Do not add a generation field or a generation digit - the done script stamps
   those. Then run the done script with fail. If the script refuses on the
   generation cap, that is the correct outcome - report it and stop.

Fix-task template (the verify path uses a backslash on purpose: the fix edits the
now-tracked test file, so it cannot be listed as protected, and lint rejects a
forward-slash test path that sits only in commit_paths):

```markdown
---
id: overlap-lint-01-fix-SLUG
plan: overlap-lint
type: fix
tier: any
fixes: overlap-lint-01-tests
depends_on: []
protected:
  - runtime/bin/
  - tests/MusterFixture.ps1
commit_paths:
  - tests/LintOverlap.Tests.ps1
verify:
  - cmd: powershell -NoProfile -ExecutionPolicy Bypass -Command Invoke-Pester tests\LintOverlap.Tests.ps1 -Output Detailed
    expect_exit: 0
    expect_contains: "[-] FAILs two impl tasks sharing a commit_path with no ordering"
    timeout_seconds: 600
  - cmd: powershell -NoProfile -ExecutionPolicy Bypass -Command Invoke-Pester tests\LintOverlap.Tests.ps1 -Output Detailed
    expect_exit: 0
    expect_contains: "[+] does not fire on a clean full batch (regression)"
    timeout_seconds: 600
---
# overlap-lint-01-fix-SLUG: fix overlap-lint-01-tests

## Context

Review of overlap-lint-01-tests failed. Findings, verbatim:

(paste findings verbatim here)

Original task intent: author tests/LintOverlap.Tests.ps1 with the nine D32
overlap tests; four finding-assertion tests red until the engines implement
check 15; engines and existing tests untouched.

## Steps

1. Ensure the target state for every finding above - exact paths, exact content,
   written out by the reviewer.

## Acceptance

- Every finding above addressed; verify green.
```

## Acceptance

- Verdict recorded with findings; done script accepted pass or fail.
