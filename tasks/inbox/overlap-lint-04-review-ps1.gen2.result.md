# Result: overlap-lint-04-review-ps1

- status: cycled
- verdict: fail
- claim_commit: 6c05f2c11f378b18ccd80d6bdf4c4bb871092fb1
- claimed_at: 2026-08-13T00:57:08Z
- completed_at: 2026-08-13T01:04:00Z
- verify: pass (attempt 1 of 3)
- files_changed:
  - tasks/backlog/overlap-lint-04-review-ps1.gen2.verify.log
  - tasks/doing/overlap-lint-04-review-ps1.md
  - tasks/doing/overlap-lint-04-review-ps1.notes.md
  - tasks/inbox/overlap-lint-03-fix2-lf-endings.md

## Surprises

none reported

## Findings

# Review findings: overlap-lint-03-ps1

Verdict: FAIL (one finding, F1). All spec-adherence criteria on the code content itself pass; the failure is an unintended whole-file side effect in the completion commit.

## What passed

- Scope: the task diff (40f1bf6..2230d68) touches only runtime/bin/_lib.ps1 plus the script-owned tasks/ sidecars.
- Anchors: Test-Reaches sits at line 414, immediately before `function Test-LintChecks {` (line 434). Check 15 sits inside the `if (-not $Lite) {` block (line 568), directly after check 12 (line 583). Checks 13 and 14 live in the -Lite section, so "after check 12" is the correct anchor.
- Finding string: byte-identical to the parity contract. Verified by mechanical string comparison, not eyeball:
  `$findings += "$($lo.Id).md: commit_path '$hit' also written by '$($hi.Id)' with no depends_on ordering between them - add a dependency edge or reshard."`
- Semantics: ContainsKey guard on depends_on (StrictMode-safe), [string]::CompareOrdinal lo/hi ordering (matches sh LC_ALL=C sort), Test-Reaches called in both directions before flagging, Test-PathListed called in both directions per path pair, pair space restricted to parse-clean impl/fix tasks carrying commit_paths. Test-Reaches is an iterative DFS with a seen-set; missing keys are dead ends. All as specified.
- No check 1-14 logic altered: `git diff -w` over the task range shows a pure 59-line insertion, nothing modified or deleted.
- Both Pester suites green (tier-0 plus this session's VERIFY PASS attempt 1).

## F1 (FAIL): whole-file LF-to-CRLF rewrite of runtime/bin/_lib.ps1

The completion commit rewrote every one of the 991 pre-existing lines from LF to CRLF: the old blob (40f1bf6) contains 0 CR bytes, the new blob (2230d68) contains 1050 - one per line. The task scoped the change to Test-Reaches plus check 15 "and nothing else"; the raw diff is 2041 lines for a 59-line change. Every other tracked .ps1 and .sh blob in the repo has 0 CR bytes, so runtime/bin/_lib.ps1 is now the sole CRLF file against a uniform LF convention (.gitattributes pins *.sh to LF; the .ps1 files follow the same convention by practice). Effects: git blame for the whole engine file now points at this commit, and every future diff or parity comparison against the sh mirror carries EOL noise. Functionally inert - PowerShell and Pester are indifferent - which is why tier-0 could not catch it; this is exactly the "unintended side effects" lane of this review.

Target state for the fix: runtime/bin/_lib.ps1 rewritten in place with LF ("\n") line endings only, content otherwise byte-identical (1050 lines, trailing final newline preserved). The task scripts commit with `-c core.autocrlf=false`, so whatever bytes sit in the working tree land in the blob verbatim - writing LF is sufficient and deterministic. Self-check after writing: `(Get-Content -Raw runtime/bin/_lib.ps1).Contains([char]13)` must be False.

## Notes for the record

- Repo-level `core.autocrlf=true` did not normalize the checkin because all MUSTER scripts commit with `-c core.autocrlf=false` by design; the executor's CRLF working file was preserved byte-for-byte.
- Fix task staged at tasks/staging/overlap-lint-03-fix-lf-endings.md.
