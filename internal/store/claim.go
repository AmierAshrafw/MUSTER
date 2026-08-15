package store

import (
	"errors"
	"strings"
	"time"
)

// ErrDoingOccupied - one executor per checkout (D18): a doing row exists.
var ErrDoingOccupied = errors.New("doing occupied")

// NextEligible peeks the lowest-id inbox task for this session identity.
// Tier pinning is equality (Authority note 12); a task with harness ” accepts
// any harness. Read-only: the caller runs its slow checks (git dirty scan,
// HEAD card read) against this candidate, then calls ClaimTask.
func (s *Store) NextEligible(tier, harness string) (*Task, error) {
	return scanTask(s.db.QueryRow(`SELECT `+taskCols+` FROM tasks
		WHERE status = 'inbox' AND tier = ? AND (harness = '' OR harness = ?)
		ORDER BY id LIMIT 1`, tier, harness))
}

// ClaimTask atomically claims the given candidate: BEGIN IMMEDIATE, re-check
// the doing invariant, guarded UPDATE (status still inbox), claim event,
// COMMIT. Returns (false, nil) when the candidate was raced away or changed
// status - the caller loops back to NextEligible. Nothing slow runs inside
// the transaction (spec section 4).
func (s *Store) ClaimTask(id, claimedBy, headAtClaim, now string) (bool, error) {
	if err := s.beginImmediate(); err != nil {
		return false, err
	}
	rollback := func() { s.db.Exec("ROLLBACK") }

	var doing int
	if err := s.db.QueryRow(`SELECT COUNT(*) FROM tasks WHERE status = 'doing'`).Scan(&doing); err != nil {
		rollback()
		return false, err
	}
	if doing > 0 {
		rollback()
		return false, ErrDoingOccupied
	}
	res, err := s.db.Exec(`UPDATE tasks SET status = 'doing', claimed_at = ?, claimed_by = ?, head_at_claim = ?
		WHERE id = ? AND status = 'inbox'`, now, claimedBy, headAtClaim, id)
	if err != nil {
		rollback()
		return false, err
	}
	if n, _ := res.RowsAffected(); n != 1 {
		rollback()
		return false, nil
	}
	if err := appendEventOn(s.db, id, claimedBy, "claim", "", now); err != nil {
		rollback()
		return false, err
	}
	if _, err := s.db.Exec("COMMIT"); err != nil {
		rollback()
		return false, err
	}
	return true, nil
}

// beginImmediate takes the write lock up front so the select-then-update pair
// cannot interleave with another writer. SetMaxOpenConns(1) guarantees every
// statement between BEGIN and COMMIT runs on this same connection. Retries
// cover SQLITE_BUSY beyond busy_timeout (the losing racer waits, then wins the
// lock after the winner commits and simply finds the row already doing).
func (s *Store) beginImmediate() error {
	var err error
	for i := 0; i < 5; i++ {
		if _, err = s.db.Exec("BEGIN IMMEDIATE"); err == nil {
			return nil
		}
		if !strings.Contains(err.Error(), "locked") && !strings.Contains(err.Error(), "busy") {
			return err
		}
		time.Sleep(100 * time.Millisecond)
	}
	return err
}
