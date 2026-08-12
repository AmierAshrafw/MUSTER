# Commit-paths overlap lint (D32) - design

## Problem

Two `impl`/`fix` tasks may name the same source path in `commit_paths` with no
dependency edge between them, and nothing detects it.

`Test-LintChecks` (`runtime/bin/_lib.ps1:414-573`) validates each task in
isolation. `commit_paths` is read only per-task: check 5 (verify paths must be
listed, `:467-499`) and check 13 (non-empty, `:529-531`). The only batch-level
checks are 11 (one integration task, `:548-562`) and 12 (review wiring,
`:563-570`). No check compares `commit_paths` across tasks.

Execution is strictly serial (D18), so there is no git race. But a second
same-file task's Steps are frozen at shard time against a view of the file that
predates the first task's committed edits. If those Steps are non-additive
(whole-file or same-region rewrite) the second task silently overwrites the
first's work at HEAD. It is caught only if some later verify or the terminal
integration suite happens to re-cover the clobbered code. Additive-append
same-file tasks work fine - MUSTER's own `_lib.ps1` was built by ~10 such tasks
(`docs/superpowers/plans/2026-08-07-muster-v1-implementation.md`, repeated
`Modify: runtime/bin/_lib.ps1 (append)` blocks).

A lint cannot parse Steps to tell an additive append from a destructive rewrite.
A shared `commit_path` is therefore a risk signal, not a proven defect. The fix
converts that silent risk into a shard-time refusal the author must consciously
resolve.

## Decision

Add a batch-level shard-lint check that FAILs when two `impl`/`fix` tasks share a
`commit_path` with no ordering between them. The author resolves it by adding a
`depends_on` edge (which serial execution imposes anyway) or resharding.

Rejected alternatives (from the 2026-08-12 solution-auditor pass):

- **Done-time clobber detection** (check at a later stage). Rejected: opposes D22
  ("reject the shard output, not the executor's mess"), fires only after a burned
  executor session, and clobber attribution across commits is fuzzy. The gap it
  would cover - fix tasks - is safe by construction (see Accepted limit). Parked
  as KIV.
- **FAIL-unless-`overlap_ack:` marker.** Rejected: adds schema surface for an
  unbacked self-attestation (same epistemic hole as a weak `assert True`, cf.
  D30). The false positive it dodges is already harmless under D18.
- **New WARN severity tier.** Rejected: breaks the binary `LINT FAIL`/`LINT OK`
  grammar (`runtime/bin/lint.ps1:9-14`) that callers parse, for weaker
  enforcement.
- **FAIL only when the shared path is not also `protected`.** Rejected as unsafe:
  `protected` does not make a write additive, and D30 dual-lists self-authored
  tests in both `protected` and `commit_paths`, so this predicate would wave
  through exactly the clobber shape it aims to catch.

## Mechanism

Runs in the batch phase only (`-not $Lite`), after per-task validation, beside
checks 11/12.

1. Collect every batch task that parsed clean and carries `commit_paths` (only
   `impl`/`fix` do - schema forbids `commit_paths` on other types,
   `_lib.ps1:160-162`). Record its id, `commit_paths`, and `depends_on`.
2. Build reachability over the batch `depends_on` edges. Task X reaches task Y if
   Y is in X's transitive `depends_on` closure within the batch. Two tasks are
   *ordered* if either reaches the other.
   - Transitive, not direct: the standard D19 pattern is `A -> review-A -> B`, so
     B depends on A only through the review. A direct-edge test would false-
     positive on every reviewed same-file chain.
3. For each unordered pair (A, B) whose `commit_paths` overlap, emit one finding.
   - *Overlap* is prefix-aware, reusing the pattern at `_lib.ps1:477`:
     `p == q`, or `p` under `q.TrimEnd('/') + '/'`, or `q` under
     `p.TrimEnd('/') + '/'`. So `src/` overlaps `src/foo.cs`.
   - One finding per offending pair, keyed by the pair so the symmetric case is
     not reported twice. Attribute it to the lexicographically-lower id and name
     the other id plus the overlapping path. Deterministic ordering.

## Message

```
<lower-id>.md: commit_path '<path>' also written by '<other-id>' with no depends_on ordering between them - add a dependency edge or reshard.
```

## Insertion points (both engines - parity is mandatory, D6)

- `runtime/bin/_lib.ps1` batch block, `:548-571`. Reachability via a hashtable +
  closure walk; `commit_paths`/`depends_on` already parsed into `$t.Fields`.
- `runtime/bin/_lib.sh` batch block, `:669-716`. Reads via `fm_list <fp>
  commit_paths` and `fm_list <fp> depends_on`; reachability walked over the
  existing `_lint_clean` tempfile. POSIX sh, no bashisms.

Both must produce byte-identical finding text so the shared test harness passes
on either engine.

## Accepted limit (documented, intentional)

The check is batch/full-mode only. Reviewer-authored `fix` tasks are linted solo
via lint-lite (`_lib.ps1:922`, single staged file, no batch), so they are out of
this check's scope. This is acceptable: a fix task is authored by the reviewer
against the impl's real committed diff, not a stale plan view, so it is the one
same-file case without the stale-Steps risk. If fix-task overlap is ever observed
in practice, revisit the parked done-time detection alternative.

## Tests

`tests/Lint.Tests.ps1`, exercised on both engines by the existing harness:

1. Two `impl` sharing `src/foo` with no edge -> FAIL, message names both ids and
   the path.
2. Same pair with a direct `depends_on` edge -> OK.
3. Same pair ordered transitively through a review task (`A -> review-A -> B`) ->
   OK (guards the D19 false-positive).
4. Prefix overlap: A `commit_paths: [src/]`, B `commit_paths: [src/foo.cs]`, no
   edge -> FAIL.
5. Disjoint paths, no edge -> OK (no spurious finding).
6. A clean full batch (impl + review + integration) still lints OK (regression:
   the new check must not fire on the existing good-batch fixture).

## Decision-ledger entry

Add `D32` to `docs/decisions.md`: the gap, the batch-lint FAIL choice, the four
rejected alternatives above (done-time parked as KIV, ack-marker and WARN and
protected-gated rejected), and the lint-lite boundary. Source: analysis session
2026-08-12 plus the solution-auditor pass.

## Not yet specified

Way is fully clear. No in-scope item is too blurry to plan.

## Out of scope

- Done-time / executor-stage clobber detection (auditor #2). Parked as KIV in
  D32; only revisited if fix-task overlap is seen in practice.
- The action-verb / idempotency lint (original "Fix B"). Cut earlier for YAGNI;
  the claim recovery probe already neutralizes its main case.
- Any change to lint severity grammar (no WARN tier).
- Any `depends_on` auto-insertion by the lint. The lint reports; the shard author
  edits. Auto-editing shard output is a separate concern.
