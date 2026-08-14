# Phase 4 design: tier classification, contract matrix, migration, gate measurement

**Date:** 2026-08-14
**Status:** approved design, feeds `superpowers:writing-plans`
**Governing plan:** `docs/test-speed-consolidation-plan.md` (rev 2), Phase 4
**Inputs:** `docs/runtime-consolidation/baseline-2026-08-13.md`,
`phase1-comparison-2026-08-13.md`, `phase3-comparison-2026-08-14.md`,
`phase3-spike-2026-08-14.md`, solution-auditor session audit (2026-08-14)

## Problem

The dev loop must meet a 30-second p95 gate (fast + contract tiers).
The full black-box suite runs 825.68 s (ps1) / 993.44 s (sh) on the current
box (RPS-MV-L-1007). Phase 4 as written says: classify tests, build a
process-tier contract matrix, migrate eligible tests in-process, measure.
This spec fixes the concrete method for each step.

## Arithmetic that shaped the design

The naive composition (migrate everything, keep current fixtures) misses the
gate by 5-6x:

- Current box is ~2.83x slower than the baseline box (825.68 s vs 292.2 s,
  same suite).
- Fixture template-copy costs ~0.35 s on the baseline box, so ~1 s here,
  paid per test. ~60 fixture-building tests in the dev-loop candidate set
  is ~60 s of fixture I/O alone - 2x the gate before any verb runs.
- `Lib.Tests.ps1` p50 was 24.6 s on the *faster* box, ~71 s projected here,
  despite already running in-process.
- The fast tier itself spawns `powershell.exe` children in setup:
  `tests/fast/Done.Fast.Tests.ps1` and `Claim.Fast.Tests.ps1` call
  `Invoke-MusterClaim` (a real child) 11 times.

Conclusion: waste removal (child spawns in setup, fixture cost) and
parallelism are the primary levers. Migration volume alone cannot reach the
gate. Measurement must decompose cost, or a miss would mis-feed the C#
decision (the dominant terms - git subprocesses, fixture I/O - are costs C#
pays too).

## Decisions (this session, user-approved)

1. **Black-box suite kept, not deleted.** It becomes the on-demand process
   tier. Deleting a black-box test would also delete the sh mirror's only
   coverage of that behavior; the shell ADR is Phase 5's call. Growth is
   frozen: new behavior tests land in fast/contract tier; black-box
   additions only for contract-matrix gaps or newly found child-only
   divergences.
2. **Output contract = normalized lines + exit code.** Every consumer is an
   LLM reading terminal text; the harness itself normalizes (`2>&1`,
   stringify, join `\n`); no programmatic byte consumer exists. No raw
   `System.Diagnostics.Process` harness. Acceptance criterion 4's byte
   branch is closed.
3. **sh engine out of the dev loop.** The mirror can only run black-box, so
   any loop containing it blows the gate by construction. Full both-engine
   parity run required before merging any branch touching `runtime/bin/`.
4. **Classification at Describe level, not It level.** ~30 verb-aligned
   Describes instead of 124 It rows. The per-It table has no consumer: the
   suite is kept wholesale and loop membership is decided per file/tag.
5. **Contract matrix is the process tier, outside the 30 s gate.** Dev loop
   = fast + contract (both in-process) only.
6. **Gate = warm p95 <= 30 s.** Cold recorded and reported alongside. A dev
   loop is repeated iteration; cold happens once per session.

## Tier model

| Tier | Mechanism | Runs | In gate? |
|---|---|---|---|
| Fast | dot-source `_lib.ps1`, direct call | dev loop | yes |
| Contract | fresh 5.1 runspace per test (`InProcHarness`) | dev loop | yes |
| Process | child `powershell.exe`, contract-matrix subset (tags) | pre-push / on demand | no |
| Full parity | full black-box, both engines | pre-merge for `runtime/bin` changes | no |

## Design

### D1. Waste removal (primary lever)

- Pre-claimed fixture template: extend `tests/MusterFixture.ps1` with a
  template variant whose task is already claimed (claim executed once at
  template build, copied per test). Removes the 11 child spawns from
  Done/Claim fast setups. Alternative implementation (in-process claim in
  setup) is measured against it; cheaper wins.
- Dev-loop child-spawn count must be 0 after this step; the runner asserts
  it (see D5).

