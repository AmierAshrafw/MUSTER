# MUSTER v2 — `reconcile`: single-task disposal for abandoned-ingest orphans

- **Date:** 2026-08-17
- **Status:** design — pending user review, then `writing-plans`
- **Scope:** one new verb, `muster reconcile <id>`, plus an ingest reuse-guard. No schema migration.
- **Inputs:** two rounds of independent review (Codex `gpt-5.6-sol`, high effort) + web research on disposal semantics. Summarised in the Appendix.

## 1. Problem

There is no way to remove a single task from the board. Dropping one dead/stale task currently requires deleting the whole `.muster/muster.db` and letting the CLI lazily recreate an empty board — a sledgehammer for one nail.

The concrete bite: `ingest` inserts task **rows** into the DB before the card **files** are committed to git (two-phase by design). An aborted or partial ingest therefore leaves an **orphan row**: a DB row with no backing committed card file. `doctor` already *detects* this ("`<id>` has no file on disk") but offers no *fix*. The owner hit this with a leftover `smoke-99-integration` row and had to nuke the database.

### 1.1 Two framings, and which one this spec addresses

- **A — Lifecycle cancel:** drop a *live, valid, committed* card that is no longer wanted (scope change). **Deferred.** Not observed in real use; `fail` already covers "give up, keep evidence." Building A now would cost a status migration, scheduler/query changes, dependency semantics, and card/redo handling — overbuild without demand.
- **B — Integrity prune:** remove an orphan row left by an abandoned ingest. **This spec.** This is not really "task disposal" — it is *rollback of an incomplete ingest*.

### 1.2 Why existing verbs don't solve B

| Verb | Why it fails on an orphan row |
|---|---|
| `fail` | Leaves a `failed` row cluttering the board; dead-blocks nothing useful; the row is still there. |
| `redo` | Re-queues it; the card still doesn't exist. |
| `reimport` | Requires the card file to exist on disk. |
| `doctor` | Detect-only; no mutation. |

## 2. Design decisions (converged)

1. **Build B only.** Defer A (`cancel`/`cancelled`), hard `rm`, cascade delete, and bulk `flush --plan`.
2. **Standalone verb `reconcile <id>`, not `doctor --fix`.** `doctor` stays a strictly read-only, whole-board diagnostic aggregator; folding a targeted destructive mutation into it muddies its exit/output semantics and invites scope creep. `doctor` instead *recommends* `muster reconcile <id>`.
3. **No git commit.** With no tracked file to remove, the prune is a single atomic SQLite transaction — either the row and its deps are gone or they aren't. This is consistent with existing DB-only board mutations that make no commit (`redo`, `promote`). A git "gravestone" would only help in disaster recovery (both DB *and* backup lost, then a pre-prune backup restored) — not transaction crash recovery — and is not justified unless "id retirement survives full DB loss" becomes an explicit requirement. It is not: losing `muster.db` loses the whole board regardless.
4. **Audit via the event chain, not a new table.** The `events` table is a global append-only hash chain (triggers block UPDATE/DELETE). A `tombstone` event carries the full metadata snapshot; the event chain *is* the audit trail. No `tombstones` table, no migration, no fingerprint change.
5. **Dry-run by default; `--execute` to act.** For a single explicit id, a dry-run/confirm/`--yes` trio is redundant. Default prints the exact plan; `--execute` performs it and re-validates the same predicates. (No time-based grace window — deterministic state/provenance checks are stronger.)

## 3. Behaviour

### 3.1 Command surface

```
muster reconcile <id>              # dry-run: print eligibility + what would be pruned
muster reconcile <id> --execute    # perform the prune (re-validates predicates first)
```

- Exactly one id. More or fewer → refuse.
- Unknown id → refuse (`no task '<id>' on the board`), unless it is an already-reconciled id (see 3.5 idempotency).

### 3.2 Eligibility predicate (all must hold; fail closed)

A row is a **safe abandoned-ingest orphan** only when every check passes. Any git lookup error is treated as *ineligible*, never as "absent."

**File absence — the card must not exist anywhere git could resurrect it:**
- absent from the **worktree** (`os.Stat` fails), and
- absent from the **git index** (a staged-but-uncommitted card still counts as present), and
- absent from the **HEAD tree** (`git show HEAD:<card_path>` errors), and
- **no reachable history** for `<card_path>` (`git log --oneline -- <card_path>` empty). This stops a card that was once committed and later deleted from being laundered as an abandoned ingest — that is a different situation and out of scope.

