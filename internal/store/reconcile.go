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
