# MUSTER `reconcile` Verb Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `muster reconcile <id>` — prune a single abandoned-ingest orphan row (a DB task row whose card was never committed) through the CLI, with a tombstone event for audit and an id-reuse guard.

**Architecture:** A new CLI verb evaluates deterministic git + DB eligibility predicates (fail-closed), prints a dry-run by default, and on `--execute` calls a single atomic `store.Reconcile` transaction that appends a `tombstone` event (metadata snapshot), deletes the task's outgoing `deps`, and deletes the task row. Events survive (no FK on `events.task_id`); the tombstone event is the durable record and the ingest reuse-guard. No git commit, no `backup.db` refresh — the prune is single-phase atomic, matching the `redo`/`promote` DB-only precedent.

**Tech Stack:** Go, `modernc.org/sqlite` (pure-Go, `foreign_keys=1`, WAL), the existing `store`/`gitx`/`cli` seams. Tests are Go `testing` at the unit tier (`gitx.Fake`, `store.Open` on a temp DB, `cli.newApp`) plus one process-tier smoke test against real git.

**Spec:** `docs/superpowers/specs/2026-08-17-muster-reconcile-design.md`

---

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `internal/gitx/gitx.go` | git seam | Add `IndexHas` + `PathHistory` to the `Git` interface and `Repo`. |
| `internal/gitx/fake.go` | git test double | Implement the two new methods on `Fake`. |
| `internal/store/reconcile.go` (new) | reconcile DB logic | `HasTombstone`, `InboundDeps`, `SemanticRefs`, `ReconcileEligibility`, `Reconcile` (the tx). |
| `internal/store/tasks.go` | ingest | Add the tombstone reuse-guard to `Ingest`. |
| `internal/cli/reconcile.go` (new) | reconcile verb | Arg/flag parse, git predicate checks, dry-run printer, execute path. |
| `internal/cli/app.go` | dispatch | Route `reconcile`. |
| `internal/cli/doctor.go` | diagnostics | Orphan-row finding recommends `reconcile`. |
| `internal/cli/templates/RUNNER.md` | runner docs | List `reconcile` in the verb reference. |
| Tests | — | `internal/gitx/gitx_test.go`, `internal/store/reconcile_test.go` (new), `internal/store/tasks_test.go`, `internal/cli/reconcile_test.go` (new), `internal/cli/doctor_test.go`, `test/process/reconcile_test.go` (new). |

**Verb semantics (single source of truth for the tasks below):**
- Eligibility (ALL must hold, fail-closed on any git error):
  - **git:** card absent from worktree (`os.Stat` fails) AND absent from index (`IndexHas`=false) AND no path history (`PathHistory` empty).
  - **DB:** `status IN ('backlog','inbox')`; all claim fields empty; event history is exactly one `ingest` from actor `shard` followed only by `promote` events; zero inbound `deps`; zero `reviews`/`fixes` references from other rows.
- `reconcile <id>` → dry-run: print each predicate group's verdict; exit 0 if eligible, 1 if not.
- `reconcile <id> --execute` → prune (re-validating DB predicates in-tx); exit 0.
- `--reason "<text>"` → recorded in the tombstone detail.
- Idempotent: task absent + tombstone present → "already reconciled", exit 0. Task absent + no tombstone → refuse (unknown id), exit 1.
- Tombstone event: `task_id=<id>`, `actor="human"`, `verb="tombstone"`, `detail="status=<s>;plan=<p>;card=<c>;sha=<sha>;deps=<comma-list>;reason=<r>"`.

---

## Task 1: gitx — `IndexHas` + `PathHistory`

**Files:**
- Modify: `internal/gitx/gitx.go` (interface + `Repo`)
- Modify: `internal/gitx/fake.go`
- Test: `internal/gitx/gitx_test.go`

- [ ] **Step 1: Write the failing test** (append to `internal/gitx/gitx_test.go`)

```go
func TestFakeIndexHasAndPathHistory(t *testing.T) {
	f := &Fake{
		IndexFiles:  map[string]bool{".muster/cards/staged.md": true},
		HistorySHAs: map[string][]string{".muster/cards/old.md": {"deadbeef"}},
	}
	if ok, _ := f.IndexHas(".muster/cards/staged.md"); !ok {
		t.Fatal("staged card must report in-index")
	}
	if ok, _ := f.IndexHas(".muster/cards/absent.md"); ok {
		t.Fatal("absent card must report not-in-index")
	}
	if h, _ := f.PathHistory(".muster/cards/old.md"); len(h) != 1 {
		t.Fatalf("committed card must have history, got %v", h)
	}
	if h, _ := f.PathHistory(".muster/cards/absent.md"); len(h) != 0 {
		t.Fatalf("never-committed card must have empty history, got %v", h)
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./internal/gitx/ -run TestFakeIndexHasAndPathHistory`
Expected: FAIL — `f.IndexHas undefined` / `Fake does not implement Git` (also `TestFakeImplementsGit` fails once the interface gains the methods).

- [ ] **Step 3: Add the two methods to the interface and `Repo`** (in `internal/gitx/gitx.go`)

In the `Git` interface, after `Untracked() ([]string, error)`:

```go
	IndexHas(relPath string) (bool, error)         // path tracked in the index (staged or committed)
	PathHistory(relPath string) ([]string, error)  // commit SHAs that ever touched relPath, newest first
```