**DB state — positive allowlist, not a blocklist:**
- `status IN ('backlog','inbox')` (never `doing`, `done`, or `failed`), and
- all claim fields empty (`head_at_claim`, `claimed_at`, `claimed_by`), and
- event history is **exactly one `ingest` event (actor `shard`), followed only by zero or more `promote` events** — nothing else. Presence of any `claim`, `attempt`, `done`, `fail`, `redo`, `reimport`, `reject`, or unknown verb → ineligible. This proves the row never did any work.

**Reference integrity — nothing may point at it:**
- zero inbound `deps` (no row `depends_on` this id), and
- zero **semantic** references: no other row carries this id in its `reviews` or `fixes` column (a review/fix card targets its impl through those columns, not through `deps`).

If any predicate fails, the verb **refuses and lists the failed predicate(s)** — it does not silently skip. This is a targeted, explicitly-named repair; a non-artifact id is a user error worth reporting.

### 3.3 Action (on `--execute`, one SQLite transaction)

Re-validate the DB predicates inside the transaction, then:

1. Append a `tombstone` event (actor `human`), detail = a deterministic single-line snapshot:
   `reconcile: <reason?> | status=<old> plan=<plan> card=<card_path> sha=<frontmatter_sha> deps=<comma-list>`
   (snapshot is captured *before* deletion so it survives the row's disappearance).
2. `DELETE FROM deps WHERE task_id = <id>` (removes only the orphan's *outgoing* edges — inbound edges were proven absent by the predicate).
3. `DELETE FROM tasks WHERE id = <id>`.
4. Commit.

Events survive the task deletion because `events.task_id` has no foreign key; `deps` rows must be deleted first because they *do* (FK, `foreign_keys=1`).

After commit: refresh `backup.db` (best-effort — see 3.5).

An optional `--reason "<text>"` populates the snapshot's reason field. Absent → reason is empty.

### 3.4 Dry-run output

The default (no `--execute`) prints, without mutating:
- each eligibility predicate and pass/fail,
- if eligible: the exact rows that would be deleted (the task row summary, the N `deps` edges) and the tombstone event line that would be written,
- if ineligible: the failed predicate(s) and exit non-zero.

`--execute` re-runs the same evaluation transactionally; if a predicate that passed at dry-run now fails (concurrent change), it refuses without mutating.

### 3.5 Idempotency, retry, and backup

The prune itself is single-phase atomic. The only post-commit side effect is the `backup.db` refresh. Handle it so a crash between commit and backup is recoverable:

- **Crash before the SQLite commit:** nothing happened; rerun.
- **Crash after commit, before backup:** the DB is already correct (task absent, tombstone present). A rerun of `reconcile <id> --execute` detects *task absent + tombstone event present* → treats it as **already reconciled**, refreshes `backup.db`, prints success, exits 0.
- **Backup refresh fails:** print `prune committed; backup refresh failed: <err>` and exit 0 (or a distinct warn code) — **never** a message implying the prune rolled back.

### 3.6 ID-reuse guard (ingest)

After a prune, the task row is gone, so `ingest`'s existing duplicate check (`SELECT COUNT(*) FROM tasks WHERE id = ?`) would *not* catch a retired id. Re-ingesting it would interleave two unrelated histories under one `task_id` in the global event log.

Guard: `ingest` additionally refuses any candidate id for which `SELECT COUNT(*) FROM events WHERE task_id = ? AND verb = 'tombstone'` > 0, with a message naming the id as retired-by-reconcile. Batch ingest checks all candidate ids; add an index on `events(task_id, verb)` only if board size later demands it.

### 3.7 `doctor` integration

`doctor` stays read-only. Its existing orphan finding ("`<id>` has no board row / has no file on disk") gains a pointer: recommend `muster reconcile <id>` for the DB-row-without-file case. No behavioural change beyond the message.

## 4. Non-goals (explicitly deferred)

- `cancel` verb and a `cancelled` status (framing A).
- Hard `rm` of an arbitrary task (breaks audit + FK/deps; the anti-pattern real trackers gate behind admin).
- Cascade disposal of dependents.
- Bulk `flush --plan`.
- A `tombstones` table, retention windows, or a git gravestone/empty-commit anchor.

If A is later justified, it is a separate spec: a new terminal `cancelled` status (migration), reversible via `redo`, dependents left blocked (matching `fail`, no cascade), card kept as evidence (no `git rm`).

## 5. Affected code

| Area | Change |
|---|---|
| `internal/cli/app.go` | Dispatch: add `case "reconcile"`. |
| `internal/cli/reconcile.go` (new) | Verb: arg parse, `--execute`/`--reason` flags, predicate evaluation (git + DB), dry-run printer, idempotent-retry path. |
| `internal/store/tasks.go` (or new `store` method) | `Reconcile(id, reason, now)` — the one-transaction tombstone-event + delete-deps + delete-task; plus a helper to fetch the event history and semantic-reference counts for predicate checks. |
| `internal/store/events.go` | (Possibly) a helper `HasTombstone(id)` for the ingest guard. |
| `internal/cli/ingest.go` / `internal/store` ingest guard | Reject ids with a `tombstone` event. |
| `internal/cli/doctor.go` | Orphan finding text recommends `reconcile`. |
| CLI usage/help + `RUNNER.md` | List `reconcile` in the verb table. |

## 6. Testing

- **Eligibility matrix:** one table-driven test per predicate, each proving a single failing predicate refuses (worktree-present, index-present, HEAD-present, history-present, status doing/done/failed, non-empty claim fields, extra event verbs, inbound dep, `reviews`/`fixes` reference).
- **Happy path:** ingest a batch, abort before card commit to synthesise an orphan, `reconcile --execute`, assert: task row gone, deps gone, tombstone event present with correct snapshot, event chain still verifies (`VerifyChain`).
- **Idempotent retry:** run `--execute` twice; second run reports "already reconciled", exits 0, chain still valid.
- **Backup-failure path:** force a backup error; assert success exit + non-rollback message + DB still pruned.
- **ID-reuse guard:** after prune, `ingest` of the same id refuses citing the tombstone.
- **Dry-run:** asserts no mutation and that the printed plan matches what `--execute` then does.
- **Fail-closed git:** a git error during a predicate check yields ineligible, not "absent."

## 7. Accepted non-requirements / open notes

- **Disaster recovery of id-retirement:** if both `muster.db` and `backup.db` are lost and a pre-prune backup is restored, the orphan and the retired-id knowledge return. Accepted — this is whole-board loss, not in scope.
- **Two pre-existing issues surfaced during review** (tracked separately, not part of this build): `Store.Backup` removes the old backup before renaming the new (crash gap); and "backup after every mutation" is documented but only `done`/`fail` call `backupDB()`.

## Appendix — how this design was reached

**Web research (disposal semantics):** append-only stores delete via tombstone + compensating event, never row deletion (event-sourcing); soft-delete/tombstone beats hard-delete when audit/undo matter; Taskwarrior keeps "deleted" as a *state* and its dependency+delete interaction is a bug-magnet; GitHub gates real issue deletion behind admin + audit; Jira "Cancel" is a reversible terminal state distinct from "Delete"; destructive-CLI guidance says dry-run must show the same concrete decisions the real op makes; `git prune`/`gc` is the integrity-reconcile analog.

**Codex round 1 (`gpt-5.6-sol`, high):** reframed B as ingest-rollback; two entry points, prefer a dedicated verb over `doctor --fix`; reconcile refuses on any inbound dep; B needs no new status; don't `git rm` on the future cancel; "drifted" is too broad (SHA-drift stays `reimport`'s job); a safe orphan must be absent from HEAD, unclaimed, unreferenced; snapshot metadata into the tombstone; prevent id reuse.

**Codex round 2 (`gpt-5.6-sol`, high):** ruled Fork 1 = no commit, Fork 2 = standalone `reconcile`; confirmed single-phase atomicity dissolves commit-first/crash-resume; replaced the proposed `tombstones` table with the lighter event-ledger reuse guard; tightened the predicate to include git-index + reachable-history absence, a positive `status`/event-history allowlist, and `reviews`/`fixes` semantic-reference checks; specified idempotent retry + non-rollback backup-failure messaging; flagged the two pre-existing backup issues.
