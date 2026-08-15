package store

import (
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"fmt"
)

type Event struct {
	ID                                                     int64
	TaskID, Actor, Verb, Detail, CreatedAt, PrevHash, Hash string
}

func eventHash(prev, taskID, actor, verb, detail, createdAt string) string {
	sum := sha256.Sum256([]byte(prev + "\n" + taskID + "\n" + actor + "\n" + verb + "\n" + detail + "\n" + createdAt))
	return hex.EncodeToString(sum[:])
}

// execer covers *sql.DB, *sql.Tx and *sql.Conn-backed transactions so event
// appends compose into larger transactions (claim, done, cycle).
type execer interface {
	Exec(query string, args ...any) (sql.Result, error)
	QueryRow(query string, args ...any) *sql.Row
}

func appendEventOn(q execer, taskID, actor, verb, detail, createdAt string) error {
	var prev string
	err := q.QueryRow("SELECT hash FROM events ORDER BY id DESC LIMIT 1").Scan(&prev)
	if err == sql.ErrNoRows {
		prev = ""
	} else if err != nil {
		return err
	}
	h := eventHash(prev, taskID, actor, verb, detail, createdAt)
	_, err = q.Exec(`INSERT INTO events(task_id, actor, verb, detail, created_at, prev_hash, hash)
		VALUES (?, ?, ?, ?, ?, ?, ?)`, taskID, actor, verb, detail, createdAt, prev, h)
	return err
}

// AppendEvent appends one event as its own transaction.
func (s *Store) AppendEvent(taskID, actor, verb, detail, createdAt string) error {
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if err := appendEventOn(tx, taskID, actor, verb, detail, createdAt); err != nil {
		return err
	}
	return tx.Commit()
}

// Events returns a task's events in append order.
func (s *Store) Events(taskID string) ([]Event, error) {
	rows, err := s.db.Query(`SELECT id, task_id, actor, verb, detail, created_at, prev_hash, hash
		FROM events WHERE task_id = ? ORDER BY id`, taskID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Event
	for rows.Next() {
		var e Event
		if err := rows.Scan(&e.ID, &e.TaskID, &e.Actor, &e.Verb, &e.Detail, &e.CreatedAt, &e.PrevHash, &e.Hash); err != nil {
			return nil, err
		}
		out = append(out, e)
	}
	return out, rows.Err()
}

// ChainHead returns the newest event hash, or "" on an empty board.
func (s *Store) ChainHead() (string, error) {
	var h string
	err := s.db.QueryRow("SELECT hash FROM events ORDER BY id DESC LIMIT 1").Scan(&h)
	if err == sql.ErrNoRows {
		return "", nil
	}
	return h, err
}

// VerifyChain recomputes every hash in id order and checks linkage.
func (s *Store) VerifyChain() error {
	rows, err := s.db.Query(`SELECT id, task_id, actor, verb, detail, created_at, prev_hash, hash
		FROM events ORDER BY id`)
	if err != nil {
		return err
	}
	defer rows.Close()
	prev := ""
	for rows.Next() {
		var e Event
		if err := rows.Scan(&e.ID, &e.TaskID, &e.Actor, &e.Verb, &e.Detail, &e.CreatedAt, &e.PrevHash, &e.Hash); err != nil {
			return err
		}
		if e.PrevHash != prev {
			return fmt.Errorf("event %d: chain linkage broken (prev_hash %q, expected %q)", e.ID, e.PrevHash, prev)
		}
		want := eventHash(e.PrevHash, e.TaskID, e.Actor, e.Verb, e.Detail, e.CreatedAt)
		if e.Hash != want {
			return fmt.Errorf("event %d: chain hash mismatch", e.ID)
		}
		prev = e.Hash
	}
	return rows.Err()
}

// AttemptsSinceClaim counts attempt events newer than the task's newest claim
// event. A redo followed by a re-claim therefore starts a fresh window.
func (s *Store) AttemptsSinceClaim(taskID string) (int, error) {
	var n int
	err := s.db.QueryRow(`SELECT COUNT(*) FROM events
		WHERE task_id = ? AND verb = 'attempt'
		  AND id > COALESCE((SELECT MAX(id) FROM events WHERE task_id = ? AND verb = 'claim'), 0)`,
		taskID, taskID).Scan(&n)
	return n, err
}

// ClaimCount counts a task's claim events (recovery-probe gate: > 1 means a
// prior session claimed this task before the current one).
func (s *Store) ClaimCount(taskID string) (int, error) {
	var n int
	err := s.db.QueryRow(`SELECT COUNT(*) FROM events WHERE task_id = ? AND verb = 'claim'`, taskID).Scan(&n)
	return n, err
}
