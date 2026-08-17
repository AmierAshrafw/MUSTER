# YAGNI Audit — 2026-08-17-muster-reconcile.md

Auditor: `yagni-guardian` subagent (opus, fresh context).

**Density tier: NONE. Findings: 0.**

Every scrutiny target resolved to spec-mandated, justified scope. No verdicts required (nothing to ACCEPT/DISMISS/DEFER).

## Why each scrutiny target cleared (auditor's reasoning, verified)

- **`IndexHas` + `PathHistory` (Y1):** both consumed by `reconcileGitFails`, covering distinct git states — `IndexHas` catches a staged-but-uncommitted card (no history), `PathHistory` catches a once-committed card. The plan actually *collapses* the spec's separate HEAD-tree check into `PathHistory` — a simplification, not expansion.
- **`ReconcileEligibility` vs in-tx re-validation (Y6/Y7):** spec §3.3/§3.4 mandate re-checking inside the execute transaction. Dry-run and `--execute` are two separate CLI invocations → a real TOCTOU window. Matches the house pattern (every tx method in `tasks.go` inlines its own `tx.QueryRow`).
- **`--reason` flag (Y3):** wired through to the durable tombstone event; user data that alters the audit record, not a dead knob.
- **Tombstone `detail` fields (Y4):** exact set specified in spec §3.3; the tombstone event *is* the audit trail (design decision #4).
- **Idempotent-retry path (Y7):** re-running `--execute` on an already-pruned id is reachable (crash-after-commit per §3.5, or a plain re-run), not impossible.
- **`SemanticRefs`/`InboundDeps`/pristine-history (Y7/Y2):** fail-closed integrity gates on a destructive `DELETE`, each guarding a reachable state, each with a direct unit test (not single-caller wrappers).

**Deferral audit (Y4):** all seven spec §4 non-goals — `cancel`/`cancelled`, hard `rm`, cascade, `flush --plan`, tombstones table, git gravestone, backup refresh on reconcile — are absent from the plan. No smuggled scope. Near 1:1 spec→task mapping.
