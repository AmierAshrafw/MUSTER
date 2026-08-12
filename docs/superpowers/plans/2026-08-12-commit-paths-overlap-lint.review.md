# Plan review sidecar - commit-paths overlap lint (D32)

Reviewer: plan-reviewer (opus), 2026-08-12. Plan:
`2026-08-12-commit-paths-overlap-lint.md`.

Verdict counts: 0 blockers, 2 warnings (1 accepted, 1 dismissed), 3 suggestions
(all accepted).

## Blockers

None. Reviewer verified insertion anchors, the `return , $findings` array-return
convention, the awk fixpoint closure (side-array avoids mutation under iteration),
`Test-Reaches` cycle-safety, and the sh finding-write-to-file pattern (no
subshell/SIGPIPE loss).

## Warnings

### W1 - ACCEPTED
ps1 `-lt` string compare is culture-aware; the sh mirror picks `lo` with
`LC_ALL=C sort` (byte-ordinal). For hyphen-adjacent ids (e.g. `p-01-a-b` vs
`p-01-ab`, both schema-legal) the two engines choose a different lower id, so the
emitted finding names a different task first - a byte-parity break (D6).
Applied: ps1 now uses `[string]::CompareOrdinal($hi.Id, $lo.Id) -lt 0` (Task 1
Step 4).

### W2 - DISMISSED
ps1 check 15 selects participants by `$_.Errors.Count -eq 0` (parse-clean); the sh
mirror builds from `_lint_clean` (schema-clean). A parse-clean-but-schema-invalid
task with valid `commit_paths` is scanned by ps1 only. Dismissed: cosmetic (a
schema-invalid batch already fails on the schema finding), and it mirrors the
pre-existing checks 11/12 per-engine convention rather than introducing new drift.
Recorded in the plan's Out of scope and flagged as a separate pre-existing cleanup.

## Suggestions

### S1 - ACCEPTED
Added three test cases (Task 1 Step 1): two `fix`-type tasks sharing a path (the
`fix` branch of the pair space was untested); a three-way overlap (multi-finding
determinism / lower-id attribution); and a reverse-direction prefix overlap
(lo=file under hi=dir, the other arm of the sh double `path_listed`).

### S2 - ACCEPTED
`@($dt.Fields['depends_on'])` yields `@($null)` when the key is absent under
StrictMode. Applied: `ContainsKey` guard when seeding `$depMap` (Task 1 Step 4).

### S3 - ACCEPTED
sh `_lint_hit=''` was set but never read (the finding is written inside the pipe
loop). Applied: line removed (Task 2 Step 3).
