# Test Speed and Runtime Consolidation Plan (PowerShell-native)

**Status:** counter-proposal for review
**Responds to:** `docs/csharp-runtime-consolidation-proposal.md`
**Goal:** cut the dev-loop test time from 10-16 min per engine to under 30 seconds, without a cross-language rewrite.
**Decision requested:** approve this plan instead of, or as a prerequisite gate before, the C# migration.

## Summary

The C# proposal correctly identifies two problems: duplicated engines and a slow test loop.
It picks one cure for both: rewrite the runtime in C#.

This plan argues the test-speed problem is not caused by PowerShell the language.
It is caused by the test-harness architecture: one child `powershell.exe` process per command invocation, one fresh `git init` fixture per test, and everything doubled across two engines.

Measurements on the current dev machine (Windows 11, PowerShell 5.1):

- One `powershell.exe -NoProfile` child spawn: **1.8 s** (measured, 5-spawn average).
- One fixture cycle (`git init` + config + add + commit): **0.83 s** (measured).
- Static `Invoke-Muster` call sites in tests: 110. Executed spawns per run: ~150-200 (helper functions re-run per test).
- Test count: 123 `It` blocks. Fixtures per run: ~120 (`BeforeEach` creates a fresh repo).

Arithmetic: ~5-6 min of pure process startup + ~1.7 min of fixture creation per engine run.
That is most of the 10-16 min. The runtime logic itself executes in milliseconds.

Conclusion: eliminate the spawns and the per-test `git init`, and the language question becomes independent of the speed question.
C# achieves fast tests through in-process execution (xUnit calling functions directly).
PowerShell supports the identical mechanism natively, and the repo already uses it: `tests/Lib.Tests.ps1` dot-sources `_lib.ps1` and runs 39 tests in-process with zero spawns.

## Root-cause table

