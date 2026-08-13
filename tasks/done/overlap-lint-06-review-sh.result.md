# Result: overlap-lint-06-review-sh

- status: done
- verdict: pass
- claim_commit: 023f236bb77237e7a8939002b25226f80e8f9616
- claimed_at: 2026-08-13T02:05:47Z
- completed_at: 2026-08-13T02:13:49Z
- verify: pass (attempt 1 of 3)
- files_changed:
  - tasks/doing/overlap-lint-06-review-sh.notes.md
  - tasks/doing/overlap-lint-06-review-sh.verify.log

## Surprises

none reported

## Findings

# Review: overlap-lint-05-sh

Verdict: PASS

## Findings

- Scope: the completion commit (3f61277) touches runtime/bin/_lib.sh as the only
  code file; every other changed path is muster-owned state (verify.log,
  result.md, card moves). runtime/bin/_lib.ps1 and tests/ untouched.
- Anchors: lint_ordered sits at _lib.sh lines 436-460, immediately before
  "lint_checks() {" (line 462). Check 15 sits at lines 743-790, inside the
  full-batch block, directly after check 12's `done <"$_lint_clean"` and before
  that block's closing `fi`.
- Verbatim fidelity: both inserted blocks compared line-by-line against the
  task's fixed code fences (Compare-Object, sync window 0) - byte-identical,
  25 lines (helper) and 48 lines (check 15).
- Finding-text parity (D6): the sh printf format at _lib.sh:783 expands to
  exactly the ps1 string at _lib.ps1:626 - "%s.md: commit_path '%s' also
  written by '%s' with no depends_on ordering between them - add a dependency
  edge or reshard." filled lo-id, path, hi-id. Both engines report lo's path
  (the first overlapping pl), pick lo/hi by ordinal compare (LC_ALL=C sort vs
  CompareOrdinal), skip either-direction-reachable pairs, and enumerate pairs
  in the same nested order, so multi-finding output order also matches.
- awk closure: new keys staged in side array nk; r is never mutated while
  iterated (r written only inside the loop over nk). Empty edges file degrades
  cleanly (n uninitialized -> 0 in numeric context, loops skip, exit 1).
- Temp files: both mktemp files removed at the end of the check
  (rm -f "$_lint_edges" "$_lint_cp").
- One deliberate asymmetry vs ps1, no behavioral divergence: ps1 filters
  cpTasks to tasks with a commit_paths key; the sh mirror includes every
  schema-clean impl/fix task, but fm_list yields nothing for a missing key and
  path_listed returns 1 on an empty list, so such pairs can never produce a
  finding - identical outcomes.
- Minor portability note, not a defect (content was fixed verbatim by the
  task): the reverse-direction overlap test relies on `exit 0` inside the last
  element of a pipeline being a subshell exit; true under bash/dash (the shells
  this engine runs on) but ksh-style lastpipe shells would exit the script.
  Same class as the `delete nk` awk extension - fine on gawk/mawk/nawk/busybox.

Tier-0 evidence: verify re-ran both suites on the sh engine
(MUSTER_ENGINE=sh, LintOverlap.Tests.ps1 + Lint.Tests.ps1) - VERIFY PASS
(attempt 1), Failed: 0 on both.
