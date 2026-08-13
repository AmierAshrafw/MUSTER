# YAGNI audit sidecar: 2026-08-13-test-speed-phase0-phase1

Auditor: yagni-guardian subagent (opus, fresh context).
Density tier: SOFT (1 finding).

## Findings

- Y3 (dead config flags) - `Measure-Baseline.ps1` declared five parameters; only `-SkipSuite` is ever flipped in plan or spec. **ACCEPT.** `-MicroRuns`, `-SuiteRuns`, `-Engines`, `-OutFile` hard-coded as script locals; `-SkipSuite` kept.

## Checked and cleared by the auditor (not re-litigated)

- `New-CommandResult` / `Invoke-CommandBoundary` / `Exit-OnRefusal`: >=2 consumers each, directly tested - not Y1/Y2.
- Throw-based refusal + six-script wrap: spec-mandated single control-flow model - not Y4.
- Baseline/percentile discipline: Codex-mandated, backed by measured figures - not Y5.
- `Invoke-MusterInProc` alongside `Invoke-Muster`, fast tests mirroring process tests: the duplication IS the parity gate - not Y6.
- Harness empty-output throw, percentile clamp, `MUSTER_ENGINE` clearing: test-infrastructure carve-out / real leak path - not Y7.
