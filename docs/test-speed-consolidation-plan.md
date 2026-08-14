# Test Speed and Runtime Consolidation Plan (PowerShell-native)

**Status:** revision 2, incorporates `docs/runtime-consolidation/codex-review.md` (all nine findings accepted)
**Responds to:** `docs/csharp-runtime-consolidation-proposal.md`
**Goal:** cut the dev-loop test time from 10-16 min per engine to a 30-second p95 gate, without a cross-language rewrite.
**Decision requested:** approve Phase 0 (baseline) and Phase 1 (two-verb prototype). Later phases proceed only on measured evidence.

## Summary

The C# proposal correctly identifies two problems: duplicated engines and a slow test loop.
It picks one cure for both: rewrite the runtime in C#.

This plan argues the test-speed problem is not caused by PowerShell the language.
It is caused by the test-harness architecture: one child `powershell.exe` process per verb invocation, one fresh `git init` fixture per test, and everything doubled across two engines.

Measurements on the current dev machine (Windows 11, Windows PowerShell 5.1):

- One `powershell.exe -NoProfile` child spawn: 1.755-1.8 s (two independent 5-spawn averages).
- One fixture cycle (`git init` + config + add + commit): 0.50-0.83 s across samples. Variance is real; hence the p50/p95 discipline below.
- Fresh 5.1 runspace after warm-up: ~17-20 ms. Runspace that dot-sources `_lib.ps1` and runs a library operation: ~35-60 ms.
- Static `Invoke-Muster` call sites in tests: 110, of which 82 are command-level tests. Test count: 123 `It` blocks; ~120 fixtures per run (`BeforeEach`).
- Historical integration log: 794 s PowerShell suite, 973 s shell suite (`tasks/archive/overlap-lint/overlap-lint-99-integration.verify.log`).

Arithmetic: several minutes of pure process startup plus over a minute of fixture creation per engine run.
Pure parsing and selection logic executes in milliseconds; stateful verb paths additionally perform filesystem work and multiple Git subprocesses, which no language change removes.

Conclusion: eliminate the verb-script child processes and reduce fixture cost, and the language question becomes independent of the speed question.
C# achieves fast tests through in-process execution (xUnit calling functions directly).
PowerShell supports the identical mechanism natively, and the repo already uses it: `tests/Lib.Tests.ps1` dot-sources `_lib.ps1` and runs its tests with zero verb-script child processes (Git and verification subprocesses remain, in any language).

## Root-cause table

