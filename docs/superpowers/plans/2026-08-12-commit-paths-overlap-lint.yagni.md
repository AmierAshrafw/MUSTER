# YAGNI audit sidecar - commit-paths overlap lint (D32)

Auditor: yagni-guardian (opus), 2026-08-12. Plan:
`2026-08-12-commit-paths-overlap-lint.md`.

Density tier: **NONE**. Findings: 0. Verdict counts: nothing to accept/dismiss/defer.

## Result

No YAGNI violations. All seven signals scored clean:

- Y1 speculative abstraction: `Test-Reaches` / `lint_ordered` transitivity is a
  genuine requirement, not gold-plating. Confirmed against D19 wiring
  (`templates/review-task.md:6-8`, `docs/decisions.md:133`): a downstream task
  reaches its sibling only through the review id, so a direct-edge test would
  false-positive on every reviewed same-file chain.
- Y2 single-caller wrapper: `Test-Reaches` has two call sites (both directions);
  `lint_ordered` wraps a non-trivial awk closure and is the mandated parity
  mirror. Neither is a pass-through.
- Y3 dead config flag: none.
- Y4 feature outside spec: none - the plan tracks the spec 1:1.
- Y5 premature optimization: the awk fixpoint closure is an algorithm forced by
  awk's lack of recursion, not a perf mechanism; the plan comment disclaims
  optimizing ("batches are tiny").
- Y6 duplicate utility: check 15 reuses `Test-PathListed` / `path_listed`; no
  existing transitive helper to duplicate.
- Y7 defensive code for impossible states: the `ContainsKey('commit_paths')` guard
  protects a genuinely reachable degenerate state (parse-clean but schema-invalid
  impl/fix), because `$_.Errors.Count -eq 0` gates parse errors only, not schema
  errors.

Scope was trimmed once in brainstorming (action-verb check cut; three enforcement
alternatives rejected) and nothing crept back.