After the `Untracked` method on `Repo`:

```go
func (r *Repo) IndexHas(relPath string) (bool, error) {
	out, err := r.git("-c", "core.autocrlf=false", "ls-files", "--", relPath)
	if err != nil {
		return false, err
	}
	return strings.TrimSpace(out) != "", nil
}

func (r *Repo) PathHistory(relPath string) ([]string, error) {
	return r.lines("-c", "core.autocrlf=false", "log", "--format=%H", "--", relPath)
}
```

- [ ] **Step 4: Implement the two methods on `Fake`** (in `internal/gitx/fake.go`)

Add two fields to the `Fake` struct (after `UntrackedList`):

```go
	IndexFiles  map[string]bool
	HistorySHAs map[string][]string
```

Add the methods (after `Untracked`):

```go
func (f *Fake) IndexHas(rel string) (bool, error)       { return f.IndexFiles[rel], nil }
func (f *Fake) PathHistory(rel string) ([]string, error) { return f.HistorySHAs[rel], nil }
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `go test ./internal/gitx/`
Expected: PASS (both `TestFakeIndexHasAndPathHistory` and `TestFakeImplementsGit`).

- [ ] **Step 6: Commit**

```bash
git add internal/gitx/gitx.go internal/gitx/fake.go internal/gitx/gitx_test.go
git commit -m "feat(gitx): add IndexHas and PathHistory for reconcile predicates"
```

---

## Task 2: store — reconcile read-side helpers

**Files:**
- Create: `internal/store/reconcile.go`
- Test: `internal/store/reconcile_test.go` (new)

- [ ] **Step 1: Write the failing test** (`internal/store/reconcile_test.go`)

```go
package store

import "testing"

func TestReconcileReadHelpers(t *testing.T) {
	s := open(t)
	// impl + a review that references it via reviews, + a dependent
	must(t, s.Ingest([]IngestTask{
		row("p-01-a", "impl", "any"),
		{Task: Task{ID: "p-02-r", Plan: "p", Seq: 2, Type: "review", Tier: "strong",
			CardPath: ".muster/cards/p-02-r.md", FrontmatterSHA: "sha", Reviews: "p-01-a"},
			Deps: []string{"p-01-a"}},
	}, "shard", "2026-01-01T00:00:00Z"))

	if has, _ := s.HasTombstone("p-01-a"); has {
		t.Fatal("no tombstone yet")
	}
	inbound, _ := s.InboundDeps("p-01-a")
	if len(inbound) != 1 || inbound[0] != "p-02-r" {
		t.Fatalf("inbound deps: %v", inbound)
	}
	refs, _ := s.SemanticRefs("p-01-a")
	if len(refs) != 1 || refs[0] != "p-02-r" {
		t.Fatalf("semantic refs: %v", refs)
	}
}
```

Note: `open`, `must`, and `row` are the existing helpers in `internal/store/tasks_test.go` (`open(t)` opens a temp store; `row(id,type,tier)` builds an `IngestTask`; `must(t, err)` fatals on error). If `must` does not exist in the test package, add it once: `func must(t *testing.T, err error) { t.Helper(); if err != nil { t.Fatal(err) } }`.

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./internal/store/ -run TestReconcileReadHelpers`
Expected: FAIL — `s.HasTombstone undefined`.

- [ ] **Step 3: Create `internal/store/reconcile.go` with the read helpers**

```go
package store

import (
	"fmt"
	"strings"
)

// ReconcileInfo is the read-side snapshot the dry-run prints and the tombstone
// detail is built from.
type ReconcileInfo struct {
	Task         *Task
	OutgoingDeps []string
}

// HasTombstone reports whether id has been reconciled (a tombstone event
// exists). Used by the ingest reuse-guard and the idempotent-retry path.
func (s *Store) HasTombstone(id string) (bool, error) {
	var n int
	err := s.db.QueryRow(`SELECT COUNT(*) FROM events WHERE task_id = ? AND verb = 'tombstone'`, id).Scan(&n)
	return n > 0, err
}

// InboundDeps returns the ids that depend_on id, sorted.
func (s *Store) InboundDeps(id string) ([]string, error) {
	rows, err := s.db.Query(`SELECT task_id FROM deps WHERE depends_on = ? ORDER BY task_id`, id)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var v string
		if err := rows.Scan(&v); err != nil {
			return nil, err
		}
		out = append(out, v)
	}
	return out, rows.Err()
}

// SemanticRefs returns the ids of rows that point at id through reviews or
// fixes (references that do not live in the deps table), sorted.
func (s *Store) SemanticRefs(id string) ([]string, error) {
	rows, err := s.db.Query(`SELECT id FROM tasks WHERE reviews = ? OR fixes = ? ORDER BY id`, id, id)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var v string
		if err := rows.Scan(&v); err != nil {
			return nil, err
		}
		out = append(out, v)
	}
	return out, rows.Err()
}

// pristineIngest reports whether an event slice is exactly one ingest (actor
// shard) followed only by promote events - the signature of a row that was
// ingested and never worked. Anything else (claim, attempt, done, fail, redo,
// reimport, reject, a non-shard ingest, or an empty slice) is not pristine.
func pristineIngest(evs []Event) bool {
	if len(evs) == 0 {
		return false
	}
	if evs[0].Verb != "ingest" || evs[0].Actor != "shard" {
		return false
	}
	for _, e := range evs[1:] {
		if e.Verb != "promote" {
			return false
		}
	}
	return true
}

// reconcileDetail builds the tombstone event detail: a deterministic snapshot
// that stays meaningful after the row is deleted.
func reconcileDetail(t *Task, deps []string, reason string) string {
	return fmt.Sprintf("status=%s;plan=%s;card=%s;sha=%s;deps=%s;reason=%s",
		t.Status, t.Plan, t.CardPath, t.FrontmatterSHA, strings.Join(deps, ","), reason)
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `go test ./internal/store/ -run TestReconcileReadHelpers`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/store/reconcile.go internal/store/reconcile_test.go
git commit -m "feat(store): reconcile read helpers (tombstone/inbound/semantic-ref)"
```

