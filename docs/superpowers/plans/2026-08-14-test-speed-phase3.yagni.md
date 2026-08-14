# YAGNI audit — 2026-08-14-test-speed-phase3

Auditor: `yagni-guardian` subagent (opus, fresh context). Read the plan (full), the design spec, `runtime/bin/_lib.ps1` (function map), the three verb scripts, and `tests/fast/InProcHarness.ps1`.

**Tier:** NONE — 0 findings. **Y4 status:** scored (spec resolved; scope check performed).

No verdicts required — nothing flagged. Recorded for completeness.

Why each signal came back clean (auditor evidence):

- **Y1 (speculative abstraction):** the `CommandResult`/`Invoke-CommandBoundary`/`New-CommandResult` abstraction already exists (`_lib.ps1:34,39`) with two established consumers (`Invoke-StatusCommand`/`Invoke-LintCommand`, `_lib.ps1:750,756`). The three new `Invoke-XCommand` functions join a proven ≥2-consumer pattern.
- **Y2 (single-caller wrapper):** each new function is called from one shim but has a dedicated direct-target fast test file, and is itself the production verb body — carve-out applies.
- **Y3 (dead config flag):** `-Verdict`/`-Harness`/`-Tier` mirror existing verb params; `-Probe`/`-SurprisesOverride` are pre-existing `Complete-Task` args. No new knob.
- **Y4 (feature outside spec):** Tasks 0–4 map 1:1 to spec Decision 1 Steps 0–4; out-of-scope items (promote, Phase 4 matrix, shared-helper restructure) explicitly excluded in both spec and plan.
- **Y5 (premature optimization):** the in-process tier IS the measured objective; Decision 6 mandates a re-measure.
- **Y6 (duplicate utility):** new functions delegate to existing helpers; no duplication.
- **Y7 (defensive code for impossible states):** the one `$LASTEXITCODE` guard is carried verbatim from `verify.ps1:33-34` at a git-subprocess trust boundary; the only guard the plan touches (`done.ps1:51`) is being deleted, not added.
