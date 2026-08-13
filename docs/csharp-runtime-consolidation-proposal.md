# C# Runtime Consolidation Proposal

**Status:** proposal for review  
**Scope:** replace the duplicated PowerShell and POSIX shell runtime implementations with one C# CLI  
**Decision requested:** whether to prototype and, if successful, migrate MUSTER's runtime to C#

## Summary

MUSTER currently implements its runtime twice: once in Windows PowerShell 5.1 and once in POSIX shell. The two shared libraries alone contain roughly 1,050 lines of PowerShell and 1,364 lines of shell, with two versions of every command and a custom task-frontmatter parser in each language.

Maintaining byte-identical behavior across the engines is expensive. It increases implementation time, test duration, review surface, and the probability of semantic drift. Recent work on commit-path overlap linting required separate graph algorithms in PowerShell and awk plus parity-specific fixes and tests.

This proposal recommends replacing both implementations with one C# command-line application while preserving MUSTER's file-backed, Git-backed architecture. PowerShell and shell files may remain temporarily as very small launchers, but they would contain no board or verification logic.

The proposed migration is incremental. Read-only `status` and `lint` commands would be implemented first and compared against the current engines using golden fixtures. State-changing commands would migrate only after observable parity is demonstrated.

## Problem

The current runtime consists of:

- `runtime/bin/_lib.ps1`: approximately 1,050 lines.
- `runtime/bin/_lib.sh`: approximately 1,364 lines.
- PowerShell and shell versions of `claim`, `verify`, `done`, `promote`, `lint`, and `status`.
- Two custom parsers for the constrained YAML frontmatter format.
- Engine-specific process execution, quoting, path handling, Git integration, and temporary-file behavior.

The contract suite is shared, which is good, but shared tests do not remove the cost of implementing and reviewing every change twice. A recent archived integration run reports 121 passing tests per engine, with an engine run taking roughly 10–16 minutes. The full dual-engine gate is therefore useful but heavy for rapid iteration.

The duplication also creates portability work unrelated to MUSTER's core problem. Examples include:

- PowerShell array-return and pipeline-enumeration behavior.
- POSIX subshell and pipeline state behavior.
- Windows versus POSIX quoting and executable launching.
- PowerShell versus awk graph traversal.
- Culture-aware versus ordinal sorting.
- Maintaining byte-identical diagnostic messages.

## Goals

1. Establish one canonical implementation of all runtime behavior.
2. Preserve the existing file-based board and Git history model.
3. Preserve deterministic output, exit codes, task transitions, and recovery behavior.
4. Support Windows first and retain a credible cross-platform distribution path.
5. Reduce local test time and make most behavior testable without spawning a new shell process.
6. Improve Git error handling, process timeouts, and claim locking during the migration.
7. Create a versioned runtime that installed repositories can diagnose and upgrade.

## Non-goals

- Do not introduce a server, database, daemon, or network dependency.
- Do not move task state outside the target Git repository.
- Do not redesign the task schema during the initial runtime migration.
- Do not adopt LibGit2Sharp initially; the Git executable remains the source of repository semantics.
- Do not rewrite every command before testing the approach on read-only commands.
- Do not add parallel task execution as part of this migration.

## Proposed architecture

Create one C# CLI with command-oriented entry points:

```text
muster claim --harness claude --tier any
muster verify
muster done
muster done --verdict pass
muster done --verdict fail
muster promote
muster lint tasks/backlog/<plan>-*.md
muster status
```

Suggested source layout:

```text
src/
  Muster.Cli/
    Program.cs
    Commands/
      ClaimCommand.cs
      VerifyCommand.cs
      DoneCommand.cs
      PromoteCommand.cs
      LintCommand.cs
      StatusCommand.cs
    Domain/
      TaskCard.cs
      BoardState.cs
      VerificationEntry.cs
      CommandResult.cs
    Infrastructure/
      GitClient.cs
      ProcessRunner.cs
      BoardLock.cs
      FileSystem.cs
    TaskFormat/
      TaskParser.cs
      TaskValidator.cs
tests/
  Muster.UnitTests/
  Muster.IntegrationTests/
  Muster.GoldenTests/
```

Responsibilities should remain explicit:

