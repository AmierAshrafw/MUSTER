# Plan review sidecar: 2026-08-13-test-speed-phase0-phase1

Reviewer: plan-reviewer subagent (opus, fresh context, live probes on Windows PowerShell 5.1).
Verdicts applied by main thread with evidence.

## Blockers

- B1 - lint fast test "LINT OK 1 file(s)" unsatisfiable: lint check 11 requires exactly one integration task per non-Lite batch; reviewer reproduced `LINT FAIL batch: expected exactly 1 integration task, found 0` against a real fixture. **ACCEPT.** Test rewritten to mirror the 3-file `New-GoodBatch` (asserts `LINT OK 3 file(s)`); Task 5 timing loop now lints the same 3-file batch.

## Warnings

- W1 - in-proc runspace turns failing-native-command stderr into a terminating error under `$ErrorActionPreference='Stop'`, so `Get-RepoRoot`-style refusals cannot round-trip in-proc (reviewer measured; `powershell.exe -File` child diverges). **ACCEPT.** Documented in the harness header comment, Task 5 comparison file, and the fog section (route such cases to the process tier; Phase 3/4 decision).
- W2 - "~35-60 ms" per-call claim unrealistic; reviewer measured 146 ms average per fresh-runspace status call. **ACCEPT.** Figures removed from architecture paragraph and harness comment; Task 5 expectation now ~0.15 s with a >=5x-vs-child sanity bar.
- W3 - `Measure-Baseline.ps1` overwrites its output file, destroying any appended Phase 1 comparison on rerun. **ACCEPT.** Comparison moved to its own file `docs/runtime-consolidation/phase1-comparison-2026-08-13.md`; overwrite warning added to script header.
- W4 - leaked `MUSTER_ENGINE=sh` would silently mislabel the micro benchmark rows. **ACCEPT.** Script clears the variable at start and stamps the engine into the doc header.
- W5 - full-suite expectations said 123; `-Path tests` recurses into `tests/fast/`, and the fast tests are engine-agnostic. **ACCEPT.** Expectations corrected to 129 (Task 2) and 136 (Task 4) on BOTH engine arms, with explanation.

## Suggestions

- S1 - inline catch duplicated the boundary's refusal mapping in five places. **ACCEPT.** New `_lib.ps1` helper `Exit-OnRefusal`; every script wrapper is now `catch { Exit-OnRefusal $_ }`.
- S2 - drop status.ps1/lint.ps1 from the Task 2 wrap since Tasks 3-4 rewrite them. **DISMISS.** Evidence: no test covers lint's no-paths refusal (`grep` of tests/Lint.Tests.ps1 - zero refusal tests), so the breakage would be silent, but `lint.ps1:7` is a live refusal path and status refuses via `Get-RepoRoot` outside a repo; leaving them unwrapped puts those refusals on stderr with the wrong stdout for two commits. Two mechanical edits are cheaper than a known-broken intermediate state.
- S3 - `_lib.ps1:1004,1042,1057` citations go stale the moment Task 2 inserts lines. **ACCEPT.** Cited by function name (`Invoke-DoneFailReview` / `Invoke-DoneFailIntegration`) in notes, checklist, and fog section.
- S4 - status returned one multi-line blob while lint returned per-line entries. **ACCEPT.** `Invoke-StatusCommand` now splits on LF; shim output unchanged.
- S5 - `Streams.Error` guard near-dead under Stop preference; `$out[$out.Count-1]` indexes [-1] on empty output. **ACCEPT.** Guard replaced with explicit empty-output throw naming the command string.
- S6 - "roughly an hour" understated the full baseline; archived logs say 794 s + 973 s per single pass. **ACCEPT.** Now says 1.5-2 hours in script header and Task 1 Step 3.

## Reviewer verification notes

Reviewer live-probed: boundary catch vs `exit`/`continue`/nested-throw semantics (preserved), runspace `Set-Location` + git cwd resolution (works), the plan's six CommandCore tests verbatim (pass), both command functions end-to-end in-proc (source of B1/W2), Pester resolution under `-ExecutionPolicy Bypass` (6.0.1 loads, 3.4.0 not picked). External callers of status/lint (`skills/auto/SKILL.md:38`, `skills/shard/SKILL.md:64`) go through the preserved child-process contract.
