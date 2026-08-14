# Phase 4 design: tier classification, contract matrix, migration, gate measurement

**Date:** 2026-08-14 (rev 2, post adversarial review)
**Status:** approved design, feeds `superpowers:writing-plans`
**Governing plan:** `docs/test-speed-consolidation-plan.md` (rev 2), Phase 4
**Inputs:** `docs/runtime-consolidation/baseline-2026-08-13.md`,
`phase1-comparison-2026-08-13.md`, `phase3-comparison-2026-08-14.md`,
`phase3-spike-2026-08-14.md`, solution-auditor session audit (2026-08-14),
three adversarial spec reviews (measurement, mechanics, conformance;
2026-08-14)

## Problem

The dev loop must meet a 30-second p95 gate (fast + contract tiers).
The full suite (161 tests, all tiers) runs 825.68 s (ps1) / 993.44 s (sh)
on the current box (RPS-MV-L-1007). Phase 4 as written says: classify
tests, build a process-tier contract matrix, migrate eligible tests
in-process, measure. This spec fixes the concrete method for each step.

## Measured budget (current box)

Rev 1 of this spec projected current-box costs by scaling old-box numbers
with a single 2.83x machine ratio. Adversarial review falsified that
method (the ratio pairs two non-comparable measurements, and the sh-arm
cross-check shows a 2.24x prediction error). All projections are replaced
with measurements taken on RPS-MV-L-1007 during review (2026-08-14,
single/dual runs; plan Task 0 re-measures under the full protocol):

| Item | Measured |
|---|---|
| `tests/fast` (37 tests), wall | 175.60 / 185.09 / 195.81 s (3 runs; flat-to-rising warm, so git/fixture-bound, not warm-up) |
| `tests/Lib.Tests.ps1` (39 tests), wall | 41.41 s |
| Dev-loop candidate set (76 tests) | ~217-237 s = 7.2-7.9x the gate |
| Fixture create+destroy, p50 | 0.799 s |
| Fresh-runspace `Invoke-StatusCommand` | 0.254 s |
| Child `claim` (`Invoke-MusterClaim`) | 5.42 s |
| In-process `claim`, warm | 0.85 s |
| First in-process call in a new host | ~5.2 s (~4.4 s one-time warm-up) |

Structure of the waste: the fast tier's setups spawn `powershell.exe`
verb children 11 times (plus 2 more as a probe verify command - 13
children total); ~47 tests build a fixture at ~0.8 s each; per-file
template builds add more.

Conclusion: best-case waste removal (in-process claim setup ~ -50 s,
fixture strategy ~ -42 s) leaves ~125-145 s serial - still 4-5x over the
gate.
Therefore: parallelism is a designed lever of this phase, not a
contingency, and the measurement protocol carries a pre-registered
decision rule so a miss produces a usable verdict instead of a shrug.

## Decisions (user-approved; 1-6 this session, 7-8 post-review)

1. **Black-box suite kept, not deleted.** It becomes the on-demand process
   tier. Deleting a black-box test would also delete the sh mirror's only
   coverage of that behavior; the shell ADR is Phase 5's call. Growth is
   frozen: new behavior tests land in fast/contract tier; black-box
   additions only for contract-matrix gaps or newly found child-only
   divergences. The freeze is enforced by the suite meta-test (D4).
2. **Output contract = normalized lines + exit code.** The only
   programmatic consumption path is `expect_contains`' literal substring
   match on merged stdout+stderr (`_lib.ps1`, `Invoke-VerifyEntry`);
   every other consumer is an LLM reading terminal text. No byte- or
   encoding-sensitive consumer exists. No raw `System.Diagnostics.Process`
   harness. Acceptance criterion 4's byte branch is closed.
3. **sh engine out of the dev loop.** The mirror can only run black-box,
   so any loop containing it blows the gate by construction. Full
   both-engine parity run required before merging any branch touching
   `runtime/bin/`.
4. **Classification at Describe level with It-level coverage counts.**
   23 Describe rows (124 Its) instead of a 124-row table. Each row
   carries "twinned N of M Its" because several files are one Describe
   with many partially-twinned Its (Lint: 3 of 18).
5. **Contract matrix is the process tier, outside the 30 s gate.** Dev
   loop = fast + contract (both in-process) only.