- Commands coordinate one user-visible operation.
- Domain types represent task cards, board state, results, and verification entries.
- `GitClient` is the only component allowed to invoke mutating Git commands.
- `ProcessRunner` owns direct execution, output capture, timeouts, and process-tree termination.
- `BoardLock` prevents simultaneous state transitions in one checkout.
- `TaskParser` and `TaskValidator` preserve the current constrained task format.

The CLI should produce stable plain-text output for humans and wrappers. An optional machine-readable output mode can be considered later, but is not needed for the migration.

## Why C#

MUSTER is a stateful CLI dominated by filesystem, Git, subprocess, timeout, validation, and locking behavior. C# provides strong standard-library support for those concerns:

- Typed domain models and command results.
- Cross-platform path and filesystem APIs.
- `ProcessStartInfo.ArgumentList` for structured process arguments.
- Asynchronous stdout and stderr capture.
- Cancellation, timeouts, and process-tree termination.
- Exclusive file handles for a real checkout lock.
- Fast in-process unit and integration tests.
- Framework-dependent and self-contained deployment options.

C# also aligns with the planned ASP.NET control-plane viewer. A future viewer could reuse task models, parsing, validation, and board-status calculation while remaining read-side only. This is a secondary benefit, not a reason to put an application in the agent critical path.

## Why not Python

Python would likely yield a smaller initial implementation and would be reasonable for a source-only personal tool. Python 3.12 is installed on the current development machine.

The drawbacks are primarily deployment-related:

- Python is not guaranteed on Windows target machines.
- A source deployment requires managing interpreter and dependency versions.
- A packaged deployment introduces PyInstaller or an equivalent toolchain.
- Cross-platform file locking and descendant-process termination require additional care or dependencies.
- It offers no direct code-sharing path with the planned ASP.NET viewer.

Python remains a credible fallback if minimal source size is valued more highly than distribution and long-term integration. It is not the recommended option for the current architecture.

## Why not PowerShell-only

A single PowerShell implementation with small `pwsh` launchers on POSIX would be the lowest-risk consolidation. It would immediately remove the shell mirror and retain Windows PowerShell 5.1 compatibility.

That option remains viable and is less expensive than a C# rewrite. However, it keeps several limitations:

- More difficult process-tree and cancellation handling.
- More awkward typed state and structured command results.
- Slower tests when behavior is exercised through scripts and process exits.
- PowerShell 7 becomes an external POSIX requirement anyway.
- No shared implementation path with the planned ASP.NET viewer.

PowerShell-only should be the fallback if the C# prototype does not demonstrate a clear reduction in complexity.

## Deployment model

Two deployment modes are possible.

### Development and controlled-machine mode

Use a framework-dependent artifact:

```text
tasks/bin/Muster.dll
```

Invoke it with:

```text
dotnet tasks/bin/Muster.dll status
```

The current development machine has .NET SDK 5, 6, 8, and 10 installed, including the matching runtimes. Framework-dependent deployment is therefore the simplest way to prototype and dogfood the CLI locally.

### Public distribution mode

Publish self-contained executables for explicitly supported runtime identifiers:

```text
runtime/
  win-x64/muster.exe
  linux-x64/muster
  linux-arm64/muster
  osx-arm64/muster
```

`muster:init` selects and copies the correct executable into the target repository. Users then need Git but do not need Visual Studio, the .NET SDK, or a separately installed runtime.

Self-contained distribution increases plugin size and requires a release build matrix, checksums, and per-platform testing. It should follow, not precede, a successful framework-dependent prototype.

## Git integration

Continue invoking the installed Git executable. Avoid LibGit2Sharp during the migration so repository behavior remains aligned with the current implementation and users' Git configuration.

All Git calls should pass through one component and return a structured result:

```csharp
public sealed record ProcessResult(
    int ExitCode,
    string StandardOutput,
    string StandardError)
{
    public bool Succeeded => ExitCode == 0;
}
```

Every mutating Git operation must check its result before the command proceeds. This includes `git mv`, `git add`, and every transition commit. Native command failures must never be hidden by stderr redirection or ignored exit codes.

The migration is an opportunity to make the documented Git-atomic behavior closer to reality:

- Acquire a checkout lock before inspecting or changing board state.
- Validate preconditions while holding the lock.
- Check each filesystem and Git operation.
- On failure, report the exact failed operation and preserved recovery state.
- Release the lock on every exit path.