| Cost driver | Measured | Fix | Needs C#? |
|---|---|---|---|
| Child `powershell.exe` per verb call | 1.755-1.8 s each | in-process function calls / runspaces (17-60 ms) | no |
| Fresh `git init` fixture per test | 0.50-0.83 s each | benchmark fixture strategies, pick fastest correct one | no |
| Dual engine (ps1 + sh) | ~2x wall clock | demote sh arm to CI; deletion is a separate ADR | no |
| Slow 5.1 startup on this box | 1.755 s vs typical 0.4-0.7 s | optional NGen experiment, measured before/after | no |
| No parallelism across test files | serial 9 files | file-level jobs (5.1) or Pester 6 parallel under PS7 for process-only suites | no |
| Git subprocess work inside verbs | irreducible | none (C# pays this too) | n/a |

Constraints established during review:

- Pester 6.0.1 is installed. Its native file-level parallel execution is experimental, requires PowerShell 7, and silently falls back to sequential under Windows PowerShell 5.1 ([Pester parallel docs](https://pester.dev/docs/usage/parallel)). In-process 5.1-compatibility tests therefore cannot use it; a process-only suite orchestrated from PS7 could.
- The current harness does not preserve stdout bytes: `Invoke-Muster` captures pipeline objects, stringifies, joins with `\n`, and merges stderr via `2>&1` (`tests/MusterFixture.ps1:110`). The real observable contract today is normalized lines plus exit code, not bytes.
- `exit` is not confined to verb scripts: it appears in shared helpers `Get-RepoRoot` and `Write-Refuse` and in review/integration failure paths (`runtime/bin/_lib.ps1:10,28,1004,1042,1057`).
- Normal 5.1 startup is 400-700 ms ([Microsoft startup-performance docs](https://learn.microsoft.com/en-us/powershell/scripting/dev-cross-plat/performance/startup-performance?view=powershell-7.5)); the cause of the 1.755 s local figure is unproven (NGen state and Defender are hypotheses, not findings).

## Test tiers (target architecture)

| Tier | Mechanism | Per-test cost | Scope | When it runs |
|---|---|---|---|---|
| Fast | dot-source `_lib.ps1`, call command functions in-process | ms (pure logic) | parsing, schema, selection, tier/harness pinning, lint graph, scope checks, formatting | every dev iteration |
| Contract | fresh 5.1 runspace per test, real command-function execution | ~35-60 ms + git ops | claim/promote/verify/done flows needing clean session state | dev loop, pre-commit |
| Process | real `powershell.exe` child | ~0.4-1.8 s | the child-process contract, scoped by a contract matrix (see Phase 4) | CI, pre-release |
| Full CI | entire suite; sh black-box suite while the mirror exists | wall ~= slowest file with file-level jobs | everything | CI only |

Dev loop = fast + contract tiers.

**30-second gate (decision gate, not a forecast):**

- p95 at or below 30 s for the dev loop on the current 5.1 machine.
- Stable across at least five runs, cold and warm recorded separately (p50 and p95).
- The full existing black-box suite stays green throughout migration.
- No behavior test is removed merely to meet the timing target.

## Plan

### Phase 0: baseline only

1. Record current test count and per-file cold/warm p50 and p95 timings, both engines.
2. Measure separately: PowerShell startup, fixture setup, representative Git commands, representative verb calls.
3. No machine changes (no NGen) until the baseline is committed to this doc.
4. Optional, after baseline: NGen precompile as a measured experiment, before/after recorded. Machine tuning only - never a repository acceptance condition.

Exit: baseline table committed.

**Result:** Phase 0 baseline committed - see [`runtime-consolidation/baseline-2026-08-13.md`](runtime-consolidation/baseline-2026-08-13.md). Full-suite p50 totals: ps1 292.2 s, sh 787.2 s (DAMAI-NEW, Windows PowerShell 5.1, no NGen).

### Phase 1: two-verb prototype (decision gate)

1. Extract `Invoke-StatusCommand` and `Invoke-LintCommand` into `_lib.ps1`, each returning a structured `CommandResult` (output lines, refusal/error info, exit code).
2. Control-flow boundary, single model:
   - command functions never call `exit`; they return `CommandResult`;
   - shared helpers (`Write-Refuse`, `Get-RepoRoot`, review/integration failure paths) throw a consistently identified refusal/error, caught at the command boundary - no dual-mode helpers;
   - only the six verb shims write output and call `exit`.
3. Add a Windows PowerShell 5.1 runspace harness (fresh runspace per test, stream + exit capture).
4. Keep all existing process tests for `status` and `lint` unchanged as the parity gate.
5. Compare behavior and timings before touching other verbs.

Exit: both verbs pass existing tests through shims; in-process timings recorded. Stop here if extraction makes control flow more complex or fragile.

**Result:** Both verbs pass the unchanged black-box suite through shims on both engines (136 tests green, ps1 and sh). In-process measured speedup: status 4.0x, lint 5.2x (~4.6x mean) - see [`runtime-consolidation/phase1-comparison-2026-08-13.md`](runtime-consolidation/phase1-comparison-2026-08-13.md). Control-flow complexity verdict: **simpler / equal** - the throw-based `Write-Refuse` plus a uniform two-line boundary wrap per verb replaced ad-hoc `exit` calls, and `status`/`lint` collapsed to clean shims over pure, independently testable command functions; no verb body grew more complex. Not worse, so the stop condition did not fire. (Known in-process limitation - refusals following a failing native command must route to the process tier - documented in the comparison file, feeding the Phase 4 contract matrix.)

### Phase 2: fixture experiment

1. Benchmark at least: current `New-MusterFixture`, recursive copy of a prepared fixture, `git clone --local`, and a worktree-or-equivalent strategy. Early samples show copy (0.30-0.65 s) is not reliably faster than init (0.50-0.56 s) - selection must be evidence-based.
2. Validate the winner for: no stale `.git` content, clean status, independent mutation between tests, reliable cleanup, compatibility with the future checkout lock.
3. Adopt only on a repeatable material gain.

Exit: fixture strategy chosen from measurements, or explicitly kept as-is.

**Result:** Adopted `copy` via a lazily built template (rebuilt per Pester test file, ~12x per full run) - see [`runtime-consolidation/fixture-comparison-2026-08-13.md`](runtime-consolidation/fixture-comparison-2026-08-13.md). Per-fixture create+destroy p50 0.344 s / 0.356 s across the two passes (worst pass 0.356 s) vs init 0.908 s (best of two init passes), a 0.39x ratio - material under the pre-fixed 30% rule in both passes. Contract validated (permanent coverage in `tests/Harness.Tests.ps1`); full black-box suite green on both engines post-swap. Single-run `Invoke-Pester -Path tests` wall time post-swap: 239.23 s (not comparable to the 292.2 s baseline, which sums per-file p50s across separate hosts).

### Phase 3: stateful vertical slice

1. Convert one complete `claim -> verify -> done` path to command functions.
2. Cover refusal, successful completion, verification failure, and review cycling - this is where the accumulated edge cases live (D12 claim-probe, D17, D20, D25, D28-D30).
3. Existing black-box suite remains the parity backstop, unchanged.

Exit: the risky region proven in-process, not just the easy read-only verbs.

**Result:** Done 2026-08-14. All three stateful verbs extracted to `Invoke-DoneCommand` / `Invoke-ClaimCommand` / `Invoke-VerifyCommand` in `runtime/bin/_lib.ps1`, each returning a `CommandResult`; `done.ps1` / `claim.ps1` / `verify.ps1` are now thin `Invoke-CommandBoundary` shims. The unchanged black-box suite stays green on both engines through the shims - full-suite parity gate `Tests Passed: 161, Failed: 0` on ps1 and on sh, no diff. The fast tier (`tests/fast/{Done,Claim,Verify}.Fast.Tests.ps1`, 24 tests) proves the risky region in fresh 5.1 runspaces: successful completion, verification failure, review cycling, and all non-native-stderr refusals. Three native-stderr paths stay process-tier by the documented runspace divergence - the uncommitted-task `Read-CommittedTask` refusal, the `eol=lf`+CRLF `Complete-Task` completion, and `Invoke-Promote`'s `Write-Host` warnings (measured in `runtime-consolidation/phase3-spike-2026-08-14.md`). Per-verb control-flow verdicts: `done` simpler, `claim` equal, `verify` simpler - none "worse", so the C#-decision stop condition did not fire. In-process vs child speedup for `done`: 3.2x (`runtime-consolidation/phase3-comparison-2026-08-14.md`), smaller than the read-only verbs' 4.6x because the stateful verbs are git-subprocess-bound; Phase 3 is net-slower in isolation and pays off in Phase 4's migration.

### Phase 4: tier classification and migration

1. Classify every existing test by the boundary it protects (logic / session state / child-process contract).
2. Build the process-tier contract matrix. Minimum coverage:
   - success and refusal/nonzero exit for every verb;
   - argument binding for `claim`, `done`, `lint`, `promote`;
   - output ordering and terminal session lines;
   - stdout/stderr separation and encoding only if declared contractual (see open question 2);
   - execution from the installed `tasks/bin` layout;
   - at least one Git failure propagation scenario.
   Coverage decides the count (likely ~20), not a preset number.
3. Migrate eligible behavior tests to function or runspace execution.
4. Measure the dev loop against the 30-second p95 gate.

Exit: gate met, or a documented measured miss that feeds the C# decision.

**Result:** Done 2026-08-14 on damai-new (Windows PowerShell 5.1, Pester 6.0.1). Shipped: **[D1]** the dev loop is verb-child-spawn-free - `Invoke-Muster` throws under `MUSTER_DEVLOOP` and the fast-tier claim/probe setups run in-process; **[D2]** shared reset-reuse fixtures (`New-SharedMusterFixture`: one copy per file, `git reset --hard <base>` + `clean` between tests, adopted on the measured ratio in `runtime-consolidation/phase4-fixture-2026-08-14.md`); **[prereq]** `Invoke-PromoteCommand` extracted (control-flow verdict *simpler*), `promote.ps1` now an `Invoke-CommandBoundary` shim; **[D3]** the `promote` malformed-backlog `Write-Host` warning folded from the runspace Information stream into the harness result, making the promote-warning rows twinnable (`runtime-consolidation/phase4-classification.md`); **[D4]** a committed contract matrix (`tests/ContractMatrix.psd1`, 24 rows), child-tier gap tests (`tests/ProcessContract.Tests.ps1`, ps1-pinned - the sh mirror diverges on the no-git refusals), a black-box growth-freeze inventory (`tests/BlackBoxInventory.psd1`), and a discovery-only meta-test (`tests/fast/SuiteMeta.Fast.Tests.ps1`) enforcing tag-linkage + growth freeze; **[D5]** 47 eligible black-box behaviors migrated to in-process twins; **[D6]** `tests/run-dev.ps1` (serial decomposition + a `Start-Job` parallel lever) and `tests/run-full.ps1` (both-engine checkpoint). Gate (spec D6, worst-of-5-warm <= 30 s): **serial warm p50 166.5 s / p95 167.9 s** (cold p50 174.0 / p95 178.0), 129 tests, 0 verb-child spawns - **MISS by 5.6x**. The `Start-Job` parallel lever is non-viable (verify-entry children deadlock inside a background job - a redirected-I/O `Process.Start` platform limitation, reproduced single-job - and per-job overhead alone exceeds 30 s). **D7** (pre-registered): the cost decomposition gives F_low (git+fixture+template) = 103.2 s, and even the tightest floor - fixture I/O alone at 39.8 s, which any language's harness pays identically - exceeds the 30 s gate, so **F_low > 30 s -> rule 1**: the gate is unreachable in any language on this machine; it is renegotiated (scope or number) and **C# is NOT revived on speed grounds**. A (~62-65 s) is the recorded upper bound on what a rewrite could remove, below which the F floor still blocks the gate. Full black-box suite green on both engines - final parity **ps1 224 passed / 0 failed, sh 219 passed / 0 failed (5 skipped)**; `ProcessContract` is ps1-child-tier so its 5 Its skip under sh (a Phase 5 shell-ADR item: sh `promote` exits 0 not 1 outside a git repo, sh `claim` rejects the ps1 flag args). Same-box before/after: the pre-Phase-4 76-test candidate set was warm p95 104.1 s; run-dev is 129 tests (53 contract behaviors migrated in-process) at 167.9 s = ~1.2 s per added test vs ~5 s as a black-box child spawn. Details: `runtime-consolidation/phase4-{baseline,fixture,classification,comparison}-2026-08-14.md`. Per the phase exit, the documented measured miss with D7 rule 1 applied is a valid exit.

### Phase 5: separate architecture decisions

Deliberately outside the test-speed work:

1. **Shell support ADR.** Evidence: the sh engine has only ever executed through Git-for-Windows `sh.exe` (`tests/MusterFixture.ps1:96`) - a POSIX coverage gap, not proof of zero POSIX users. Either add genuine Linux/macOS CI and keep the mirror, or change the support policy to PowerShell-canonical and document the new POSIX runtime requirement (`pwsh` launchers). While the mirror exists, its complete black-box suite stays in CI; it gains nothing from PowerShell in-process tests. Short-term: demote sh out of the local dev loop now.
2. **Git hardening + checkout lock.** Exit-code-checked mutating Git calls (no `2>$null` masking), exclusive lock file under `.git/` covering all mutating commands, `tasks/.muster-version`. Separate change after the structural refactor is stable. These are language-independent wins adopted from the C# proposal.

## Relationship to the C# proposal

This plan is the cheaper experiment and the prerequisite gate. Test speed alone no longer justifies C# if the prototype meets the 30-second p95 gate. Revive the C# proposal if any of these holds:

- the measured dev loop cannot meet the gate without materially reducing coverage;
- `CommandResult` extraction makes PowerShell control flow more complex or fragile (Phase 1 exit check);
- dual-engine maintenance remains a demonstrated recurring cost and shell support cannot be retired;
- self-contained cross-platform distribution becomes a real requirement;
- sharing domain code with an ASP.NET viewer becomes an approved near-term requirement;
- process control, cancellation, locking, or Git failure recovery cannot be implemented reliably in PowerShell.

If revived, the C# Phase 1 gate must include a `done`/review-cycling slice, not only `status`/`lint` - that is where the rewrite risk lives.

## Acceptance criteria

1. Dev loop (fast + contract) meets the 30-second p95 gate as defined above.
2. Full existing behavior preserved: the pre-refactor suite passes unchanged against the post-refactor shims at every phase.
3. No new runtime, toolchain, or distribution requirement for users.
4. The child-process contract (exit codes, normalized-line output, refusal text) is asserted by the contract-matrix process tests. A byte-level contract, if declared, gets a dedicated `System.Diagnostics.Process` harness without pipeline normalization.
5. Every phase independently shippable; stopping after any phase leaves the repo consistent.

## Risks

- `exit`-to-throw refactor touches shared helpers, not just the six verb bodies. Mitigated by the single control-flow model, the Phase 1 two-verb gate, and the unchanged black-box suite as parity backstop.
- Runspace state bleed between tests. Mitigated by one fresh runspace per test; process tier remains the backstop.
- In-process tests can mask child-process-only bugs (encoding, `$LASTEXITCODE`, CRLF). Covered by the contract-matrix process tier and full CI run.
- Fixture-strategy change could break Git independence or cleanup. Covered by Phase 2 validation checklist.
- Measurement variance on one machine. Covered by cold/warm p50/p95 over five-plus runs.

## Open questions

1. Shell support ADR (Phase 5.1): real POSIX CI, or PowerShell-canonical policy change?
2. Is any output byte-contractual (encoding, CRLF), or is the normalized-line contract the real one? Decides whether the raw `System.Diagnostics.Process` harness is needed at all.
3. Should the process-only suite be orchestrated from PS7 to use Pester 6 parallel, or are 5.1-hosted file-level jobs enough for CI?

## Revision history

- rev 1: initial counter-proposal.
- rev 2: all nine findings from `docs/runtime-consolidation/codex-review.md` accepted after repo verification (Pester 6.0.1 confirmed installed; `exit` sites in `_lib.ps1:10,28,1004,1042,1057` confirmed; `Invoke-Muster` normalization at `tests/MusterFixture.ps1:110` confirmed; Pester-6-parallel-requires-PS7 confirmed against pester.dev). Phases restructured to Codex's amended sequence; template-copy prescription replaced with benchmark; NGen made optional; 30 s made a p95 gate; byte contract corrected to normalized-line; process-test count replaced with contract matrix; shell decision and Git hardening split out.