6. **Gate = worst of 5 warm runs <= 30 s.** Reported as p95 per repo
   convention; with n=5 the two are the same statistic (see
   `baseline-2026-08-13.md:5`). This is a max-based acceptance gate, not
   a tail estimate, and must not be read as one in the C#-decision doc.
   Cold is recorded and reported, non-gating; cold p95 > 2x warm p95 is
   flagged as a finding. Rationale for warm-only gating: a dev loop is
   repeated iteration; cold is paid once per session.
7. **Parallelism is designed up front** (see D6), because the measured
   serial budget cannot reach the gate.
8. **The C#-decision rule is pre-registered** (see D7) before gate
   measurement, following the Phase 2 / Phase 3 precedent of fixing the
   verdict rule before measuring.

## Tier model

| Tier | Mechanism | Runs | In gate? |
|---|---|---|---|
| Fast | dot-source `_lib.ps1`, direct call | dev loop | yes |
| Contract | fresh 5.1 runspace per test (`InProcHarness`) | dev loop | yes |
| Process | child `powershell.exe`, contract-matrix subset (tags) | checkpoint | no |
| Full parity | full black-box, both engines | pre-merge for `runtime/bin` changes | no |

**Dev-loop membership is an explicit file list** inside
`tests/run-dev.ps1` (directory globs cannot express it - the fast tier's
largest file, `Lib.Tests.ps1`, lives beside the black-box files):
`tests/fast/*.Fast.Tests.ps1` + `tests/Lib.Tests.ps1` + new twin files.
`tests/Harness.Tests.ps1` stays checkpoint-tier (it builds from-scratch
fixtures and spawns a child by design), and so does the suite meta-test:
its nested discovery pass measures ~5-6 s wall (plan review, 2026-08-14) -
too fat for the 30 s gate; freeze violations are commit-time events, caught
at checkpoints.

**Checkpoint enforcement:** no CI exists, so the outer tiers bind to the
repo's existing mechanism instead of habit: `tests/run-full.ps1` (both
engines) is created in this phase, and the Phase 4 board plan's own
integration task carries it as a verify entry. Residual risk: between
checkpoints, a child-process-only regression can sit undetected on a
branch; the parity-before-merge rule bounds it to unmerged work.

## Design

### D1. Kill harness verb-child spawns (primary lever)

- Default: replace the 11 `Invoke-MusterClaim` child calls in
  `Done.Fast` / `Claim.Fast` setups with in-process claims via
  `Invoke-MusterInProc`. Evidence this is safe and faster: 8 green tests
  already run `Invoke-ClaimCommand` in runspaces; the Phase 3 spike
  passes both default-fixture stateful chains; claim's probe uses
  `Process::Start` (no `NativeCommandError` path); 0.85 s warm vs 5.42 s
  child.
- Fallback (only if in-process claim shows divergence in practice):
  pre-claimed fixture template family - one lazily-cached variant per
  distinct claimed shape (six exist: impl, impl-failing-verify, review,
  review-failing-verify, integration, claimed-then-recovered). Choice
  governed by the same pre-registered material-gain rule as D2.
- Free win: `Claim.Fast.Tests.ps1`'s probe verify command is literally
  `powershell -NoProfile -Command Test-Path src/out.txt` - two full
  `powershell.exe` children inside in-process tests. Replace with a
  git-based expectation.
- Invariant, restated precisely: **harness-initiated verb-script child
  spawns = 0 in the dev loop.** Enforced mechanically: `Invoke-Muster`
  throws when `$env:MUSTER_DEVLOOP` is set. Children the runtime itself
  spawns by design (verify entries via `Invoke-VerifyEntry`, git calls)
  are sanctioned, counted separately in the decomposition as
  language-independent cost.

### D2. Fixture primitive re-benchmark (primary lever)

Benchmark on the current box, dev-loop scope only:

