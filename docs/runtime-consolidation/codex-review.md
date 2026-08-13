# Codex Review: Test Speed and Runtime Consolidation Plan

**Date:** 2026-08-13  
**Reviewer:** Codex  
**Reviewed proposal:** [`test-speed-consolidation-plan.md`](test-speed-consolidation-plan.md)  
**Related proposal:** [`../csharp-runtime-consolidation-proposal.md`](../csharp-runtime-consolidation-proposal.md)

## Decision

Approve a revised Phase 0 and a limited PowerShell prototype. Do not yet approve the entire plan as a replacement for the C# proposal.

The central diagnosis is correct: the command-level test harness spends substantial time starting child PowerShell processes, and test speed can be improved independently of a language rewrite. However, the under-30-second target and the proposed fixture-copy optimization are not yet supported by measurements. The plan also does not solve duplicated-engine maintenance unless the shell implementation is eventually retired.

## What the repository and measurements confirm

- The current suite contains 123 `It` blocks and 110 static `Invoke-Muster` call sites.
- There are 82 command-level tests across the verb test files. The remaining tests are library or fixture tests.
- [`../../tests/MusterFixture.ps1`](../../tests/MusterFixture.ps1) starts `powershell.exe` for every PowerShell verb invocation.
- Five local `powershell.exe -NoProfile` measurements averaged 1.755 seconds on this machine.
- Fresh Windows PowerShell 5.1 runspaces took about 17-20 ms after warm-up.
- Fresh runspaces that dot-sourced `_lib.ps1` and executed a library operation generally took about 35-60 ms after warm-up.
- Historical integration results report 794 seconds for the PowerShell suite and 973 seconds for the shell suite in [`../../tasks/archive/overlap-lint/overlap-lint-99-integration.verify.log`](../../tasks/archive/overlap-lint/overlap-lint-99-integration.verify.log).

These results justify an in-process PowerShell prototype.

## Required corrections

### 1. Do not prescribe template copying before benchmarking it

Three warm local samples produced:

| Operation | Observed time |
|---|---:|
| Existing `New-MusterFixture` | 0.50-0.56 s |
| Recursive copy of a prepared fixture | 0.30-0.65 s |

Copying was not consistently faster and did not reach the proposed 0.15 seconds. Phase 3 should benchmark at least the existing initialization, recursive copy, local clone, and a safe worktree or equivalent strategy. The fastest correct option should be selected from evidence.

A copied repository must also be checked for hidden `.git` content, clean status, independent mutation, cleanup reliability, and compatibility with the proposed checkout lock.

### 2. Replace "zero spawns" with "zero verb-script child processes"

`Lib.Tests.ps1` does not invoke the PowerShell verb scripts, but it still starts Git commands, verification executables, and a timeout PowerShell process. Git and verification subprocess costs remain after the command functions move in-process.

Consequently, "the runtime logic executes in milliseconds" should be narrowed to pure parsing and selection logic. Stateful command paths still perform filesystem work and multiple Git subprocesses.

### 3. The current harness does not preserve stdout bytes

`Invoke-Muster` captures PowerShell pipeline objects, stringifies them, and rejoins them with `\n`. It cannot verify original encoding, CRLF/LF bytes, separate stdout and stderr, or all stream-ordering behavior.

If byte-level output is a real contract, the retained process tier needs a new `System.Diagnostics.Process` harness that captures stdout and stderr without PowerShell pipeline normalization. Otherwise, change the acceptance criterion from a byte contract to the actual normalized-line contract.

### 4. Make `exit` shim-only

The refactor is wider than the six verb bodies. `exit` currently exists in shared helpers, including `Write-Refuse`, `Get-RepoRoot`, and the review/integration failure paths in `_lib.ps1`.

Use this boundary:

- Command functions return one structured `CommandResult` containing output, error/refusal information, and exit code.
- Shared helpers return values or throw a consistently identified refusal/error caught at the command boundary.
- Only the six small executable shims write output and call `exit`.

Avoid keeping two behavioral modes in `Write-Refuse` if possible. A single control-flow model will be easier to reason about and test.

### 5. Correct the Pester parallelism statement

This machine currently has Pester 6.0.1. Pester 6 has experimental native file-level parallel execution, but it requires PowerShell 7 and falls back to sequential execution under Windows PowerShell 5.1.

The relevant constraint is therefore:

- In-process compatibility tests must run under Windows PowerShell 5.1.
- A process-only suite that explicitly launches `powershell.exe` may potentially be orchestrated from PowerShell 7.
- File-level jobs remain a valid option for a Windows PowerShell 5.1-hosted suite.

