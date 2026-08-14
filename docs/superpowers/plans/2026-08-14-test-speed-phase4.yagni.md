# YAGNI sidecar: 2026-08-14-test-speed-phase4.md

Auditor: yagni-guardian subagent (opus), 2026-08-14.
Density tier: SOFT (3 findings). Y4 and Y5 scored clean - every optimization
traces to the spec's measured-budget table, every task to a spec decision.

## Verdicts

- Y3 (Measure-DevLoop `-ColdRuns`/`-WarmRuns` dead knobs) ACCEPT. No plan
  invocation passes them and the gate statistic is defined as worst-of-5-warm;
  a flipped knob would silently invalidate it. Cut applied: script-scope
  constants with the Measure-Baseline "no dead knobs" comment; `-Command`
  kept (Task 12 flips it).
- Y6 (fixture benchmark duplicates FixtureStrategies/Measure-Fixture) ACCEPT
  via the finding's own justified-duplicate route: `Assert-FixtureContract`
  holds two fixtures live simultaneously to prove independent mutation - a
  single shared reset-reuse dir fails that shape by construction, so the
  sequential contract cannot reuse the framework. Cut applied: header
  justification in `Measure-Phase4Fixture.ps1` naming exactly that, matching
  the `Measure-Fixture.ps1` precedent.
- Y6 (3rd/4th copy of the percentile helper) ACCEPT. Cut applied: new
  `tests/bench/BenchCommon.ps1` with `Get-Percentile`; both new bench scripts
  dot-source it. The two existing copies stay (out of Phase 4 scope).

Tally: 3 findings - 3 ACCEPT, 0 DISMISS, 0 DEFER. Dropped-by-auditor items
(single-caller `Remove-SharedMusterFixture`, guarded stopwatches, `-Workers`
knob) reviewed and agreed - no action.
