# Test Speed Phase 3 — Stateful Vertical Slice (design)

**Status:** design approved 2026-08-14, ready for writing-plans.
**Spec section:** `docs/test-speed-consolidation-plan.md` → "Phase 3: stateful vertical slice".
**Builds on:** Phase 1 (`docs/superpowers/plans/2026-08-13-test-speed-phase0-phase1.md`, `docs/runtime-consolidation/phase1-comparison-2026-08-13.md`) and Phase 2 (`docs/superpowers/plans/2026-08-13-test-speed-phase2-fixture.execution.md`).

## Goal

Convert the stateful `claim` / `verify` / `done` verbs into `Invoke-XCommand` command functions in `runtime/bin/_lib.ps1`, each returning a `CommandResult` (Output lines + ExitCode), tested in fresh Windows PowerShell 5.1 runspaces — the same in-process pattern Phase 1 proved on the read-only verbs `status` / `lint`. The unchanged black-box suite (`tests/Claim.Tests.ps1` 17, `tests/Done.Tests.ps1` 22, `tests/Verify.Tests.ps1` 7) stays the parity backstop, run on both engines (ps1 + sh).

**Exit condition (spec):** the risky region proven in-process, not just the easy read-only verbs — refined below to account for a hard runspace constraint.

This design was pressure-tested by an independent adversarial reviewer that ran real runspace experiments. Two of its findings (B1, B2 below) corrected load-bearing assumptions in the first draft and are baked into the decisions here.

## Background — the runspace divergence, corrected

Phase 1 documented a divergence between the in-process runspace tier and the `powershell.exe -File` child tier: under the library's `$ErrorActionPreference = 'Stop'`, a native command's stderr becomes a terminating `NativeCommandError` inside a hosted runspace, where a `-File` child does not terminate.

The first draft assumed this bites **only when a git command exits nonzero** (corrupted-state refusals), so happy/target-edge paths — whose git commands succeed — were assumed safe. **This is false.** The reviewer proved:

- The termination fires on **any native stderr write, including on success**.
- `2> $null` does **not** prevent it under `Stop` (corroborated by the existing `_lib.ps1:337` comment, which avoids the redirect for exactly this reason).
- Decisive case: an `eol=lf` fixture (which `muster:init` ships) plus a CRLF-written `commit_path` (the normal Windows executor case) drives `Complete-Task` and **throws** at `_lib.ps1:957` — `git add --renormalize -- $c 2> $null` emits "CRLF will be replaced by LF" to stderr, exits 0, and terminates anyway. This is the path `tests/Done.Tests.ps1:134` exercises; that test passes only because it sets `core.safecrlf false`.

Corrected rule: **a path round-trips in-process iff it writes no native stderr on the taken path** — not "iff its commands succeed."

The reviewer also confirmed (experiments CASE1/2/4) that on the **default** test fixture — no `eol=lf` pin, LF-only content written via `Write-Utf8` — the done-pass path (incl. `Complete-Task` + `Invoke-Promote -NoCommit`), the review-cycling fail path (incl. `Invoke-DoneFailReview`), and `Move-TaskToFailed` all round-trip cleanly, with no stderr and no throw. The bulk of the risky region is therefore provable in-process; the exceptions are the carve-outs below.

## In-process vs process-tier: coverage map

The spec's target edges and where each is proven. D-numbers reference the accumulated edge cases named in the code.

| Edge | What it is | Tier | Reason |
|---|---|---|---|
| D12 (claim-probe) | recovery probe auto-files a re-dispatched green task | in-process | probe git ops succeed silently; verify runs via isolated `System.Diagnostics.Process` |
| D12 (status-before-refusal) | claim prints the status block before any refusal | in-process | via the accumulate-and-return model (B1 fix) |
| D17 | script-only frontmatter edits (`Set-ClaimedAt`, `Add-DependsOn`) | in-process | file writes, no native stderr |
| D20 (happy) | claim-time task copy read from the HEAD blob | in-process | `git show HEAD:…` succeeds on a committed task |
| D20 (corrupted-state refusal) | `Read-CommittedTask` on an **uncommitted** task | **process-tier** | `git show` fails **with stderr** → runspace throws |
| D25 | tier pinning (strong/any) selection | in-process | pure selection logic, no git |
| D28 | attempt burns as a marker commit before the run | in-process | marker commit succeeds silently |
| D29 | judgment-fail filed on a red done-check | in-process | red verify runs via `System.Diagnostics.Process`, stderr as data |
| D30 | self-authored grader / untracked protected path | in-process | `git diff` on a valid claim commit succeeds |
| CRLF/eol=lf completion | `Complete-Task` renormalizes a CRLF commit_path under an `eol=lf` pin | **process-tier** | `git add --renormalize` warns to stderr on success → runspace throws (`Done.Tests.ps1:134`) |
| promote warnings | `Invoke-Promote` skips an invalid backlog task | **process-tier** | warnings are `Write-Host` (Information stream), not captured by `$ps.Invoke()` |

