# Plan review — muster bench recorder

Plan: `docs/superpowers/plans/2026-08-16-muster-bench-recorder.md`
Reviewer: `plan-reviewer` subagent (opus, fresh context), 2026-08-16.
Summary: 2 blockers, 4 warnings, 2 suggestions. **All 8 ACCEPTED and applied inline.**

## Blockers

### [B1] claim tier deadlock — ACCEPT (applied)
Finding: `NextEligible` matches tier by exact equality (store/claim.go:18, asserted
by claim_test.go:34). Impl cards are `tier: any`; `claimArgs()` hard-pinned `-tier
strong`, so a strong session claims only the integration — which is not eligible
until impl deps complete — so the first claim returns "nothing to claim" and the
loop fails. Verified: the reviewer read store/claim.go, which I had not.
Fix applied: `claimArgs(tier string)`; `runClaimLoop` starts on `-tier any`,
escalates to `-tier strong` once "any" is drained. Unit test updated to assert the
tier is threaded, not pinned. (Task 12.)

### [B2] degenerate batch at N=BatchMax+1 — ACCEPT (applied)
Finding: `remaining=1` after a full batch → `implN=0` → empty `depends_on` block →
`card.Parse` rejects ("use [] for an empty list", card.go:146). `TestWorkloadLintsClean`
lints BatchMax+1, so the boundary test fails. Real N=10/100/1000 unaffected.
Fix applied: `Generate` now computes `nb = ceil(n/BatchMax)` and even-splits n
across batches, so no batch is ever degenerate (each ≥1 impl + 1 integration).
Golden N=10 manifest unchanged (still one batch, identical ids/bytes). (Task 2.)

## Warnings

### [W1] `show` needs an id — ACCEPT (applied)
Finding: `Show` refuses without exactly one id (board.go:101); bare `show` cold-verb
rows would all be errors, uncaught (no cold-verb smoke).
Fix applied: `RunColdVerb(exe, fx, verb, extra ...string)`; `BuildBoard` returns a
deterministic `showTarget` (lowest impl id); Task 15b passes it for `show`. (Tasks 12, 15b.)

### [W2] fingerprint drops Tier-1 fields — ACCEPT (applied)
Finding: spec §5 Tier-1 requires `ram_total_bytes`, `git_version`, physical cores,
`defender_exclusions_cover_benchdir`, and `box_tag = <short-cpu>-<hostname>`; the
struct/probe omitted them.
Fix applied: added `GitVersion` (direct `git --version` exec), `PhysicalCores`,
`RAMTotalBytes`, and a `defender_exclusions` probe to `psScript`; `boxTag` now
composes short-cpu + hostname after the probe fills CPUModel; `parseProbe` handles
the new keys; imports updated (`os/exec`, `strconv`). (Tasks 7, 8.)

### [W3] only max-N workload archived — ACCEPT (applied)
Finding: `Persist` archived `Generate(1, maxN(nSet))` once, but each N has a distinct
workload (integration dep-lists differ) and each row references its own manifest —
so N=10/100 bytes were never archived (the reconstruction hole §4.3 warns against).
Fix applied: `Persist` archives one immutable content-addressed dir per distinct N
and stamps each row with its matching `artifact_sha`; removed `maxN`. (Task 15.)

## Suggestions

### [S1] sha/shaBytes duplication + shadowed local — ACCEPT (applied)
Fix applied: dropped the duplicate `shaBytes` from record.go; `Persist` reuses the
package-level `sha` helper (workload.go); removed the shadowing local. (Task 15.)

### [S2] duplicate `strings` import note — ACCEPT (applied)
Fix applied: reworded Task 4's note to say merge into the existing import, not add a
second import statement. (Task 4.)

## Reviewer notes carried forward
- The reviewer confirmed no task commits non-compiling code (Task 12/13 placeholder→
  replacement handoffs resolve before their commits), and that Row/ExeInfo/Fingerprint/
  ArchiveSpec usage is consistent across record.go ↔ suite.go ↔ archive.go.
- No security-tagged findings.
