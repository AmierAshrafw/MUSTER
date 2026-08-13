# Phase 2 Fixture Experiment — Execution Report

Ran unattended overnight via `superpowers:subagent-driven-development`, fresh subagent per task, two-stage review (spec compliance, then code quality) after each. All 4 tasks completed, no cap breaches, no failures, no retries needed. Nothing pushed; `tasks/` untouched.

## Outcome

**Adopted `copy`.** Decision rule (fixed in the plan before measuring): a candidate is material only if it passed `Assert-FixtureContract` AND both benchmark passes show p50 ≤ 0.7 × best `init` pass p50.

- init best p50 = 0.908 s → threshold = 0.6356 s
- **copy**: pass1 p50 0.344 s, pass2 p50 0.356 s, contract passed → both ≤ 0.6356 → **MATERIAL** (ratio 0.39×) → **adopted**
- **clone-local**: pass1 p50 0.851 s, pass2 p50 0.856 s → both > 0.6356 → not material (ratio 0.94×)
- **worktree**: contract FAILED (its `.git` lives under the template, not its own dir — disqualified by design, expected per plan) → not eligible regardless of timing (ratio 0.45×, timed for the record only)

Full timing table and verdicts: [`docs/runtime-consolidation/fixture-comparison-2026-08-13.md`](../../runtime-consolidation/fixture-comparison-2026-08-13.md).

`New-MusterFixture` now lazily builds one template per Pester test file (via `New-MusterFixtureFromScratch`, the renamed old git-init body) and returns `Copy-Item -Recurse -Force` copies thereafter.

## Tasks completed

| Task | Commit | Spec review | Quality review |
|---|---|---|---|
| 1 — Fixture contract + candidate strategies (TDD) | `81bb243` | ✅ compliant | ✅ Approved |
| 2 — Benchmark script + comparison doc | `02e998b` | ✅ compliant | ✅ Approved with follow-up (cosmetic) |
| 3 — Decision gate: adopt `copy` | `986416a` | ✅ compliant | ✅ Approved with follow-up (latent bug) |
| 4 — Record result in spec | `a039f0a` | verified directly (doc-only, 2-line diff) | — |

Branch `test-speed-consolidation` is now 9 commits ahead of `origin/test-speed-consolidation` (not pushed, per instructions).

## Suite results (wall times)

| Run | Result | Wall time | Tests |
|---|---|---|---|
| Task 1: `Harness.Tests.ps1` (TDD red→green) | PASS | 6.75 s | 3/3 |
| Task 3 Step 3: contract + fast tests | PASS | 14.88 s | 16/16 (3 Harness + 13 fast) |
| Task 3 Step 4: full ps1 suite (`-Path tests`) | PASS | 239.23 s (~4.0 min) | 137/137 |
| Task 3 Step 5: full sh suite (`MUSTER_ENGINE=sh`) | PASS | 730.97 s (~12.2 min) | 137/137 |

All well inside their hard caps (25 min / 45 min respectively). No kills, no breaches, no test failures, no retries.

## Cap breaches or failures

None. Every step finished within its expected range, let alone its hard cap.

One process-management wrinkle, not a task failure: the Task 3 implementer subagent twice ended its turn while its own background suite run was still in flight (waiting on a Monitor it had armed but not blocked on), producing two intermediate task-notifications before the real terminal one. Resumed it via `SendMessage` each time with an explicit instruction to block until a terminal state. No data lost, no re-run, no impact on results — noted only because it added ~2 extra round-trips to Task 3's wall-clock, not to the measured suite times themselves.

## Needing your attention this morning

1. **Latent bug, spawned as a background task (`task_01159b3f`), not fixed inline:** `tests/bench/FixtureStrategies.ps1`'s `'init'` strategy entry still calls `New-MusterFixture` directly. Before Task 3 that was the true git-init path; after Task 3's swap, `New-MusterFixture` **is** the template-cached copy path, so `'init'` and `'copy'` now silently run identical code. Doesn't affect anything committed tonight (the permanent contract test in `Harness.Tests.ps1` still validates real behavior, since `'init'` now equals current `New-MusterFixture`), but a future rerun of `Measure-Fixture.ps1` would compare copy against itself and report a meaningless ~1.0× ratio with no warning. Fix is a one-line redirect to `New-MusterFixtureFromScratch` plus a comment update; task chip is ready to dispatch whenever convenient. Out of Task 3's file scope per the plan (which lists only `tests/MusterFixture.ps1` and `tests/bench/Measure-Baseline.ps1`), so it wasn't fixed inline.

2. **Cosmetic only, left as-is:** the committed `fixture-comparison-2026-08-13.md` has a doubled prefix in the worktree verdict line — `DISQUALIFIED (contract: contract: ...)`. This comes from the plan's own verbatim spec text for `Measure-Fixture.ps1` (the `Assert-FixtureContract` throw message already starts with `"contract: "`, and the verdict-formatting line wraps it in another literal `"(contract: ...)"`). Not an implementer deviation — confirmed byte-for-byte match to the plan. Zero effect on the verdict math (independently recomputed and confirmed correct by the spec reviewer). Not worth a re-run of the 2.4-minute benchmark to fix a doc string that already served its purpose; leaving it.

3. **Informational, doesn't change the decision:** Task 2's benchmark measured `init` p50 at 0.908–0.915 s, about 16–17% above the same-day baseline doc's 0.783 s figure (`docs/runtime-consolidation/baseline-2026-08-13.md`), with non-overlapping sample ranges across the two measurement sessions. Reviewed and judged not a structural measurement problem — stable within-run (two passes agree to <1%), tight sample clustering, larger N (40 samples vs. baseline's 5) — but the root cause of the session-to-session shift (machine load, AV, disk cache) wasn't diagnosed further, since the adoption decision only ever compares candidates against `init`'s p50 from the *same* run and is unaffected either way.

4. Everything else is clean: working tree has no uncommitted changes to tracked files (only the plan's own untouched sidecar docs remain untracked, as they were at the start of the run); nothing under `tasks/` was touched; nothing was pushed.