---

## Task 3: store — `ReconcileEligibility` + `Reconcile` transaction

**Files:**
- Modify: `internal/store/reconcile.go`
- Test: `internal/store/reconcile_test.go`

- [ ] **Step 1: Write the failing tests** (append to `internal/store/reconcile_test.go`)

```go
func TestReconcileEligibilityGates(t *testing.T) {
	s := open(t)
	must(t, s.Ingest([]IngestTask{row("p-01-a", "impl", "any")}, "shard", "2026-01-01T00:00:00Z"))
	// pristine backlog orphan -> eligible (no failures)
	info, fails, err := s.ReconcileEligibility("p-01-a")
	if err != nil || info == nil || len(fails) != 0 {
		t.Fatalf("expected eligible: info=%v fails=%v err=%v", info, fails, err)
	}
	// a claimed row -> ineligible
	mustExec(t, s, `UPDATE tasks SET status='doing', claimed_by='x' WHERE id='p-01-a'`)
	_, fails, _ = s.ReconcileEligibility("p-01-a")
	if len(fails) == 0 {
		t.Fatal("claimed/doing row must be ineligible")
	}
	// unknown id -> nil info, nil fails, nil err (caller checks HasTombstone)
	info, fails, err = s.ReconcileEligibility("nope")
	if info != nil || fails != nil || err != nil {
		t.Fatalf("unknown id: info=%v fails=%v err=%v", info, fails, err)
	}
}

func TestReconcilePrunesAndIsIdempotent(t *testing.T) {
	s := open(t)
	must(t, s.Ingest([]IngestTask{row("p-01-a", "impl", "any")}, "shard", "2026-01-01T00:00:00Z"))

	pruned, err := s.Reconcile("p-01-a", "human", "leftover smoke card", "2026-01-02T00:00:00Z")
	if err != nil || !pruned {
		t.Fatalf("first reconcile: pruned=%v err=%v", pruned, err)
	}
	if got, _ := s.Task("p-01-a"); got != nil {
		t.Fatal("row must be gone")
	}
	deps, _ := s.Deps("p-01-a")
	if len(deps) != 0 {
		t.Fatalf("deps must be gone: %v", deps)
	}
	// tombstone event present, chain still verifies
	evs, _ := s.Events("p-01-a")
	last := evs[len(evs)-1]
	if last.Verb != "tombstone" || last.Actor != "human" ||
		!strings.Contains(last.Detail, "leftover smoke card") {
		t.Fatalf("tombstone event wrong: %+v", last)
	}
	if err := s.VerifyChain(); err != nil {
		t.Fatalf("chain broken after prune: %v", err)
	}
	// second call is idempotent success (row already gone, tombstone present)
	pruned, err = s.Reconcile("p-01-a", "human", "", "2026-01-02T00:01:00Z")
	if err != nil || pruned {
		t.Fatalf("second reconcile should be idempotent no-op: pruned=%v err=%v", pruned, err)
	}
}

func TestReconcileRefusesNonPristineInTx(t *testing.T) {
	s := open(t)
	must(t, s.Ingest([]IngestTask{row("p-01-a", "impl", "any")}, "shard", "2026-01-01T00:00:00Z"))
	// give it a claim event -> not pristine
	must(t, s.AppendEvent("p-01-a", "claude/any", "claim", "", "2026-01-01T01:00:00Z"))
	if _, err := s.Reconcile("p-01-a", "human", "", "2026-01-02T00:00:00Z"); err == nil {
		t.Fatal("reconcile must refuse a non-pristine row in-tx")
	}
	if got, _ := s.Task("p-01-a"); got == nil {
		t.Fatal("row must survive a refused reconcile")
	}
}

func TestReconcileRefusesReferencedRow(t *testing.T) {
	s := open(t)
	// p-02-r references p-01-a via reviews AND depends_on (inbound dep + semantic ref)
	must(t, s.Ingest([]IngestTask{
		row("p-01-a", "impl", "any"),
		{Task: Task{ID: "p-02-r", Plan: "p", Seq: 2, Type: "review", Tier: "strong",
			CardPath: ".muster/cards/p-02-r.md", FrontmatterSHA: "sha", Reviews: "p-01-a"},
			Deps: []string{"p-01-a"}},
	}, "shard", "2026-01-01T00:00:00Z"))
	_, fails, err := s.ReconcileEligibility("p-01-a")
	if err != nil || len(fails) == 0 {
		t.Fatalf("referenced impl must be ineligible: fails=%v err=%v", fails, err)
	}
	if _, err := s.Reconcile("p-01-a", "human", "", "2026-01-02T00:00:00Z"); err == nil {
		t.Fatal("Reconcile must refuse a row referenced via deps/reviews")
	}
	if got, _ := s.Task("p-01-a"); got == nil {
		t.Fatal("referenced row must survive")
	}
}
```