## Checkout locking

The current one-executor rule is documented but vulnerable to two claim processes observing an empty `doing/` concurrently. The C# runtime should use an exclusive lock file, preferably under the repository's Git directory so it does not appear as working-tree dirt.

Conceptually:

```csharp
using var boardLock = BoardLock.Acquire(gitDirectory);
```

The lock should cover every mutating command:

- `claim`
- `promote`
- `verify` attempt recording and terminal filing
- `done`
- review cycling
- plan close
- runtime upgrade

This does not introduce parallel execution. It prevents accidental concurrent writers from corrupting the checkout.

## Task format

The first C# implementation should preserve the current constrained YAML subset. Changing the runtime and schema simultaneously would make parity failures difficult to diagnose.

Implement the existing parser behavior once and lock it with the current parser/schema fixtures. After migration, consider adopting a maintained YAML parser or a versioned format.

A later schema could replace command strings with structured execution:

```yaml
verify:
  - executable: dotnet
    args:
      - test
      - tests/Example.Tests.csproj
    expect_exit: 0
```

Structured arguments would remove cross-platform quoting ambiguity and make path and network policy validation more accurate. This is explicitly deferred until after runtime parity.

## Testing strategy

The migration should compare observable behavior, not implementation shape.

### Unit tests

Run in-process without creating child shells:

- Frontmatter parsing and schema validation.
- Task selection and tier/harness eligibility.
- Dependency satisfaction and graph reachability.
- Path scope and protected-path checks.
- Lint findings and deterministic ordering.
- Result-sidecar construction.
- Status and board-line formatting.

### Git integration tests

Use isolated temporary Git repositories:

- Claim commit and task move.
- Verification attempt markers.
- Third-attempt terminal failure.
- Completion commit contents.
- Promotion behavior.
- Review rejection and fix-generation cycling.
- Crash recovery probe.
- Lock contention.
- Git failure handling.

### Golden parity tests

During migration, run the same fixture through the existing PowerShell implementation and the C# implementation. Compare:

- Exit code.
- Standard output and refusal text.
- Board file locations.
- Result and verification sidecars.
- Git commit subjects and touched paths.
- Final working-tree cleanliness.

Byte-identical output is useful during migration, but should not prevent deliberate improvements. Any intentional difference must be documented and approved as a protocol change.

### Test tiers

Provide three commands:

- Fast: unit tests and pure golden transformations.
- Contract: critical temporary-repository transitions.
- Full: all integration and cross-platform tests.

The normal development loop should run the fast tier. The full suite belongs in CI and release/integration verification.

## Runtime versioning and upgrades

The C# migration must not reproduce the current installed-runtime drift problem. Each initialized repository should contain a machine-readable version file, for example:

```text
tasks/.muster-version
```

With content such as:

```text
runtime_version: 1
schema_version: 1
```

Add two orchestrator commands or skills:

- `muster:doctor`: report installed/runtime version, platform compatibility, board health, and runtime drift.
- `muster:upgrade`: upgrade the installed runtime only when the board is in a safe state, commit the upgrade explicitly, and run a post-upgrade smoke check.

Upgrade design must cover:

- An idle board versus a live plan.
- Runtime-only changes versus task-schema migrations.
- Rollback or recovery when copying or committing fails.
- Compatibility between old cards and a new runtime.
- Checksums or version metadata for installed binaries.

## Incremental migration plan

### Phase 0: freeze and capture behavior

1. Avoid adding new runtime features during the initial prototype.
2. Capture existing command fixtures and exact expected board/Git outcomes.
3. Add missing fixtures for Git failures, claim races, and malformed states.

### Phase 1: read-only prototype

1. Create the C# solution.
2. Implement task parsing and validation.
3. Implement `status`.
4. Implement `lint`.
5. Compare both commands against the current PowerShell engine.
6. Measure implementation size, test time, startup time, and diagnostic quality.

This phase is the decision gate. Stop if C# does not materially reduce complexity.

### Phase 2: low-risk state changes

1. Implement `promote` with locking and checked Git operations.
2. Implement `claim` and tier/harness selection.
3. Add claim-race and Git-failure integration tests.

### Phase 3: verification and completion

1. Implement the process runner and transcript format.
2. Implement attempt-marker commits and terminal failure.
3. Implement `done`, protected/scope checks, sidecars, and completion commits.
4. Implement review failure, fix generations, and integration failure.
5. Run the entire current contract suite as golden parity fixtures.

