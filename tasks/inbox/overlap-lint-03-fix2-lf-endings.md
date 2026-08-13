---
id: overlap-lint-03-fix2-lf-endings
plan: overlap-lint
type: fix
tier: any
fixes: overlap-lint-03-ps1
generation: 2
depends_on: []
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
# overlap-lint-03-fix2-lf-endings: fix overlap-lint-03-ps1

## Context

Review of overlap-lint-03-ps1 failed. Findings, verbatim:

F1 (FAIL): whole-file LF-to-CRLF rewrite of runtime/bin/_lib.ps1. The
completion commit rewrote every one of the 991 pre-existing lines from LF to
CRLF: the old blob contains 0 CR bytes, the new blob contains 1050 - one per
line. The task scoped the change to Test-Reaches plus check 15 "and nothing
else"; the raw diff is 2041 lines for a 59-line change. Every other tracked
.ps1 and .sh blob in the repo has 0 CR bytes, so runtime/bin/_lib.ps1 is now
the sole CRLF file against a uniform LF convention. Effects: git blame for the
whole engine file now points at this commit, and every future diff or parity
comparison against the sh mirror carries EOL noise. The 59 inserted lines
(Test-Reaches and check 15) are content-correct and must not change.

Target state: runtime/bin/_lib.ps1 rewritten in place with LF ("\n") line
endings only, content otherwise byte-identical (1050 lines, trailing final
newline preserved). One safe way, from the repo root:

    powershell -NoProfile -Command "$p = 'runtime/bin/_lib.ps1'; $t = [IO.File]::ReadAllText($p); [IO.File]::WriteAllText($p, $t.Replace([string][char]13 + [char]10, [string][char]10))"

Self-check after writing (must print False):

    powershell -NoProfile -Command "(Get-Content -Raw 'runtime/bin/_lib.ps1').Contains([char]13)"

Do not edit any line's text. Do not touch runtime/bin/_lib.sh or tests/. The
task scripts commit with core.autocrlf=false, so the LF bytes written to the
working tree land in the blob verbatim.

Original task intent: add Test-Reaches plus batch check 15 (D32 unordered
commit_path overlap) to runtime/bin/_lib.ps1 with the exact finding string the
sh mirror must reproduce; no other file touched.

## Steps

1. Ensure the target state for every finding above - exact paths, exact content,
   written out by the reviewer.

## Acceptance

- Every finding above addressed; verify green.
