# Plan Review — 2026-08-17-muster-reconcile.md

Reviewer: `plan-reviewer` subagent (opus, fresh context). Verdicts by the writing-plans main thread. Findings: **1 blocker, 2 warnings, 3 suggestions — all 6 ACCEPTED and applied.**

## Blockers

### [B1] Process test missing `//go:build process` tag + run commands lack `-tags process`
**Verdict: ACCEPT.** Verified: every file in `test/process/` carries `//go:build process` ([main_test.go:1](../../../test/process/main_test.go), [v1fixture.go:1](../../../test/process/v1fixture.go)); the convention is `go test -tags process ./test/process` (README.md:181, docs/INSTALL.md:28). Without the tag, `go test ./...` in Step 4 would compile the lone untagged file against tagged-only helpers → build failure.
**Applied:** Task 7 Step 1 now emits `//go:build process`; Step 2 runs `go test -tags process ./test/process/ -run TestReconcileProcess`; Step 4 splits into `go test ./...` (unit) + `go test -tags process ./test/process` (process tier, excluded from `./...`).

## Warnings

### [W1] Process test ingest path must be git-canonicalized absolute, not relative
**Verdict: ACCEPT.** Verified against [main_test.go:156-164](../../../test/process/main_test.go): the house harness builds ingest args as `filepath.Join(gitRoot, filepath.FromSlash(rel))` because the real binary's path guard ([ingest.go:41-44](../../../internal/cli/ingest.go)) rejects paths that don't canonicalize under `<gitroot>/.muster/cards/`.
**Applied:** Task 7 rewritten to use the real harness (`newRepo`, `mustMuster`, `muster`, `write`, `run`, `implCardP2`, `integrationCardP2`) and canonicalized ingest paths. Invented helpers (`env.run`, `writeCard`, `implCardBody`) removed.

### [W2] Missing per-predicate eligibility refusal tests (spec §6 matrix)
**Verdict: ACCEPT.** For a fail-closed destructive prune, each refusal predicate must be independently proven or a mis-wired `IndexHas`/`SemanticRefs` ships green. Plan originally tested only history-present, claimed/doing, and non-pristine.
**Applied:** Added `TestReconcileRefusesReferencedRow` (Task 3 — inbound-dep + `reviews`/`fixes` refusal, in-tx) and `TestReconcileRefusesWorktreePresent` + `TestReconcileRefusesIndexPresent` (Task 5 — git-predicate refusals). Added `os`/`path/filepath` imports to the cli test file.

## Suggestions

### [S1] Tombstone detail format diverges from spec §3.3
**Verdict: ACCEPT.** Content equivalent, format differs. Aligned the **spec** to the plan's `;`-delimited, `reason`-suffixed format (more deterministic/parseable than the spec's `|`-prefixed draft). Spec §3.3 updated.

### [S2] Dry-run nil-`info` deref panic on concurrent prune
**Verdict: ACCEPT.** `ReconcileEligibility` returns nil info when the row is absent; a cross-process prune between the `Task()` read and `ReconcileEligibility()` would nil-deref `info.OutgoingDeps`. Not impossible (store.go documents cross-process concurrency via SQLite locking), so the guard is justified, not Y7.
**Applied:** Task 5 CLI code adds `if info == nil { … HasTombstone → already-reconciled / else refuse }` before use.

### [S3] Spec §6 stale "Backup-failure path" test bullet
**Verdict: ACCEPT.** §3.3 removed the backup refresh from reconcile, so the §6 backup-failure test can't exist. Struck the bullet from the spec.

## Confirmed correct (no finding)
Reviewer verified against source: `scanTask`/`taskCols`/`appendEventOn`/`execer`-accepts-`*sql.Tx`, `Task`/`Deps`/`Events`/`AppendEvent`/`flip`, test helpers `open`/`mustExec`/`row`/`newApp`/`seed`, arg-then-flag parse for `reconcile <id> --execute --reason`, and the FK/event-chain ordering (append tombstone → delete deps → delete task) under `foreign_keys=1` with append-only event triggers. `HasTombstone` is created fresh (no dependency on the unmerged `HasEvent`).
