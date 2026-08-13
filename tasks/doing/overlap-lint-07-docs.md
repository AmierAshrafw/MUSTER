---
id: overlap-lint-07-docs
plan: overlap-lint
type: impl
tier: any
depends_on: []
protected: []
commit_paths:
  - docs/decisions.md
verify:
  - cmd: powershell -NoProfile -ExecutionPolicy Bypass -Command Select-String -Path docs/decisions.md -Pattern "D32. Shard-lint flags unordered commit_path overlap" -Quiet
    expect_exit: 0
    expect_contains: "True"
  - cmd: powershell -NoProfile -ExecutionPolicy Bypass -Command Select-String -Path docs/decisions.md -Pattern "executor-stage commit_path clobber detection" -Quiet
    expect_exit: 0
    expect_contains: "True"
claimed_at: 2026-08-13T02:14:58Z
---
# overlap-lint-07-docs: record D32 in the decision ledger

## Context

The commit_paths overlap lint (batch check 15) is being added to both engines in
sibling tasks of this plan. docs/decisions.md is the decision ledger; every
mechanism change gets a numbered entry. The ledger currently ends its numbered
run at "## D31. Subagent-orchestrated dispatch (muster:auto)" (line 251), followed
by "## Rejected (do not reopen without new facts)" (line 276) and
"## KIV (revisit later, do not delete)" (line 291). This task is documentation
only - no engine or test file changes.

## Steps

1. Ensure docs/decisions.md contains, between the end of the D31 block and the
   "## Rejected (do not reopen without new facts)" heading, exactly this block
   (blank line before and after):

```markdown
## D32. Shard-lint flags unordered commit_path overlap

Two `impl`/`fix` tasks may name the same `commit_path` with no `depends_on` edge
between them. Nothing detected it: `Test-LintChecks` read `commit_paths` per-task
only (checks 5, 13); the batch checks were just integration-count (11) and review
wiring (12). Execution is serial (D18) so there is no git race, but the second
same-file task's Steps are frozen at shard time against a view of the file that
predates the first task's committed edits. Non-additive Steps then silently
overwrite the first task's work at HEAD, caught only if a later verify or the
integration suite re-covers the clobbered code. Additive appends (MUSTER's own
`_lib.ps1` was built this way) are fine, but a lint cannot tell additive from
destructive - a shared path is a risk signal, not a proven defect.

New batch check (15): FAIL when two `impl`/`fix` tasks share a `commit_path`
(prefix-aware) with no transitive, either-direction `depends_on` ordering between
them. The author adds an edge (`Add-DependsOn`-shaped, one line) or reshards. The
forced edge costs nothing under D18's serial execution and stays correct under
future worktree concurrency (you cannot safely parallel-edit one file).
Reachability is transitive so the D19 `A -> review-A -> B` chain does not
false-positive.

Boundary: the check is full-batch only. Reviewer-authored fix tasks are linted
solo via lint-lite (no batch), so they are out of scope - acceptable because a
fix task is authored against the impl's real committed diff, not a stale plan
view, so it is the one same-file case without stale-Steps risk.

Rejected alternatives (solution-auditor pass, 2026-08-12):
- Done-time clobber detection: opposes D22 (reject shard output, not executor
  mess), fires after a burned session, fuzzy attribution. Parked as KIV; revisit
  only if fix-task overlap is seen in practice.
- `overlap_ack:` frontmatter marker: unbacked self-attestation (cf. D30), adds
  schema surface for a false positive D18 already makes harmless.
- WARN severity tier: breaks the binary LINT grammar for weaker enforcement.
- FAIL only when the shared path is not also `protected`: unsafe - `protected`
  does not make a write additive, and D30 dual-lists self-authored tests in both
  lists, so the predicate would wave through the exact clobber shape.

Source: analysis session 2026-08-12 + solution-auditor.
```

2. Ensure the list under "## KIV (revisit later, do not delete)" additionally
   ends with exactly this line:

```markdown
- Done-time / executor-stage commit_path clobber detection (D32 alternative) - only if fix-task overlap is observed in practice.
```

3. Ensure no other file changed and no existing ledger text was reworded.

## Acceptance

- docs/decisions.md carries the D32 entry between D31 and the Rejected section,
  plus the KIV line; nothing else in the repo changed.