### Phase 4: dogfood and cutover

1. Install the C# runtime into a controlled fixture repository.
2. Execute a real multi-task plan through it.
3. Review Git history, failure recovery, and elapsed test/runtime cost.
4. Make C# the default engine after the integration task passes.
5. Retain the old runtime only for a defined rollback window.
6. Remove the duplicated implementations after the rollback window closes.

### Phase 5: distribution

1. Add self-contained release builds for supported platforms.
2. Add checksums and platform selection to init/upgrade.
3. Run the same golden and integration fixtures on every supported runtime identifier.
4. Document the exact platform support policy.

## Acceptance criteria

The C# migration is successful only if:

1. One implementation owns all board and verification behavior.
2. Existing valid task cards remain valid without modification.
3. All current contract scenarios pass or have explicitly approved protocol changes.
4. Every Git mutation is exit-code checked.
5. Concurrent mutating invocations fail safely through a checkout lock.
6. The fast development test tier is materially faster than the current full script suite.
7. Installed runtime and schema versions are detectable.
8. A safe runtime upgrade flow exists before public distribution.
9. No server, database, daemon, or network dependency enters the executor critical path.
10. At least one real plan completes through the new engine before cutover.

## Risks

### Rewrite risk

`done` and review cycling encode many edge cases. A clean-looking rewrite can easily omit recovery behavior accumulated through earlier failures. The incremental parity approach is intended to contain this risk.

### Distribution size

Self-contained .NET executables are larger than scripts. Framework-dependent deployment should be used during development, and self-contained size should be measured before choosing the public distribution matrix.

### Platform-specific behavior

One source implementation does not guarantee identical OS behavior. Filesystem case sensitivity, executable resolution, process termination, and line endings still require cross-platform tests.

### Binary transparency

Scripts are directly inspectable; binaries are not. Public releases should be reproducible where practical, include checksums, and retain source corresponding to each release.

### Premature coupling to the viewer

Shared C# libraries may benefit a future ASP.NET viewer, but the runtime must remain independently usable. The viewer must stay read-side and must never become required for claiming, verification, or completion.

## Alternatives

### A. PowerShell canonical, POSIX through `pwsh`

Lowest-risk consolidation. Delete the shell implementation and replace it with thin `pwsh` launchers. Choose this if the C# prototype does not show enough benefit to justify a rewrite.

### B. Python canonical

Likely the smallest source implementation and fastest initial rewrite. Choose this only if Python availability or Python binary packaging becomes an accepted deployment requirement.

### C. Generated PowerShell and shell

Not recommended for procedural runtime logic. It adds a generator while retaining platform-specific execution behavior. Generation may still be useful for static schema tables, error messages, or test fixtures.

### D. Continue dual handwritten engines

Preserves the current zero-additional-runtime promise but retains the cost this proposal is intended to remove. Choose only if both Windows PowerShell 5.1 and dependency-free POSIX shell are demonstrated, non-negotiable user requirements.

## Questions for review

1. Is the current zero-additional-runtime POSIX support a demonstrated requirement or a speculative one?
2. Does C# materially simplify the hardest code (`verify`, `done`, recovery, lint), or merely relocate it?
3. Is framework-dependent deployment acceptable for the current controlled environment?
4. What public platforms and architectures actually need self-contained binaries?
5. Should runtime upgrades be allowed while cards exist in backlog/inbox, or only when the entire board is empty?
6. Which current outputs are protocol and must remain byte-identical, versus merely human-facing wording?
7. Should the initial C# CLI retain the strict custom parser or adopt a YAML library immediately?
8. Is an exclusive file lock sufficient, or should state transitions use a Git-native locking/ref mechanism?
9. Which Git failure and crash points are missing from the current test fixtures?
10. What measurable thresholds should the Phase 1 prototype meet for code size, test speed, and maintainability before continuing?

## Proposed decision

Approve Phase 0 and Phase 1 only: capture current behavior, then implement `status` and `lint` in a framework-dependent C# CLI. Use their results to decide whether to proceed.

Do not approve a full rewrite yet. The prototype should demonstrate simpler code, faster tests, stable output, and a credible deployment path before any state-changing command is replaced.