The three process-tier carve-outs keep their existing black-box tests unchanged (Phase-1 precedent for `Get-RepoRoot`). No shared git helper is restructured to force them in-process — that would touch code the black-box suite guards and risk the "control flow worse" stop condition.

**Refined exit condition:** the risky region — successful completion, verification failure, review cycling, and all non-native-stderr refusals — proven in-process; the three native-stderr carve-outs (corrupted-state failing-git refusals, the `eol=lf` + CRLF completion, promote's `Write-Host` warnings) remain process-tier by the documented divergence. This satisfies the spec's intent (the risky region proven in-process, not just the read-only verbs) while stating honestly what the runspace tier structurally cannot hold.

## Decision 1 — cadence: spike → done → claim → verify

Verb-by-verb, each behind its own parity gate, stop-clean after any verb.

1. **Step 0 — divergence spike (throwaway).** Before any production code, run in a fresh runspace and record in `docs/runtime-consolidation/phase3-spike-2026-08-14.md`:
   - a default-fixture `done` **success** completion (expect: round-trips);
   - a default-fixture `done` **review-cycling fail** (expect: round-trips);
   - an `eol=lf` + CRLF-`commit_path` `done` completion (expect: **throws** — documents carve-out (b));
   - a `Read-CommittedTask` corrupted-state refusal (expect: **throws** — documents carve-out (a)).

   This maps the real boundary. The first draft's spike omitted the stderr-on-success case and would have passed with false confidence.

   **Gate:** if a **success or non-native-stderr** path of a target edge unexpectedly trips the divergence → **halt and report** (feeds the deferred C# decision, spec "Relationship to the C# proposal"). The two throwing cases above are **expected** carve-outs, not halt triggers.

2. **Step 1 — `done` (riskiest first).** Extract `Invoke-DoneCommand`; convert the self-exiting fail branches `Invoke-DoneFailReview` / `Invoke-DoneFailIntegration` (`_lib.ps1:1022,1094`) from `Write-Output …; exit` to **returning** a `CommandResult`. Add `tests/fast/Done.Fast.Tests.ps1`. Gate: `Done.Tests.ps1` green on both engines. Verdict: simpler / equal / worse.

3. **Step 2 — `claim` (most entangled).** Extract `Invoke-ClaimCommand` using the accumulate-and-return model (Decision 3). Add `tests/fast/Claim.Fast.Tests.ps1`. Gate: `Claim.Tests.ps1` green both engines. Verdict.

4. **Step 3 — `verify` (simplest last).** Extract `Invoke-VerifyCommand` (exit 0/2/3 → `-ExitCode`). Add `tests/fast/Verify.Fast.Tests.ps1`. Gate: `Verify.Tests.ps1` green both engines. Verdict.

5. **Step 4 — record.** Phase 3 exit note + per-verb verdicts in `docs/test-speed-consolidation-plan.md`; the re-measure (Decision 7) in the comparison doc.

`done` first because it is the region the spec exists to prove (review cycling + fail branches = "where the rewrite risk lives") and CASE1/2 already show it round-trips on the default fixture — so the go/no-go signal lands on commit 1. `promote` stays out of scope: `Invoke-Promote` is already a function, exercised transitively (claim self-heal, `Complete-Task` fold), and its only observable extra is `Write-Host` warnings that cannot round-trip in-process anyway.

## Decision 2 — extraction pattern (Phase 1 mirror)

For `done` and `verify`: the verb body moves into `Invoke-XCommand` in `_lib.ps1` returning `New-CommandResult`; the script becomes the shim

```powershell
$r = Invoke-CommandBoundary { Invoke-XCommand <args> }
$r.Output | Write-Output
exit $r.ExitCode
```

Refusals already throw (`Write-Refuse`, Phase 1) and are caught by `Invoke-CommandBoundary` → refusal `CommandResult`. Multi-exit maps straight to `-ExitCode`. These two verbs emit **nothing** to stdout before any refusal, so the throw-and-rebuild boundary loses nothing for them.

### done fail-branch conversion (Warning 4)

`Invoke-DoneFailReview` / `Invoke-DoneFailIntegration` currently `Write-Output …; exit 0|3` on every path. They convert to **return** `New-CommandResult -Output @(…) -ExitCode 0|3` (cycle → 0, cap/integration → 3). `Invoke-DoneCommand` **returns** the branch's result directly. The `exit 3   # unreachable` guard at `done.ps1:51` is **deleted**, not mirrored — a naive fall-through to `-ExitCode 3` would return 3 for a review-cycle that must be 0 (`Done.Tests.ps1:200,230`).

## Decision 3 — claim's accumulate-and-return model (Blocker 1)

`claim` prints the status block (`claim.ps1:18`, D12) **before** every subsequent refusal, and the auto-file path prints "Auto-filed …" before looping. The throw-based boundary is structurally incompatible with this: `Invoke-CommandBoundary` rebuilds the result from **only** the exception message, discarding anything accumulated before the throw. Using the bare boundary would break the **retained black-box gate** itself (`Claim.Tests.ps1:12,17,144` assert board line + refusal together), not merely the fast tier.

`Invoke-ClaimCommand` therefore:

- may `Write-Refuse` (throw) only for the **pre-status** identity-flag refusal (`claim.ps1:8`), where nothing is accumulated;
- for every refusal **after** the status print, accumulates output into a list and `return New-CommandResult -Output ($acc + "MUSTER refuse: …") -ExitCode 1`;
- appends to the list and `continue`s on the auto-file case; returns the full list with `-ExitCode 0` on the terminal claim.

The shim still wraps the call in `Invoke-CommandBoundary` to catch the early throw and genuine (non-refusal) errors. This is a **documented, claim-specific deviation** from Phase 1's "uniform two-line boundary"; the plan states it explicitly.

## Decision 4 — in-process test tier

- **Fresh runspace per test** via the existing `tests/fast/InProcHarness.ps1` `Invoke-MusterInProc` (takes a fixture + a command-expression string, e.g. `Invoke-DoneCommand -Verdict fail`; already supports args). Clean session state, no bleed. `Set-Location` into the fixture makes `Get-RepoRoot` (`git rev-parse`, no `-C`) resolve to the fixture, confirmed no bleed to the outer repo.
- **Fixtures** via the existing `New-MusterFixture` template-copy + `New-TaskFile`, exactly as `Status.Fast` / `Lint.Fast`. Review-cycling state is built by hand: impl committed in `done/`, review task in `doing/` with `reviews:` frontmatter, staged fix in `staging/` with `fixes:`.
- Because these verbs **mutate**, each fast test asserts on **both** the `CommandResult` (Output, ExitCode) **and** the resulting board state (files moved, generation stamped, `depends_on` appended) — read via `Test-Path` / `git log` / file content, same as the black-box tests.
- **Harness caveat (kept, not fixed):** `Invoke-MusterInProc` returns `$out[-1]`, silently discarding any leading pipeline pollution. So the fast tier cannot catch stray- or double-output regressions; that detection stays with the black-box tier. Not worth changing the harness for.

## Decision 5 — parity backstop and stop conditions

- The full black-box suite runs green on **both** engines after every verb commit. No black-box test is edited; no `.sh` file is touched.
- **Halt and report** (feeds the C# decision) on either: (a) the spike shows a success / non-native-stderr target-edge path tripping the divergence; (b) any verb's extraction verdict is "worse."

## Decision 6 — re-measure the stateful verbs (Nit)

Phase 1's ~4.6x speedup was measured on `status` / `lint` (1–2 git calls each). `claim` / `done` are git-subprocess-bound (a probing claim runs promote + status + mv + commit + probe + `Complete-Task` = 10+ git children), so the in-process win will be smaller, and Phase 3 is **net-slower** in isolation (it adds fast tests while keeping the full black-box suite on both engines; the payoff is Phase 4's migration). Add an in-process-vs-child re-measure for `claim` / `done` to the comparison doc — the Phase 5 C# decision feeds on this delta.

## Out of scope

`promote` extraction; the Phase 4 contract matrix; the byte-contract decision (spec open question 2); NGen / machine tuning; any edit to `runtime/bin/*.sh`; anything C#.

## Risks

- **Boundary-model deviation for claim** (Decision 3) is the subtlest change; mitigated by keeping the black-box gate green at each commit and by asserting the accumulated status block explicitly in the fast tests.
- **Divergence carve-outs** could be under-mapped; mitigated by the expanded Step-0 spike measuring the real boundary before any production code.
- **Fail-branch exit-code regressions** in `done`; mitigated by `Done.Tests.ps1:200,230` in the gate.
- **Runspace state bleed** between tests; mitigated by a fresh runspace per test.
