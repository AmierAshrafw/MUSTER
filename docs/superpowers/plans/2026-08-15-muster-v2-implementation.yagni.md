# YAGNI sidecar: 2026-08-15-muster-v2-implementation.md

**Mode deviation (owner-directed):** surface pass only - the opus
`yagni-guardian` subagent was NOT dispatched (owner instructed no subagent
runs). Signals scored by the main thread against the plan text and the spec's
"Deferred, explicitly" section (spec section 10).

## Signal scores

- **Y1 speculative abstraction:** the `gitx.Git` interface + `Fake` is the one
  deliberate seam. Justified, not speculative: the spec's test strategy
  (section 8, ~90% unit tier with zero git) is impossible without it. The
  store has NO repository-pattern indirection beyond the package boundary the
  spec's D-v2-1 asks for. CLEAR.
- **Y2 single-caller wrapper:** checked every `App` helper - `backupDB` (4
  callers), `headCard` (2), `runBlock` (3), `failCommitAndFile` (2),
  `writeResult` (4), `occupant` (2), `changedSinceClaim` (2). Two dead store
  APIs (`Path()`, `AddDep`) were found and cut during authoring. CLEAR.
- **Y3 dead config flag:** none. Hook policy is deliberately knob-less
  (Authority note 2); the only flags are `-harness`/`-tier` (spec CLI),
  `-reason` (spec: reason required on fail), `-sync-ok` (replaces v1 init's
  interactive confirm - CLI is non-interactive). CLEAR.
- **Y4 feature outside spec:** none found. No `close` verb (Authority note 5),
  no dashboard, no `adopt`, no multi-board flags - matching spec section 10.
  `show`/`board`/`redo`/`fail`/`reimport`/`doctor` are all in the spec's CLI
  table. CLEAR.
- **Y5 premature optimization:** none. The one-connection pool is a
  correctness device (transaction pinning), not an optimization. CLEAR.
- **Y6 duplicate utility:** `tokenizeForLint` (card) duplicates
  `verify.SplitCmdLine` (~20 lines). Deliberate: importing verify from card
  would invert the dependency layering for a tokenizer both sides must agree
  on; v1 carried the same duplication across its ps1/sh engines. ACCEPT AS-IS
  with this justification recorded (plan Task 10 comment says the same).
- **Y7 defensive code for impossible states:** one branch - ingest re-parses
  cards after a clean lint and refuses on parse errors ("unreachable after a
  clean lint; belt and braces", Task 12). Kept: it guards a real TOCTOU (file
  changed between lint and read), not an impossible state. CLEAR.

## Findings

- [Y6-1] `tokenizeForLint` duplication - ACCEPT AS-IS (layering justification
  above; cutting it would couple card -> verify).

## Density tier: NONE

1 finding, 0 cuts required. The plan tracks the spec's scope tightly; the two
dead APIs that would have been findings were already removed in self-review.