Reference: [Pester parallel execution documentation](https://pester.dev/docs/usage/parallel).

### 6. Make NGen an optional experiment

The 1.755-second startup time is real, but the proposal has not demonstrated that missing native images or Defender are the cause. NGen is administrator-level, machine-global tuning whose benefit varies by workload and must be measured.

Do not make it a Phase 0 prerequisite or a repository acceptance condition. Record the baseline first, optionally test NGen separately, and record before/after results.

Reference: [Microsoft NGen documentation](https://learn.microsoft.com/en-us/dotnet/framework/tools/ngen-exe-native-image-generator).

### 7. Treat 30 seconds as a decision gate, not a forecast

The target is appropriate, but it has not yet been demonstrated. The suite has roughly 100 fixture-backed tests, while Git and verification subprocesses remain. Record cold and warm p50/p95 timings rather than one best run.

Suggested gates:

- Fast plus contract tier: p95 at or below 30 seconds on the current Windows PowerShell 5.1 machine.
- Results must be stable across at least five runs.
- The full PowerShell black-box suite remains green during migration.
- No behavior test is removed merely to meet the timing target.

### 8. Separate the shell support decision from test-speed work

Moving the shell suite out of the local loop is reasonable. Deleting the shell implementation changes the product's documented platform contract and needs a separate architecture decision.

Current testing through Git-for-Windows `sh.exe` proves there is a POSIX coverage gap; it does not prove that POSIX support has no users. Before deletion, either:

- add genuine Linux/macOS CI and keep the shell implementation, or
- explicitly change the support policy to PowerShell-canonical and document the new POSIX runtime requirement.

While the shell mirror remains, its complete black-box command suite must remain in CI. It cannot gain coverage from direct PowerShell function tests.

### 9. Do not select an arbitrary process-test count

The proposed 10-15 retained process tests may be enough, but the number should follow a contract matrix. At minimum, cover:

- success and refusal/nonzero behavior for every verb;
- argument binding for `claim`, `done`, `lint`, and `promote`;
- output ordering and terminal session lines;
- stdout/stderr and encoding behavior if those are contractual;
- execution from the installed `tasks/bin` layout;
- at least one Git failure propagation scenario.

This is likely closer to 20 tests, but coverage—not the count—should decide it.

## Recommended amended sequence

### Phase 0: baseline only

1. Record current test count and per-file cold/warm p50 and p95 timings.
2. Measure PowerShell startup, fixture setup, Git commands, and representative verb calls separately.
3. Do not change NGen or machine configuration until the baseline is saved.

### Phase 1: two-verb prototype

1. Extract `Invoke-StatusCommand` and `Invoke-LintCommand` returning `CommandResult`.
2. Add a Windows PowerShell 5.1 runspace harness.
3. Keep all existing process tests for these verbs unchanged.
4. Compare behavior and timings before extracting the other verbs.

### Phase 2: fixture experiment

1. Benchmark competing fixture strategies.
2. Validate Git independence, cleanup, and lock compatibility.
3. Adopt a new fixture strategy only if it provides a repeatable material gain.

### Phase 3: stateful vertical slice

1. Convert a complete `claim -> verify -> done` path.
2. Include refusal, successful completion, verification failure, and review cycling.
3. Keep the existing black-box suite as the parity backstop.

### Phase 4: tier classification

1. Classify tests by what boundary they actually protect.
2. Build the process-tier contract matrix.
3. Migrate eligible behavior tests to direct function or runspace execution.
4. Measure the p95 development loop against the 30-second gate.

### Phase 5: separate architecture decisions

1. Decide shell support in a dedicated ADR.
2. Implement checkout locking and Git error hardening in a separate change after the structural refactor is stable.
3. Reconsider C# using the measured outcome and remaining product requirements.

## When to revive the C# proposal

Test speed alone no longer justifies C# if the revised PowerShell prototype meets the 30-second p95 gate. Revive the C# proposal if one or more of these remains true:

- the measured PowerShell development loop cannot meet the gate without materially reducing coverage;
- structured command-result extraction makes the PowerShell control flow more complex or fragile;
- maintaining two handwritten engines remains a demonstrated recurring cost and shell support cannot be retired;
- self-contained cross-platform distribution becomes a real requirement;
- sharing domain code with an ASP.NET viewer becomes an approved near-term requirement;
- process control, cancellation, locking, or Git failure recovery cannot be implemented reliably in the PowerShell design.

## Final recommendation

Proceed with the cheaper experiment, but narrow approval to the baseline and two-verb prototype. The proposal convincingly separates test speed from the language decision. It does not yet demonstrate the 30-second outcome or resolve runtime duplication, so it should not replace the C# proposal until the prototype produces repeatable measurements and the shell support decision is made explicitly.
