# Plan review — Phase 1 orchestrator auto-recovery

**Plan:** `2026-08-18-orchestrator-auto-recovery-phase1.md`
**Reviewer:** plan-reviewer (opus). **Verdict counts:** 1 Blocker, 2 Warnings, 2 Suggestions — all ACCEPTED and applied inline.

Reviewer confirmed clean on Tasks 1/2/3/5/6: pasted snippets match current signatures
(`Card.CommitPaths`, `passOpts.DoneCheckPass`, `a.St.Task`, `failCommitAndFile(...) int` → -1,
`writeResult` → `.muster/cards/<id>.result.md`), seeded-`doing` row lets `MarkDone`/`Promote`
succeed, the hook re-stage/amend block still references the reconstructed `paths`, SKILL.md line
numbers match, and no test-helper name collisions.

| # | Sev | Finding | Verdict | Resolution |
|---|-----|---------|---------|------------|
| B1 | Blocker | Task 4 test writes `.gitignore` **untracked** → `donePreconditions` refuses with "changed outside commit_paths: .gitignore" before reaching force-add; fails even on fixed tree. | ACCEPT | Commit `.gitignore` via `gitCommit` **before** `claim` (also truer to the real incident — tracked ignore file). Evidence: `done.go:46-60`, `result.go:31,37`, `claim.go:19-28`. |
| W1 | Warning | Task 4 test omits `skipOffWindows(t)`; fixture verify uses `findstr` (Windows-only) → suite fails off-Windows for the wrong reason. | ACCEPT | Added `skipOffWindows(t)` as first line of both process tests. Evidence: `loop_test.go:14-18`, `main_test.go:109-111`. |
| W2 | Warning | Spec testing-intent (a) reject-path + gen-history force and (b) gitignored `commit_paths` refused are uncovered. | ACCEPT (split) | (b) → new `TestDoneRefusesIgnoredCommitPath` process test. (a) → recorded as an accepted coverage gap (Task 3 note): one-line change identical to the tested `failCommitAndFile`; full `doneFailReview` harness disproportionate. |
| S1 | Suggestion | Task 2 Step 2 "Expected: FAIL" narration self-contradictory (`src/hello.txt` in `fake.Forced` vs "force-adds nothing"). | ACCEPT | Reworded: pre-fix `Forced` is empty; first failing assertion is the missing `.result.md`. |
| S2 | Suggestion | Task 4 pre-fix RED not reproducible (binary rebuilt from fixed source); should say so plainly. | ACCEPT | Reworded Step 2 as a post-fix regression guard with an explicit manual-revert procedure to witness red. |

No DISMISS/DEFER except the (a) sub-item of W2, deferred with justification per the reviewer's
"either add these or explicitly record the coverage gap."