| Cost driver | Measured | Fix | Needs C#? |
|---|---|---|---|
| Child `powershell.exe` per command call | 1.8 s each | in-process function calls / runspaces | no |
| Fresh `git init` fixture per test | 0.83 s each | template fixture, copy per test | no |
| Dual engine (ps1 + sh) | x2 everything | demote or delete sh arm | no |
| Abnormally slow 5.1 startup on this box | 1.8 s vs normal 0.4-0.7 s | one-time `ngen` precompile | no |
| No parallelism across test files | serial 9 files | parallel jobs per file (CI) | no |
| Git subprocess work inside commands | irreducible | none (C# pays this too) | n/a |

Reference points from research:

- Normal Windows PowerShell 5.1 startup is 400-700 ms; 1.8 s indicates missing ngen native images and/or Defender scanning. `ngen` precompile of PowerShell assemblies is a documented one-time fix (Microsoft startup-performance docs; SimeonOnSecurity ngen guide; woshub).
- Runspaces give a fresh isolated PowerShell session inside the same process at tens of milliseconds, available in 5.1. Established Pester pattern for clean-session testing (Adam the Automator; MCPmag).
- Pester has no native parallel execution (pester/Pester#1704, open since 2020). Standard workaround is file-level parallelism via jobs.
- pwsh 7 starts in 150-250 ms but the runtime targets 5.1; testing under a different engine risks semantic drift. Rejected.

## Test tiers (target architecture)

| Tier | Mechanism | Per-test cost | Scope | When it runs |
|---|---|---|---|---|
| Fast | dot-source `_lib.ps1`, call functions in-process | ~ms | parsing, schema, selection, tier/harness pinning, lint graph, scope checks, formatting | every dev iteration |
| Contract | fresh in-process runspace per test, real verb execution | ~50-100 ms + git ops | claim/promote/verify/done flows needing clean session state | dev loop, pre-commit |
| Process | real `powershell.exe` child, unchanged harness | ~0.4-1.8 s | exit codes, stdout byte contract, argument parsing; ~10-15 tests only | CI, pre-release |
| Full CI | entire suite, files parallelized via jobs | wall ~= slowest file | everything | CI only |

Target dev loop (fast + contract): **under 30 seconds**.

## Plan

### Phase 0: box hygiene and baseline

1. Run `ngen` precompile for PowerShell/.NET assemblies (one-time, admin). Re-measure spawn cost.
2. Record baseline timings: full suite per engine, per test file. Commit numbers to this doc.

Exit: baseline table committed. Expected side effect: existing suite already faster with zero code change.

### Phase 1: verbs become functions

1. Move each verb script body (`claim.ps1`, `promote.ps1`, `verify.ps1`, `done.ps1`, `lint.ps1`, `status.ps1`) into a `_lib.ps1` function: `Invoke-ClaimCommand`, `Invoke-DoneCommand`, etc.
2. Each function returns a result object (output lines + exit code) instead of calling `exit` directly. The scripts become 3-line shims: dot-source, call function, write output, exit with code.
3. `Write-Refuse` gains a non-terminating mode (throw a typed refusal the function converts to a result) so in-process callers do not kill the test host.
4. Parity gate: the existing process-based suite runs unchanged before and after. Same language, same engine - the current 121-test suite IS the golden fixture set. No cross-language parity harness needed.

Exit: all six verbs are shims; full existing suite green on both engines.

### Phase 2: fast tier

1. New Pester tag `Fast` (or separate `tests/fast/` files) calling `_lib` functions directly, following the existing `Lib.Tests.ps1` pattern.
2. Port the pure-logic assertions out of the process-based tests: frontmatter parsing, schema validation, task selection, dependency/tier/harness eligibility, lint findings and ordering, path scope checks, status formatting.
3. One command runs it: `Invoke-Pester -Tag Fast`. Target: single-digit seconds.

Exit: fast tier exists, measured, documented in `tests/README` or RUNNER notes.

### Phase 3: template fixture

1. Build the fixture repo once per run (run-level `BeforeAll`), then `Copy-Item` the prepared directory per test instead of `git init` + commit each time.
2. Expected: 0.83 s -> ~0.15 s per test. Applies to contract and process tiers.

Exit: fixture creation no longer dominates any tier.

### Phase 4: contract tier via runspaces

1. Add a harness helper that executes a verb in a fresh in-process runspace: inject location, run the shim or function, capture streams and exit code.
2. Migrate the state-transition tests (claim, promote, verify attempts, done pass/fail, review cycling) to this harness.
3. Keep a thin process tier: ~10-15 tests asserting the child-process contract (exit codes, stdout bytes, arg parsing) through the real `powershell.exe` path.

Exit: dev loop = fast + contract tiers, measured under 30 s.

### Phase 5: sh-arm decision

Evidence: the sh engine has only ever executed through Git-for-Windows `sh.exe` on Windows (`tests/MusterFixture.ps1:96`). Real-POSIX parity is asserted, not demonstrated.

1. Immediately: demote the sh arm out of the local dev loop. CI-only.
2. Decision for review: delete the sh mirror entirely (1,364 lines) and adopt PowerShell-canonical, with thin `pwsh` launchers reintroduced only when a real POSIX user exists.

Exit: dual-engine tax removed from the dev loop now; deletion decided explicitly, not by default.

### Phase 6: CI parallelism

1. CI runs test files in parallel jobs (9 files today; wall clock ~= slowest file).
2. Keep the full serial run as a nightly or pre-release gate if desired.

Exit: CI wall-clock measured and documented.

## Adopted from the C# proposal (language-independent wins)

These are good ideas in that proposal that do not require C#. Implement in PowerShell during or after Phase 1:

- Every mutating Git call is exit-code checked; no `2>$null` hiding failures.
- A checkout lock covering all mutating commands (exclusive lock file under `.git/`).
- `tasks/.muster-version` with runtime and schema version, plus a doctor/upgrade story.

## Relationship to the C# proposal

This plan is the cheaper experiment and the prerequisite gate:

- If this plan hits its target, the C# proposal's main motivations (test speed, single implementation) are satisfied at near-zero risk, and the rewrite is deferred until its remaining benefits (typed domain, self-contained distribution, shared code with a future ASP.NET viewer) become real requirements.
- If Phase 1-4 fail to hit the target, or maintenance pain persists, the C# proposal revives with better evidence, and its Phase 1 gate should then include a `done`/review-cycling slice, not only `status`/`lint`, because that is where the rewrite risk lives (`runtime/bin/_lib.ps1`, done/review region; decisions D12, D17, D20, D25, D28-D30).

The C# proposal's own review question 1 ("is zero-additional-runtime POSIX support demonstrated or speculative?") is answered by this repo today: speculative. `tests/MusterFixture.ps1:96` shows the sh engine has never run on a POSIX kernel.

## Acceptance criteria

1. Dev loop (fast + contract) under 30 seconds on the current machine.
2. Full existing behavior preserved: the pre-refactor suite passes unchanged against the post-refactor shims (Phase 1 parity gate).
3. No new runtime, toolchain, or distribution requirement for users.
4. Process-level contract (exit codes, stdout, refusal text) still asserted by real child-process tests.
5. Every phase independently shippable; stopping after any phase leaves the repo consistent.

## Risks

- `exit`-to-result refactor touches every verb's control flow. Mitigated by the Phase 1 parity gate (existing suite unchanged).
- Runspace state bleed between tests (loaded functions, globals). Mitigated by one fresh runspace per test; process tier remains the backstop.
- In-process tests can mask child-process-only bugs (encoding, `$LASTEXITCODE`, CRLF). That is exactly what the retained process tier and CI full run cover.
- ngen gains are box-specific and reversible; they help the residual process tier but nothing depends on them.

## Questions for review

1. Any reason the 30-second dev-loop target is insufficient, such that only a compiled runtime would do?
2. Is keeping the sh mirror as CI-only acceptable short-term, or should deletion (Phase 5.2) be decided now?
3. Are the retained process-tier tests (~10-15) enough to protect the child-process contract?
4. Should the checkout lock and Git exit-code hardening land in Phase 1 (same refactor) or as a separate follow-up plan?
5. What measured outcome here would justify reviving the C# proposal anyway?
