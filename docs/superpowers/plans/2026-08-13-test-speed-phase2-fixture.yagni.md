# YAGNI audit sidecar: 2026-08-13-test-speed-phase2-fixture.md

Auditor: yagni-guardian subagent (opus, fresh context). Tier: SOFT — 2 findings. Y4 scored against docs/test-speed-consolidation-plan.md (rev 2, Phase 2). Both findings ACCEPTED and applied.

## Verdicts

- **[Y6] Get-Percentile duplicated from Measure-Baseline.ps1:23-29** — ACCEPT (lighter cut of the two offered). Extracting a shared `_bench.ps1` for 7 lines would itself be premature structure and would touch a committed measurement script; the finding's alternative — state the intentional duplicate in the header — applied instead. `Measure-Fixture.ps1` now carries a comment explaining why dot-sourcing `Measure-Baseline.ps1` is impossible (it runs its whole benchmark on load).
- **[Y7] unreachable `$initRows.Count -eq 0` guard** — ACCEPT. Auditor is right: after the W5 restructure, the timing loop appends rows unconditionally for every strategy (contract failures are captured, not thrown), and any other throw aborts the script under `$ErrorActionPreference='Stop'` before the guard line. Guard removed; a comment records why the empty case cannot occur; the W1 `try/finally` template cleanup (reachable) stays.

## Auditor notes retained

Auditor explicitly cleared: the four-strategy table (spec-named), `Assert-FixtureContract` scriptblock params (four concrete impls exist), the permanent Harness contract test (test-infra carve-out), fixed benchmark constants (matches the "no dead knobs" precedent), template caching (gated by the pre-fixed 0.7x rule), and all reviewer-driven additions (B1/W4/W5).
