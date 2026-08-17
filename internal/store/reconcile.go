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