### D2. Fixture primitive re-benchmark (primary lever)

Benchmark on the current box, dev-loop scope only:

1. current template-copy;
2. one fixture per file, `git reset --hard` + `git clean -xfd` between
   tests (reuse);
3. pre-built fixture pool.

Winner must pass the Phase 2 validation checklist: no stale `.git` content,
clean status, independent mutation between tests, reliable cleanup. Adopt
only on a repeatable material gain (Phase 2 precedent: the 30% rule).

### D3. Classification (Describe-level, gap-driven)

Audit every black-box and `Lib.Tests` Describe. Output committed to
`docs/runtime-consolidation/phase4-classification.md`:

| Column | Values |
|---|---|
| Describe | file + Describe name |
| Boundary | logic / session-state / child-contract |
| Twin status | exists / needed / child-only |

Known gaps going in: Promote and LintOverlap have zero fast twins; Lint has
3 fast tests against 26 black-box. Any newly discovered runspace-divergent
path is routed child-only and added to the carve-out list with the same
evidence standard as the Phase 3 spike.

### D4. Contract matrix (process tier)

Rows top-down from the plan's minimum coverage list:

- success + refusal/nonzero exit per verb (6 verbs, 12 rows);
- argument binding for `claim`, `done`, `lint`, `promote` (4);
- output ordering + terminal session lines (2);
- execution from the installed `tasks/bin` layout (1, made explicit);
- at least one Git failure propagation scenario (1).

Roughly 20 rows; coverage decides the count. The 3 known runspace-divergent
carve-outs (uncommitted-task `Read-CommittedTask` refusal, `eol=lf`+CRLF
`Complete-Task`, `Invoke-Promote` `Write-Host` warnings) are listed
separately as forced process-tier rows, not matrix choices.

Implementation: Pester tags on existing black-box It blocks. Additive only -
no assertion edits, the pre-refactor-suite invariant stays intact. New
black-box tests only for rows nothing covers (expected: git-failure
propagation, possibly argument-binding corners).

A meta-test in `Harness.Tests.ps1` asserts: every matrix row's tag exists,
and every eligible row has a fast twin per naming convention. This enforces
the growth freeze.

### D5. Migration

From the classification table, write fast/contract twins only for
uncovered Describes. New fast tests use shared expectation helpers to bound
twin drift. Black-box originals untouched except tags.

The single-source parameterized rewrite (one test body, injected invoker,
tier = tag) is recorded as a post-gate option. It would touch all 161 tests
and break the "suite passes unchanged" anchor mid-consolidation - wrong
phase for it.

### D6. Dev-loop runner + measurement protocol

- `tests/run-dev.ps1`: wraps `Invoke-Pester` over the dev-loop set (fast +
  contract, ps1 only). Prints wall time plus component decomposition:
  fixture total, execution total, child-spawn count (asserted 0).
- Protocol: 5 cold runs (fresh shell each) + 5 warm runs (same shell),
  p50/p95 for each population, machine name recorded.
- Gate: warm p95 <= 30 s on the current dev box.
- Parallelism lever: if serial warm p95 > 30 s, file-level `Start-Job`
  (5.1-native, 4-6 workers, per-job TEMP dir), then re-measure. PS7 +
  Pester 6 parallel stays deferred.
- Miss handling: committed comparison doc
  (`docs/runtime-consolidation/phase4-comparison-<date>.md`) with the
  decomposition splitting irreducible git/fixture I/O from interpreter
  overhead. That document is the honest feed to the C# decision.

## Exit criteria

1. Gate met (warm p95 <= 30 s), or a decomposed measured miss committed.
2. Full black-box suite green on both engines, unchanged except additive
   tags.
3. Classification doc, matrix tags, meta-test, and runner committed.
4. Every step leaves the repo shippable.

## Out of scope

- Shell-support ADR and Git hardening (Phase 5, by plan).
- Single-source parameterized test rewrite (post-gate option, recorded in
  D5).
- PS7 / Pester 6 parallel orchestration (deferred; only revisited if the
  Start-Job lever proves insufficient).
- CI infrastructure (none exists; all tiers are locally invoked).
- NGen or other machine tuning.

## Not yet specified

- Parallel-runner ergonomics (output interleaving, failure attribution
  across jobs). Blurry until serial numbers exist; only matters if the
  parallelism lever fires.
