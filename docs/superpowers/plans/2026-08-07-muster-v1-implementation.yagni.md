# YAGNI audit sidecar: 2026-08-07-muster-v1-implementation

Auditor: yagni-guardian subagent (opus, fresh context), 2026-08-07.

**Tier:** NONE. **Findings:** 0. **Y4 (scope vs spec):** scored - plan checked against
docs/superpowers/specs/2026-08-07-muster-v1.md.

No verdicts required. Signals cleared by the auditor:

- Y1 speculative abstraction: `_lib.ps1` has five verb-script consumers (Authority
  deviation 1); the ps1/sh engine switch has two real implementations.
- Y2 single-caller wrappers: lib helpers fall under the stated architecture (logic in
  lib, verbs thin); fixture helpers are test-infrastructure carve-out.
- Y3 dead config flags: `-NoCommit`, `-Lite`, `-Staged`, `-Probe`, `-Attempts`,
  `MUSTER_ENGINE` each have a named caller in-plan; `-Harness codex` is spec 8.2 and
  a documented prior dismissal (spec yagni sidecar).
- Y4 feature outside spec: init's CLAUDE.md/AGENTS.md pointer lines and sync-root
  warning traced to architecture.md:95 (settled design); sh mirror is spec 4.0; eval
  harness is test infrastructure for a prose artifact unit tests cannot reach.
- Y5 premature optimization: none found.
- Y6 duplicate utility: repo is greenfield - no repo-side target exists.
- Y7 impossible-state defense: the guards present protect against model-authored
  input and git failures (robustness carve-out, plan-reviewer provenance).