Note: `strings` must be imported in the test file; `mustExec(t, s, sql)` is the existing helper in `tasks_test.go`. `TestReconcileRefusesReferencedRow` covers the inbound-dep and `reviews`/`fixes` refusal predicates (spec §6 matrix).

- [ ] **Step 2: Run tests to verify they fail**

Run: `go test ./internal/store/ -run 'TestReconcile'`
Expected: FAIL — `s.ReconcileEligibility undefined` / `s.Reconcile undefined`.

- [ ] **Step 3: Add `ReconcileEligibility` and `Reconcile`** (append to `internal/store/reconcile.go`)

```go
// ReconcileEligibility returns the read-side snapshot plus the list of failed
// DB-predicate messages (empty = DB-eligible). A nil info with nil error means
// no such row - the caller checks HasTombstone for the idempotent case.
func (s *Store) ReconcileEligibility(id string) (*ReconcileInfo, []string, error) {
	t, err := s.Task(id)
	if err != nil {
		return nil, nil, err
	}
	if t == nil {
		return nil, nil, nil
	}
	var fails []string
	if t.Status != "backlog" && t.Status != "inbox" {
		fails = append(fails, fmt.Sprintf("status is %s (must be backlog or inbox)", t.Status))
	}
	if t.HeadAtClaim != "" || t.ClaimedAt != "" || t.ClaimedBy != "" {
		fails = append(fails, "task has claim fields set (it was claimed at least once)")
	}
	evs, err := s.Events(id)
	if err != nil {
		return nil, nil, err
	}
	if !pristineIngest(evs) {
		fails = append(fails, "event history is not a pristine ingest (has claim/attempt/done/fail/redo/reimport/reject history)")
	}
	inbound, err := s.InboundDeps(id)
	if err != nil {
		return nil, nil, err
	}
	if len(inbound) > 0 {
		fails = append(fails, fmt.Sprintf("other tasks depend on it: %s", strings.Join(inbound, ", ")))
	}
	refs, err := s.SemanticRefs(id)
	if err != nil {
		return nil, nil, err
	}
	if len(refs) > 0 {
		fails = append(fails, fmt.Sprintf("other tasks reference it via reviews/fixes: %s", strings.Join(refs, ", ")))
	}
	deps, err := s.Deps(id)
	if err != nil {
		return nil, nil, err
	}
	return &ReconcileInfo{Task: t, OutgoingDeps: deps}, fails, nil
}

// Reconcile prunes a pristine abandoned-ingest orphan in ONE transaction:
// append a tombstone event snapshotting the row, delete its outgoing deps,
// delete the row. DB predicates are re-validated inside the tx (concurrent
// -change safety net). Returns true if the row was pruned now, false if it was
// already gone with a tombstone present (idempotent success); a missing row
// with no tombstone is an error.
func (s *Store) Reconcile(id, actor, reason, now string) (bool, error) {
	tx, err := s.db.Begin()
	if err != nil {
		return false, err
	}
	defer tx.Rollback()

	t, err := scanTask(tx.QueryRow(`SELECT `+taskCols+` FROM tasks WHERE id = ?`, id))
	if err != nil {
		return false, err
	}
	if t == nil {
		var n int
		if err := tx.QueryRow(`SELECT COUNT(*) FROM events WHERE task_id = ? AND verb = 'tombstone'`, id).Scan(&n); err != nil {
			return false, err
		}
		if n > 0 {
			return false, nil // already reconciled
		}
		return false, fmt.Errorf("%s: not on the board", id)
	}

	// re-validate DB predicates in-tx
	if t.Status != "backlog" && t.Status != "inbox" {
		return false, fmt.Errorf("%s: status %s is not backlog/inbox", id, t.Status)
	}
	if t.HeadAtClaim != "" || t.ClaimedAt != "" || t.ClaimedBy != "" {
		return false, fmt.Errorf("%s: task was claimed", id)
	}
	evRows, err := tx.Query(`SELECT id, task_id, actor, verb, detail, created_at, prev_hash, hash
		FROM events WHERE task_id = ? ORDER BY id`, id)
	if err != nil {
		return false, err
	}
	var evs []Event
	for evRows.Next() {
		var e Event
		if err := evRows.Scan(&e.ID, &e.TaskID, &e.Actor, &e.Verb, &e.Detail, &e.CreatedAt, &e.PrevHash, &e.Hash); err != nil {
			evRows.Close()
			return false, err
		}
		evs = append(evs, e)
	}
	evRows.Close()
	if err := evRows.Err(); err != nil {
		return false, err
	}
	if !pristineIngest(evs) {
		return false, fmt.Errorf("%s: event history is not a pristine ingest", id)
	}
	var inbound int
	if err := tx.QueryRow(`SELECT COUNT(*) FROM deps WHERE depends_on = ?`, id).Scan(&inbound); err != nil {
		return false, err
	}
	if inbound > 0 {
		return false, fmt.Errorf("%s: other tasks depend on it", id)
	}
	var refs int
	if err := tx.QueryRow(`SELECT COUNT(*) FROM tasks WHERE reviews = ? OR fixes = ?`, id, id).Scan(&refs); err != nil {
		return false, err
	}
	if refs > 0 {
		return false, fmt.Errorf("%s: other tasks reference it via reviews/fixes", id)
	}

	// snapshot outgoing deps, then tombstone + delete, one tx
	depRows, err := tx.Query(`SELECT depends_on FROM deps WHERE task_id = ? ORDER BY depends_on`, id)
	if err != nil {
		return false, err
	}
	var deps []string
	for depRows.Next() {
		var d string
		if err := depRows.Scan(&d); err != nil {
			depRows.Close()
			return false, err
		}
		deps = append(deps, d)
	}
	depRows.Close()
	if err := depRows.Err(); err != nil {
		return false, err
	}

	if err := appendEventOn(tx, id, actor, "tombstone", reconcileDetail(t, deps, reason), now); err != nil {
		return false, err
	}
	if _, err := tx.Exec(`DELETE FROM deps WHERE task_id = ?`, id); err != nil {
		return false, err
	}
	if _, err := tx.Exec(`DELETE FROM tasks WHERE id = ?`, id); err != nil {
		return false, err
	}
	if err := tx.Commit(); err != nil {
		return false, err
	}
	return true, nil
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `go test ./internal/store/ -run 'TestReconcile'`
Expected: PASS (all three).

- [ ] **Step 5: Commit**

```bash
git add internal/store/reconcile.go internal/store/reconcile_test.go
git commit -m "feat(store): Reconcile transaction + eligibility (tombstone, atomic prune)"
```

---

## Task 4: store — ingest tombstone reuse-guard

**Files:**
- Modify: `internal/store/tasks.go` (the first loop of `Ingest`)
- Test: `internal/store/reconcile_test.go`

- [ ] **Step 1: Write the failing test** (append to `internal/store/reconcile_test.go`)

```go
func TestIngestRefusesReconciledID(t *testing.T) {
	s := open(t)
	must(t, s.Ingest([]IngestTask{row("p-01-a", "impl", "any")}, "shard", "2026-01-01T00:00:00Z"))
	if _, err := s.Reconcile("p-01-a", "human", "", "2026-01-02T00:00:00Z"); err != nil {
		t.Fatal(err)
	}
	err := s.Ingest([]IngestTask{row("p-01-a", "impl", "any")}, "shard", "2026-01-03T00:00:00Z")
	if err == nil || !strings.Contains(err.Error(), "reconciled") {
		t.Fatalf("re-ingest of a reconciled id must refuse, got: %v", err)
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./internal/store/ -run TestIngestRefusesReconciledID`
Expected: FAIL — re-ingest currently succeeds (the row was deleted, so the existing `already on the board` check does not fire).

- [ ] **Step 3: Add the guard** (in `internal/store/tasks.go`, inside `Ingest`'s first `for _, it := range batch` loop, immediately after the existing `if exists > 0 { return ... }` block)

```go
		var tombstoned int
		if err := tx.QueryRow(`SELECT COUNT(*) FROM events WHERE task_id = ? AND verb = 'tombstone'`, it.Task.ID).Scan(&tombstoned); err != nil {
			return err
		}
		if tombstoned > 0 {
			return fmt.Errorf("%s: id was reconciled (retired) - pick a new id", it.Task.ID)
		}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `go test ./internal/store/`
Expected: PASS (new test + no regressions).

- [ ] **Step 5: Commit**

```bash
git add internal/store/tasks.go internal/store/reconcile_test.go
git commit -m "feat(store): ingest refuses a reconciled (tombstoned) id"
```

---

## Task 5: cli — `reconcile` verb (dry-run + execute) and dispatch

**Files:**
- Create: `internal/cli/reconcile.go`
- Modify: `internal/cli/app.go` (dispatch)
- Test: `internal/cli/reconcile_test.go` (new)

- [ ] **Step 1: Write the failing tests** (`internal/cli/reconcile_test.go`)

```go
package cli

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// orphan seeds a pristine abandoned-ingest orphan: a DB row whose card is
// absent from worktree, index, and history (the Fake defaults supply absence).
func orphan(t *testing.T, a *App, id string) {
	t.Helper()
	seed(t, a, id, "impl", "any", "backlog")
}

func TestReconcileDryRunEligible(t *testing.T) {
	a, _, out := newApp(t)
	orphan(t, a, "p-01-a")
	if code := a.Dispatch("reconcile", []string{"p-01-a"}); code != 0 {
		t.Fatalf("code %d: %s", code, out.String())
	}
	s := out.String()
	if !strings.Contains(s, "ELIGIBLE") || !strings.Contains(s, "--execute") {
		t.Fatalf("dry-run output: %s", s)
	}
	// dry-run must NOT mutate
	if row, _ := a.St.Task("p-01-a"); row == nil {
		t.Fatal("dry-run must not delete the row")
	}
}

func TestReconcileExecutePrunes(t *testing.T) {
	a, _, out := newApp(t)
	orphan(t, a, "p-01-a")
	if code := a.Dispatch("reconcile", []string{"p-01-a", "--execute", "--reason", "leftover"}); code != 0 {
		t.Fatalf("code %d: %s", code, out.String())
	}
	if row, _ := a.St.Task("p-01-a"); row != nil {
		t.Fatal("row must be pruned")
	}
	if !strings.Contains(out.String(), "Reconciled p-01-a") {
		t.Fatalf("out: %s", out.String())
	}
	// idempotent re-run
	out.Reset()
	if code := a.Dispatch("reconcile", []string{"p-01-a", "--execute"}); code != 0 {
		t.Fatalf("idempotent code %d: %s", code, out.String())
	}
	if !strings.Contains(out.String(), "already reconciled") {
		t.Fatalf("idempotent out: %s", out.String())
	}
}

func TestReconcileRefusesNonOrphan(t *testing.T) {
	a, fake, out := newApp(t)
	orphan(t, a, "p-01-a")
	// card committed => has history => ineligible
	fake.HistorySHAs = map[string][]string{".muster/cards/p-01-a.md": {"abc123"}}
	if code := a.Dispatch("reconcile", []string{"p-01-a", "--execute"}); code != 1 {
		t.Fatalf("must refuse, code %d: %s", code, out.String())
	}
	if row, _ := a.St.Task("p-01-a"); row == nil {
		t.Fatal("refused reconcile must not prune")
	}
	if !strings.Contains(out.String(), "git history") {
		t.Fatalf("out: %s", out.String())
	}
}

func TestReconcileUnknownID(t *testing.T) {
	a, _, out := newApp(t)
	if code := a.Dispatch("reconcile", []string{"nope"}); code != 1 {
		t.Fatalf("code %d", code)
	}
	if !strings.Contains(out.String(), "MUSTER refuse:") {
		t.Fatalf("out: %s", out.String())
	}
}

func TestReconcileRefusesWorktreePresent(t *testing.T) {
	a, _, out := newApp(t)
	orphan(t, a, "p-01-a")
	// card is present in the worktree -> not an abandoned ingest
	if err := os.WriteFile(filepath.Join(a.Dir, "cards", "p-01-a.md"), []byte("body"), 0o644); err != nil {
		t.Fatal(err)
	}
	if code := a.Dispatch("reconcile", []string{"p-01-a", "--execute"}); code != 1 {
		t.Fatalf("worktree-present must refuse, code %d: %s", code, out.String())
	}
	if row, _ := a.St.Task("p-01-a"); row == nil {
		t.Fatal("refused reconcile must not prune")
	}
	if !strings.Contains(out.String(), "worktree") {
		t.Fatalf("out: %s", out.String())
	}
}

func TestReconcileRefusesIndexPresent(t *testing.T) {
	a, fake, out := newApp(t)
	orphan(t, a, "p-01-a")
	// card is staged in the index (absent from worktree + history)
	fake.IndexFiles = map[string]bool{".muster/cards/p-01-a.md": true}
	if code := a.Dispatch("reconcile", []string{"p-01-a", "--execute"}); code != 1 {
		t.Fatalf("index-present must refuse, code %d: %s", code, out.String())
	}
	if row, _ := a.St.Task("p-01-a"); row == nil {
		t.Fatal("refused reconcile must not prune")
	}
	if !strings.Contains(out.String(), "index") {
		t.Fatalf("out: %s", out.String())
	}
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `go test ./internal/cli/ -run TestReconcile`
Expected: FAIL — `reconcile` dispatches to the default refuse branch (`verb "reconcile" is not implemented yet`).

- [ ] **Step 3: Create `internal/cli/reconcile.go`**

```go
package cli

import (
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"muster/internal/store"
)

// reconcileGitFails returns the failed git-side predicate messages for t's
// card. Any unexpected git error is returned (fail closed) - the caller must
// refuse, never treat an error as "absent".
func (a *App) reconcileGitFails(t *store.Task) ([]string, error) {
	var fails []string
	abs := filepath.Join(a.Root, filepath.FromSlash(t.CardPath))
	if _, err := os.Stat(abs); err == nil {
		fails = append(fails, fmt.Sprintf("card present in the worktree (%s)", t.CardPath))
	} else if !os.IsNotExist(err) {
		return nil, err
	}
	inIndex, err := a.G.IndexHas(t.CardPath)
	if err != nil {
		return nil, err
	}
	if inIndex {
		fails = append(fails, "card is staged in the git index")
	}
	hist, err := a.G.PathHistory(t.CardPath)
	if err != nil {
		return nil, err
	}
	if len(hist) > 0 {
		fails = append(fails, fmt.Sprintf("card has git history (%d commit(s)) - it was committed before", len(hist)))
	}
	return fails, nil
}

// Reconcile implements `muster reconcile <id> [--execute] [--reason <text>]`.
func (a *App) Reconcile(args []string) int {
	var id string
	if len(args) > 0 && !strings.HasPrefix(args[0], "-") {
		id = args[0]
		args = args[1:]
	}
	fs := flag.NewFlagSet("reconcile", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	execute := fs.Bool("execute", false, "")
	reason := fs.String("reason", "", "")
	if err := fs.Parse(args); err != nil {
		return a.refuse("reconcile: %v", err)
	}
	if id == "" {
		return a.refuse("reconcile needs exactly one task id.")
	}

	t, err := a.St.Task(id)
	if err != nil {
		return a.refuse("reconcile query failed: %v", err)
	}
	if t == nil {
		if has, _ := a.St.HasTombstone(id); has {
			a.pf("Reconcile: %s already reconciled (tombstone present). Nothing to do.", id)
			return 0
		}
		return a.refuse("no task '%s' on the board.", id)
	}

	gitFails, err := a.reconcileGitFails(t)
	if err != nil {
		return a.refuse("reconcile git check failed: %v (treating as ineligible)", err)
	}
	info, dbFails, err := a.St.ReconcileEligibility(id)
	if err != nil {
		return a.refuse("reconcile db check failed: %v", err)
	}
	if info == nil { // row vanished between the Task() read and here (concurrent prune by another process)
		if has, _ := a.St.HasTombstone(id); has {
			a.pf("Reconcile: %s already reconciled (tombstone present). Nothing to do.", id)
			return 0
		}
		return a.refuse("no task '%s' on the board.", id)
	}
	fails := append(gitFails, dbFails...)

	if !*execute {
		a.pf("Reconcile dry-run for %s (status %s):", id, t.Status)
		if len(fails) == 0 {
			a.pf("  ELIGIBLE - abandoned-ingest orphan.")
			a.pf("  Would delete: task row %s + %d dep edge(s) %v", id, len(info.OutgoingDeps), info.OutgoingDeps)
			a.pf("  Would write a tombstone event (the id then refuses re-ingest).")
			a.pf("Run: muster reconcile %s --execute", id)
			return 0
		}
		a.pf("  INELIGIBLE - not a safe orphan:")
		for _, f := range fails {
			a.pf("    - %s", f)
		}
		return 1
	}

	if len(fails) > 0 {
		a.pf("MUSTER refuse: %s is not a safe orphan:", id)
		for _, f := range fails {
			a.pf("    - %s", f)
		}
		return 1
	}
	pruned, err := a.St.Reconcile(id, "human", *reason, a.iso())
	if err != nil {
		return a.refuse("reconcile failed: %v", err)
	}
	if !pruned {
		a.pf("Reconcile: %s already reconciled (tombstone present). Nothing to do.", id)
		return 0
	}
	a.pf("Reconciled %s: row and %d dep edge(s) pruned; tombstone written. The id is retired - re-ingesting it will refuse.", id, len(info.OutgoingDeps))
	return 0
}
```

- [ ] **Step 4: Wire dispatch** (in `internal/cli/app.go`, add a case before `default:`)

```go
	case "reconcile":
		return a.Reconcile(args)
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `go test ./internal/cli/ -run TestReconcile`
Expected: PASS (all four).

- [ ] **Step 6: Commit**

```bash
git add internal/cli/reconcile.go internal/cli/app.go internal/cli/reconcile_test.go
git commit -m "feat(cli): reconcile verb (dry-run default, --execute prunes orphan)"
```

---

## Task 6: cli — doctor recommends `reconcile`

**Files:**
- Modify: `internal/cli/doctor.go` (the "no file on disk" finding)
- Test: `internal/cli/doctor_test.go`

- [ ] **Step 1: Write the failing test** (append to `internal/cli/doctor_test.go`)

```go
func TestDoctorOrphanRecommendsReconcile(t *testing.T) {
	a, _, out := newApp(t)
	// DB row with no card file on disk = the abandoned-ingest orphan
	seed(t, a, "p-01-a", "impl", "any", "backlog")
	a.Dispatch("doctor", nil)
	s := out.String()
	if !strings.Contains(s, "no file on disk") || !strings.Contains(s, "reconcile p-01-a") {
		t.Fatalf("doctor should recommend reconcile:\n%s", s)
	}
}
```

Note: confirm `strings` is imported in `doctor_test.go`; add it if missing.

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./internal/cli/ -run TestDoctorOrphanRecommendsReconcile`
Expected: FAIL — current message has no "reconcile" text.

- [ ] **Step 3: Update the finding** (in `internal/cli/doctor.go`, the `os.Stat` branch of the per-row loop)

Replace:

```go
			if _, err := os.Stat(abs); err != nil {
				fail("cards", "%s has no file on disk (%s)", t.ID, t.CardPath)
			}
```

with:

```go
			if _, err := os.Stat(abs); err != nil {
				fail("cards", "%s has no file on disk (%s) - if it is an abandoned ingest, run: muster reconcile %s", t.ID, t.CardPath, t.ID)
			}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `go test ./internal/cli/ -run TestDoctor`
Expected: PASS (new test + existing doctor tests).

- [ ] **Step 5: Commit**

```bash
git add internal/cli/doctor.go internal/cli/doctor_test.go
git commit -m "feat(cli): doctor recommends reconcile for abandoned-ingest orphans"
```

---

## Task 7: process smoke test + RUNNER docs

**Files:**
- Create: `test/process/reconcile_test.go`
- Modify: `internal/cli/templates/RUNNER.md`

- [ ] **Step 1: Write the process smoke test** (`test/process/reconcile_test.go`)

This exercises the real `Repo` (`IndexHas`/`PathHistory`) and the real DB end-to-end, using the existing process-tier harness in `test/process/main_test.go` (`newRepo`, `muster`, `mustMuster`, `implCardP2`, `integrationCardP2`) and `v1fixture.go` (`write`, `run`). The file MUST carry the `//go:build process` tag every file in that package has (`main_test.go:1`), and the real binary's ingest path guard requires **git-canonicalized absolute** card paths (`main_test.go:161-164`), not relative ones.

The orphan we prune is the integration card `p2-99-int`: after `ingest` inserts both rows (uncommitted), delete `p2-99-int.md` from the worktree. The integration has no inbound deps and nothing references it via `reviews`/`fixes`, so it is a clean orphan; the impl `p2-01-hello` is not (the integration depends on it).

```go
//go:build process

package process

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestReconcileProcess(t *testing.T) {
	repo := newRepo(t)
	mustMuster(t, repo, "init")
	gitRoot := strings.TrimSpace(run(t, repo, "git", "rev-parse", "--show-toplevel"))

	// write both cards and ingest (canonicalized paths) - but DO NOT commit them
	write(t, repo, ".muster/cards/p2-01-hello.md", implCardP2)
	write(t, repo, ".muster/cards/p2-99-int.md", integrationCardP2)
	mustMuster(t, repo, "ingest",
		filepath.Join(gitRoot, ".muster", "cards", "p2-01-hello.md"),
		filepath.Join(gitRoot, ".muster", "cards", "p2-99-int.md"))

	// simulate an abandoned ingest of the integration card: remove it from the
	// worktree; it was never staged or committed -> absent from worktree, index, history
	if err := os.Remove(filepath.Join(repo, ".muster", "cards", "p2-99-int.md")); err != nil {
		t.Fatal(err)
	}

	// dry-run: eligible
	out := mustMuster(t, repo, "reconcile", "p2-99-int")
	assertContains(t, out, "ELIGIBLE")

	// execute: pruned
	out = mustMuster(t, repo, "reconcile", "p2-99-int", "--execute")
	assertContains(t, out, "Reconciled p2-99-int")

	// re-ingest of the retired id refuses (tombstone guard); ingest exits 1
	write(t, repo, ".muster/cards/p2-99-int.md", integrationCardP2)
	out, code := muster(t, repo, nil, "ingest",
		filepath.Join(gitRoot, ".muster", "cards", "p2-99-int.md"))
	if code != 1 {
		t.Fatalf("re-ingest of a retired id must exit 1, got %d:\n%s", code, out)
	}
	if !strings.Contains(out, "reconciled") && !strings.Contains(out, "retired") {
		t.Fatalf("re-ingest refusal should name the retired id:\n%s", out)
	}
}
```

- [ ] **Step 2: Run the process test**

Run: `go test -tags process ./test/process/ -run TestReconcileProcess`
Expected: PASS.

- [ ] **Step 3: Document the verb** (in `internal/cli/templates/RUNNER.md`, the verb reference/table)

Add a row/line describing:

```
reconcile <id> [--execute] [--reason <text>]
    Prune ONE abandoned-ingest orphan (a DB row whose card was never committed).
    Dry-run by default; --execute performs the prune. Refuses anything that is
    not a pristine, unreferenced, never-worked orphan. The id is retired
    afterward (re-ingest refuses). doctor points here for "no file on disk".
```

- [ ] **Step 4: Full test sweep**

Run (unit tier — the `process` package is build-tagged and excluded here):
`go test ./...`
Then run the process tier explicitly:
`go test -tags process ./test/process`
Expected: PASS in both.

- [ ] **Step 5: Commit**

```bash
git add test/process/reconcile_test.go internal/cli/templates/RUNNER.md
git commit -m "test(process): end-to-end reconcile smoke; docs(runner): list reconcile"
```

---

## Self-Review

**Spec coverage** (spec §3 behaviour → task):
- §3.1 command surface + flags → Task 5. ✓
- §3.2 eligibility predicate (git absence trio) → Task 1 (methods) + Task 5 (`reconcileGitFails`). ✓
- §3.2 eligibility predicate (DB: status/claim/pristine-history/inbound-deps/semantic-refs) → Task 2 + Task 3 (`ReconcileEligibility`, re-checked in `Reconcile`). ✓
- §3.3 action (tombstone event → delete deps → delete task, one tx, no commit, no backup) → Task 3. ✓
- §3.4 dry-run output → Task 5. ✓
- §3.5 idempotency/retry → Task 3 (`Reconcile` returns false on already-gone) + Task 5 (CLI messaging). ✓
- §3.6 ingest reuse-guard → Task 4. ✓
- §3.7 doctor integration → Task 6. ✓
- Real-git coverage of the new gitx methods → Task 7 (process test). ✓

**Placeholder scan:** no TBD/TODO; every code step shows complete code. The one plumbing-adaptation note (Task 7) names the exact files to read and fixes the contract, not the mechanism. ✓

**Type consistency:** `store.Reconcile(id, actor, reason, now string) (bool, error)`, `store.ReconcileEligibility(id) (*ReconcileInfo, []string, error)`, `store.HasTombstone(id) (bool, error)`, `store.InboundDeps`/`SemanticRefs(id) ([]string, error)`, `gitx…IndexHas(rel) (bool, error)`, `gitx…PathHistory(rel) ([]string, error)`, `App.Reconcile(args) int`, `App.reconcileGitFails(t) ([]string, error)` — names and signatures are used identically across tasks. Event verb `"tombstone"` and actor `"human"` are consistent between Task 3 (write), Task 4 (guard query), and Task 5 (idempotent check). ✓

**Deferred (not in this plan, per spec §4):** `cancel`/`cancelled`, hard `rm`, cascade, `flush --plan`, tombstones table, git gravestone, `backup.db` refresh on reconcile. ✓