1. current template-copy;
2. one fixture per file with baseline reset between tests:
   capture the template's baseline SHA at build, then
   `git reset --hard <baseSha>` + `git clean -xfd` (a bare
   `reset --hard` targets HEAD, which the verbs move - review proved it
   leaves the previous test's claim and commits in place);
3. pre-built fixture pool.

The Phase 2 validation checklist gets a reuse-aware variant: sequential
isolation (commit in test N invisible to test N+1), attempt-marker
history wiped (the `Get-AttemptCount` range must not see the previous
test's `attempt` commits - the Verify Describes, which drive attempts
1..3 on the same task id, are the named acceptance tests), clean status,
reliable cleanup. Adoption by the pre-registered material-gain rule
(Phase 2 precedent: repeatable >=30% gain).

### D3. Classification (Describe rows, It-level coverage)

Audit every black-box and `Lib.Tests` Describe (23 rows, 124 Its).
Output committed to `docs/runtime-consolidation/phase4-classification.md`:

| Column | Values |
|---|---|
| Describe | file + Describe name |
| Boundary | logic / session-state / child-contract |
| Twinned | N of M Its |
| Divergence | none / native-stderr / info-stream / failing-native-cmd |

Four documented divergence sources route tests child-only:

- two measured native-stderr paths (uncommitted-task `Read-CommittedTask`
  refusal; `eol=lf`+CRLF `Complete-Task`) - `phase3-spike-2026-08-14.md`;
- the promote warning path, reclassified: `Invoke-Promote` warnings go
  through `Write-Host` to the Information stream, which the runspace
  harness currently drops (not native stderr; rev 1 was wrong). A small
  probe decides: fold `$ps.Streams.Information` into the harness (making
  these rows twinnable) or keep them child-only;
- the Phase 1 failing-native-command class: any refusal that follows a
  failing native command throws in a hosted runspace
  (`phase1-comparison-2026-08-13.md`). D3 enumerates which refusal paths
  fall in this class before the matrix count is fixed.

### D4. Contract matrix (process tier)

Rows top-down from the plan's minimum coverage list: success +
refusal/nonzero exit per verb (12), argument binding for claim / done /
lint / promote (4), output ordering + terminal session lines (2),
installed `tasks/bin` layout (1), Git failure propagation (1) - about 20;
coverage decides the count, plus the forced child-only rows from D3.

- The matrix is a **committed data file** (row id, tag, black-box test,
  eligible-for-twin flag), not prose. The meta-test asserts against it.
- Implementation: It-level Pester tags on existing black-box tests
  (verified working in Pester 6.0.1 under PS 5.1; untagged Describes do
  not run their setup blocks when filtered out). Twin linkage is **the
  same tag on the black-box It and its fast twin** - join on tag, never
  on test names (names already diverge between existing pairs).
- The `tasks/bin` layout row is a tag on an existing test: every
  black-box test already runs `tasks/bin/<verb>.ps1` from an installed
  copy by construction (`MusterFixture.ps1` installs `runtime/bin/*`).
  No new test.
- New coverage only where nothing exists. One gap is already known:
  claim-with-malformed-backlog - `Invoke-ClaimCommand` calls
  `Invoke-Promote`, whose skip warning vanishes in-process, and no test
  on any tier covers it.
- **Suite meta-test** (new checkpoint-tier file, discovery-only via
  `Invoke-Pester` `Run.SkipRun` - ~5-6 s for the full nested discovery
  pass, builds no fixtures): asserts every matrix row's tag exists exactly where the
  data file says; every eligible row has a same-tag twin; and the
  black-box inventory (file + Describe + It count) matches a committed
  inventory, so any untracked black-box addition fails the dev loop
  until the inventory is updated deliberately. This is the growth-freeze
  enforcement.

### D5. Migration

From the classification table, write fast/contract twins for uncovered
eligible Its. New fast tests use shared expectation helpers. Black-box
test **files** are unchanged except additive tags; shared fixture
helpers (`MusterFixture.ps1`) may change under D1/D2, gated by the
reuse-aware validation checklist plus a full both-engine parity run.

- **Promote prerequisite:** `Invoke-PromoteCommand` does not exist -
  `promote.ps1` still wraps `Invoke-Promote` via `Exit-OnRefusal`.
  Extracting it (same pattern and stop-conditions as Phases 1/3,
  ps1-side only) is a Phase 4 sub-step and touches `runtime/bin/`, so
  the full parity rule applies. Without it, Promote rows stay
  child-only.
- The single-source parameterized rewrite (one test body, injected
  invoker, tier = tag) stays a post-gate option: it would rewrite the
  124 black-box+Lib tests and break the "suite passes unchanged" anchor
  mid-consolidation.

### D6. Dev-loop runner, parallelism, measurement protocol

- `tests/run-dev.ps1`: explicit file list, `Import-Module Pester
  -MinimumVersion 6.0.0` (a 3.4.0 is also installed - a bare
  `Invoke-Pester` is PSModulePath roulette), sets `MUSTER_DEVLOOP=1`,
  prints wall time and the serial-only decomposition.
- **Decomposition (serial runs only):** fixture total via stopwatch
  accumulators inside `New-MusterFixture` / `Remove-MusterFixture`
  aggregated through a process-global sink (each test file dot-sources
  its own fixture scope, so `$script:` accumulators are per-file);
  template builds attributed separately; execution total = sum of It
  durations from the Pester result object; sanctioned child spawns
  (verify entries) counted separately. Parallel runs report wall time
  and per-job wall times only.
- **Parallelism (designed, not contingent):** file-level `Start-Job`,
  4-6 workers, per-job TEMP. Gate metric under parallelism =
  end-to-end wall time of one runner invocation, warm = repeated
  invocation; each job pays its own host spawn and ~4.4 s first-call
  warm-up - that cost is real and stays inside the metric. Consequence:
  wall time is bounded by the slowest file (`Lib.Tests.ps1` after D2 is
  the likely bound); if it dominates, splitting `Lib.Tests.ps1` at file
  level (assertions unchanged, treated as a harness change gated by the
  full parity run) is the sanctioned balancing move.
- **Protocol:** 5 cold runs (fresh shell each; only run 1 is OS-cache
  cold - "cold" here means fresh PowerShell host, stated in the doc) +
  5 warm runs (same shell), p50/p95 per population, machine recorded.
  Pre-change baseline: the review measurements above, re-taken under
  this protocol as plan Task 0 (micro rows via
  `tests/bench/Measure-Baseline.ps1 -SkipSuite` to a NEW output file -
  the script overwrites its hard-coded path).
- Gate: Decision 6. Results committed to
  `docs/runtime-consolidation/phase4-comparison-<date>.md`.

### D7. Pre-registered C#-decision rule (fixed before measurement)

The decomposition splits warm p95 into:

- **F** = language-independent floor: git children + verify-entry
  children + fixture filesystem I/O;
- **A** = C#-addressable share: PowerShell interpreter/runspace overhead
  + in-process execution time.

Rules, in order:

1. **F > 30 s:** the gate is unreachable in any language on this
   machine; the gate itself is renegotiated (scope or number). C# is
   NOT revived on speed grounds.
2. **F + A > 30 s and F <= 30 s:** the speed case for C# is established;
   the comparison doc feeds Phase 5 with A as the measured bound on what
   a rewrite buys.
3. **F + A <= 30 s:** gate met; test speed no longer justifies C#
   (plan, "Relationship to the C# proposal").

## Exit criteria

1. Gate met (Decision 6), or the D7 rule's outcome (1 or 2) documented
   in the committed comparison doc.
2. Full black-box suite green on both engines; black-box test files
   unchanged except additive tags; harness changes parity-gated.
3. Classification doc, matrix data file + tags, suite meta-test,
   `run-dev.ps1`, `run-full.ps1` committed.
4. Every step leaves the repo shippable.

## Risks

- Reuse-strategy isolation: mitigated by the reuse-aware checklist with
  the Verify Describes as named acceptance tests; template-copy remains
  the fallback.
- Checkpoint tiers rely on the run-full verify entry and the
  parity-before-merge rule, not CI; regression window = unmerged
  branches, accepted and documented.
- Parallel runner: job-host overhead and slowest-file bound may cap the
  gain; Decision 6's metric absorbs the overhead honestly; file split of
  `Lib.Tests.ps1` is the sanctioned rebalance.
- Twin drift: bounded by same-tag linkage + the meta-test inventory.

## Out of scope

- Shell-support ADR and Git hardening (Phase 5, by plan).
- Single-source parameterized test rewrite (post-gate option, D5).
- PS7 / Pester 6 parallel orchestration (only if `Start-Job` proves
  insufficient).
- CI infrastructure (none exists; all tiers are locally invoked).
- Upgrading the repo's own pinned `tasks/bin` install to the extracted
  runtime (board self-hosting concern, not test speed).
- NGen or other machine tuning.

## Not yet specified

- Parallel-runner ergonomics: output interleaving and per-job failure
  attribution. Blurry until the serial numbers and worker count exist.
- The Information-stream probe outcome (D3): fold vs child-only for the
  promote-warning rows - sharp question, answered by a plan task, but
  the answer is not assumed here.
